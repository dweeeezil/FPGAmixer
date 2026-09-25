SUMMARY = "FPGAmixer OSC control server and its parameter store, as a boot service"
DESCRIPTION = "Installs the (interim, Python) OSC server with its hardware \
backend and persistent parameter store, and a systemd unit that starts it at \
boot with --hw. On start it restores the saved state from \
/var/lib/fpgamixer/mixer_state.json and pushes it to the PL register windows. \
See docs/architecture_modules.md and docs/phase6_status_*.md in the repo."
LICENSE = "CLOSED"

# The Python comes from the repo's tools/ (FPGAMIXER_TOOLS, conf/layer.conf),
# never from a copy inside the layer; the unit file lives with the recipe.
FILESEXTRAPATHS:prepend := "${FPGAMIXER_TOOLS}:${THISDIR}/files:"

SRC_URI = " \
    file://osc_mixer_server.py \
    file://mixer_state.py \
    file://mixer_hw.py \
    file://fpgamixer-osc.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-osc.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Module -> package, from poky's python3-manifest.json: argparse, math,
# signal, struct, threading, dataclasses -> core; socket -> io; json; mmap.
RDEPENDS:${PN} = "python3-core python3-io python3-json python3-mmap"

APPDIR = "${libdir}/fpgamixer"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0644 ${S}/osc_mixer_server.py ${S}/mixer_state.py ${S}/mixer_hw.py ${D}${APPDIR}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-osc.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR}"
