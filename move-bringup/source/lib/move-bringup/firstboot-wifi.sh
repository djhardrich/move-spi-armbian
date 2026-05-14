#!/bin/sh
# firstboot-wifi.sh - On first boot, read /boot/firmware/move-wifi.txt
# (populated by the operator after flashing the SD) and turn it into a
# permanent NetworkManager connection. Then shred the source file so
# the PSK does not linger on a FAT partition that any OS can mount.

set -eu

CFG=/boot/firmware/move-wifi.txt
[ -f "$CFG" ] || exit 0

# Default values; can be overridden by CFG.
SSID=""
PSK=""
COUNTRY=""
CONNECTION_NAME="move-wifi"
HIDDEN="false"

# shellcheck source=/dev/null
. "$CFG"

if [ -z "$SSID" ] || [ -z "$PSK" ]; then
    echo "firstboot-wifi: SSID or PSK empty in $CFG; aborting" >&2
    exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
KEYFILE="/etc/NetworkManager/system-connections/${CONNECTION_NAME}.nmconnection"

mkdir -p /etc/NetworkManager/system-connections
umask 077

cat > "$KEYFILE" <<EOF
[connection]
id=${CONNECTION_NAME}
uuid=${UUID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${SSID}
hidden=${HIDDEN}

[wifi-security]
key-mgmt=wpa-psk
psk=${PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$KEYFILE"
chown root:root "$KEYFILE"

# Regulatory domain (needed on 5 GHz / power-limited channels)
if [ -n "$COUNTRY" ]; then
    iw reg set "$COUNTRY" 2>/dev/null || true
    # Persist via NM
    if [ -d /etc/NetworkManager/conf.d ]; then
        cat > /etc/NetworkManager/conf.d/wifi-country.conf <<EOF
[device]
wifi.scan-rand-mac-address=no
EOF
    fi
fi

# Wipe credentials file from FAT so it can't be read off a swapped SD.
shred -u "$CFG" 2>/dev/null || rm -f "$CFG"

# Tell NM to pick up the new keyfile and connect.
if systemctl is-active --quiet NetworkManager.service; then
    nmcli connection reload 2>/dev/null || true
    nmcli connection up "$CONNECTION_NAME" 2>/dev/null || true
fi

echo "firstboot-wifi: configured connection '$CONNECTION_NAME' (ssid='$SSID')"
exit 0
