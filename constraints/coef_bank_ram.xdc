# =============================================================================
# coef_bank_ram.xdc -- CDC constraints for EVERY coef_bank_ram instance
#
# Scoped to the module (SCOPED_TO_REF coef_bank_ram in
# scripts/create_project.tcl, added when the module enters the build in
# P9.A5), so cell names are relative to each instance. Keep the register names
# in step with src/rtl/coef_bank_ram.sv.
#
# The two clocks are unrelated (aclk = AXI pl_clk0, mclk = audio). The ONLY
# register-to-register paths between them inside the module:
#   1. req_tgl -> req_s1   toggle into a 2FF synchronizer (ASYNC_REG in RTL)
#   2. ack_tgl -> ack_s1   toggle into a 2FF synchronizer (ASYNC_REG in RTL)
# The coefficient data crosses inside the lane RAMs (ram_style "block": port
# A written on aclk, port B read on mclk), where there is no timing path
# between the ports; the protocol keeps the two ports on different banks.
# Unlike coef_bank_handoff there is no multi-bit bank register crossing.
#
# The toggles have no reset, so every path starting at them is a plain
# register launch; bounding the routing to 10 ns is the same formulation as
# coef_bank_handoff.xdc.
# =============================================================================

set_max_delay -datapath_only 10.000 \
    -from [get_cells req_tgl_reg] \
    -to   [get_cells req_s1_reg]

set_max_delay -datapath_only 10.000 \
    -from [get_cells ack_tgl_reg] \
    -to   [get_cells ack_s1_reg]
