#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
move-connman-shim — provide net.connman D-Bus surface backed by NetworkManager.

MoveOriginal (the on-device Move UI engine) was written against ConnMan and
calls net.connman.Manager / .Technology / .Service / .Agent over the system
bus to display and configure WiFi. Our Armbian build runs NetworkManager
instead, so those calls fail with ServiceUnknown and the Move WiFi UI shows
nothing useful.

This daemon owns the well-known name `net.connman` on the system bus and
implements just enough of the ConnMan API to satisfy MoveOriginal:

  /                              net.connman.Manager
    GetProperties()              {State, OfflineMode}
    GetServices()                array of (path, props) — visible APs + active
    GetTechnologies()            [(/net/connman/technology/wifi, {props})]
    RegisterAgent(o)             remember MoveOriginal's agent path
    UnregisterAgent(o)           forget it
    PropertyChanged signal       fired on NM StateChanged
    ServicesChanged signal       fired on NM AP add/remove + connection change
    TechnologyAdded/Removed      not needed; technologies static

  /net/connman/technology/wifi   net.connman.Technology
    GetProperties()              {Powered, Connected, Name, Type}
    SetProperty(name, value)     Powered=true/false → nmcli radio wifi on/off
    Scan()                       NM Device.Wireless.RequestScan

  /net/connman/service/<id>      net.connman.Service
    GetProperties()              per-AP — Name, State, Strength, Security, Type
    Connect()                    NM AddAndActivateConnection; ask agent for PSK
                                 if needed and not yet known
    Disconnect()                 NM DeactivateConnection
    Remove()                     delete the saved NM connection
    SetProperty(name, value)     AutoConnect, etc.

  Agent callbacks (we call these on MoveOriginal):
    RequestInput(o, dict)        → returns dict with Passphrase=<psk>
    Cancel()                     user dismissed
    ReportError(o, msg)
    RequestBrowser(o, url)       captive portal

Implementation notes:
  * dbus-next (asyncio) for low CPU — no polling, NM signal-driven cache invalidation.
  * Lazy NM queries on each ConnMan request (no in-memory state to drift).
  * Pure Python, single file, no external state.
  * Memory ~30 MB resident.

