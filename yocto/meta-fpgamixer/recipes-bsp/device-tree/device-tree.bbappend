FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Board fixes for the Linux device tree only. device-tree is also built in the
# FSBL and PMU multiconfigs (esw.bbclass depends on device-tree:do_deploy in
# each), where TARGET_OS is not "linux", so the :linux override keeps these
# out of the firmware domains. EXTRA_DT_INCLUDE_FILES (meta-xilinx-core
# device-tree.bb) adds the file to SRC_URI and #includes it into BASE_DTS.
EXTRA_DT_INCLUDE_FILES:append:linux = " system-user.dtsi"
