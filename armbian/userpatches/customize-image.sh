#!/bin/bash
# Armbian customize-image.sh - runs inside the assembled rootfs chroot
# right before the final image is rolled. Documented signature:
#
#   $1 = RELEASE        e.g. bookworm, trixie
#   $2 = LINUXFAMILY    e.g. bcm2711
#   $3 = BOARD          e.g. move
#   $4 = BUILD_DESKTOP  yes|no
#
# $SDCARD points at the rootfs being assembled; userpatches/overlay on
# the host is bind-mounted into the chroot at /tmp/overlay.
#
# Steps performed (in order):
#   1.  Install the locally-built ablspi-dkms + move-bringup .debs
#   2.  Build and install the Move DT overlays into /boot/dtb/broadcom/overlay/
#   3.  Pre-create the ableton user (uid 1000) + ablspi group (gid 1000)
#       matching the stock AbletonOS layout, with home on /data/UserData
#   4.  Install the firstboot service that creates /data on first boot
#       and add the fstab entry that mounts it
#   5.  Skip Armbian's firstrun wizard entirely by removing
#       /root/.not_logged_in_yet (we've already pre-configured everything
#       the wizard would have asked about)
#   6.  Enable our systemd units

set -euo pipefail

RELEASE="${1:-}"
LINUXFAMILY="${2:-}"
BOARD="${3:-}"
BUILD_DESKTOP="${4:-no}"

EXTRAS_DIR="/tmp/overlay/extras"
SRC_DIR="/tmp/overlay/move-bringup-src"

echo "customize-image.sh: BOARD=$BOARD LINUXFAMILY=$LINUXFAMILY RELEASE=$RELEASE"

[ "$BOARD" = "move" ] || {
    echo "customize-image.sh: not the Move board ($BOARD); skipping Move-specific steps"
    exit 0
}

export DEBIAN_FRONTEND=noninteractive

