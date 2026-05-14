#!/bin/bash
# extract-move-firmware.sh
#
# Pull the Ableton-proprietary user-space files from a stock Move device
# and pack them into a personal .deb that can be installed into your
# Armbian Move image during build.
#
# WHY THIS EXISTS
# ───────────────
# /opt/move/* and the vendored libraries Ableton ships in /usr/lib/ are
# proprietary. We don't redistribute them in this repo, and you shouldn't
# either - but you own your Move hardware, so you're entitled to copy the
# bits off it for your own use. This script automates that, producing a
# `move-firmware_<version>_arm64.deb` that:
#
#   - Installs /opt/move/<contents> exactly as on your device
#   - Installs the vendored libraries to /opt/move/lib/ + an ld.so.conf
#     entry so the Move binaries link correctly
#   - Adds SONAME shims (libusb-1.0.so etc.) that the Ableton binaries
#     reference but Debian only ships as versioned (.so.0)
#   - Depends on move-bringup so apt resolution does the right thing
#
# USAGE
# ─────
#   ./extract-move-firmware.sh [--host root@move.local] [--output DIR]
#                              [--version VER] [--keep-tmp]
#                              [--no-data | --data-only] [--firmware-only]
#
# By default produces TWO debs in <output-dir>:
#   - move-firmware_<version>_arm64.deb     : /opt/move/* + vendored libs
#   - move-user-data_<date>_arm64.deb       : the full /data tree, files
#                                             land at /var/lib/move-data/
#                                             (the rootfs side of the
#                                             data.mount bind-mount).
#
# Flags:
#   --firmware-only   skip the /data pull
#   --no-data         alias for --firmware-only
#   --data-only       only pull /data; skip /opt/move
#   --output DIR      write debs to DIR instead of cwd
#
# After it runs, copy whichever debs you produced into your Armbian build:
#   cp move-firmware_*_arm64.deb move-user-data_*_arm64.deb \
#      ~/armbian-build/userpatches/overlay/extras/
# and run compile.sh as normal. customize-image.sh will dpkg -i them in
# the chroot, in order (move-bringup → move-firmware → move-user-data).

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────
HOST="root@move.local"
OUTPUT_DIR="$(pwd)"
VERSION=""
KEEP_TMP=0
PULL_FIRMWARE=1     # /opt/move/* + vendored libs -> move-firmware_*.deb
PULL_DATA=1         # /data -> move-user-data_*.deb (default ON)
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# ── Arg parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --host)            HOST="$2"; shift 2 ;;
        --output)          OUTPUT_DIR="$2"; shift 2 ;;
        --version)         VERSION="$2"; shift 2 ;;
        --keep-tmp)        KEEP_TMP=1; shift ;;
        --no-data|--firmware-only)
                           PULL_DATA=0; shift ;;
        --data-only)       PULL_FIRMWARE=0; PULL_DATA=1; shift ;;
        -h|--help)
            sed -n '/^# USAGE/,/^# After/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            echo "use --help for usage" >&2
            exit 2
            ;;
    esac
done

log()   { printf '[extract-move-firmware] %s\n' "$*" >&2; }
fatal() { log "FATAL: $*"; exit 1; }

command -v ssh    >/dev/null || fatal "ssh not found"
command -v rsync  >/dev/null || fatal "rsync not found (apt install rsync)"
command -v dpkg-deb >/dev/null || fatal "dpkg-deb not found (apt install dpkg)"
command -v fakeroot >/dev/null || fatal "fakeroot not found (apt install fakeroot)"

# ── 1. Verify the host is actually a Move ───────────────────────────────
log "checking $HOST"
if ! ssh "${SSH_OPTS[@]}" "$HOST" 'true' 2>/dev/null; then
    fatal "cannot ssh to $HOST"
fi

remote_os=$(ssh "${SSH_OPTS[@]}" "$HOST" 'cat /etc/os-release 2>/dev/null | grep -E "^ID=" || true')
if ! echo "$remote_os" | grep -q 'ableton'; then
    log "WARNING: $HOST does not look like an AbletonOS device"
    log "         /etc/os-release ID is: $remote_os"
    log "         continuing anyway in 3s; ctrl-C to abort..."
    sleep 3
