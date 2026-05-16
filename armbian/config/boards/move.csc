# Armbian board config — Ableton Move (CM4 or CM5)
# Tier: csc (Community Supported, current branch only)
#
# Single board entry covering both Compute Module variants. The Move's
# carrier is the same hardware regardless of which CM is socketed in,
# and Armbian's bcm2711 family already targets all 64-bit Pi/CM models
# (config.txt has dedicated [cm4] and [cm5] filter sections that handle
# the SoC-level differences at boot time). We layer the Move-specific
# bits — XMOS ablspi link, PCF85063 RTC, dwc2 OTG config — on top via
# a DT overlay and the move-bringup + ablspi-dkms packages.
#
# Variant detection happens at boot via config.txt [cm4]/[cm5] filters:
# the right ablspi-move-cm{4,5}.dtbo is loaded based on which CM the
# bootloader detects. Both .dtbo files are installed unconditionally.

declare -g BOARD_NAME="Ableton Move"
declare -g BOARD_VENDOR="ableton"
declare -g BOARDFAMILY="bcm2711"
declare -g BOARD_MAINTAINER="move-port"
declare -g INTRODUCED="2026"
declare -g KERNEL_TARGET="current,edge"
declare -g KERNEL_TEST_TARGET="current"
declare -g ASOUND_STATE="asound.state.rpi"

# Activate our kernel-config fragment extension. Armbian does NOT
# auto-load files from userpatches/extensions/ - they must be enabled
# explicitly. Without this, custom_kernel_config__merge_move_fragment
# never fires and the kernel ships without PREEMPT_RT or iwlwifi etc.
enable_extension "move-kernel-config"

# Move owns its LCD and audio path via XMOS over ablspi; the CM's
# HDMI/DSI outputs are unused on the stock device.
declare -g HAS_VIDEO_OUTPUT="no"
declare -g FULL_DESKTOP="no"

# UART console matches the stock cmdline (serial0). On CM4 this is
# ttyAMA0, on CM5 ttyAMA10 - the kernel cmdline references serial0
# which is aliased to the right device in each base DTB.
declare -g RASPI_SERIALCON="serial0"

# Cap rootfs at 6 GB so the firstboot-data hook has room for /data.
declare -g FIXED_IMAGE_SIZE="6144"

declare -g MODULES="i2c_dev"
declare -g MODULES_BLACKLIST=""

# Upstream packages we want in the rootfs. The two Move-specific .debs
# (move-bringup, ablspi-dkms) are NOT listed here - they would fail
# Armbian's pre-rootfs apt-dry-run because they don't live in any apt
# repo. They are built from source and apt-installed by our
# userpatches/customize-image.sh later in the build.
declare -g PACKAGE_LIST_BOARD="u-boot-tools parted e2fsprogs \
                               device-tree-compiler network-manager \
                               iw dkms build-essential debhelper dh-dkms \
                               firmware-iwlwifi firmware-brcm80211 \
                               bluez-firmware wireless-regdb \
                               rpi-eeprom libraspberrypi-bin"

# firmware-iwlwifi:    Intel WiFi binary firmware for the Move carrier's
#                      Intel 9260 PCIe card.
# firmware-brcm80211:  Broadcom/Cypress WiFi firmware for the CM5's
#                      onboard SDIO radio (CYW43455 / similar). Harmless
#                      on CM4 (carrier has no Brcm radio); needed on CM5
#                      so brcmfmac doesn't fail probe with missing
#                      brcm/brcmfmac*.bin.
# bluez-firmware:      Broadcom BT firmware blobs (BCM4345C0 etc.) for
#                      the CM5 combo radio. Doesn't pull in bluez itself
#                      (bluetoothd / bluetoothctl) — install separately
#                      if you actually want to use BT; for now this just
#                      ensures the firmware is on disk when the kernel
#                      BT stack asks for it.
# wireless-regdb:      regulatory domain database so iw can set country.
# rpi-eeprom:          CM5 (BCM2712) second-stage bootloader updater.
#                      Without this + a manual `rpi-eeprom-update -a`
#                      on first boot, the CM5 stays on whatever stale
#                      bootloader its eMMC shipped with, and the BCM2712
#                      firmware-mailbox protocol may not honor newer
#                      SET_POWER_STATE / GET_CLOCKS calls — that's the
#                      root cause of dwc2/v3d/raspberrypi-clk failing
#                      with -22 on CM5 (verified on hardware; see
#                      BUILD.md §6d). Harmless on CM4 (different
#                      bootloader path, package no-ops).
# libraspberrypi-bin:  Provides vcgencmd, which rpi-eeprom-update needs
#                      to query the current bootloader version. Without
#                      it, the eeprom updater fails with "vcgencmd: not
#                      found" and the bootloader never gets updated.
# All live in Debian non-free-firmware, auto-enabled in debootstrapped
# trixie images since Debian 12.

