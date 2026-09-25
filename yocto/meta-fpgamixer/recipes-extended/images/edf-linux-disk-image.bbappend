# Put the FPGAmixer's own software into the EDF disk image, from the layer
# rather than from local.conf, so what the image contains is tracked in git.
#
#   fpgamixer-osc            the OSC server + parameter store, started at boot
#   fpgamixer-bench-network  bench addressing (end0 = 10.0.0.2/24 + DHCP),
#                            only with FPGAMIXER_BENCH = 1 (conf/layer.conf)
IMAGE_INSTALL:append = " fpgamixer-osc \
    ${@'fpgamixer-bench-network' if d.getVar('FPGAMIXER_BENCH') == '1' else ''}"
