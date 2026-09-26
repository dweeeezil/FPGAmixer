SUMMARY = "FPGAmixer PS<->PL audio link: ALSA card over the AMD Audio Formatter"
DESCRIPTION = "Out-of-tree ASoC machine driver (one DAI link: dummy CPU and \
codec DAIs, the in-kernel xlnx_formatter_pcm as platform) that turns the \
FPGAmixer's Audio Formatter into the ALSA card 'FPGAmixerLink'. Bound by the \
device tree (compatible fpgamixer,pcm-link-card, in system-user.dtsi) and \
loaded by udev from its modalias. Link-generic: nothing here knows about USB. \
See docs/phase8_status_*.md in the repo."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit module

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI = " \
    file://Makefile \
    file://fpgamixer-link-card.c \
"

S = "${WORKDIR}"

RPROVIDES:${PN} += "kernel-module-fpgamixer-link-card"
