SUMMARY = "FPGAmixer AVB front door, Linux half: class A shaping, AAF devices, the bridge to link #2"
DESCRIPTION = "Phase 9 P9.6: at boot, from /etc/fpgamixer/avb.conf, sets the \
kernel TAI offset the AAF plugin needs, creates the stream VLAN interface, \
shapes end0 (mqprio + software CBS + ETF) and writes the ALSA AAF devices \
avb_tx / avb_rx. P9.7: fpgamixer-avb-bridge moves 8 channels each way between \
those devices and link #2 (FPGAmixerLink2), at a fixed queue (both sides run \
on the PHC's time). Nothing here knows about the mixer core. See \
docs/phase9_status_2026-09-26.md."
LICENSE = "CLOSED"

# avb_net.py comes from the repo's tools/ (FPGAMIXER_TOOLS, conf/layer.conf),
# like mediaclock.py; its unit tests (test_avb_net.py) stay in the repo.
# bridge_core (shared with fpgamixer-usb-bridge) is in ../fpgamixer-bridge-core.
FILESEXTRAPATHS:prepend := "${FPGAMIXER_TOOLS}:${THISDIR}/files:${THISDIR}/../fpgamixer-bridge-core:"

SRC_URI = " \
    file://avb_net.py \
    file://avb_entityd.py \
    file://avdecc_pdu.py \
    file://avdecc_model.py \
    file://avdecc_entity.py \
    file://msrp.py \
    file://avdecc_probe.py \
    file://avb.conf \
    file://fpgamixer-avb-net.service \
    file://fpgamixer-avb-entity.service \
    file://fpgamixer-avb-bridge.c \
    file://bridge_core.c \
    file://bridge_core.h \
    file://bridge_convert.h \
    file://fpgamixer-avb-bridge.service \
"

S = "${WORKDIR}"

DEPENDS = "alsa-lib"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-avb-net.service fpgamixer-avb-bridge.service \
    fpgamixer-avb-entity.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -O2 -I${S} -o fpgamixer-avb-bridge \
        ${S}/fpgamixer-avb-bridge.c ${S}/bridge_core.c -lasound -lpthread
}

# libasound-module-pcm-aaf: the AAF plugin (alsa-plugins with PACKAGECONFIG aaf,
# see recipes-multimedia/alsa); iproute2-tc for tc (the image had only ip);
# python3-ctypes for adjtimex (the TAI offset).
RDEPENDS:${PN} = "python3-core python3-ctypes python3-io python3-json python3-math \
    python3-threading iproute2-ip iproute2-tc libasound-module-pcm-aaf linuxptp"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 fpgamixer-avb-bridge ${D}${bindir}/

    install -d ${D}${APPDIR}
    for f in avb_net.py avb_entityd.py avdecc_pdu.py avdecc_model.py avdecc_entity.py \
             msrp.py avdecc_probe.py; do
        install -m 0644 ${S}/$f ${D}${APPDIR}/
    done

    install -d ${D}${sysconfdir}/fpgamixer
    install -m 0644 ${S}/avb.conf ${D}${sysconfdir}/fpgamixer/avb.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-avb-net.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${S}/fpgamixer-avb-bridge.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${S}/fpgamixer-avb-entity.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR} ${sysconfdir}/fpgamixer/avb.conf"
CONFFILES:${PN} = "${sysconfdir}/fpgamixer/avb.conf"
