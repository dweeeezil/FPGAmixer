# FPGAmixer — progress report

**Date:** August 7, 2026
**Covers:** Phase 3 (static PCM matrix mixer), simulation infrastructure, Phase 2 testbench repair
**Previous report:** project_status_2026-08-06.md

---

## Summary

Phase 3 — the static 4-in / 4-out PCM matrix mixer across both Pmod I2S2 modules — is written and **verified in simulation**. A command-line simulation flow now exists and works, which is the thing the previous report flagged as a prerequisite before Phase 3 went deep. As a side effect of getting that flow running, the three Phase 2 testbenches (which had never actually executed end-to-end) were found to be broken and have been fixed.

One important boundary: "verified" here means **simulation**, not silicon. Phases 1 and 2 were hardware-validated. Phase 3 has not yet been synthesized in Vivado or run on the board. The build and hardware bring-up are the next step, and the checklist for that is at the end of this doc.

---

## Phase 3 — what was built

Three new RTL/constraint files implement the mixer:

- **`src/rtl/pcm_matrix.sv`** — a static N×N crosspoint matrix. Each output is the saturated sum of every input times a compile-time gain: `out[o] = saturate(Σ in[i]·gain[o][i])`. There is no runtime control yet; changing the mix means rebuilding. That's expected — live control is Phase 5.
- **`src/rtl/phase3_top.sv`** — the top level: two I2S receivers (JA + JB) feed the matrix, which feeds two I2S transmitters (JA + JB). All four inputs and four outputs are analog via the two Pmods.
- **`constraints/phase3_arty_z7.xdc`** — JA pins unchanged from Phase 1/2; JB pins taken from Digilent's official Arty-Z7-20 master XDC, mirroring the same Pmod-pin-to-function mapping that JA uses.

### Design decisions worth knowing

**One clock tree drives both Pmods.** A single MMCM and a single clock divider generate the MCLK/SCLK/LRCK that go to all four converters. This means every input and output is sample-synchronous and lives in one clock domain, so the matrix can combine the four inputs with no clock-domain crossing. This is the assumption that makes the matrix trivially correct. If the two Pmods ever run on independent clocks, that assumption breaks and the design would need elastic buffering between inputs.

**Fixed-point format.** Samples are 24-bit signed two's-complement PCM. Gains are signed Q2.16 (18-bit, 16 fractional): unity is `0x10000`, half is `0x08000`, phase-invert (−1.0) is `0x30000`, mute is `0`. Each crosspoint is a 24×18 signed multiply, which maps to one DSP48 on the Zynq — so the N=4 matrix should infer 16 DSP48s. The accumulator is sized (44-bit) so it cannot overflow before the final clamp back to 24-bit.

**Truncation, not rounding,** on the fixed-point descale. This was chosen so results are hand-checkable in a waveform. It introduces a sub-LSB DC bias toward −∞. Rounding is a one-line half-LSB add before the shift when it's wanted later.

### Default routing (compile-time)

The mix currently baked into `phase3_top` (rows are outputs, so each output is a sum over inputs):

| Output | Sourced from | Purpose |
|---|---|---|
| JA_L | JA_L (unity) | passthrough |
| JA_R | JB_L (unity) | cross-Pmod route |
| JB_L | 0.5·JA_L + 0.5·JB_L | summed mix |
| JB_R | JB_R (unity) | passthrough |

This is deliberately varied — a passthrough, a cross-route between Pmods, and a summed 0.5+0.5 mix — so that when it's on hardware, a wiring or routing error is audible rather than silent. Changing the mix is editing one `localparam` in `phase3_top.sv`.

### Verification

Two testbenches, both passing:

- **`tb_pcm_matrix`** — drives PCM straight in and out (no I2S timing), checking 28 cases against an *independent* 64-bit reference model rather than hardcoded expected values. Covers unity passthrough, cross-routing, the 0.5+0.5 mix, truncation, positive and negative saturation, and phase-invert / sign handling.
- **`tb_phase3_datapath`** — the full end-to-end path through the real `phase3_top` (with the MMCM IP replaced by a behavioral stub). It uses the project's *own* known-good transmitter as the ADC stimulus and receiver as the DAC monitor, so there is no hand-rolled bit timing anywhere. 16 checks across four input vectors.

The integration test earned its place immediately: it caught a real bug in the Phase 3 gain constant (an output was routing input 0 instead of input 3 because unity sat in the wrong column). A bug like that would have shown up on hardware as "why does one output sound wrong," which is exactly the kind of thing that's slow to chase in silicon and fast to catch in sim.

---

## Simulation infrastructure

There is now a working command-line simulation flow, entirely independent of Vivado's XSim GUI/Tcl path (the flow that caused trouble in Phase 2).

- It uses **Icarus Verilog** (open-source, event-driven). Every module under test is plain synthesizable SystemVerilog with no Xilinx primitives, so it simulates directly. The one Vivado IP — the Clocking Wizard MMCM — is replaced for simulation by `src/sim/clk_wiz_audio_stub.sv`, which is never synthesized and is deliberately excluded from the Vivado project so it can't collide with the real IP.
- **`scripts/sim.mk`** is the driver. From the repo root:
  - `make -f scripts/sim.mk all` runs the whole suite (five testbenches).
  - Individual targets: `rx`, `tx`, `loopback`, `matrix`, `phase3`.
  - On macOS, install the simulator first with `brew install icarus-verilog`.

