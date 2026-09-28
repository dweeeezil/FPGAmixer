SUMMARY = "FPGAmixer AVB front door, Linux half (network side): class A shaping and AAF devices"
DESCRIPTION = "Phase 9 P9.6: at boot, from /etc/fpgamixer/avb.conf, sets the \
kernel TAI offset the AAF plugin needs, creates the stream VLAN interface, \
shapes end0 (mqprio + software CBS + ETF) and writes the ALSA AAF devices \
avb_tx / avb_rx. Nothing here knows about the mixer core; P9.7's bridge \
connects these devices to link #2. See docs/phase9_status_2026-09-26.md."
LICENSE = "CLOSED"

# avb_net.py comes from the repo's tools/ (FPGAMIXER_TOOLS, conf/layer.conf),
# like mediaclock.py; its unit tests (test_avb_net.py) stay in the repo.
FILESEXTRAPATHS:prepend := "${FPGAMIXER_TOOLS}:${THISDIR}/files:"

SRC_URI = " \
    file://avb_net.py \
    file://avb.conf \
    file://fpgamixer-avb-net.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-avb-net.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# libasound-module-pcm-aaf: the AAF plugin (alsa-plugins with PACKAGECONFIG aaf,
# see recipes-multimedia/alsa); iproute2-tc for tc (the image had only ip);
# python3-ctypes for adjtimex (the TAI offset).
RDEPENDS:${PN} = "python3-core python3-ctypes iproute2-ip iproute2-tc \
    libasound-module-pcm-aaf"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0644 ${S}/avb_net.py ${D}${APPDIR}/

    install -d ${D}${sysconfdir}/fpgamixer
    install -m 0644 ${S}/avb.conf ${D}${sysconfdir}/fpgamixer/avb.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-avb-net.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR} ${sysconfdir}/fpgamixer/avb.conf"
CONFFILES:${PN} = "${sysconfdir}/fpgamixer/avb.conf"
