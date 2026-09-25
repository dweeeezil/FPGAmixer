# FPGAmixer kernel configuration on top of the EDF kernel.
#
#   fpgamixer-usb.cfg   USB device mode for the UAC2 gadget (Phase 8)
#
# Same pattern as meta-embedded-plus: the fragment goes into SRC_URI and is
# named in KERNEL_FEATURES, so kernel-yocto merges it after the distro's .scc
# features (which include usb-gadgets.scc when 'usbgadget' is a machine
# feature, setting USB_GADGET=m). Check the result in the build's .config:
# kernel_configcheck only warns when a requested value doesn't land.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://fpgamixer-usb.cfg"
KERNEL_FEATURES:append = " fpgamixer-usb.cfg"
