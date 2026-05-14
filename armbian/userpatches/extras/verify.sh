#!/bin/sh
# verify.sh - post-flash sanity check for an Armbian Move image.
#
# Run on the freshly booted target (Pi 4 CM4 or Pi 5 CM5):
#   scp verify.sh root@move.local:/tmp/
#   ssh root@move.local 'sh /tmp/verify.sh'
#
# Exits 0 if everything checks out, non-zero on any failure. Each test
# prints PASS / FAIL / WARN with a one-line context so you can grep the
# output for the first problem.

set -u
ok=0; warn=0; fail=0
PASS() { echo "PASS  $1";  ok=$((ok+1)); }
WARN() { echo "WARN  $1";  warn=$((warn+1)); }
FAIL() { echo "FAIL  $1";  fail=$((fail+1)); }

# ── Kernel identity ─────────────────────────────────────────────────────
KREL=$(uname -r)
echo "----- Kernel: $KREL ($(uname -m)) -----"
case "$(uname -r)" in
    *PREEMPT_RT*|*rt*) PASS "PREEMPT_RT kernel running" ;;
    *)                 FAIL "kernel is not PREEMPT_RT — fragment merge likely failed" ;;
esac

# /proc/config.gz is present if our fragment landed (we set IKCONFIG=y).
if [ -r /proc/config.gz ]; then
    PASS "/proc/config.gz is exposed (IKCONFIG=y from fragment)"
    for opt in CONFIG_PREEMPT_RT=y CONFIG_HZ_1000=y \
               CONFIG_RTC_DRV_PCF85063=y \
               CONFIG_USB_DWC2=m CONFIG_USB_CONFIGFS_NCM=y \
               CONFIG_IWLMVM=m CONFIG_CFG80211=m \
               CONFIG_SPI_BCM2835=m CONFIG_I2C_BCM2835=m \
               CONFIG_IRQ_FORCED_THREADING=y; do
        if zgrep -qx "$opt" /proc/config.gz; then
            PASS "kernel has $opt"
        else
            FAIL "kernel missing $opt"
        fi
    done
    # RT_GROUP_SCHED must be OFF for audio. Anything other than "is not
    # set" means our fragment didn't take.
    if zgrep -qx "# CONFIG_RT_GROUP_SCHED is not set" /proc/config.gz; then
        PASS "CONFIG_RT_GROUP_SCHED is disabled (audio-safe)"
    elif zgrep -qx "CONFIG_RT_GROUP_SCHED=y" /proc/config.gz; then
        FAIL "CONFIG_RT_GROUP_SCHED=y — RT threads will be throttled by cgroup bandwidth"
    else
        WARN "CONFIG_RT_GROUP_SCHED status unclear in /proc/config.gz"
    fi
else
    WARN "/proc/config.gz absent — cannot verify kernel options"
fi

# Runtime RT tuning
echo "----- RT runtime tuning -----"
rt_runtime=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo "?")
case "$rt_runtime" in
    -1)        PASS "sched_rt_runtime_us = -1 (no RT throttling)" ;;
    950000|?)  WARN "sched_rt_runtime_us = $rt_runtime (default cap — audio may underrun)" ;;
    *)         WARN "sched_rt_runtime_us = $rt_runtime (non-default)" ;;
esac

# Check that the audio group has rtprio + memlock via PAM limits
if [ -f /etc/security/limits.d/99-move-audio.conf ]; then
    PASS "PAM limits file for audio group installed"
else
    WARN "/etc/security/limits.d/99-move-audio.conf missing"
fi

# Cgroup v2 hierarchy check - we want cpu controller available
if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    if grep -qw cpu /sys/fs/cgroup/cgroup.controllers; then
        PASS "cgroup v2 with cpu controller (RT throttling can't bite without RT_GROUP_SCHED)"
    fi
fi

# Kernel pins: make sure apt cannot upgrade our RT kernel out from under us
echo "----- Kernel pinning -----"
if [ -f /etc/apt/preferences.d/99-move-kernel-pin.pref ]; then
    PASS "/etc/apt/preferences.d/99-move-kernel-pin.pref installed"
else
    FAIL "kernel-pin preferences file missing"
fi
held=$(apt-mark showhold 2>/dev/null)
for pkg in linux-image-current-bcm2711 linux-headers-current-bcm2711 \
           linux-dtb-current-bcm2711; do
    if dpkg -l "$pkg" >/dev/null 2>&1; then
        if echo "$held" | grep -qx "$pkg"; then
            PASS "$pkg held (apt-mark)"
        else
            FAIL "$pkg installed but NOT held — apt upgrade can replace it"
        fi
    fi
done

# ── Partition layout / mounts ───────────────────────────────────────────
echo "----- Storage -----"
if findmnt /data >/dev/null 2>&1; then
    PASS "/data is mounted ($(findmnt -n -o SOURCE /data))"
else
    if [ -e /etc/systemd/system/multi-user.target.wants/move-firstboot-data.service ] \
       || [ -e /lib/systemd/system/move-firstboot-data.service ]; then
        WARN "/data not mounted but firstboot service is queued; reboot to provision"
    else
        FAIL "/data not mounted and no firstboot-data service queued"
    fi
fi
if blkid -L data >/dev/null 2>&1; then
    PASS "ext4 partition LABEL=data exists"
else
    WARN "no partition with LABEL=data yet (will be created on first boot)"
fi