# Install the locally-built kernel headers so ablspi-dkms can compile
# the module at first install. Armbian builds the headers .deb but
# defaults to NOT installing it (saves rootfs space). Without this,
# ablspi-dkms's postinst sees no headers and quietly skips the build,
# leaving /dev/ablspi0.0 absent at boot.
declare -g KERNEL_HAS_WORKING_HEADERS="yes"
declare -g INSTALL_HEADERS="yes"

# Sort order matters here. Armbian dispatches pre_umount_final_image__*
# hooks in alphabetical order. The bcm2711 family defines
# `pre_umount_final_image__write_raspi_config` which writes config.txt
# from scratch with `>`. We need to run AFTER that so our appended
# Move section survives. Hence `zzz_` prefix: z > w sorts later.
#
# Empirically verified from build log: the family's write_raspi_config
# fires, then this function fires after, and the appended config.txt
# content persists into the final image.
#
# This function also:
#   - Stages the WiFi credentials template on the FAT partition
#   - Belt-and-braces rebuilds the DT overlays on the host (in case
#     the in-chroot kernel-postinst.d hook missed any)
function pre_umount_final_image__zzz_move_finalise() {
    local CFG="${MOUNT}/boot/firmware/config.txt"
    local OVR="${MOUNT}/boot/firmware/overlays"
    local SRC_DTS="${SRC}/userpatches/overlay/move-bringup-src/source/usr/share/move-bringup/overlays-src"
    local WIFI_TPL="${SRC}/userpatches/overlay/move-bringup-src/source/usr/share/move-bringup/move-wifi.txt.example"

    display_alert "$BOARD" "appending Move section to /boot/firmware/config.txt" "info"

    if [[ -f "$CFG" ]] && ! grep -q 'ableton-move-bringup' "$CFG"; then
        # Strip the family's otg_mode=1 from [cm4] section - forces
        # XHCI mode, blocking the dwc2 OTG path the Move's USB-C needs.
        sed -i '/^\[cm4\]/,/^\[/{ /^otg_mode=1$/d }' "$CFG"

        # Strip the family's `dtoverlay=dwc2,dr_mode=host` from [cm5].
        # On CM5 the BCM2712 USB controller at /axi/usb@480000 is
        # dwc2-compatible and the family ships host-mode as the default
        # for it, but Move needs peripheral/OTG for the NCM gadget.
        # Without this strip our [cm5] append produces two conflicting
        # dwc2 overlay loads. Mirrored in move-bringup.postinst.
        sed -i '/^\[cm5\]/,/^\[/{ /^dtoverlay=dwc2,dr_mode=host$/d }' "$CFG"

        cat >> "$CFG" <<'EOF'

# ─── ableton-move-bringup ──────────────────────────────────────────
[all]
enable_uart=1
dtparam=spi=on

[cm4]
dtoverlay=dwc2,dr_mode=otg
dtoverlay=ablspi-move-cm4

[cm5]
dtoverlay=dwc2,dr_mode=otg
dtoverlay=ablspi-move-cm5

[all]
EOF
    fi

    # Build overlays directly on the host. dtc is in Armbian's build
    # image (device-tree-compiler). -q suppresses the intentional
    # gpios_property warning about the bare-integer irq-gpio binding.
    display_alert "$BOARD" "compiling Move DT overlays" "info"
    mkdir -p "$OVR"
    local src base out
    for src in "$SRC_DTS"/ablspi-move-cm*.dts; do
        [[ -f "$src" ]] || continue
        base="$(basename "$src" .dts)"
        out="$OVR/${base}.dtbo"
        if dtc -@ -q -W no-gpios_property -I dts -O dtb -o "$out" "$src" 2>/dev/null; then
            display_alert "$BOARD" "  + $(basename "$out")" "info"
        else
            display_alert "$BOARD" "  ! dtc FAILED for $src" "wrn"
        fi
    done

    # WiFi template (FAT partition mountable from any laptop OS)
    if [[ -f "$WIFI_TPL" ]]; then
        cp -f "$WIFI_TPL" "${MOUNT}/boot/firmware/move-wifi.txt.example"
        display_alert "$BOARD" "staged move-wifi.txt.example" "info"
    fi
}
