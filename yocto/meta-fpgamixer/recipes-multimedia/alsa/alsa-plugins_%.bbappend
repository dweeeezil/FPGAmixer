# FPGAmixer (Phase 9, P9.6, decision A7): build the AAF PCM plugin, the AVB
# talker/listener that looks like an ALSA device (libasound_module_pcm_aaf.so,
# packaged as libasound-module-pcm-aaf). It pulls in libavtp from
# meta-openembedded/meta-multimedia. Only that plugin package goes into the
# image (via fpgamixer-avb's RDEPENDS), not the whole alsa-plugins set.
PACKAGECONFIG:append = " aaf"
