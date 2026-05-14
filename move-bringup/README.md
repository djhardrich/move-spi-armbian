# move-bringup + ablspi-dkms

Debian source package emitting two `.deb`s:

- **`ablspi-dkms`** — kernel module for the Move's CM ↔ XMOS SPI link,
  installed via DKMS so it rebuilds against every new kernel.
- **`move-bringup`** — userspace glue: `ableton` user, `ablspi` group,
  udev rule, DBus system policy + service files, modules-load.d entry,
  systemd units for MoveLauncher / MoveWebService / the USB-Ethernet NCM
  gadget / the XMOS power sequencer, and the RT-thread tuning helper.

## Build

```sh
cd port/move-bringup
sudo apt install build-essential debhelper dh-dkms devscripts
dpkg-buildpackage -us -uc -b
ls ../*.deb
# ablspi-dkms_1.0.0-1_all.deb
# move-bringup_1.0.0-1_arm64.deb
```

## Install (on the target Debian arm64 image)

```sh
sudo apt install linux-headers-arm64        # so DKMS can build the module
sudo dpkg -i ablspi-dkms_*.deb move-bringup_*.deb
sudo apt -f install                         # pull dbus, systemd-sysv, etc.

# Populate /opt/move from your existing Move (rsync over SSH or copy
# from the official Ableton update payload).
rsync -aHAX root@move.local:/opt/move/ /opt/move/

# Bring up the Move-side libraries that aren't in Debian:
sudo mkdir -p /opt/move/lib
sudo rsync -aHAX root@move.local:/usr/lib/libc++.so.1        /opt/move/lib/
sudo rsync -aHAX root@move.local:/usr/lib/libXSDBusCpp.so   /opt/move/lib/
sudo rsync -aHAX root@move.local:/usr/lib/libXTCMalloc.so   /opt/move/lib/
sudo rsync -aHAX root@move.local:/usr/lib/libubootenv.so.0  /opt/move/lib/
sudo rsync -aHAX root@move.local:/usr/lib/libswupdate.so.0.1 /opt/move/lib/

# Drop a ld.so.conf entry so the runtime finds them:
echo "/opt/move/lib" | sudo tee /etc/ld.so.conf.d/move.conf
sudo ldconfig

# Fix unversioned SONAMEs that the Move binaries expect but Debian
# packages as versioned-only:
for f in libusb-1.0.so libmp3lame.so; do
    soname_versioned=$(ls /usr/lib/aarch64-linux-gnu/${f}.[0-9]* | head -1)
    sudo ln -sf "$soname_versioned" "/usr/lib/aarch64-linux-gnu/$f"
done

# Enable services and reboot.
sudo systemctl enable --now move-usb-gadget.service
sudo systemctl enable --now move-launcher.service
sudo systemctl enable --now move-web.service
sudo systemctl enable        move-xmos-shutdown.service
sudo reboot
```

## Layout

```
move-bringup/
├── debian/
│   ├── ablspi-dkms.dkms      DKMS manifest, $MODULE_VERSION resolved from changelog
│   ├── changelog
│   ├── compat                debhelper compat 13
│   ├── control               two binary packages from one source
│   ├── copyright             GPL-2.0+
│   ├── move-bringup.install  dh_install manifest
│   ├── move-bringup.postinst create user/group, reload udev/systemd/dbus
│   ├── move-bringup.prerm    stop services
│   ├── move-bringup.postrm   purge handler (preserves user/group, prints note)
│   ├── rules                 dh + dh-dkms; copies src/ablspi/ to /usr/src/
│   └── source/format         3.0 (native)
├── source/                   files staged into the image by dh_install
│   ├── etc/
│   │   ├── dbus-1/system.d/move.conf
│   │   ├── modules-load.d/ablspi.conf
│   │   └── udev/rules.d/50-ablspi.rules
│   ├── lib/
│   │   ├── move-bringup/                     helper scripts (chmod +x)
│   │   │   ├── rt-tune.sh                    SCHED_FIFO + CPU pinning
│   │   │   ├── setup-usb-network-gadget.sh   NCM gadget via configfs
│   │   │   ├── xmos-power-cycle.sh           reboot hook
│   │   │   └── xmos-power-off.sh             poweroff hook
│   │   └── systemd/system/
│   │       ├── move-launcher.service         /opt/move/MoveLauncher
│   │       ├── move-usb-gadget.service       configfs gadget setup
│   │       ├── move-web.service              /opt/move/MoveWebService
│   │       └── move-xmos-shutdown.service    XMOS power sequencing at shutdown
│   └── usr/share/dbus-1/system-services/
│       ├── com.ableton.system.service
│       └── com.ableton.update.service
└── src/ablspi/               in-tree copy of the kernel module
    ├── ablspi.c
    ├── Kbuild
    └── Makefile
```

## Notes

- The `ableton:1000` UID and `ablspi:1000` GID are intentional matches
  with the stock AbletonOS image so that `/data/UserData/*` ownership
  survives a migration to Debian. If the UIDs are already in use, the
  postinst falls back to dynamically allocated system UIDs and warns.
- The kernel module loads via `/etc/modules-load.d/ablspi.conf`, and
  udev applies `GROUP="ablspi"` ownership to `/dev/ablspi0.0` as soon
  as the driver probes. The `move-launcher.service` has a
  `ConditionPathExists=/dev/ablspi0.0` so it waits for the device.
- `move-xmos-shutdown.service` runs at the `shutdown.target` transition
  and dispatches to `xmos-power-off.sh` (poweroff) and
  `xmos-power-cycle.sh` (reboot, gated by `/run/move-power-cycle`).
