SUMMARY = "FPGAmixer USB bridge: UAC2 gadget <-> PS/PL audio link, clock-steered"
DESCRIPTION = "Moves 8 channels each way between the UAC2 gadget card and the \
FPGAmixerLink card, and bridges the Mac's USB clock to the PL's mclk without \
resampling by steering the gadget's pitch controls (a PI servo on each \
direction's playback queue). The USB front door's Linux half, next to \
fpgamixer-usb-gadget. See docs/phase8_status_*.md in the repo."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# bridge_core (shared with fpgamixer-avb-bridge since Phase 9 P9.7) lives in
# ../fpgamixer-bridge-core: not a recipe, just the common source.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${THISDIR}/../fpgamixer-bridge-core:"
SRC_URI = " \
    file://fpgamixer-usb-bridge.c \
    file://bridge_core.c \
    file://bridge_core.h \
    file://bridge_convert.h \
    file://fpgamixer-usb-bridge.service \
"
S = "${WORKDIR}"

DEPENDS = "alsa-lib"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-usb-bridge.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -O2 -I${S} -o fpgamixer-usb-bridge \
        ${S}/fpgamixer-usb-bridge.c ${S}/bridge_core.c -lasound -lpthread
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 fpgamixer-usb-bridge ${D}${bindir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-usb-bridge.service ${D}${systemd_system_unitdir}/
}
