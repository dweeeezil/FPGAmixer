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
# Installed but NOT enabled yet: the bench first steers by hand
# (mixer_hw.py steer) to prove sign and scale on hardware, then starts the
# loop with systemctl. Switched to "enable" once the loop has passed the bench.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

RDEPENDS:${PN} = "fpgamixer-osc python3-core"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0644 ${S}/mediaclock.py ${D}${APPDIR}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-mediaclock.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR}"
