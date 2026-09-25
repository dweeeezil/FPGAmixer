# =============================================================================
# coef_bank_handoff.xdc -- CDC constraints for EVERY coef_bank_handoff instance
#
# Scoped to the module (scripts/create_project.tcl sets SCOPED_TO_REF
# coef_bank_handoff on this file), so cell names below are relative to each
# instance, and every instance -- the matrix today, the bus matrix and DSP
# blocks later -- is covered without editing this file. Keep the register
# names in step with src/rtl/coef_bank_handoff.sv.
#
# The two clocks are unrelated (src = AXI pl_clk0, dst = audio mclk). The ONLY
# paths between them inside the module:
#   1. req_tgl  -> req_s1   toggle into a 2FF synchronizer (ASYNC_REG in RTL)
#   2. ack_tgl  -> ack_s1   toggle into a 2FF synchronizer (ASYNC_REG in RTL)
#   3. xfer_bank -> active_bank   the bank, captured under an enable derived
#      from the synchronized request. xfer_bank is stable for >= 2 dst periods
#      before the capture edge (> 160 ns at 12.288 MHz); bounding the routing to
#      10 ns keeps bit-to-bit skew irrelevant.
#
# set_max_delay -datapath_only replaces the meaningless inter-clock setup
# check with a plain routing bound and drops hold for these paths.
# =============================================================================

set_max_delay -datapath_only 10.000 \
    -from [get_cells req_tgl_reg] \
    -to   [get_cells req_s1_reg]

set_max_delay -datapath_only 10.000 \
    -from [get_cells ack_tgl_reg] \
    -to   [get_cells ack_s1_reg]

set_max_delay -datapath_only 10.000 \
    -from [get_cells {xfer_bank_reg[*]}] \
    -to   [get_cells {active_bank_reg[*]}]
