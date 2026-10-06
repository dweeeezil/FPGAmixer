SUMMARY = "FPGAmixer media clock: locks the audio clock (mclk) to gPTP time"
DESCRIPTION = "Phase 9 P9.4b: a small service that reads the PL media-clock \
meter once per gPTP second and steers mclk through the MMCM's fine phase \
shift, so every gPTP second starts at the same point of the audio frame grid. \
The PL only measures and steps; the loop is here. See \
docs/phase9_status_2026-09-26.md in the repo."
LICENSE = "CLOSED"

# The Python comes from the repo's tools/ (FPGAMIXER_TOOLS, conf/layer.conf),
# like fpgamixer-osc; mixer_hw.py (the window access) is installed by that one.
FILESEXTRAPATHS:prepend := "${FPGAMIXER_TOOLS}:${THISDIR}/files:"

SRC_URI = " \
    file://mediaclock.py \
    file://fpgamixer-mediaclock.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-mediaclock.service"
# Enabled since the bench of 2026-09-27 (docs/phase9_status_2026-09-26.md
# 6.6.1): open-loop steps confirmed sign and scale on hardware, and the loop
# locked in 5 s and held the frame phase within +/-3 cycles (+/-244 ns). The
# first image shipped it disabled so that the open-loop test came first.
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = "fpgamixer-osc python3-core"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0644 ${S}/mediaclock.py ${D}${APPDIR}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-mediaclock.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR}"
