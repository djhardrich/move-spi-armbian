#!/usr/bin/env python3
"""
move-update-dbus — com.ableton.update D-Bus service for Armbian Move.

Replaces UpdateDBusService (stock binary) which crashes on Armbian because
it calls libubootenv to read/write U-Boot environment variables that don't
exist on our SD-based Armbian system.

Implements two methods on com.ableton.update / /com/ableton/Update:
  registerSuccessfulStartup() — no-op (stock: commits A/B boot slot)
  factoryReset(as)           — wipes /var/lib/move-data/ subtrees by category
"""

import asyncio
import grp
import logging
import os
import pwd
import shutil
import subprocess
import sys

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method
from dbus_next import BusType

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [update-dbus] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

DATA_ROOT = "/var/lib/move-data"

CATEGORY_MAP = {
    "UserData":    "UserData",
    "Settings":    "settings",
    "CoreLibrary": "CoreLibrary",
}


class UpdateService(ServiceInterface):
    def __init__(self):
        super().__init__("com.ableton.update")

    @method()
    def registerSuccessfulStartup(self):
        """No-op: stock implementation commits A/B boot slot via libubootenv."""
        log.info("registerSuccessfulStartup() — no-op on Armbian")

    @method()
    def factoryReset(self, categories: "as"):
        log.info("factoryReset(%s)", categories)
        subprocess.run(
            ["systemctl", "stop", "move-launcher.service", "move-web.service"],
            capture_output=True
        )
        for cat in categories:
            if cat not in CATEGORY_MAP:
                log.warning("factoryReset: unknown category %r — skipping", cat)
                continue
            target = os.path.join(DATA_ROOT, CATEGORY_MAP[cat])
            if os.path.exists(target):
                log.info("wiping %s", target)
                shutil.rmtree(target, ignore_errors=True)
            if cat == "UserData":
                os.makedirs(target, exist_ok=True)
                try:
                    uid = pwd.getpwnam("ableton").pw_uid
                    gid = grp.getgrnam("users").gr_gid
                    os.chown(target, uid, gid)
                    os.chmod(target, 0o2775)
                except Exception as e:
                    log.warning("could not chown UserData: %s", e)

        subprocess.run(
            ["systemctl", "start", "move-launcher.service", "move-web.service"],
            capture_output=True
        )
        log.info("factoryReset done")


async def main():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    service = UpdateService()
    bus.export("/com/ableton/Update", service)
    await bus.request_name("com.ableton.update")
    log.info("com.ableton.update ready at /com/ableton/Update")
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(main())
