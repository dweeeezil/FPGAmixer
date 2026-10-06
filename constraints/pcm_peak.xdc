# =============================================================================
# pcm_peak.xdc -- CDC constraints for EVERY pcm_peak instance
#
# Scoped to the module (SCOPED_TO_REF pcm_peak in scripts/create_project.tcl),
# so cell names are relative to each instance. Keep the register names in
# step with src/rtl/pcm_peak.sv.
#
# The two clocks are unrelated (aclk = AXI pl_clk0, mclk = audio). The ONLY
# register-to-register paths between them inside the module:
#   1. req_tgl -> req_s1      toggle into a 2FF synchronizer (ASYNC_REG in RTL)
#   2. ack_tgl -> ack_s1      toggle into a 2FF synchronizer (ASYNC_REG in RTL)
#   3. closed  -> st_rdata    multi-bit, captured under a read enable that is
#                             only true while the protocol holds closed stable
#                             (>= 2 aclk periods after its last change): the
#                             MCP formulation of coef_bank_handoff.xdc
# Bounding the routing to 10 ns (one aclk period) keeps the skew between the
# bits of path 3 below the settling time the protocol guarantees.
# =============================================================================

set_max_delay -datapath_only 10.000 \
    -from [get_cells req_tgl_reg] \
    -to   [get_cells req_s1_reg]

set_max_delay -datapath_only 10.000 \
    -from [get_cells ack_tgl_reg] \
    -to   [get_cells ack_s1_reg]

set_max_delay -datapath_only 10.000 \
    -from [get_cells {closed_reg[*][*]}] \
    -to   [get_cells {st_rdata_reg[*]}]