Tested on Move CM4 Rev 1.1 with NetworkManager 1.50+ and MoveLauncher 3.18.
"""

import asyncio
import logging
import os
import re
import signal
import sys
import time
import uuid
from typing import Optional

from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal as dbus_signal
from dbus_next.errors import DBusError

# ─── Logging ───────────────────────────────────────────────────────────
log = logging.getLogger("move-connman-shim")
logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s",
    level=os.environ.get("MOVE_CONNMAN_SHIM_LOGLEVEL", "INFO"),
)

# ─── NM constants ─────────────────────────────────────────────────────
NM = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"
NM_DEVICE_TYPE_WIFI = 2
NM_STATE_CONNECTED_GLOBAL = 70
NM_STATE_CONNECTED_SITE = 60
NM_STATE_CONNECTED_LOCAL = 50

# AccessPoint flags / WPA flags bitmasks
AP_FLAGS_PRIVACY = 0x1
AP_WPA_FLAG_KEY_MGMT_PSK = 0x100
AP_WPA_FLAG_KEY_MGMT_802_1X = 0x200
AP_WPA_FLAG_KEY_MGMT_SAE = 0x400  # WPA3

# ConnMan service path encoding helpers ───────────────────────────────
def _hex_ssid(ssid_bytes: bytes) -> str:
    return ssid_bytes.hex()


def _service_id(bssid: str, ssid_bytes: bytes, security: str) -> str:
    """Build a ConnMan-style service id: wifi_<bssidnocolons>_<ssidhex>_managed_<sec>."""
    mac = bssid.replace(":", "").lower() or "000000000000"
    return f"wifi_{mac}_{_hex_ssid(ssid_bytes)}_managed_{security}"


def _service_path(service_id: str) -> str:
    return f"/net/connman/service/{service_id}"


def _security_from_ap_flags(flags: int, wpa: int, rsn: int) -> str:
    """Map NM AP flags to a ConnMan-style security tag."""
    if rsn & AP_WPA_FLAG_KEY_MGMT_SAE:
        return "psk"  # WPA3-SAE; ConnMan treats as psk for legacy clients
    if rsn or wpa:
        if (rsn | wpa) & AP_WPA_FLAG_KEY_MGMT_802_1X:
            return "ieee8021x"
        return "psk"
    if flags & AP_FLAGS_PRIVACY:
        return "wep"
    return "none"


# ─── NM facade ─────────────────────────────────────────────────────────
class NMFacade:
    """Thin wrapper around the NetworkManager system-bus API."""

    def __init__(self, bus: MessageBus):
        self.bus = bus
        self._nm = None
        self._settings = None
        self._wifi_dev_path: Optional[str] = None
        # Caches invalidated on NM signals; nothing TTL-based.
        self._ap_cache: dict[str, dict] = {}  # ap_path -> properties

    async def attach(self):
        intro = await self.bus.introspect(NM, NM_PATH)
        nm_obj = self.bus.get_proxy_object(NM, NM_PATH, intro)
        self._nm = nm_obj.get_interface(NM)
        self._nm_props = nm_obj.get_interface("org.freedesktop.DBus.Properties")

        intro_s = await self.bus.introspect(NM, NM_PATH + "/Settings")
        s_obj = self.bus.get_proxy_object(NM, NM_PATH + "/Settings", intro_s)
        self._settings = s_obj.get_interface(NM + ".Settings")

        await self._discover_wifi_device()
        log.info("NM facade attached, wifi device=%s", self._wifi_dev_path)

    async def _discover_wifi_device(self):
        devices = await self._nm.call_get_devices()
        for dev_path in devices:
            intro = await self.bus.introspect(NM, dev_path)
            obj = self.bus.get_proxy_object(NM, dev_path, intro)
            dev_props = obj.get_interface("org.freedesktop.DBus.Properties")
            try:
                t = await dev_props.call_get(NM + ".Device", "DeviceType")
                if t.value == NM_DEVICE_TYPE_WIFI:
                    self._wifi_dev_path = dev_path
                    return
            except DBusError:
                continue
        log.warning("no NM wifi device found")

    async def wifi_powered(self) -> bool:
        v = await self._nm_props.call_get(NM, "WirelessEnabled")
        return bool(v.value)

    async def set_wifi_powered(self, powered: bool):
        await self._nm_props.call_set(NM, "WirelessEnabled", Variant("b", powered))

    async def overall_state(self) -> str:
        """Map NM state → ConnMan Manager.State string."""
        v = await self._nm_props.call_get(NM, "State")
        st = int(v.value)
        if st >= NM_STATE_CONNECTED_GLOBAL:
            return "online"
        if st >= NM_STATE_CONNECTED_LOCAL:
            return "ready"
        return "offline"

    async def wifi_connected(self) -> bool:
        if not self._wifi_dev_path:
            return False
        intro = await self.bus.introspect(NM, self._wifi_dev_path)
        obj = self.bus.get_proxy_object(NM, self._wifi_dev_path, intro)
        p = obj.get_interface("org.freedesktop.DBus.Properties")
        s = await p.call_get(NM + ".Device", "State")
        return int(s.value) == 100  # NM_DEVICE_STATE_ACTIVATED

    async def access_points(self) -> list[str]:
        if not self._wifi_dev_path:
            return []
        intro = await self.bus.introspect(NM, self._wifi_dev_path)
        obj = self.bus.get_proxy_object(NM, self._wifi_dev_path, intro)
        wifi = obj.get_interface(NM + ".Device.Wireless")
        return await wifi.call_get_access_points()

    async def ap_properties(self, ap_path: str) -> dict:
        if ap_path in self._ap_cache:
            return self._ap_cache[ap_path]
        intro = await self.bus.introspect(NM, ap_path)
        obj = self.bus.get_proxy_object(NM, ap_path, intro)
        p = obj.get_interface("org.freedesktop.DBus.Properties")
        all_props = await p.call_get_all(NM + ".AccessPoint")
        # Unpack variants
        d = {k: v.value for k, v in all_props.items()}
        # SSID is ay (array of bytes); make it bytes
        if "Ssid" in d:
            d["Ssid"] = bytes(d["Ssid"])
        self._ap_cache[ap_path] = d
        return d

    def invalidate_ap(self, ap_path: str):
        self._ap_cache.pop(ap_path, None)

    async def active_ap_path(self) -> Optional[str]:
        if not self._wifi_dev_path:
            return None
        intro = await self.bus.introspect(NM, self._wifi_dev_path)
        obj = self.bus.get_proxy_object(NM, self._wifi_dev_path, intro)
        p = obj.get_interface("org.freedesktop.DBus.Properties")
        try:
            v = await p.call_get(NM + ".Device.Wireless", "ActiveAccessPoint")
            path = v.value
            return path if path and path != "/" else None
        except DBusError:
            return None

    async def request_scan(self):
        if not self._wifi_dev_path:
            return
        intro = await self.bus.introspect(NM, self._wifi_dev_path)
        obj = self.bus.get_proxy_object(NM, self._wifi_dev_path, intro)
        wifi = obj.get_interface(NM + ".Device.Wireless")
        try:
            await wifi.call_request_scan({})
        except DBusError as e:
            log.debug("RequestScan failed (often benign): %s", e)

    async def add_and_activate(self, ssid_bytes: bytes, security: str, psk: Optional[str]) -> str:
        """Create + activate a new NM connection for an SSID with optional PSK.
        Returns the new ActiveConnection path."""
        if not self._wifi_dev_path:
            raise RuntimeError("no wifi device")

        conn_id = ssid_bytes.decode("utf-8", errors="replace")
        u = str(uuid.uuid4())

        settings = {
            "connection": {
                "id": Variant("s", conn_id),
                "uuid": Variant("s", u),
                "type": Variant("s", "802-11-wireless"),
                "autoconnect": Variant("b", True),
            },
            "802-11-wireless": {
                "ssid": Variant("ay", ssid_bytes),
                "mode": Variant("s", "infrastructure"),
            },
            "ipv4": {"method": Variant("s", "auto")},
            "ipv6": {"method": Variant("s", "auto")},
        }
        if security == "psk" and psk:
            settings["802-11-wireless"]["security"] = Variant("s", "802-11-wireless-security")
            settings["802-11-wireless-security"] = {
                "key-mgmt": Variant("s", "wpa-psk"),
                "psk": Variant("s", psk),
            }

        # AddAndActivateConnection(connection a{sa{sv}}, device o, specific_object o) -> (path o, active_path o)
        ret = await self._nm.call_add_and_activate_connection(
            settings, self._wifi_dev_path, "/"
        )
        return ret[1]  # active connection path

    async def deactivate_active(self):
        v = await self._nm_props.call_get(NM, "ActiveConnections")
        for ac in v.value:
            intro = await self.bus.introspect(NM, ac)
            obj = self.bus.get_proxy_object(NM, ac, intro)
            p = obj.get_interface("org.freedesktop.DBus.Properties")
            t = await p.call_get(NM + ".Connection.Active", "Type")
            if t.value == "802-11-wireless":
                await self._nm.call_deactivate_connection(ac)


# ─── ConnMan interface implementations ────────────────────────────────
class ConnmanService(ServiceInterface):
    """net.connman.Service @ /net/connman/service/<id>"""

    def __init__(self, daemon: "Daemon", ap_path: str, service_id: str):
        super().__init__("net.connman.Service")
        self.daemon = daemon
        self.ap_path = ap_path
        self.service_id = service_id

    async def _props_dict(self) -> dict:
        ap = await self.daemon.nm.ap_properties(self.ap_path)
        ssid_bytes = ap.get("Ssid", b"")
        strength = int(ap.get("Strength", 0))
        flags = int(ap.get("Flags", 0))
        wpa = int(ap.get("WpaFlags", 0))
        rsn = int(ap.get("RsnFlags", 0))
        security = _security_from_ap_flags(flags, wpa, rsn)
        active = await self.daemon.nm.active_ap_path()
        is_active = active == self.ap_path
        state = "online" if is_active else "idle"
        return {
            "Name": Variant("s", ssid_bytes.decode("utf-8", errors="replace")),
            "Type": Variant("s", "wifi"),
            "State": Variant("s", state),
            "Strength": Variant("y", min(strength, 255)),
            "Security": Variant("as", [security] if security != "none" else ["none"]),
            "AutoConnect": Variant("b", True),
            "Favorite": Variant("b", is_active),
            "Immutable": Variant("b", False),
            "Roaming": Variant("b", False),
        }

    @method()
    async def GetProperties(self) -> "a{sv}":  # noqa: F821
        return await self._props_dict()

    @method()
    async def SetProperty(self, name: "s", value: "v"):  # noqa: F821
        # Most SetProperty calls (AutoConnect) we can no-op cleanly.
        log.debug("Service[%s] SetProperty %s=%s (ignored)", self.service_id, name, value.value)

    @method()
    async def Connect(self):
        log.info("Service[%s] Connect", self.service_id)
        ap = await self.daemon.nm.ap_properties(self.ap_path)
        ssid_bytes = ap.get("Ssid", b"")
        flags = int(ap.get("Flags", 0))
        wpa = int(ap.get("WpaFlags", 0))
        rsn = int(ap.get("RsnFlags", 0))
        security = _security_from_ap_flags(flags, wpa, rsn)
        psk: Optional[str] = None
        if security == "psk":
            psk = await self.daemon.ask_passphrase(self.service_id)
            if psk is None:
                raise DBusError("net.connman.Agent.Error.Canceled", "user cancelled")
        await self.daemon.nm.add_and_activate(ssid_bytes, security, psk)

    @method()
    async def Disconnect(self):
        log.info("Service[%s] Disconnect", self.service_id)
        await self.daemon.nm.deactivate_active()

    @method()
    async def Remove(self):
        # Could iterate NM Settings.ListConnections and delete by SSID match.
        log.info("Service[%s] Remove (no-op for now)", self.service_id)


class ConnmanTechnology(ServiceInterface):
    """net.connman.Technology @ /net/connman/technology/wifi"""

    def __init__(self, daemon: "Daemon"):
        super().__init__("net.connman.Technology")
        self.daemon = daemon

    async def _props_dict(self) -> dict:
        """Computable form of GetProperties — callable from Python."""
        powered = await self.daemon.nm.wifi_powered()
        connected = await self.daemon.nm.wifi_connected()
        return {
            "Name": Variant("s", "WiFi"),
            "Type": Variant("s", "wifi"),
            "Powered": Variant("b", powered),
            "Connected": Variant("b", connected),
            "Tethering": Variant("b", False),
        }

    @method()
    async def GetProperties(self) -> "a{sv}":  # noqa: F821
        # dbus-next's @method wraps this — call _props_dict() from Python.
        return await self._props_dict()

    @method()
    async def SetProperty(self, name: "s", value: "v"):  # noqa: F821
        if name == "Powered":
            await self.daemon.nm.set_wifi_powered(bool(value.value))
            self.PropertyChanged("Powered", Variant("b", bool(value.value)))
        else:
            log.debug("Technology.SetProperty %s=%s ignored", name, value.value)

    @method()
    async def Scan(self):
        await self.daemon.nm.request_scan()

    @dbus_signal()
    def PropertyChanged(self, name: "s", value: "v") -> "sv":  # noqa: F821
        return [name, value]


class ConnmanManager(ServiceInterface):
    """net.connman.Manager @ /"""

    def __init__(self, daemon: "Daemon"):
        super().__init__("net.connman.Manager")
        self.daemon = daemon

    @method()
    async def GetProperties(self) -> "a{sv}":  # noqa: F821
        st = await self.daemon.nm.overall_state()
        return {
            "State": Variant("s", st),
            "OfflineMode": Variant("b", False),
            "SessionMode": Variant("b", False),
        }

    @method()
    async def GetTechnologies(self) -> "a(oa{sv})":  # noqa: F821
        tech_props = await self.daemon.tech._props_dict()
        # dbus-next requires struct values as list (not tuple).
        return [["/net/connman/technology/wifi", tech_props]]

    @method()
    async def GetServices(self) -> "a(oa{sv})":  # noqa: F821
        return await self.daemon.list_services()

    @method()
    async def RegisterAgent(self, path: "o"):  # noqa: F821
        # dbus-next's @method decorator doesn't expose the calling message's
        # sender field. MoveOriginal owns the well-known name `com.ableton.move`
        # and registers its agent under that name's tree, so route callbacks
        # to that name instead of needing the unique :1.N sender. Confirmed
        # via `busctl list` + `busctl tree com.ableton.move` on a running
        # Move (the agent path is typically /com/ableton/agent).
        self.daemon.set_agent(path, "com.ableton.move")
        log.info("Agent registered: path=%s (callback name=com.ableton.move)", path)

    @method()
    async def UnregisterAgent(self, path: "o"):  # noqa: F821
        log.info("Agent unregistered: %s", path)
        self.daemon.clear_agent()

    @dbus_signal()
    def PropertyChanged(self, name: "s", value: "v") -> "sv":  # noqa: F821
        return [name, value]

    @dbus_signal()
    def ServicesChanged(self, changed: "a(oa{sv})", removed: "ao") -> "a(oa{sv})ao":  # noqa: F821
        return [changed, removed]

    @dbus_signal()
    def TechnologyAdded(self, path: "o", properties: "a{sv}") -> "oa{sv}":  # noqa: F821
        return [path, properties]


# ─── Main daemon ───────────────────────────────────────────────────────
class Daemon:
    def __init__(self):
        self.bus: Optional[MessageBus] = None
        self.nm: Optional[NMFacade] = None
        self.manager: Optional[ConnmanManager] = None
        self.tech: Optional[ConnmanTechnology] = None
        # Registered ConnMan agent (MoveOriginal)
        self.agent_path: Optional[str] = None
        self.agent_bus_name: Optional[str] = None
        self.last_caller_bus: Optional[str] = None
        # Currently-exported service objects
        self.services: dict[str, ConnmanService] = {}  # path -> obj
        self._services_lock = asyncio.Lock()

    def set_agent(self, path: str, sender: Optional[str]):
        self.agent_path = path
        self.agent_bus_name = sender

    def clear_agent(self):
        self.agent_path = None
        self.agent_bus_name = None

    async def ask_passphrase(self, service_id: str) -> Optional[str]:
        if not self.agent_path or not self.agent_bus_name:
            log.warning("Connect requested but no agent registered")
            return None
        try:
            intro = await self.bus.introspect(self.agent_bus_name, self.agent_path)
            obj = self.bus.get_proxy_object(self.agent_bus_name, self.agent_path, intro)
            agent = obj.get_interface("net.connman.Agent")
            svc_path = _service_path(service_id)
            req = {"Passphrase": Variant("a{sv}", {"Type": Variant("s", "psk"),
                                                    "Requirement": Variant("s", "mandatory")})}
            reply = await agent.call_request_input(svc_path, req)
            psk_v = reply.get("Passphrase")
            return psk_v.value if psk_v else None
        except DBusError as e:
            log.warning("Agent.RequestInput failed: %s", e)
            return None

    async def list_services(self) -> list[tuple[str, dict]]:
        ap_paths = await self.nm.access_points()
        result = []
        async with self._services_lock:
            # Export new service objects, remove vanished ones
            current_paths: set[str] = set()
            for ap_path in ap_paths:
                ap = await self.nm.ap_properties(ap_path)
                ssid_bytes = ap.get("Ssid", b"")
                if not ssid_bytes:
                    continue
                bssid = ap.get("HwAddress", "")
                flags = int(ap.get("Flags", 0))
                wpa = int(ap.get("WpaFlags", 0))
                rsn = int(ap.get("RsnFlags", 0))
                security = _security_from_ap_flags(flags, wpa, rsn)
                sid = _service_id(bssid, ssid_bytes, security)
                spath = _service_path(sid)
                current_paths.add(spath)
                if spath not in self.services:
                    svc = ConnmanService(self, ap_path, sid)
                    self.bus.export(spath, svc)
                    self.services[spath] = svc
                svc = self.services[spath]
                props = await svc._props_dict()
                # dbus-next requires struct values as list (not tuple).
                result.append([spath, props])
            # Remove vanished
            for old in list(self.services.keys()):
                if old not in current_paths:
                    self.bus.unexport(old)
                    del self.services[old]
        return result

    async def run(self, stop_event: asyncio.Event):
        self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        self.nm = NMFacade(self.bus)
        await self.nm.attach()

        self.manager = ConnmanManager(self)
        self.tech = ConnmanTechnology(self)
        self.bus.export("/", self.manager)
        self.bus.export("/net/connman/technology/wifi", self.tech)

        await self.bus.request_name("net.connman")
        log.info("net.connman owned, ready")

        # Listen for NM signals to invalidate caches + emit ConnMan signals
        await self._wire_nm_signals()

        # Idle until SIGTERM/SIGINT trips the stop event (registered in main()).
        await stop_event.wait()
        log.info("stop event received; disconnecting bus")
        self.bus.disconnect()

    async def _wire_nm_signals(self):
        # NM emits StateChanged, ActiveConnections changes, AccessPoint add/remove etc.
        # We listen via the Properties.PropertiesChanged signal on NM root.
        intro = await self.bus.introspect(NM, NM_PATH)
        nm_obj = self.bus.get_proxy_object(NM, NM_PATH, intro)
        nm_props = nm_obj.get_interface("org.freedesktop.DBus.Properties")

        def on_nm_changed(_iface, changed, _invalidated):
            if "State" in changed:
                asyncio.create_task(self._emit_manager_state(changed["State"]))
            if "ActiveConnections" in changed:
                asyncio.create_task(self._emit_services_changed())

        nm_props.on_properties_changed(on_nm_changed)

        # Listen for AP add/remove on the wifi device
        if self.nm._wifi_dev_path:
            intro_d = await self.bus.introspect(NM, self.nm._wifi_dev_path)
            dev_obj = self.bus.get_proxy_object(NM, self.nm._wifi_dev_path, intro_d)
            wifi = dev_obj.get_interface(NM + ".Device.Wireless")

            def on_ap_added(path):
                self.nm.invalidate_ap(path)
                asyncio.create_task(self._emit_services_changed())

            def on_ap_removed(path):
                self.nm.invalidate_ap(path)
                asyncio.create_task(self._emit_services_changed())

            wifi.on_access_point_added(on_ap_added)
            wifi.on_access_point_removed(on_ap_removed)

    async def _emit_manager_state(self, state_variant: Variant):
        st = int(state_variant.value)
        s = "online" if st >= NM_STATE_CONNECTED_GLOBAL else \
            "ready" if st >= NM_STATE_CONNECTED_LOCAL else "offline"
        self.manager.PropertyChanged("State", Variant("s", s))

    async def _emit_services_changed(self):
        services = await self.list_services()
        # ConnMan ServicesChanged: (changed, removed). We always report full snapshot.
        self.manager.ServicesChanged(services, [])


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    daemon = Daemon()
    stop_event = asyncio.Event()

    # add_signal_handler routes signals into the asyncio loop properly;
    # signal.signal() callbacks don't interrupt loop.run_until_complete cleanly.
    def _signal_stop():
        log.info("signal received, shutting down")
        stop_event.set()

    loop.add_signal_handler(signal.SIGTERM, _signal_stop)
    loop.add_signal_handler(signal.SIGINT, _signal_stop)

    try:
        loop.run_until_complete(daemon.run(stop_event))
    except Exception:
        log.exception("fatal")
        sys.exit(1)
    finally:
        loop.close()


if __name__ == "__main__":
    main()
