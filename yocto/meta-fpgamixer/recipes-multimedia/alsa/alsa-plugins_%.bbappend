# FPGAmixer (Phase 9, P9.6, decision A7): build the AAF PCM plugin, the AVB
# talker/listener that looks like an ALSA device (libasound_module_pcm_aaf.so,
# packaged as libasound-module-pcm-aaf). It pulls in libavtp from
# meta-openembedded/meta-multimedia. Only that plugin package goes into the
# image (via fpgamixer-avb's RDEPENDS), not the whole alsa-plugins set.
PACKAGECONFIG:append = " aaf"

# Phase 10: an optional 'bit_depth' key, so the plugin can send and accept
# AAF INT_32BIT with bit_depth 24 (Milan's base format). Written against
# alsa-plugins 1.2.7.1, whose aaf/pcm_aaf.c is identical to 1.2.12's.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://0001-aaf-optional-bit_depth.patch"