Why this matters going into the harder phases: as soon as fixed-point arithmetic and (later) DSP are involved, a waveform/reference-model check is far cheaper than rebuilding and probing hardware. This flow is that check, and it's now proven on real modules.

---

## Phase 2 testbench repair

Running the existing Phase 2 testbenches for the first time revealed that all three failed — not because the RTL is wrong (it's hardware-validated and unchanged) but because the harnesses had bit-timing bugs that stayed hidden while they were never executed. All three are fixed, and the fixes were made by adjusting the harnesses until they agreed with the silicon-proven RTL, never the other way around.

- **`tb_i2s_receiver`** — the harness drove an extra delay bit, so the receiver sampled that delay bit as the MSB and every captured word came out shifted right by one. Fix: drive the MSB on the first falling SCLK edge, matching the real transmitter.
- **`tb_i2s_transmitter`** — the harness captured left and right back-to-back without re-syncing to the LRCK edge, so the right channel started in the wrong place and was always wrong. Fix: re-align to the LRCK edge before capturing the right channel.
- **`tb_i2s_loopback`** — had both bugs plus fragile latency bookkeeping. Rebuilt on a hold-and-verify pattern: drive each value continuously until it flushes through, then capture one LRCK-aligned frame. Steady state is what gets checked, so the rx→tx latency no longer has to be tracked by hand.

---

## Files added / changed this session

| Repo path | Status | What it is |
|---|---|---|
| `src/rtl/pcm_matrix.sv` | new | N×N crosspoint matrix mixer |
| `src/rtl/phase3_top.sv` | new | Phase 3 top: 2 rx → matrix → 2 tx, both Pmods |
| `constraints/phase3_arty_z7.xdc` | new | JA + JB pin constraints |
| `src/sim/tb_pcm_matrix.sv` | new | Matrix unit test (independent reference model) |
| `src/sim/tb_phase3_datapath.sv` | new | End-to-end datapath integration test |
| `src/sim/clk_wiz_audio_stub.sv` | new | Sim-only MMCM stub (excluded from Vivado) |
| `scripts/sim.mk` | new | Icarus command-line sim driver |
| `src/sim/tb_i2s_receiver.sv` | modified | Delay-bit timing fix |
| `src/sim/tb_i2s_transmitter.sv` | modified | Right-channel re-alignment fix |
| `src/sim/tb_i2s_loopback.sv` | modified | Rebuilt on hold-and-verify |
| `scripts/create_project.tcl` | modified | Phase 3 default; explicit XDC; stub excluded |
| `.gitignore` | new | Ignores `vivado_project/` and `build_sim/` |

Note on `.gitignore`: the repo didn't have one at the root, so it was created. If `vivado_project/` is already ignored somewhere else, check for duplication before committing.

---

## Verified vs. not verified

Being explicit about this, since the confidence level differs by item:

**Verified (in simulation):**
- Matrix arithmetic — routing, summing, saturation, truncation, sign/phase handling.
- Full datapath through `phase3_top`, including channel mapping across both Pmods (no L/R swap, no JA/JB mix-up).
- The Phase 2 modules still round-trip correctly (the repaired testbenches confirm it).
- JB pin assignments match Digilent's master XDC.

**Not verified (requires Vivado / hardware):**
- Synthesis, implementation, and timing closure — not run; there's no Vivado in the environment this was built in.
- DSP48 inference — expected from the arithmetic, but unconfirmed.
- Anything on the board — Phase 3 has not been run on hardware.
- The JB Pmod master/slave jumper — set it to SLV, the same as JA (both modules are clock-slaved to the FPGA). This couldn't be checked without eyes on the board.

---

## Building it

Same command as before, from the repo root:

```
vivado -source scripts/create_project.tcl
```

`create_project.tcl` now defaults to Phase 3: it wipes `vivado_project/`, sets `phase3_top` as the synthesis top, pulls in `constraints/phase3_arty_z7.xdc`, and regenerates the MMCM IP. Nothing else needs changing.

## Hardware bring-up checklist (next session)

1. Build the project with the command above; run synthesis and implementation; confirm no unexpected timing or constraint errors.
2. Check the DSP48 utilization report — expect ~16 DSP48s for the N=4 matrix.
3. Set the JB Pmod's master/slave jumper to SLV (match JA).
4. Program the board over JTAG.
5. Feed audio into JA and JB line-in; confirm the default routing on the outputs: JA_L passthrough, JB_L appearing on JA_R, the 0.5+0.5 mix on JB_L, JB_R passthrough.

---

## Open items carried forward

- **Power supply** — the DC barrel connection is still unreliable and taped; currently working around it with USB power. Not addressed this session.
- **Phase 3 hardware validation** — the whole point of the next session; sim is done, silicon isn't.
- **Runtime crosspoint control** — still Phase 5 (needs PetaLinux + OSC first). The parameter path is a flat gain vector today, which is a reasonable seam to hook control into later.
