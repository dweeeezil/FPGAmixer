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
    file://osc_codec.py \
    file://osc_discovery.py \
    file://mixer_params.py \
    file://mixer_state.py \
    file://mixer_hw.py \
    file://mixer_meters.py \
    file://mixer_snapshots.py \
    file://fpgamixer-osc.service \
    file://fpgamixer-mdns.conf \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgamixer-osc.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# Module -> package, from poky's python3-manifest.json: argparse, math,
# signal, struct, threading, time, dataclasses -> core; socket -> io; json;
# mmap; re, subprocess -> core (checked in poky's python3-manifest.json,
# 2026-10-04). osc_codec, mixer_params and osc_discovery add nothing beyond these;
# nor does mixer_meters (Phase 13: math, struct, threading, time -> core);
# nor does mixer_snapshots (Phase 14: json, os, threading, time).
RDEPENDS:${PN} = "python3-core python3-io python3-json python3-mmap"

APPDIR = "${libdir}/fpgamixer"

# Re-run do_install when a new sync changes the recorded commit.
FPGAMIXER_SYNCED_FROM = "${FPGAMIXER_TOOLS}/../.synced-from"
do_install[file-checksums] += "${FPGAMIXER_SYNCED_FROM}:True"

do_install() {
    install -d ${D}${APPDIR}
    install -m 0644 ${S}/osc_mixer_server.py ${S}/osc_codec.py ${S}/osc_discovery.py \
        ${S}/mixer_params.py ${S}/mixer_state.py ${S}/mixer_hw.py ${S}/mixer_meters.py \
        ${S}/mixer_snapshots.py ${D}${APPDIR}/

    # Discovery: resolved's mDNS on (drop-in); the server writes its
    # _studiorunner._tcp service into /etc/systemd/dnssd/ at runtime.
    install -d ${D}${sysconfdir}/systemd/resolved.conf.d ${D}${sysconfdir}/systemd/dnssd
    install -m 0644 ${S}/fpgamixer-mdns.conf ${D}${sysconfdir}/systemd/resolved.conf.d/

    # The config reply's "firmware": the commit scripts/sync_buildhost.sh
    # synced (".synced-from", next to tools/ on the VM; '-dirty' if the tree
    # had changes). Without it the server reports "dev".
    if [ -f ${FPGAMIXER_SYNCED_FROM} ]; then
        install -m 0644 ${FPGAMIXER_SYNCED_FROM} ${D}${APPDIR}/VERSION
    fi

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/fpgamixer-osc.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${APPDIR} ${sysconfdir}/systemd/resolved.conf.d ${sysconfdir}/systemd/dnssd"
