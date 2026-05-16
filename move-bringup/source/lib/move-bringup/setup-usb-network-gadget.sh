#!/bin/sh
# Build the Ableton Move USB-Ethernet NCM gadget via configfs. Ported from
# the stock /etc/init.d/setup-usb-network-gadget script; functionally
# identical, with bash-isms scrubbed for /bin/sh portability.
#
# References:
#   https://www.kernel.org/doc/Documentation/usb/gadget_configfs.rst

set -e

CONFIGFS_HOME="/sys/kernel/config"
GADGET_NAME="g1"
INSTANCE_NAME="ncm.usb0"
LANGUAGE="0x409"
CONFIG="c.1"

ensure_modules() {
    # Belt-and-braces: /etc/modules-load.d/move-usb-gadget.conf should
    # have loaded these at boot. If something stripped that file or the
    # service ran before systemd-modules-load.service somehow, we
    # self-recover here. modprobe is a no-op if already loaded.
    modprobe libcomposite 2>/dev/null || true
    modprobe usb_f_ncm    2>/dev/null || true
}

ensure_configfs() {
    [ -d "$CONFIGFS_HOME/usb_gadget" ] && return 0
    mount -t configfs none "$CONFIGFS_HOME"
}

create_gadget() {
    mkdir -p "$CONFIGFS_HOME/usb_gadget/$GADGET_NAME"
}

write_usb_ids() {
    # Ableton VID 0x2982, registered NCM PID 0x1959.
    printf "0x2982\n" > idVendor
    printf "0x1959\n" > idProduct
    printf "0x0200\n" > bcdUSB
    printf "2\n"      > bDeviceClass
    printf "0x0101\n" > bcdDevice
}

write_usb_strings() {
    mkdir -p "strings/$LANGUAGE"
    printf "Ableton\n"                   > "strings/$LANGUAGE/manufacturer"
    printf "Ableton Move USB Ethernet\n" > "strings/$LANGUAGE/product"
    if [ -e /sys/firmware/devicetree/base/serial-number ]; then
        cat /sys/firmware/devicetree/base/serial-number \
            > "strings/$LANGUAGE/serialnumber" || true
    fi
}

create_configuration() {
    mkdir -p "configs/$CONFIG/strings/$LANGUAGE"
    printf "Config1\n" > "configs/$CONFIG/strings/$LANGUAGE/configuration"
    printf "0xc0\n"    > "configs/$CONFIG/bmAttributes"   # self-powered
    printf "0\n"       > "configs/$CONFIG/MaxPower"
}

create_ncm_function() {
    mkdir -p "functions/$INSTANCE_NAME"

    eth0_addr=$(cat /sys/class/net/eth0/address 2>/dev/null \
                  || echo "02:00:00:00:00:00")
    b1=$(echo "$eth0_addr" | cut -d: -f2)
    b2=$(echo "$eth0_addr" | cut -d: -f3)
    b3=$(echo "$eth0_addr" | cut -d: -f4)
    b4=$(echo "$eth0_addr" | cut -d: -f5)
    b5=$(echo "$eth0_addr" | cut -d: -f6)

    host_addr="02:$b1:$b2:$b3:$b4:$b5"
    dev_addr="02:$b1:$b2:$b3:$b5:$b4"
    printf "%s\n" "$host_addr" > "functions/$INSTANCE_NAME/host_addr"
    printf "%s\n" "$dev_addr"  > "functions/$INSTANCE_NAME/dev_addr"

    ln -sf "../../functions/$INSTANCE_NAME" "configs/$CONFIG/"
}

create_os_descriptor() {
    # Required for Windows 10 plug-and-play NCM recognition.
    mkdir -p os_desc
    printf "1\n"       > os_desc/use
    printf "0x1\n"     > os_desc/b_vendor_code
    printf "MSFT100\n" > os_desc/qw_sign
    ln -sf "../configs/$CONFIG" os_desc/

    mkdir -p "functions/$INSTANCE_NAME/os_desc/interface.ncm"
    printf "WINNCM\n" > "functions/$INSTANCE_NAME/os_desc/interface.ncm/compatible_id"
}

enable_gadget() {
    udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    if [ -z "$udc" ]; then
        echo "setup-usb-network-gadget: no UDC available" >&2
        return 1
    fi
    printf "%s\n" "$udc" > UDC
}

start() {
    ensure_modules
    ensure_configfs
    # If a previous run left partial state, tear it down first so we
    # start from a clean tree. Without this, a re-run after a partial
    # failure (e.g. stop() not finishing cleanly) trips
    #   ln: failed to create symbolic link 'configs/c.1/ncm.usb0':
    #   No such file or directory
    # because configfs left configs/c.1 in a half-initialised state
    # that mkdir -p doesn't recover.
    stop
    create_gadget
    cd "$CONFIGFS_HOME/usb_gadget/$GADGET_NAME"
    write_usb_ids
    write_usb_strings
    create_configuration
    create_ncm_function
    create_os_descriptor
    enable_gadget
}

stop() {
    cd "$CONFIGFS_HOME/usb_gadget/$GADGET_NAME" 2>/dev/null || return 0
    # Unbind the UDC first — every other cleanup step requires the
    # gadget to be deactivated, otherwise configfs returns EBUSY.
    : > UDC 2>/dev/null || true

    # Tear down in reverse dependency order. rmdir on configfs nodes
    # returns success only when the node has no remaining children, so
    # we work from leaves inward. The 2>/dev/null || true suppression
    # is intentional — we want to plow through partial state.

    # Detach the NCM function from the config (these are symlinks).
    rm -f "configs/$CONFIG/$INSTANCE_NAME"     2>/dev/null || true
    rm -f "os_desc/$CONFIG"                    2>/dev/null || true

    # Tear down the config: leaf strings dir first, then the config.
    rmdir "configs/$CONFIG/strings/$LANGUAGE"  2>/dev/null || true
    rmdir "configs/$CONFIG/strings"            2>/dev/null || true
    rmdir "configs/$CONFIG"                    2>/dev/null || true

    # Tear down the function's OS descriptor subtree.
    rmdir "functions/$INSTANCE_NAME/os_desc/interface.ncm" 2>/dev/null || true
    rmdir "functions/$INSTANCE_NAME/os_desc"   2>/dev/null || true
    rmdir "functions/$INSTANCE_NAME"           2>/dev/null || true

    # Tear down the top-level strings tree.
    rmdir "strings/$LANGUAGE"                  2>/dev/null || true

    # Finally remove the gadget itself.
    cd "$CONFIGFS_HOME/usb_gadget"
    rmdir "$GADGET_NAME"                       2>/dev/null || true
}

case "${1:-start}" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac
