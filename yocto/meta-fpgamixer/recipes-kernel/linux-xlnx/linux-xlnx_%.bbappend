# FPGAmixer kernel configuration on top of the EDF kernel.
#
#   fpgamixer-usb.cfg   USB device mode for the UAC2 gadget (Phase 8)
#
# Same pattern as meta-embedded-plus: the fragment goes into SRC_URI and is
# named in KERNEL_FEATURES, so kernel-yocto merges it after the distro's .scc
# features (which include usb-gadgets.scc when 'usbgadget' is a machine
# feature, setting USB_GADGET=m). Check the result in the build's .config:
# kernel_configcheck only warns when a requested value doesn't land.
#   0001-usb-gadget-f_uac2-...patch
#                       configfs switch single_clock: one Clock Source for
#                       both directions, so macOS shows ONE 8x8 device instead
#                       of a playback-only and a capture-only one. Default off
#                       (upstream behaviour); fpgamixer-usb-gadget turns it on.
#                       Written against linux-xlnx v2026.1 (6.18.10,
#                       4f7afe14f724): re-check it on every kernel update.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://fpgamixer-usb.cfg \
    file://0001-usb-gadget-f_uac2-add-optional-single-clock-source.patch \
"
KERNEL_FEATURES:append = " fpgamixer-usb.cfg"
