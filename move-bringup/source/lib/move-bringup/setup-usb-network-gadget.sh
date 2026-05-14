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
    ensure_configfs
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
    : > UDC || true
    rm -f "configs/$CONFIG/$INSTANCE_NAME" "os_desc/$CONFIG"
    rmdir "configs/$CONFIG/strings/$LANGUAGE" 2>/dev/null || true
    rmdir "configs/$CONFIG"                   2>/dev/null || true
    rmdir "functions/$INSTANCE_NAME"          2>/dev/null || true
    rmdir "strings/$LANGUAGE"                 2>/dev/null || true
    cd "$CONFIGFS_HOME/usb_gadget"
    rmdir "$GADGET_NAME" 2>/dev/null || true
}

case "${1:-start}" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac
