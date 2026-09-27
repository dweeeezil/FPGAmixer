# Put the FPGAmixer's own software into the EDF disk image, from the layer
# rather than from local.conf, so what the image contains is tracked in git.
#
#   fpgamixer-osc            the OSC server + parameter store, started at boot
#   fpgamixer-usb-gadget     the board as a UAC2 soundcard on the Type-C port
#   fpgamixer-usb-bridge     gadget <-> link audio, steering the Mac's clock
#   kernel-module-fpgamixer-link-card  ALSA card for the PS<->PL audio link
#                            (needs a Phase 8+ bitstream; bound by the DT)
#   alsa-utils-*             ALSA userspace: the genesys-zu3eg image ships none
#                            (checked in its manifest, 2026-09-25). alsaloop is
#                            the first candidate for the USB bridge; aplay
#                            (+ arecord), amixer and speaker-test are the bench
#                            tools for the gadget and the PL link cards.
#   fpgamixer-bench-network  bench addressing (end0 = 10.0.0.2/24 + DHCP),
#                            only with FPGAMIXER_BENCH = 1 (conf/layer.conf)
#   fpgamixer-gptp           ptp4l + phc2sys on end0 at boot (Phase 9, P9.1);
#                            pulls in linuxptp
#   linuxptp-configs ethtool the gPTP spike's bench tools (example configs,
#                            ethtool -T); were in the VM's local.conf until P9.1
IMAGE_INSTALL:append = " fpgamixer-osc fpgamixer-usb-gadget fpgamixer-usb-bridge \
    kernel-module-fpgamixer-link-card fpgamixer-gptp linuxptp-configs ethtool \
    alsa-utils-alsaloop alsa-utils-aplay alsa-utils-amixer alsa-utils-speakertest \
    ${@'fpgamixer-bench-network' if d.getVar('FPGAMIXER_BENCH') == '1' else ''}"

# ----- Bench login (FPGAMIXER_BENCH = 1 only) -----
# EDF's distro config creates 'amd-edf' with an EMPTY password that expires at
# once (useradd -p '' + passwd-expire), so every freshly flashed card needed a
# serial-console login to set a password before SSH would work. On the bench
# image the user instead gets a fixed password (chosen by the project owner,
# 2026-09-25) and no forced change, so the board is reachable over SSH
# straight after a flash.
#
# This replaces EDF's EXTRA_USERS_PARAMS (set there with ?=), keeping its
# groups; its sudoers rule (EXTRA_USERS_SUDOERS) is untouched. The value is a
# SHA-512 crypt hash with a fixed salt so builds are reproducible:
#   openssl passwd -6 -salt fpgamixerbench '<password>'
# '$' is escaped as extrausers.bbclass documents (PASSWD = "\$X\$ab\$cd").
# Anyone with the repo can recover a short password from this hash: it is a
# bench convenience, not security. A non-bench build (FPGAMIXER_BENCH = "0")
# keeps EDF's behaviour.
FPGAMIXER_BENCH_PW_HASH = "\$6\$fpgamixerbench\$zikEG7ZdSxk.e34tdhwwTIPp/ygESEijrGVMpPXAt2I18lhwmcKPYJZbCiJ.tIEKNPahs2.stXTCeRWwXulGn1"

FPGAMIXER_BENCH_USERS = "\
    useradd -p '${FPGAMIXER_BENCH_PW_HASH}' amd-edf; \
    groupadd -r aie; \
    groupadd -r wayland; \
    usermod -a -G aie,audio,input,users,video,wayland amd-edf; \
"

EXTRA_USERS_PARAMS := "${@d.getVar('FPGAMIXER_BENCH_USERS') if d.getVar('FPGAMIXER_BENCH') == '1' else d.getVar('EXTRA_USERS_PARAMS')}"
