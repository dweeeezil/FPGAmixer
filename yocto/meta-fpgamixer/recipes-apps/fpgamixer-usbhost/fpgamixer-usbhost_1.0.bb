SUMMARY = "FPGAmixer USB host bridge: a USB audio interface <-> PS/PL audio link, resampled"
DESCRIPTION = "The USB-host front door's Linux half (Phase 11): moves audio both \
ways between a class-compliant interface on the board's Type-A port (the MOTU \
M2) and a FPGAmixer link card, resampling with libsamplerate at a ratio set by \
a PI servo on each playback queue. Also installs fpgamixer-rate-test, the \
resampler's unit test and CPU benchmark (--bench). Trimmable: this recipe is \
the whole Linux half (decision H4). See docs/phase11_status_*.md in the repo."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# bridge_core and the rate stage live in ../fpgamixer-bridge-core (shared
# source, not a recipe); only this bridge links the rate stage and libsamplerate.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:${THISDIR}/../fpgamixer-bridge-core:"
SRC_URI = " \
    file://fpgamixer-usbhost-bridge.c \
    file://bridge_core.c \
    file://bridge_core.h \
    file://bridge_convert.h \
    file://bridge_rate_src.c \
    file://bridge_rate_src.h \
    file://test_bridge_rate.c \
    file://fpgamixer-usbhost-bridge.service \
    file://usbhost.conf \
"
S = "${WORKDIR}"

DEPENDS = "alsa-lib libsamplerate0"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-usbhost-bridge.service"
# H.2: installed but not enabled (it shares link #1 with the USB device bridge
# and is started by hand for the test). H.4 enables it, on link #3.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -O2 -I${S} -o fpgamixer-usbhost-bridge \
        ${S}/fpgamixer-usbhost-bridge.c ${S}/bridge_core.c ${S}/bridge_rate_src.c \
        -lasound -lsamplerate -lpthread -lm
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -O2 -I${S} -o fpgamixer-rate-test \
        ${S}/test_bridge_rate.c ${S}/bridge_rate_src.c -lsamplerate -lm
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 fpgamixer-usbhost-bridge fpgamixer-rate-test ${D}${bindir}/

    install -d ${D}${sysconfdir}/fpgamixer
    install -m 0644 ${S}/usbhost.conf ${D}${sysconfdir}/fpgamixer/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-usbhost-bridge.service ${D}${systemd_system_unitdir}/
}

CONFFILES:${PN} = "${sysconfdir}/fpgamixer/usbhost.conf"
