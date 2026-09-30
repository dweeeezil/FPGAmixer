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
BCD_DEVICE=0x0101  # bump on any descriptor change (see above)
                   # 0x0101: one clock source (single_clock), 2026-09-26

CHANNELS_MASK=0xff # 8 channels each way
RATE=48000
SSIZE=3            # 24-bit samples in 3 bytes (S24_3LE)

# ----- Type-C role (Genesys ZU board specific) -----
# The Type-C port's TI TUSB322I comes up dual-role with Try.SRC preferred
# (REG 0x0A = 0x06, read 2026-09-25). Against a Mac, which is dual-role too,
# the board won the negotiation as SOURCE (REG 0x09 = 0x50, Attached.SRC):
# both ends then wait for the other to be the device and nothing enumerates.
# Forcing the chip to UFP (device only) fixed it (REG 0x09 = 0x90,
# Attached.SNK, UDC "addressed", "FPGAmixer" in Audio MIDI Setup). The setting
# lasts until power-off, so it is written at every start.
#
# The chip is at 0x47 behind a TCA9548A mux (0x70, branch 3) on the PS I2C
# controller at 0xff020000 (i2c-1 today; looked up by name so a bus
# renumbering can't send these writes to the wrong bus). Linux has no driver
# on the mux, so selecting a branch and releasing it again disturbs nothing.
I2C_CTRL=ff020000
MUX_ADDR=0x70
MUX_BRANCH3=0x08
TUSB_ADDR=0x47
TUSB_REG_MODE=0x0a  # [5:4] MODE_SELECT, [2:1] SOURCE_PREF, [0] DISABLE_TERM

typec_ufp() {
    bus=""
    for d in /sys/bus/i2c/devices/i2c-*; do
        if grep -q "$I2C_CTRL" "$d/name" 2>/dev/null; then bus=${d##*i2c-}; break; fi
    done
    if [ -z "$bus" ]; then
        echo "WARNING: I2C controller $I2C_CTRL not found; Type-C role left as is" >&2
        return 1
    fi

    i2cset -y "$bus" $MUX_ADDR $MUX_BRANCH3 || return 1
    # TUSB32x datasheet sequence: terminations off, change mode, terminations
    # on. Keep SOURCE_PREF and debounce as they were, set MODE_SELECT = 01.
    mode=$(i2cget -y "$bus" $TUSB_ADDR $TUSB_REG_MODE) || { i2cset -y "$bus" $MUX_ADDR 0x00; return 1; }
    ufp=$(( (mode & ~0x31) | 0x10 ))
    i2cset -y "$bus" $TUSB_ADDR $TUSB_REG_MODE $(( mode | 0x01 ))
    i2cset -y "$bus" $TUSB_ADDR $TUSB_REG_MODE $(( ufp | 0x01 ))
    i2cset -y "$bus" $TUSB_ADDR $TUSB_REG_MODE $ufp
    i2cset -y "$bus" $MUX_ADDR 0x00
    printf "Type-C: TUSB322 mode register %s -> 0x%02x (UFP)\n" "$mode" "$ufp"
}

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

    # Before binding, so the port is already a device when the pull-up appears.
    # A failure is logged, not fatal: a host that is not dual-role still works.
    typec_ufp || echo "WARNING: could not force the Type-C port to UFP; a Mac may not see the gadget" >&2

    mkdir -p "$G"
    cd "$G"
    echo $VID > idVendor
    echo $PID > idProduct
    echo $BCD_DEVICE > bcdDevice
    echo 0x0200 > bcdUSB

    mkdir -p strings/0x409
    # Device name as the host shows it (user's choice, 2026-09-30): the USB
    # front door is "StudioRunner USB", the AVB one "StudioRunner AVB"
    echo "StudioRunner" > strings/0x409/manufacturer
    echo "StudioRunner USB" > strings/0x409/product
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
    echo "StudioRunner USB" > $F/function_name

    # One clock source for both directions, so the Mac shows ONE 8x8 device.
    # True here: both directions run on the PL's mclk (the bridge steers the
    # Mac to it). Needs the carried f_uac2 patch (meta-fpgamixer
    # recipes-kernel/linux-xlnx); on a kernel without it, fall back to the
    # stock two clock sources (two devices on the Mac).
    if [ -e $F/single_clock ]; then
        echo 1 > $F/single_clock
        echo "StudioRunner USB clock" > $F/clksrc_out_name
        echo "UAC2: one clock source (single_clock)"
    else
        echo "UAC2: kernel without single_clock, two clock sources (two devices on a Mac)"
    fi

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
