SUMMARY = "FPGAmixer USB audio gadget: the board as a UAC2 soundcard"
DESCRIPTION = "Builds a USB Audio Class 2 gadget (8 channels each way, 48 kHz, \
async with explicit feedback) on the Type-C port (PS USB0) through configfs at \
boot. A front door's USB side only: it creates the gadget ALSA card and does \
not move audio to the PL. Kept apart from fpgamixer-osc on purpose, since USB \
is a front door and the OSC server is control plane. Needs the kernel fragment \
in recipes-kernel/linux-xlnx and dr_mode in system-user.dtsi. See \
docs/phase8_status_*.md in the repo."
LICENSE = "CLOSED"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://fpgamixer-usb-gadget.sh \
    file://fpgamixer-usb-gadget.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-usb-gadget.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0755 ${S}/fpgamixer-usb-gadget.sh ${D}${APPDIR}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-usb-gadget.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR}"