fi

remote_arch=$(ssh "${SSH_OPTS[@]}" "$HOST" 'uname -m')
if [ "$remote_arch" != "aarch64" ]; then
    fatal "$HOST architecture is $remote_arch, expected aarch64"
fi

if ! ssh "${SSH_OPTS[@]}" "$HOST" '[ -x /opt/move/MoveLauncher ]'; then
    fatal "$HOST does not have /opt/move/MoveLauncher; not a Move?"
fi

# ── 2. Resolve version ──────────────────────────────────────────────────
if [ -z "$VERSION" ]; then
    remote_ver=$(ssh "${SSH_OPTS[@]}" "$HOST" \
        'grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d "\""')
    if [ -z "$remote_ver" ]; then
        VERSION="0.0.0-$(date +%Y%m%d)"
        log "could not read VERSION_ID; defaulting to $VERSION"
    else
        # Normalise "abletonos-aarch64-rpi4-v3.18" -> "3.18"
        VERSION=$(echo "$remote_ver" \
            | sed -nE 's/.*-v([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
        [ -z "$VERSION" ] && VERSION="$(date +%Y%m%d)"
    fi
fi
log "package version: $VERSION"

# ── 3. Stage the build tree ─────────────────────────────────────────────
TMPDIR=$(mktemp -d -t move-fw-XXXXXX)
trap '[ "$KEEP_TMP" = 1 ] || rm -rf "$TMPDIR"' EXIT
log "staging in $TMPDIR"

if [ "$PULL_FIRMWARE" = 1 ]; then
PKGROOT="$TMPDIR/pkgroot"
mkdir -p "$PKGROOT"/{DEBIAN,opt/move,opt/move/lib,etc/ld.so.conf.d}
mkdir -p "$PKGROOT"/usr/lib/aarch64-linux-gnu

# ── 4. Pull /opt/move ───────────────────────────────────────────────────
log "rsync /opt/move/  (this is the big one, ~70 MB)"
rsync -aHAX --info=progress2 \
      -e "ssh ${SSH_OPTS[*]}" \
      --exclude='*.log' \
      --exclude='log/' \
      --exclude='Scratch/' \
      "$HOST:/opt/move/" "$PKGROOT/opt/move/"

# ── 5. Pull the vendored libraries Debian doesn't carry ────────────────
# Each entry is the SONAME we want callable from the Ableton binaries.
# We expand each to a glob so the symlink (`libc++.so.1` -> `libc++.so.1.0`)
# AND its target are both pulled - otherwise the SONAME ends up as a
# dangling symlink on install.
log "pulling vendored libs to /opt/move/lib/"
VENDORED_PREFIXES=(
    libc++         # LLVM libc++ - Ableton-built, not in Debian default
    libXSDBusCpp   # Ableton's sdbus-cpp build
    libXTCMalloc   # Ableton's tcmalloc build
    libubootenv    # Yocto-built, may not match Debian's
    libswupdate    # SWUpdate library (no Debian binary pkg ships it)
)
for prefix in "${VENDORED_PREFIXES[@]}"; do
    # Use the device's shell to glob-expand: catches both the SONAME
    # symlink and its versioned target file.
    files=$(ssh "${SSH_OPTS[@]}" "$HOST" \
            "ls /usr/lib/${prefix}.so* 2>/dev/null" | tr '\n' ' ')
    if [ -z "$files" ]; then
        log "  - ${prefix}.so* (not on device; skipping)"
        continue
    fi
    log "  + ${prefix}.so*  ($(echo "$files" | wc -w | tr -d ' ') file(s))"
    for f in $files; do
        rsync -aHAX -e "ssh ${SSH_OPTS[*]}" \
              "$HOST:$f" "$PKGROOT/opt/move/lib/"
    done
done

# Sanity-check: every symlink in /opt/move/lib must point to a file
# that's also inside the package (or to a Debian-shipped library).
log "validating symlink chains"
broken=0
for link in "$PKGROOT"/opt/move/lib/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
        /*)  resolved="$target" ;;
        *)   resolved="$PKGROOT/opt/move/lib/$target" ;;
    esac
    if [ ! -e "$resolved" ]; then
        log "  BROKEN: $(basename "$link") -> $target"
        broken=$((broken + 1))
    fi
done
if [ "$broken" -gt 0 ]; then
    log "WARNING: $broken broken symlinks in package; continuing anyway"
    log "         (target may be supplied by a Debian package at install time)"
fi

# ── 6. SONAME shims for Debian's versioned-only libs ───────────────────
# Ableton's binaries link against unversioned SONAMEs that Debian only
# ships as versioned files. Install relative symlinks under
# /usr/lib/aarch64-linux-gnu/ so ldconfig picks them up.
log "installing SONAME shims to /usr/lib/aarch64-linux-gnu/"
declare -A SHIMS=(
    [libusb-1.0.so]=libusb-1.0.so.0
    [libmp3lame.so]=libmp3lame.so.0
)
for shim in "${!SHIMS[@]}"; do
    target=${SHIMS[$shim]}
    ln -sf "$target" "$PKGROOT/usr/lib/aarch64-linux-gnu/$shim"
    log "  + $shim -> $target"
done

# ── 7. ld.so.conf.d entry for /opt/move/lib ────────────────────────────
cat > "$PKGROOT/etc/ld.so.conf.d/move-firmware.conf" <<'EOF'
# Ableton Move vendored libraries
/opt/move/lib
EOF

# ── 8. Compute installed size ──────────────────────────────────────────
INSTALLED_KB=$(du -sk "$PKGROOT" --exclude=DEBIAN | awk '{print $1}')

# ── 9. DEBIAN/control ───────────────────────────────────────────────────
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: move-firmware
Version: ${VERSION}-1
Architecture: arm64
Maintainer: Local Move owner <local@invalid>
Installed-Size: ${INSTALLED_KB}
Depends: move-bringup, libssl3, libasound2, libsystemd0, libudev1, libcap2,
 libyaml-0-2, libz1, libusb-1.0-0, libmp3lame0, libdbus-1-3, sqlite3, libsqlite3-0
Section: misc
Priority: optional
Homepage: https://www.ableton.com/move/
Description: Ableton Move proprietary user-space (extracted from owned hardware)
 Contains /opt/move/* and the vendored libraries (libc++.so.1, libXSDBusCpp,
 libXTCMalloc, libubootenv, libswupdate) extracted from a Move device the
 builder owns. NOT REDISTRIBUTABLE - Ableton's EULA permits personal use
 only.
 .
 Built by extract-move-firmware.sh from ${HOST} on $(date -u +%Y-%m-%dT%H:%M:%SZ).
EOF

# ── 10. postinst: ldconfig + restart services ──────────────────────────
cat > "$PKGROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    configure)
        ldconfig
        if [ -d /run/systemd/system ]; then
            for u in move-launcher.service move-web.service; do
                if systemctl is-enabled --quiet "$u" 2>/dev/null; then
                    systemctl try-restart "$u" || true
                fi
            done
        fi
        ;;
esac
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

cat > "$PKGROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    remove|upgrade|deconfigure)
        if [ -d /run/systemd/system ]; then
            for u in move-launcher.service move-web.service; do
                systemctl stop "$u" 2>/dev/null || true
            done
        fi
        ;;
esac
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/prerm"

cat > "$PKGROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    remove|purge)
        ldconfig
        ;;
esac
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postrm"

# ── 11. Build the firmware deb ─────────────────────────────────────────
FIRMWARE_DEB="$OUTPUT_DIR/move-firmware_${VERSION}-1_arm64.deb"
log "building $FIRMWARE_DEB"
mkdir -p "$OUTPUT_DIR"
# fakeroot so file ownership ends up root:root regardless of build user.
fakeroot dpkg-deb --build --root-owner-group "$PKGROOT" "$FIRMWARE_DEB"
fi  # PULL_FIRMWARE

# ── 12. /data → move-user-data deb (default-on; --no-data to skip) ─────
USERDATA_DEB=""
if [ "$PULL_DATA" = 1 ]; then
    log "── pulling /data (user content) ──"

    DATAROOT="$TMPDIR/datapkg"
    mkdir -p "$DATAROOT/DEBIAN" "$DATAROOT/var/lib/move-data"

    # Pull /data → /var/lib/move-data/.  Exclude transient/cache content
    # that's regenerated at runtime and would just bloat the deb. The
    # log dir is recreated by move-bringup.postinst with the right
    # permissions; Scratch is workspace.
    log "rsync /data/  (this may take a while if the user has samples)"
    rsync -aHAX --info=progress2 \
          -e "ssh ${SSH_OPTS[*]}" \
          --exclude='log/' \
          --exclude='Scratch/' \
          --exclude='**/.cache/' \
          --exclude='**/Sentry/' \
          --exclude='**/*.log' \
          --exclude='**/lost+found/' \
          "$HOST:/data/" "$DATAROOT/var/lib/move-data/"

    # Compute installed size BEFORE we drop the control files.
    DATA_INSTALLED_KB=$(du -sk "$DATAROOT" --exclude=DEBIAN | awk '{print $1}')
    DATA_VERSION=$(date +%Y%m%d.%H%M)

    cat > "$DATAROOT/DEBIAN/control" <<EOF
Package: move-user-data
Version: ${DATA_VERSION}-1
Architecture: arm64
Maintainer: Local Move owner <local@invalid>
Installed-Size: ${DATA_INSTALLED_KB}
Depends: move-bringup
Section: misc
Priority: optional
Description: Ableton Move /data tree (extracted from owned hardware)
 Contains the full /data tree (UserData, CoreLibrary, settings) from a
 Move device the builder owns. Installs to /var/lib/move-data/ which
 move-bringup bind-mounts at /data via data.mount. NOT REDISTRIBUTABLE
 - your user content (sets, samples, presets, settings) is personal.
 .
 Built by extract-move-firmware.sh from ${HOST} on $(date -u +%Y-%m-%dT%H:%M:%SZ).
EOF

    # postinst: chown the UserData subtree so the ableton user (uid 1000,
    # primary group users / gid 100) actually owns its home content.
    # dpkg installs files as root:root by default; the stock device has
    # /data/UserData/ owned by ableton.
    cat > "$DATAROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in
    configure)
        if getent passwd ableton >/dev/null && \
           [ -d /var/lib/move-data/UserData ]; then
            chown -R ableton:users /var/lib/move-data/UserData || true
        fi
        # Make sure data.mount sees the freshly populated source. If the
        # bind-mount is already active, the new files are visible via
        # /data immediately (bind-mount shares the underlying inodes).
        ;;