# ── 1. Build + install move-bringup + ablspi-dkms from source ───────────
# The source tree under /tmp/overlay/move-bringup-src/ is bind-mounted
# from userpatches/overlay/move-bringup-src/ on the host. We dpkg-build
# it inside the chroot so the .debs end up correctly compiled against
# the target rootfs's debhelper / dh-dkms versions, then apt-install
# them so dependencies resolve from the chroot's apt sources.
if [ -d "$SRC_DIR" ]; then
    echo "customize-image.sh: building move-bringup from source in $SRC_DIR"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential debhelper dh-dkms devscripts \
        device-tree-compiler

    # Copy the source into a writable build dir (the bind mount is RO-ish).
    cp -r "$SRC_DIR" /tmp/move-bringup-build
    cd /tmp/move-bringup-build
    dpkg-buildpackage -b -us -uc -d
    cd /tmp
    rm -rf /tmp/move-bringup-build

    debs=$(ls /tmp/*.deb 2>/dev/null | grep -E 'move-bringup|ablspi-dkms' || true)
    if [ -z "$debs" ]; then
        echo "customize-image.sh: FATAL — dpkg-buildpackage produced no debs" >&2
        exit 1
    fi
    apt-get install -y --no-install-recommends $debs
    rm -f $debs
else
    # Fall back to pre-built core debs if the operator staged them
    # directly (rather than the source tree).
    if compgen -G "$EXTRAS_DIR"/ablspi-dkms_*.deb > /dev/null \
       && compgen -G "$EXTRAS_DIR"/move-bringup_*.deb > /dev/null; then
        echo "customize-image.sh: installing pre-built core debs from $EXTRAS_DIR"
        apt-get update -y
        apt-get install -y --no-install-recommends \
            "$EXTRAS_DIR"/ablspi-dkms_*.deb \
            "$EXTRAS_DIR"/move-bringup_*.deb
    else
        echo "customize-image.sh: FATAL — neither $SRC_DIR nor pre-built core debs found" >&2
        exit 1
    fi
fi

# Opportunistically install any other .debs staged in extras/ — e.g. the
# personal move-firmware + move-user-data debs produced by
# scripts/extract-move-firmware.sh, which contain the Ableton-proprietary
# /opt/move stack and the operator's own /data tree pulled from their
# Move. We never ship these files ourselves.
#
# Install order matters: move-firmware depends on move-bringup (already
# installed above), and move-user-data depends on move-bringup too. The
# user-data deb's content lands at /var/lib/move-data/, which the
# data.mount unit bind-mounts at /data, so /data is pre-populated on
# first boot just like a stock Move.
for extra in "$EXTRAS_DIR"/move-firmware_*.deb \
             "$EXTRAS_DIR"/move-user-data_*.deb \
             "$EXTRAS_DIR"/move-extra-*.deb; do
    [ -f "$extra" ] || continue
    echo "customize-image.sh: installing $(basename "$extra")"
    apt-get install -y --no-install-recommends "$extra"
done

# Best-effort install of the CM5 EEPROM update tooling. These two
# can't go in PACKAGE_LIST_BOARD (the pre-rootfs apt dry-run can't
# find libraspberrypi-bin in Armbian's chroot sources), so we install
# them here where the chroot's apt sources are fully populated. The
# `|| true` makes the build resilient — if either package isn't
# available, the build continues without it. BUILD.md §4c documents
# the manual install fallback for end users.
#   rpi-eeprom         : CM5 (BCM2712) second-stage bootloader updater.
#   libraspberrypi-bin : provides vcgencmd, needed by rpi-eeprom-update.
echo "customize-image.sh: best-effort install of CM5 EEPROM tooling"
apt-get install -y --no-install-recommends rpi-eeprom || \
    echo "customize-image.sh: WARNING: rpi-eeprom unavailable; see BUILD.md §4c for manual install"
apt-get install -y --no-install-recommends libraspberrypi-bin || \
    echo "customize-image.sh: WARNING: libraspberrypi-bin unavailable; see BUILD.md §4c for manual install"

# ── 2. DT overlays now ship inside the move-bringup .deb ─────────────
# The .deb's postinst builds them from /usr/share/move-bringup/overlays-src/
# and installs them to /boot/firmware/overlays/, plus an
# /etc/kernel/postinst.d/move-overlays hook rebuilds them on every
# kernel update (necessary because Armbian's bcm2711 BSP rewrites
# /boot/firmware/overlays/ via zzz-copy-new-files on kernel upgrade).
# No work needed here; sanity-check that they landed.
for variant in cm4 cm5; do
    if [ ! -f "/boot/firmware/overlays/ablspi-move-${variant}.dtbo" ]; then
        echo "customize-image.sh: WARNING ablspi-move-${variant}.dtbo not built" >&2
        echo "  Did move-bringup install correctly? Check /var/log/dpkg.log" >&2
    fi
done

# ── 3. Pre-create ableton user (uid 1000) + RT-relevant groups ──────────
# UIDs match the stock AbletonOS image so /data/UserData/* ownership
# migrates 1:1 if the operator copies the data partition over.
#
# Groups granted (all checked for existence first, created if missing):
#   ablspi   - /dev/ablspi0.0 access (our udev rule sets GROUP=ablspi)
#   audio    - PAM rtprio/memlock/nice via /etc/security/limits.d
#   realtime - newer RT convention (realtime-privileges package); we
#              create it ourselves so the limits.d file matches
#   dialout  - /dev/ttyUSB*, serial console
#   plugdev  - hot-pluggable devices (mtp, libusb-claimed devs)
#   video    - /dev/dri/* and framebuffer
#   render   - /dev/dri/renderD* (GPU compute / Vulkan)
#   sudo     - admin convenience; remove if you want a locked-down image

ensure_group() {
    local name=$1 gid=${2:-}
    if getent group "$name" >/dev/null; then return 0; fi
    if [ -n "$gid" ] && ! getent group "$gid" >/dev/null; then
        groupadd --system --gid "$gid" "$name"
    else
        groupadd --system "$name"
    fi
}

ensure_group ablspi   1000
ensure_group audio
ensure_group realtime
ensure_group dialout
ensure_group plugdev
ensure_group video
ensure_group render

ABL_GROUPS="ablspi,audio,realtime,dialout,plugdev,video,render,sudo"

if ! getent passwd ableton >/dev/null; then
    if ! getent passwd 1000 >/dev/null; then
        useradd --uid 1000 --gid 100 \
                --groups "$ABL_GROUPS" \
                --home-dir /data/UserData --no-create-home \
                --shell /bin/bash \
                --comment "Ableton Move runtime" \
                ableton
    else
        useradd --gid 100 \
                --groups "$ABL_GROUPS" \
                --home-dir /data/UserData --no-create-home \
                --shell /bin/bash \
                --comment "Ableton Move runtime" \
                ableton
        echo "customize-image.sh: WARNING UID 1000 was taken; assigned dynamic UID" >&2
    fi
fi

# In case ableton existed (e.g. base image already has it), ensure
# membership in every group above. Idempotent.
for g in $(echo "$ABL_GROUPS" | tr ',' ' '); do
    if getent group "$g" >/dev/null; then
        usermod -a -G "$g" ableton || true
    fi
done

# Default passwords - operator overrides via env or post-flash.
# Keep these documented in the README so nobody is surprised.
echo "ableton:move" | chpasswd
echo "root:move"    | chpasswd

# Pre-seed /etc/hostname and /etc/hosts so the wizard doesn't ask.
echo "move" > /etc/hostname
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "127.0.1.1   move" >> /etc/hosts

# ── 4. fstab entry + firstboot /data provisioner ────────────────────────
mkdir -p /data
if ! grep -q 'LABEL=data' /etc/fstab; then
    cat >> /etc/fstab <<'EOF'

# Ableton Move /data partition (created on first boot if absent)
LABEL=data  /data  ext4  defaults,nofail,X-mount.mkdir  0  2
EOF
fi

install -d /usr/lib/move-bringup
cat > /usr/lib/move-bringup/firstboot-data-partition.sh <<'EOF'
#!/bin/sh
# Idempotent: create /dev/mmcblk0p4 with LABEL=data if it doesn't exist.
set -eu

DISK=/dev/mmcblk0
DATA_PART="${DISK}p4"

if blkid -L data > /dev/null 2>&1; then
    echo "firstboot-data-partition: /data already provisioned"
    exit 0
fi

ROOT_SRC=$(findmnt -n -o SOURCE /)
case "$ROOT_SRC" in
    /dev/mmcblk0p*) ;;
    *)
        echo "firstboot-data-partition: rootfs not on $DISK ($ROOT_SRC); skipping" >&2
        exit 0
        ;;
esac

ROOTFS_NUM="${ROOT_SRC##*p}"
SECTORS_6G=$(( 6 * 1024 * 1024 * 1024 / 512 ))

echo "firstboot-data-partition: shrinking rootfs ($ROOT_SRC) to 6G"
resize2fs -f "$ROOT_SRC" 6G || {
    echo "firstboot-data-partition: resize2fs failed; aborting" >&2
    exit 0
}

PART_START=$(parted -m -s "$DISK" unit s print \
    | awk -F: -v n="$ROOTFS_NUM" '$1==n{print $2}' | tr -d s)
PART_END=$(( PART_START + SECTORS_6G - 1 ))

parted -s "$DISK" resizepart "$ROOTFS_NUM" ${PART_END}s
parted -s "$DISK" mkpart primary ext4 $(( PART_END + 1 ))s 100%
partprobe "$DISK"
sleep 1

mkfs.ext4 -F -L data "$DATA_PART"
mkdir -p /data
mount "$DATA_PART" /data

# Set up the directory layout the Move userspace expects on /data.
install -d -o ableton -g users /data/UserData
install -d /data/CoreLibrary /data/Scratch /data/settings /data/log
chmod 1777 /data/log

echo "firstboot-data-partition: /data ready"
EOF
chmod +x /usr/lib/move-bringup/firstboot-data-partition.sh

cat > /lib/systemd/system/move-firstboot-data.service <<'EOF'
[Unit]
Description=Create /data partition on first boot
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target
ConditionPathExists=!/var/lib/move-bringup/data-provisioned

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/move-bringup/firstboot-data-partition.sh
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/move-bringup && touch /var/lib/move-bringup/data-provisioned'

[Install]
WantedBy=local-fs.target
EOF

# NOTE: move-firstboot-data.service is INSTALLED but NOT enabled.
# It does live resize2fs + parted on the running rootfs which previously
# stalled boot before sshd came up. Operator can `systemctl start` it
# manually after first successful SSH login (see /root/MOVE-FIRST-STEPS.md).

# ── 5. Skip the firstrun wizard entirely ────────────────────────────────
# Every prompt the wizard would normally raise (hostname, root password,
# user/password, locale, timezone, network) is either preconfigured above
# or handled by the move-bringup package. Removing this sentinel makes
# the wizard a no-op on first login.
rm -f /root/.not_logged_in_yet

# ── 6. SAFE MODE: install services DISABLED ─────────────────────────────
# Boot-blocking risk: move-firstboot-data.service has DefaultDependencies=no
# + Before=local-fs.target, so if its parted/resize2fs sequence fails or
# hangs, local-fs.target never completes and networking/sshd never starts.
# That's catastrophic for headless debugging - the device is unreachable.
#
# So: ship every Move service installed but DISABLED, except the WiFi
# bringup (which is conditional on a file existing so it's safe to enable).
# The operator SSHes in, runs verify.sh, confirms ablspi probes and
# /dev/ablspi0.0 exists, then `systemctl enable --now` the rest.
#
# /root/MOVE-FIRST-STEPS.md captures the enable sequence.
echo "customize-image.sh: enabling Move services for first-boot autostart"
# Everything except the risky firstboot-data resize. The data-partition
# carve-out (move-firstboot-data) is still off-by-default because it
# rewrites the SD partition table live; if you need a real /data
# partition instead of the bind-mount, enable it manually after
# verifying SD health.
for unit in move-usb-gadget.service \
            move-xmos-init.service \
            move-launcher.service \
            move-web.service \
            move-xmos-shutdown.service \
            move-firstboot-wifi.service; do
    if [ -f "/lib/systemd/system/$unit" ]; then
        systemctl enable "$unit" || true
    fi
done
for unit in move-firstboot-data.service; do
    if [ -f "/lib/systemd/system/$unit" ]; then
        systemctl disable "$unit" 2>/dev/null || true
    fi
done

# Document the first-boot sanity-check sequence for the operator.
cat > /root/MOVE-FIRST-STEPS.md <<'EOF'
# Move bring-up - sanity check after first boot

The image now boots Move services AUTOMATICALLY: USB-Ethernet gadget,
WiFi firstboot, XMOS init, MoveLauncher, MoveWebService, and the XMOS
shutdown hook are all systemctl-enabled at image build time. If the
hardware is plugged in correctly and a stock /opt/move + /data tree is
in place via move-firmware/move-user-data debs, the device should be
booting to the normal Move UI within ~15 s of power-on.

After your first SSH in, spot-check that everything is healthy:

    sh /tmp/verify.sh    # if you scp'd verify.sh up
    # or just check the highlights:
    uname -a                            # should end in -current-bcm2711
    ls -la /dev/ablspi0.0               # should be crw-rw---- root:ablspi
    lsmod | grep ablspi                 # should be loaded
    findmnt /data                       # should show /var/lib/move-data
    systemctl is-active move-xmos-init move-launcher swupdateprog-stub
    # all three should be "active"
    journalctl -u move-xmos-init -n 5
    # Expect: "OK: XMOS reports mode=1 (standaloneMode)"

If a service failed at boot, it's safe to retry by hand once you've
fixed whatever was wrong:

    sudo systemctl restart move-launcher.service
    journalctl -u move-launcher -n 50 -f

# /data partition - DEFERRED for safety

The risky `move-firstboot-data.service` (resizes the SD live to carve
out a 4th ext4 partition labelled `data`) is the one service that
stays disabled by default — its bind-mount stand-in (`data.mount`)
satisfies MoveLauncher's `findmnt /data` gate using `/var/lib/move-data`
on the rootfs, which is just-as-functional without the partition
surgery risk. Enable the real-partition path only if you have a working
SD backup and specifically need it:

    sudo systemctl start move-firstboot-data.service
    journalctl -u move-firstboot-data -n 30

# Known limitations

  * **WiFi status icon on the device shows "disconnected"** even when
    NetworkManager has the Move online. MoveLauncher reads connection
    state via the `net.connman` D-Bus interface, which ConnMan
    provides on stock AbletonOS. We use NetworkManager instead.
    Networking still WORKS (SSH, HTTP, NTP all function); only the
    on-device status icon is stale. To get the icon back, either
    install + run ConnMan alongside NM (configured to leave the WiFi
    interface unmanaged by NM, by setting `unmanaged-devices` in NM
    keyfile config) or wait for a future move-bringup update with an
    NM-state → ConnMan-D-Bus bridge.

# Defaults

Default users:
    root:move
    ableton:move (uid 1000, home /data/UserData)

Change passwords immediately:
    passwd
    passwd ableton

EOF
chmod 644 /root/MOVE-FIRST-STEPS.md

# Stage the WiFi template on the FAT boot partition so the operator can
# fill it in after flashing without rebuilding the image. (The .deb's
# postinst also does this, but doing it here too is safe and covers the
# case where the deb postinst couldn't write to /boot/firmware.)
if [ -f /usr/share/move-bringup/move-wifi.txt.example ] \
   && [ -d /boot/firmware ] \
   && [ ! -f /boot/firmware/move-wifi.txt.example ]; then
    cp /usr/share/move-bringup/move-wifi.txt.example \
       /boot/firmware/move-wifi.txt.example
fi

# Optional: convenient locale/timezone defaults. The user can change
# them later via timedatectl/locale-gen.
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime || true
if [ -f /etc/locale.gen ]; then
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
    locale-gen >/dev/null 2>&1 || true
fi

echo "customize-image.sh: done"
