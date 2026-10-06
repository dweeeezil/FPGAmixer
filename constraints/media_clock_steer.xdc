# =============================================================================
# media_clock_steer.xdc -- CDC constraint for EVERY media_clock_steer instance
#
# Scoped to the module (SCOPED_TO_REF media_clock_steer in
# scripts/create_project.tcl, phase9). Keep the register names in step with
# src/rtl/media_clock_steer.sv.
#
# mmcm_locked is the MMCM's LOCKED output, asynchronous to PSCLK (pl_clk0). It
# enters a 2FF synchronizer (lk_s1, lk_s2, ASYNC_REG in RTL); only lk_s2 is
# used. Which PSCLK edge first sees LOCKED change doesn't matter, so the path
# into the first stage is false. PSEN / PSINCDEC / PSDONE are synchronous to
# PSCLK at the MMCM and are timed normally.
# =============================================================================

set_false_path -to [get_pins lk_s1_reg/D]
