#!/bin/sh
# Tell the XMOS to power Move down. Mirrors /etc/init.d/xmos-power-off
# from the stock image. Invoked by move-xmos-shutdown.service at the
# poweroff/halt transition; harmless on a reboot (xmos-power-cycle runs
# next and takes precedence).
[ -x /opt/move/MoveXmosPower ] || exit 0
/opt/move/MoveXmosPower power-off 2>/dev/null || true
exit 0
