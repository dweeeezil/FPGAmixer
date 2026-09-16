# FPGAmixer — solved bug report: Phase 3 noise / distortion

**Date:** August 14, 2026, 19:33 PDT
**Status:** Root cause found and fixed in RTL; verified in simulation (including a new regression that reproduces the bug). **Hardware re-test pending** — see the bring-up checklist at the end.
**Supersedes:** the open bug in `reset_2026-08-07_phase3-debug.md`.

---

## Symptom (as reported in the Aug 7 handoff)

- Looped-back audio through Phase 3 was significantly distorted.
- A steady ~−18 dBFS noise signal was present even with no audio playing, on both monitored outputs (JA_L, JB_L), including under IDENTITY routing.
- The noise onset was ~5 seconds **after** the DONE LED — the clue that (correctly) pointed away from datapath math, but (incorrectly) toward a purely analog cause.
- Meanwhile: all six testbenches passed, timing closed with ~74 ns of margin, power was ruled out.

## Root cause

**`i2s_transmitter` launched `sdata_o` exactly ON the SCLK rising edge at the pins — the edge the CS4344 DAC samples.**

The mechanism is arithmetic, not exotic:

- `sclk`/`lrck` (divider counter bits) and `sdata_o` are all mclk-registered, so **every pin transition lands on an mclk posedge**.
- SCLK = mclk/4, so half an SCLK period is exactly **2 mclk cycles**.
- The transmitter detected SCLK edges through two registered copies (`sclk_r`, `sclk_prev`), which adds exactly **2 mclk of latency** between the true falling edge and the `sdata_o` update.
- Falling edge + 2 mclk = rising edge. The data launch landed precisely on the DAC's sampling edge:

```
bit cell (4 mclk):    E0        E1        E2        E3        E4
SCLK at pin:          fall                rise                fall
CS4344 samples:                           ^
sdata_o, BUGGY:                           X changes   <- ON the sampling edge (race)
sdata_o, FIXED:                 X changes             <- mid-cell: ~81 ns setup, ~244 ns hold
```

Which bit the DAC actually captured came down to a few ns of relative pin-path routing skew between the SCLK path and the SDIN path — a razor race that **placement re-rolls on every build**.

The receive direction was never affected: the CS5343 launches data on the falling edge and `i2s_receiver` samples mid-cell ~160–240 ns later. Only the transmit direction sat on the razor. The receiver is unchanged by this fix.

## Why every existing check said "fine"

| Check | Why it was blind |
|---|---|
| All six testbenches | Every functional TB monitors the transmitter with the in-house `i2s_receiver` (or a harness with the same timing), which samples `sdata` ~1 mclk **after** the rising edge — it always reads the freshly-launched bit. The CS4344 samples **at** the edge. The bug lives in the last ~2 ns at the pin; a functional capture check structurally cannot see it. |
| Vivado timing closure | STA only covered internal mclk-domain paths. There are no `set_output_delay` constraints modeling the codec's setup/hold, so the pin race was invisible to timing analysis too. |
| "Phase 2 was hardware-validated" | The race is settled by per-build routing skew. Phase 2's placement happened to land data-before-clock; Phase 3 re-placed everything (doubled clock-pin loads, added the matrix) and the coin landed the other way. Phase 2 was working on borrowed luck — any rebuild could have flipped it. |

## How the root cause maps to each symptom

- **Distortion:** every bit boundary where SDIN transitions is a coin flip at the DAC, so program material picks up sporadic wrong bits — worst when a flip hits a high-order bit.
- **~−18 dBFS noise from silence:** the ADC's high-pass-filtered idle output dithers between `0x000000` and `0xFFFFFF` (0 and −1). Serializing −1 puts a 0→1 transition (delay bit → sign bit) exactly on the MSB sampling edge; each mis-capture turns an inaudible −1 into ~+full-scale (`0x7FFFFF`). A few-percent flip rate on that one bit yields a steady hash in the −18 dBFS neighborhood. (−18 dB ≈ 1/8 also matches a 3-bit shift, which is what made "bit misalignment" tempting — but a static shift can't manufacture noise out of silence. This can.)
- **The ~5 s onset after DONE:** consistent with codec DC settling gating the *audibility* of a constant digital bug. Immediately after reset the ADC's DC offset is large, so idle words keep a stable sign bit and the razor has nothing to flip. Once the HPF pulls the offset down to straddle 0/−1 (seconds, compounded by the CS4344 PopGuard output ramp), the sign-bit razor switches on and noise "appears from nowhere." Nothing in the RTL needs a multi-second timescale — the Aug 7 instinct that the delay was analog settling was right; the settling was *revealing* the bug, not causing it.

## Evidence

