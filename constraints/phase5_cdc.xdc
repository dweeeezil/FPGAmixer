# =============================================================================
# phase5_cdc.xdc -- clock-domain crossings of the Phase 5 gain registers
#
# Added on top of phase3_genesys_zu.xdc for phase5 builds only (the cells named
# here exist only when INCLUDE_PS instantiates u_regs in phase3_top).
#
# The two clocks are unrelated: ctrl_aclk is the PS's pl_clk0 (100 MHz), mclk
# is the 12.288 MHz MMCM output from the 25 MHz PL reference. The ONLY paths
# between them are inside u_regs (matrix_regs_axil.sv, see its header):
#
#   1. req_tgl  -> req_s1   toggle into a 2FF synchronizer (ASYNC_REG)
#   2. ack_tgl  -> ack_s1   toggle into a 2FF synchronizer (ASYNC_REG)
#   3. xfer_bank -> active_bank   288-bit bus, captured under an enable derived
#      from the synchronized request. xfer_bank is held stable for >= 2 mclk
#      periods (> 160 ns) before the capture edge, so the requirement is that
#      every bit arrives well inside that window -- bounded here to one aclk
#      period so skew stays irrelevant.
#
# set_max_delay -datapath_only replaces the (meaningless) inter-clock setup
# check with a plain routing bound and drops hold for these paths.
# =============================================================================

set cdc_max 10.000

set_max_delay -datapath_only $cdc_max \
    -from [get_cells u_regs/req_tgl_reg] \
    -to   [get_cells u_regs/req_s1_reg]

set_max_delay -datapath_only $cdc_max \
    -from [get_cells u_regs/ack_tgl_reg] \
    -to   [get_cells u_regs/ack_s1_reg]

set_max_delay -datapath_only $cdc_max \
    -from [get_cells -hier -filter {NAME =~ u_regs/xfer_bank_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ u_regs/active_bank_reg*}]
