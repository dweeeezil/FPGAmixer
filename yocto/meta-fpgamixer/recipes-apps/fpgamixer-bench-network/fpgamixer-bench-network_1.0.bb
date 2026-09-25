SUMMARY = "FPGAmixer bench network: end0 = 10.0.0.2/24 plus DHCP"
DESCRIPTION = "Lab-only addressing for the Genesys ZU-3EG on the gPTP bench \
(end0 cabled to the Raspberry Pi 5's I350, Pi = 10.0.0.1). Kept out of the \
mixer recipes on purpose: it describes the bench, not the product. Included \
only when FPGAMIXER_BENCH = 1 (the default, conf/layer.conf)."
LICENSE = "CLOSED"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = "file://10-end0-bench.network"
S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${S}/10-end0-bench.network ${D}${sysconfdir}/systemd/network/
}

FILES:${PN} = "${sysconfdir}/systemd/network/10-end0-bench.network"
