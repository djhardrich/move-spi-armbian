#!/usr/bin/env python3
"""Minimal UNIX-socket stub for /tmp/swupdateprog.

Ableton's MoveControlModeHandler links libswupdate and calls
`progress_ipc_connect()` on startup. Without a listener at
/tmp/swupdateprog the connect() spam-retries forever, and
MoveControlModeHandler never progresses to opening /dev/ablspi0.0 —
which leaves MoveLauncher stuck on the boot splash forever.

On stock AbletonOS the real `swupdate` daemon creates this socket. We
can't run upstream swupdate as-is because the Debian build of it is
compiled with -DCONFIG_SIGNED_IMAGES and refuses to start without a
public key file. Rather than carry a signing key + configuration we
don't actually want, this script just creates the socket, accepts
connections, and never sends progress messages. MoveControlMode's
progress thread blocks on recv() forever — which is fine, it runs on
a side thread and the main thread proceeds past the swupdate
dependency to open /dev/ablspi0.0 and drive the audio loop.

A real swupdate stand-in would matter only if you want the device to
auto-update over the network; for our use case where firmware comes
in through MoveFirmwareUpdater on demand, the stub is enough.
"""

import os
import socket

PATH = "/tmp/swupdateprog"

try:
    os.unlink(PATH)
except FileNotFoundError:
    pass

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(PATH)
os.chmod(PATH, 0o666)
sock.listen(64)

# Hold references so accepted sockets aren't garbage-collected (which
# would close the fd and unblock the client's recv() with EOF, prompting
# a reconnect storm). Idle clients sit in recv() until process exit.
clients = []

while True:
    conn, _ = sock.accept()
    clients.append(conn)
