# Put the FPGAmixer's own software into the EDF disk image, from the layer
# rather than from local.conf, so what the image contains is tracked in git.
#
#   fpgamixer-osc            the OSC server + parameter store, started at boot
#   fpgamixer-usb-gadget     the board as a UAC2 soundcard on the Type-C port
#   alsa-utils-*             ALSA userspace: the genesys-zu3eg image ships none
#                            (checked in its manifest, 2026-09-25). alsaloop is
#                            the first candidate for the USB bridge; aplay
#                            (+ arecord), amixer and speaker-test are the bench
#                            tools for the gadget and the PL link cards.
#   fpgamixer-bench-network  bench addressing (end0 = 10.0.0.2/24 + DHCP),
#                            only with FPGAMIXER_BENCH = 1 (conf/layer.conf)
IMAGE_INSTALL:append = " fpgamixer-osc fpgamixer-usb-gadget \
    alsa-utils-alsaloop alsa-utils-aplay alsa-utils-amixer alsa-utils-speakertest \
    ${@'fpgamixer-bench-network' if d.getVar('FPGAMIXER_BENCH') == '1' else ''}"
