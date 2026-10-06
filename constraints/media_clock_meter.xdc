# =============================================================================
# media_clock_meter.xdc -- CDC constraint for EVERY media_clock_meter instance
#
# Scoped to the module (SCOPED_TO_REF media_clock_meter in
# scripts/create_project.tcl, phase9), so cell names are relative to the
# instance. Keep the register names in step with src/rtl/media_clock_meter.sv.
#
# pps_async is asynchronous to mclk by design: in fpgamixer_top it is a bit of
# the PS's GEM TSU counter, which runs on the PS-internal 250 MHz TSU clock
# that the PL has no definition of. It enters a 2FF synchronizer (pps_s1,
# pps_s2, ASYNC_REG in RTL); nothing else of the meter sees it. The meter's
# result only depends on WHICH mclk edge first samples the new level, which
# the synchronizer settles, so no bound on the routing is needed: the path into
# the first stage is false.
# =============================================================================

set_false_path -to [get_pins pps_s1_reg/D]