# ── User / group setup ──────────────────────────────────────────────────
echo "----- Users -----"
if getent passwd ableton >/dev/null; then
    uid=$(id -u ableton)
    home=$(getent passwd ableton | cut -d: -f6)
    if [ "$uid" = "1000" ]; then
        PASS "ableton user exists at UID 1000"
    else
        WARN "ableton user exists but UID is $uid (expected 1000)"
    fi
    if [ "$home" = "/data/UserData" ]; then
        PASS "ableton home is /data/UserData"
    else
        WARN "ableton home is $home (expected /data/UserData)"
    fi
else
    FAIL "ableton user does not exist"
fi

if getent group ablspi >/dev/null; then
    gid=$(getent group ablspi | cut -d: -f3)
    if [ "$gid" = "1000" ]; then
        PASS "ablspi group exists at GID 1000"
    else
        WARN "ablspi group exists but GID is $gid (expected 1000)"
    fi
else
    FAIL "ablspi group does not exist"
fi

ableton_groups=$(id -nG ableton 2>/dev/null | tr ' ' '\n')
for g in ablspi audio realtime dialout plugdev video render sudo; do
    if echo "$ableton_groups" | grep -qx "$g"; then
        PASS "ableton is in $g group"
    else
        # ablspi + audio are mandatory for RT audio; the rest are
        # convenience and may be missing on stripped-down images.
        case "$g" in
            ablspi|audio|realtime) FAIL "ableton NOT in $g group" ;;
            *)                     WARN "ableton not in $g group (optional)" ;;
        esac
    fi
done

# ── Firstrun wizard sentinel ────────────────────────────────────────────
if [ -e /root/.not_logged_in_yet ]; then
    FAIL "/root/.not_logged_in_yet still present — firstrun wizard will trigger"
else
    PASS "firstrun wizard skipped (no .not_logged_in_yet)"
fi

# ── ablspi kernel module + chardev ──────────────────────────────────────
echo "----- ablspi -----"
if lsmod | awk '{print $1}' | grep -qx ablspi; then
    PASS "ablspi module loaded"
elif modinfo ablspi >/dev/null 2>&1; then
    WARN "ablspi installed but not loaded (DT may not have probed yet)"
else
    FAIL "ablspi module not installed (DKMS build may have failed)"
fi

if [ -c /dev/ablspi0.0 ]; then
    owner=$(stat -c '%U:%G %a' /dev/ablspi0.0)
    if echo "$owner" | grep -q ':ablspi 660'; then
        PASS "/dev/ablspi0.0 owned $owner"
    else
        WARN "/dev/ablspi0.0 exists but ownership is $owner (expected root:ablspi 660)"
    fi
else
    FAIL "/dev/ablspi0.0 not present — DT overlay or kernel module missing"
fi

# ── DT overlays applied ─────────────────────────────────────────────────
echo "----- Device tree -----"
if grep -q 'ableton,move' /proc/device-tree/compatible 2>/dev/null; then
    PASS "device tree advertises ableton,move compatible"
else
    FAIL "device tree does not advertise ableton,move — overlay not applied"
fi
if [ -d /proc/device-tree/soc/spi@7e204000 ] || [ -d /proc/device-tree/axi/pcie0/rp1 ]; then
    PASS "SPI controller present in DT"
fi
if [ -d /proc/device-tree/__symbols__ ]; then
    if grep -l ablspi /proc/device-tree/__symbols__/* >/dev/null 2>&1; then
        PASS "ablspi node referenced in DT __symbols__"
    fi
fi

# ── DBus services registered ────────────────────────────────────────────
echo "----- D-Bus -----"
for f in /etc/dbus-1/system.d/move.conf \
         /usr/share/dbus-1/system-services/com.ableton.system.service \
         /usr/share/dbus-1/system-services/com.ableton.update.service; do
    if [ -f "$f" ]; then PASS "$f present"; else FAIL "$f missing"; fi
done

# ── Systemd units installed and enabled ─────────────────────────────────
echo "----- Services -----"
for unit in move-launcher.service move-web.service \
            move-usb-gadget.service move-xmos-shutdown.service; do
    if [ -f "/lib/systemd/system/$unit" ]; then
        if systemctl is-enabled --quiet "$unit"; then
            PASS "$unit enabled"
        else
            WARN "$unit installed but not enabled"
        fi
    else
        FAIL "$unit not installed"
    fi
done

# ── /opt/move stack (operator-supplied, not in our packages) ────────────
echo "----- /opt/move -----"
if [ -x /opt/move/MoveLauncher ]; then
    PASS "/opt/move/MoveLauncher present"
else
    WARN "/opt/move/MoveLauncher absent — operator must rsync /opt/move/ from device"
fi
for lib in libc++.so.1 libXSDBusCpp.so libXTCMalloc.so \
           libubootenv.so.0 libswupdate.so.0.1; do
    if [ -f /opt/move/lib/$lib ] || [ -f /usr/lib/$lib ] \
       || [ -f /usr/lib/aarch64-linux-gnu/$lib ]; then
        PASS "$lib resolvable"
    else
        WARN "$lib not resolvable — bring it from the stock image"
    fi
done

# ── Network gadget ──────────────────────────────────────────────────────
echo "----- USB gadget -----"
if ip link show usb0 >/dev/null 2>&1; then
    PASS "usb0 NCM gadget interface present"
else
    WARN "usb0 not up — move-usb-gadget.service may not have run yet"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "===================================="
echo "PASS: $ok   WARN: $warn   FAIL: $fail"
echo "===================================="

[ "$fail" -eq 0 ]
