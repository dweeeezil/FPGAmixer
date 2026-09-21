# Handoff: codec-interface timing hardening (ODDR forwarding + pin-delay constraints)

**Repo:** github.com/dweeeezil/FPGAmixer
**Board:** Arty Z7-20 (xc7z020clg400-1), 2× Pmod I2S2 on JA + JB
**Codecs:** CS4344-CZZ (DAC, sinks SDIN) and CS5343-CZZ (ADC, sources SDOUT), both in **slave** mode — the FPGA is I2S master and drives MCLK/SCLK/LRCK to both.
**Prepared for:** a Claude Code session that can run Vivado (STA) and reprogram the board. Written because the payoff of this work is only observable in static timing analysis and on hardware — the Icarus functional sim is structurally blind to it (see §6).

---

## 1. Goal

Two coupled changes that make the codec interface timing *deterministic and analyzable*, instead of dependent on per-build fabric routing luck:

- **A. Forward MCLK/SCLK/LRCK (and SDIN) through ODDR primitives** instead of the current plain combinational assigns, so their launch instants are pinned to the MCLK network through the dedicated OLOGIC→OBUF path.
- **B. Add `set_output_delay`/`set_input_delay` constraints** on the codec pins so STA actually covers the SDIN→DAC and ADC→SDOUT paths — the exact region where the Phase 3 pin-phase race lived and where STA currently sees nothing.

These are coupled because the correct output-delay formulation depends on whether SDIN/SCLK leave via ODDR or combinationally. Do them together.

## 2. Preconditions (already true — don't redo)

