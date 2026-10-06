# FPGAmixer (Phase 10): accept gPTP from macOS, whose Follow_Up carries an
# Apple TLV after messageLength (every Follow_Up was a "bad message", the
# port stayed UNCALIBRATED). Written against linuxptp 4.4 (meta-xilinx).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://0001-msg-ignore-octets-after-messageLength.patch"
