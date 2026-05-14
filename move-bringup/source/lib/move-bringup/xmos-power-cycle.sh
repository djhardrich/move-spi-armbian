#!/bin/sh
# Tell the XMOS to power-cycle Move on reboot. Mirrors /etc/init.d/
# xmos-power-cycle from the stock image. The XMOS delays the cycle by
# ~100 ms; we halt the system immediately so the next init step does
# not race the power transition.
SENTINEL=/run/move-power-cycle
[ -e "$SENTINEL" ] || exit 0
[ -x /opt/move/MoveXmosPower ] || exit 0
/opt/move/MoveXmosPower power-cycle 2>/dev/null || true
exec /sbin/halt -d -f