- Phase 3 is hardware-validated. The I2S TX pin-phase race is fixed in `i2s_transmitter.sv` (1-flop-early edge detect; data now launches ~half an SCLK before the DAC's sampling edge). Regression test `tb_i2s_tx_pin_phase` guards it.
- The duplicate `create_clock` is gone from both XDCs; the clk_wiz IP owns the primary clock. A post-route methodology gate (`scripts/check_methodology.tcl`) fails the build on any Critical Warning. **This means there is, for the first time, a trustworthy STA baseline to compare against.** Capture the current WNS/methodology report before changing anything.

## 3. Current forwarding (what you're replacing)

In `src/rtl/phase3_top.sv`, all clock/frame outputs are combinational:

```systemverilog
assign ja_da_mclk = mclk;  assign ja_da_lrck = lrck;  assign ja_da_sclk = sclk;
// ...same for ja_ad_*, jb_da_*, jb_ad_*  (8 destinations, one MMCM + one divider)
```

`mclk` = 12.288 MHz (MMCM `clk_out1`). `sclk` = `cnt[1]` = MCLK/4 ≈ 3.072 MHz, `lrck` = `cnt[7]` = MCLK/256 = 48 kHz, both generated in `i2s_clock_divider.sv` as counter bits in the MCLK domain. SDIN (`ja_da_sdin`, `jb_da_sdin`) comes from `i2s_transmitter`, also MCLK-domain.

Internal I2S convention (from `i2s_receiver.sv`): **data changes on SCLK falling, is sampled on SCLK rising.** The receiver samples SDOUT against its *internal* SCLK net, not a forwarded copy — this matters in §4.3.

## 4. Workstream A — ODDR forwarding

### 4.1 Per-signal ODDR configuration (7-series ODDR, UG471)

| Signal(s) | ODDR clock `C` | `D1`, `D2` | Effect |
|---|---|---|---|
| MCLK (×4 pins) | `mclk` | `D1=1'b1`, `D2=1'b0` | Reconstructs a clean 12.288 MHz clock at the pin, phase-defined by the ODDR. Standard clock-forwarding idiom. |
| SCLK (×4), LRCK (×4), SDIN (×2) | `mclk` | `D1=D2=<signal>` | Passes the SDR value through, relaunched on the MCLK edge via the dedicated output path. Adds ~1 MCLK (≈81 ns) of launch latency. |

Wrap this in a small `oddr_out` module rather than scattering primitives through the top. Instantiate one per physical output pin (MCLK/SCLK/LRCK fan out to both Pmods and both codec sides = 8 clock/frame pins + 2 SDIN pins). Keep `DDR_CLK_EDGE="SAME_EDGE"`, `SRTYPE="SYNC"`, reset tied off unless there's a reason otherwise.

### 4.2 The one rule that must not be broken

**SCLK, LRCK, and SDIN must all get the identical ODDR treatment (same clock, same `D1=D2` pattern), so all three receive the same ~1 MCLK launch latency and their *relative* alignment is preserved.** The thing that was just fixed — SDIN launching ~half an SCLK before the DAC's sampling edge — survives only if SDIN and SCLK move together. If SDIN goes through ODDR but SCLK stays combinational (or vice-versa), you deterministically re-create the Phase 3 pin-phase race. This is the single highest-risk mistake in this change.

### 4.3 Interactions STA must confirm (not assumed safe)

1. **MCLK-vs-SCLK phase.** MCLK via ODDR(1,0) reconstructs the clock; the SDR group shifts ~1 MCLK relative to it. The codecs require SCLK/LRCK synchronous to MCLK — verify the resulting MCLK↔SCLK relationship still meets the CS4344/CS5343 requirements. (The 81 ns shift is large relative to ns-scale setup/hold; confirm, don't hand-wave.)
2. **RX sampling margin.** The ADC receives the *forwarded* SCLK (now ~1 MCLK later at the pin) and drives SDOUT relative to it. The FPGA receiver samples SDOUT against the *internal, un-forwarded* SCLK — so forwarding introduces ~1 MCLK of skew between the SCLK the ADC uses and the SCLK the receiver samples on. Verify the capture still lands in-window. This may require referencing the receiver's sampling to the forwarded-SCLK phase, or absorbing the skew in the `set_input_delay` numbers (Workstream B). **Resolve this explicitly; don't leave it to chance.**

### 4.4 Simulation note

The ODDR primitive won't elaborate under Icarus. Follow the existing stub precedent (`src/sim/clk_wiz_audio_stub.sv`, excluded from Vivado): put a behavioral ODDR model behind an ``ifdef`` (e.g. `SIM_ODDR`) inside `oddr_out`, real primitive for Vivado, behavioral for Icarus, and add the define in `scripts/sim.mk`. **But see §6 — a green sim here only proves the logic still works, nothing about the timing.** The sim's job is regression-guarding the datapath, not validating this change.

## 5. Workstream B — codec pin-delay constraints

Add these to `constraints/phase3_arty_z7.xdc` (and mirror the pattern into `phase1_arty_z7.xdc` if you want Phase 1 STA to be honest too).

### 5.1 Datasheet numbers

**ADC input path (CS5343) — available in repo** (`docs/CS5343-44_F5.pdf`, p.9, Slave Mode, C_L = 20 pF):

- SDOUT valid *before* SCLK rising: `t_stp` = 10 ns (min)
- SDOUT valid *after* SCLK rising: `t_hld` = 40 ns (min)
- SCLK falling to LRCK edge: `t_slrd` = −20 … +20 ns
- Convention: data driven on SCLK falling, sampled on SCLK rising.

These seed `set_input_delay` on `ja_ad_sdout` / `jb_ad_sdout`, referenced to the SCLK the FPGA forwards (a forwarded-clock / source-synchronous-return formulation, *including* the round-trip: FPGA→SCLK-out→ADC→SDOUT-in). Board trace delay on the Pmod is short but nonzero; treat it as a small fixed number and note it as an assumption.

**DAC output path (CS4344) — NOT in the repo.** The SDIN setup/hold-vs-SCLK figures the `set_output_delay` on `ja_da_sdin`/`jb_da_sdin` needs are in the **CS4344 datasheet (Cirrus DS692)**, which must be fetched. Do not invent these — pull the actual serial-audio-input setup (`t_su`) and hold (`t_h`) relative to SCLK and use them. Flag this as the one external dependency for the constraint values.

### 5.2 Formulation

Both directions are source-synchronous relative to the FPGA-generated SCLK. Derive `set_output_delay -max/-min` (SDIN) from the DAC setup/hold, and `set_input_delay -max/-min` (SDOUT) from the ADC `t_stp`/`t_hld` above, each against a clock definition that reflects how SCLK actually reaches the codec (post-ODDR). This is the part most likely to need two or three STA iterations to get slack positive and *meaningful* — expect that, and read the timing report each pass rather than trusting the first green.

## 6. Why the functional sim can't validate this (read before trusting a green suite)

`tb_phase3_datapath` taps the DUT's own SCLK/LRCK off the internal nets/pins and clocks its monitor "DACs" on them with **zero pin-path or trace delay**. ODDR forwarding and pin-delay constraints are entirely *about* pin-launch timing and build-to-build skew — none of which exists in the sim model. So after this change the seven-testbench suite proves only "the logic still produces the right samples." It cannot tell you whether the timing goal was met or whether you nudged a codec setup/hold out of spec. Validation is STA + hardware, full stop.

## 7. Definition of done

1. `make -f scripts/sim.mk all` — all seven testbenches still pass (regression guard only).
2. Rebuild (`vivado -source scripts/create_project.tcl`), implement. Methodology gate passes; **no new** TIMING Critical Warnings.
3. Under the new pin-delay constraints, the SDIN→DAC and ADC→SDOUT paths report **positive, non-trivial** slack — and the report is now actually analyzing those paths (confirm they're no longer unconstrained). Compare WNS against the §2 baseline; explain any regression.
4. §4.3 interactions (MCLK-vs-SCLK, RX margin) each explicitly checked in the timing report, not assumed.
5. **Hardware re-test on identity routing**: reprogram, confirm the −18 dBFS-from-silence noise class has *not* returned and audio is clean on all four channels. Only then restore the DEMO routing block in `phase3_top.sv` (currently commented) and re-confirm.
6. Update `docs/` with a short dated note recording the final constraint values, the DAC datasheet figures used, and the hardware result.

## 8. Explicitly out of scope

- The one-frame L/R interchannel skew (inaudible; its output-hold-register fix rides along whenever the transmitter is next touched — not here).
- Any matrix/routing/DSP change. This is interface timing only; the bitstream's audio function is unchanged by ODDR/constraints.

## 9. References

- Xilinx UG471 (7-series SelectIO), ODDR usage for clock forwarding.
- CS5343-44 datasheet in repo: `docs/CS5343-44_F5.pdf`, p.9 (Slave Mode switching characteristics), Figures 1–2 p.10.
- CS4344 datasheet (Cirrus DS692) — **to be fetched** for the SDIN output-delay numbers.
- Prior context: `docs/bugfix_2026-08-14_phase3-noise.md` (the pin-phase race this hardens against).