A diagnostic probe (Icarus, against the unmodified RTL: real divider + real transmitter, worst-case `0xAAAAAA`/`0x555555` data) measured where every `sdata_o` transition lands within the 4-mclk bit cell:

```
BEFORE:  192 transitions, all at +2 mclk after the SCLK falling edge  (+2 = the rising edge)
AFTER:   192 transitions, all at +1 mclk after the SCLK falling edge  (mid-cell)
```

The probe's check is now a permanent regression, `src/sim/tb_i2s_tx_pin_phase.sv` (target `txphase` in `scripts/sim.mk`, part of `all`): **`sdata_o` may only change while SCLK is low.** Against the pre-fix transmitter it fails 202/202 transitions; against the fixed one it passes 202/202.

## The fix

Three functional lines in `src/rtl/i2s_transmitter.sv` — detect edges one flop earlier so the data launch moves from falling+2 (= the rising edge) to falling+1 (mid-cell):

```systemverilog
wire sclk_falling = !sclk_i && sclk_r;    // was: !sclk_r && sclk_prev
wire lrck_changed = (lrck_i != lrck_r);   // was: (lrck_r != lrck_prev)
...
shift_reg <= (lrck_i == 1'b0) ? left_data : right_data;   // was: lrck_r
```

(The now-unused `sclk_prev`/`lrck_prev` registers were removed.)

**Why this is safe:** `sclk_i`/`lrck_i` are outputs of the same-mclk-domain divider — synchronous signals, not async inputs. The 2FF stages were synchronizer-style caution the internal path doesn't need, and their latency is exactly what pushed the launch onto the sampling edge. The header comment in the module now documents this as a load-bearing constraint. Do **not** re-add the second flop, and do not reuse 1FF detection anywhere the clocks genuinely cross domains.

**The trap the third line avoids:** the first fix attempt changed only the two detection lines. The unit testbenches immediately failed with a clean L↔R swap — with early detection, `lrck_r` still holds the *old* channel level at load time, so the load mux picked the wrong word. Two details worth keeping:

1. The channel select must come from `lrck_i` (the new level) whenever detection is 1FF-early.
2. `tb_phase3_datapath` alone would have **passed** that broken intermediate — the swap happens at both the stimulus transmitter and the output transmitter and cancels end-to-end. The unit/integration split in the TB suite is what caught it. Keep both layers.

## Verification performed (2026-08-14)

- `make -f scripts/sim.mk all` — all **seven** testbenches pass (the original six plus `txphase`).
- Offset probe on the fixed RTL: all transitions at falling+1, none on either SCLK edge.
- `tb_i2s_tx_pin_phase` vs the pre-fix transmitter: FAIL (202/202 flagged) — the regression demonstrably catches the original bug.
- Frame latency, delay-bit slot, and the documented one-frame L/R skew are all unchanged by the retiming (the TX still loads before the matrix's frame update, exactly as before).

**Not verified (requires hardware):** the actual point of all this. Sim proves the pin phase is now mid-cell; silicon proves the noise is gone.

## Hardware bring-up checklist

1. Rebuild: `vivado -source scripts/create_project.tcl`, synth + impl + bitstream (routing is still IDENTITY in `phase3_top.sv`).
2. Program the board. Expected: **no noise onset at all** — not at DONE, not 5 s later. Idle outputs should be silent.
3. Feed audio into JA/JB line-in; identity loopback should be clean on all monitored outputs (get JA_R/JB_R monitored too if cabling allows).
4. If clean: restore the DEMO routing (swap the commented `MATRIX_GAINS` block in `phase3_top.sv`) and re-verify the cross-route and 0.5+0.5 mix.
5. If noise persists: re-open `reset_2026-08-07_phase3-debug.md` — but re-read its "ruled out" list first; this fix removes the leading digital suspect, and the next candidates were codec sequencing and MCLK jitter.

## Follow-ups (not in this change)

- **`set_output_delay`/`set_input_delay` constraints** for the codec interfaces, so STA covers the pin timing that silently carried this bug. With the mid-cell launch there is ~81 ns of setup margin to protect — generous, but it should be *constrained*, not lucky.
- **ODDR clock forwarding for MCLK** (jitter improvement, was suspect #2 in the Aug 7 doc). Warning recorded here deliberately: ODDR makes SCLK arrive *earlier* at the pin, so applying it **without** this TX fix would likely have converted the razor race into a deterministic wrong-bit capture. Sequence matters: TX phase first (done), ODDR later if wanted.
- **Known one-frame L/R skew** (transmitter latches L and R from adjacent matrix frames) — still open, still inaudible, fix is one output-hold register.
- `vivado_project/` is tracked in git despite the README describing it as generated-and-ignored; separate cleanup.
