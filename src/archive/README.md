# src/archive

RTL and testbenches no longer in the build, kept for reference (and in git history).

**Moved here 2026-10-07 (Phase 11, decision P1: the Pmod I2S2 modules removed;
the board's analog I/O is now a USB interface on link #3):**

- `rtl/i2s_port.sv`, `rtl/i2s_receiver.sv`, `rtl/i2s_transmitter.sv`,
  `rtl/i2s_clock_divider.sv`, `rtl/oddr_out.sv`: the Pmod I2S2 front door
  (Phases 1–3.5, the L/R skew fix of Phase 9 C7). The codec-interface timing
  constraints they needed are in `constraints/fpgamixer_genesys_zu.xdc`'s git
  history before this change.
- `rtl/phase1_top.sv`, `rtl/phase2_top.sv`: the Phase 1–2 loopback tops.
- `sim/tb_i2s_*.sv`: their unit tests; `sim/tb_phase3_datapath.sv`,
  `sim/tb_phase3_dynamic.sv`: the integration tests that drove audio through
  `fpgamixer_top`'s Pmod pins.

`scripts/create_project.tcl` globs `src/rtl/*.sv` and `src/sim/*.sv` only, so
nothing here is in the Vivado project; the `phase1`–`phase3` project variants
that used these files no longer build from this tree.
