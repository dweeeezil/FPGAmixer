#!/bin/sh
# fpgamixer-usb-gadget.sh start|stop
#
# The board as a USB Audio Class 2 soundcard on the Type-C port (PS USB0),
# built through configfs. Phase 8, docs/phase8_status_2026-09-25.md sec. 3.2.
#
# This only makes the USB side exist: Linux gets an ALSA card ("UAC2Gadget")
# whose capture is what the Mac plays and whose playback is what the Mac
# records. Moving that audio to and from the PL is the bridge's job, not
# this script's.
#
# Clocking: async endpoints with explicit feedback. The gadget card exposes
# "Capture Pitch 1000000" (the feedback value the Mac follows for its OUT
# stream) and "Playback Pitch 1000000" (our IN packet sizing); the bridge
# steers both so the Mac runs at the PL's mclk rate.
#
# macOS caches a device's descriptors by VID/PID/bcdDevice. After changing
# the channel counts, rates or sample size here, bump BCD_DEVICE or the Mac
# keeps showing the old layout.
set -eu

G=/sys/kernel/config/usb_gadget/fpgamixer
F=functions/uac2.usb0
C=configs/c.1

VID=0x1d6b         # Linux Foundation
PID=0x0104         # Multifunction Composite Gadget
BCD_DEVICE=0x0100  # bump on any descriptor change (see above)

CHANNELS_MASK=0xff # 8 channels each way
RATE=48000
SSIZE=3            # 24-bit samples in 3 bytes (S24_3LE)

start() {
    if [ -e "$G/UDC" ] && [ -n "$(cat "$G/UDC")" ]; then
        echo "gadget already bound to $(cat "$G/UDC")"
        return 0
    fi

    udc=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    if [ -z "$udc" ]; then
        echo "no USB device controller: is dwc3_0 dr_mode = peripheral, and is the kernel built with USB_GADGET=y?" >&2
        return 1
    fi

    mkdir -p "$G"
    cd "$G"
    echo $VID > idVendor
    echo $PID > idProduct
    echo $BCD_DEVICE > bcdDevice
    echo 0x0200 > bcdUSB

    mkdir -p strings/0x409
    echo "FPGAmixer" > strings/0x409/manufacturer
    echo "FPGAmixer" > strings/0x409/product
    serial=$(cut -c1-16 /etc/machine-id 2>/dev/null || echo 0)
    echo "$serial" > strings/0x409/serialnumber

    mkdir -p "$F"
    echo $CHANNELS_MASK > $F/c_chmask     # Mac -> board (the Mac's output)
    echo $RATE          > $F/c_srate
    echo $SSIZE         > $F/c_ssize
    echo async          > $F/c_sync
    echo $CHANNELS_MASK > $F/p_chmask     # board -> Mac (the Mac's input)
    echo $RATE          > $F/p_srate
    echo $SSIZE         > $F/p_ssize
    echo "FPGAmixer"    > $F/function_name

    mkdir -p $C/strings/0x409
    echo "UAC2" > $C/strings/0x409/configuration
    echo 0xc0 > $C/bmAttributes   # self-powered: the board never draws from VBUS
    echo 0    > $C/MaxPower
    [ -e $C/uac2.usb0 ] || ln -s $F $C/

    echo "$udc" > UDC
    echo "gadget bound to $udc"
}

stop() {
    [ -d "$G" ] || return 0
    cd "$G"
    [ -n "$(cat UDC 2>/dev/null)" ] && echo "" > UDC
    rm -f $C/uac2.usb0
    rmdir $C/strings/0x409 $C "$F" strings/0x409 2>/dev/null || true
    cd /
    rmdir "$G"
    echo "gadget removed"
}

case "${1:-}" in
    start) start ;;
    stop)  stop ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
