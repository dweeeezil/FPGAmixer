SUMMARY = "FPGAmixer gPTP: ptp4l + phc2sys on end0 as boot services"
DESCRIPTION = "802.1AS time for the AVB front door (Phase 9, P9.1): ptp4l on \
end0 with hardware timestamping and the gPTP profile, the board's role chosen \
by BMCA (priority1 250: follows the bench's Pi, can be made grandmaster by one \
config value), and phc2sys keeping the system clock on the PHC while \
following. See docs/phase9_status_2026-09-26.md in the repo."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://fpgamixer-gptp.cfg \
    file://fpgamixer-ptp4l.service \
    file://fpgamixer-phc2sys.service \
"
S = "${WORKDIR}"

inherit systemd allarch

# linuxptp: ptp4l, phc2sys, pmc (meta-xilinx 4.4). Its own units stay disabled.
RDEPENDS:${PN} = "linuxptp"

SYSTEMD_SERVICE:${PN} = "fpgamixer-ptp4l.service fpgamixer-phc2sys.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sysconfdir}/fpgamixer
    install -m 0644 ${S}/fpgamixer-gptp.cfg ${D}${sysconfdir}/fpgamixer/gptp.cfg

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-ptp4l.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${S}/fpgamixer-phc2sys.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${sysconfdir}/fpgamixer/gptp.cfg"
CONFFILES:${PN} = "${sysconfdir}/fpgamixer/gptp.cfg"