esac
exit 0
EOF
    chmod 0755 "$DATAROOT/DEBIAN/postinst"

    USERDATA_DEB="$OUTPUT_DIR/move-user-data_${DATA_VERSION}-1_arm64.deb"
    log "building $USERDATA_DEB"
    fakeroot dpkg-deb --build --root-owner-group "$DATAROOT" "$USERDATA_DEB"
fi

# ── 13. Summary ────────────────────────────────────────────────────────
log "done"
echo
[ "$PULL_FIRMWARE" = 1 ] && {
    echo "  Firmware: $FIRMWARE_DEB"
    echo "    Size:   $(du -h "$FIRMWARE_DEB" | cut -f1)"
    echo "    SHA256: $(sha256sum "$FIRMWARE_DEB" | cut -d' ' -f1)"
    echo
}
[ -n "$USERDATA_DEB" ] && {
    echo "  UserData: $USERDATA_DEB"
    echo "    Size:   $(du -h "$USERDATA_DEB" | cut -f1)"
    echo "    SHA256: $(sha256sum "$USERDATA_DEB" | cut -d' ' -f1)"
    echo
}
echo "  Stage them into your Armbian build with:"
[ "$PULL_FIRMWARE" = 1 ] && \
    echo "    cp $FIRMWARE_DEB ~/armbian-build/userpatches/overlay/extras/"
[ -n "$USERDATA_DEB" ] && \
    echo "    cp $USERDATA_DEB ~/armbian-build/userpatches/overlay/extras/"
echo
echo "  Then rebuild your Armbian image. customize-image.sh dpkg-installs"
echo "  them in dependency order (move-bringup → move-firmware →"
echo "  move-user-data)."
echo
echo "  DO NOT distribute these .debs — Ableton's EULA on the firmware"
echo "  permits personal use only, and the user-data deb contains your"
echo "  own private sets/samples/settings."
