# FPGAmixer — reset / handoff doc

**Date:** August 7, 2026 (evening)
**Purpose:** Get a fresh chat up to speed on an ACTIVE HARDWARE BUG in Phase 3.
**Repo:** https://github.com/dweeeezil/FPGAmixer

---

## One-paragraph state

Phase 3 (static PCM matrix mixer, both Pmods) is written, simulation-clean, synthesized, and running on hardware — **but the audio output is distorted, with a ~-18 dBFS noise floor even with no signal present.** The RTL is verified correct in simulation (including a dynamic per-frame test) and timing closes with huge margin. Power has been ruled out. The current single most important clue: **the noise appears ~5 seconds AFTER the DONE LED lights**, which points at a startup/sequencing or analog-settling effect, not a datapath-math bug. This is where the next session should start.

---

## The bug (what to debug)

- Symptom: looped-back audio is very distorted; a steady ~-18 dBFS noise signal is present even with no audio playing.
- Monitored so far: only the two LEFT outputs (JA_L, JB_L) — both show the noise. Right outputs not yet monitored (cabling limit).
- **Key timing clue: DONE LED goes high, then the noise onsets ~5 s later.** Nothing in the RTL operates on a multi-second timescale (a 48 kHz frame is ~21 us), so this strongly implies a slow startup/sequencing/analog-settling cause rather than the matrix arithmetic.

### Ruled OUT (with evidence)
- **RTL logic / matrix math** — `tb_pcm_matrix` (28 checks vs independent reference) and `tb_phase3_dynamic` (24 frames, changing value every frame, identity routing: tags + counters all correct) both pass. Datapath moves samples correctly frame-to-frame in sim.
- **Timing** — reported WNS ~74 ns (huge margin; ~7 ns used of the 81 ns MCLK period). No timing corruption.
- **Power** — total build utilization 0.22 W; runs clean on both USB and external DC. The JTAG dropouts in the old `vivado_2580_backup.log` were during programming only; programming otherwise succeeds and DONE stays high. Power is NOT the cause. (Do not re-chase this.)

### Still OPEN / leading suspects (post power-rule-out)
- **Startup sequencing / analog settling (leading).** The ~5 s delay fits a codec analog-domain ramp, an MMCM-lock / reset-release transient, or the CS5343/CS4344 free-running into a mis-clocked state that only then produces hash. Both noisy outputs share the matrix and both left codecs.
- **Clock forwarding.** MCLK/SCLK/LRCK are driven to the Pmod pins with a plain `assign`, not an ODDR. This was clean for JA in Phase 2, but Phase 3 doubled the clock-output load (second Pmod). Standard Zynq fix is ODDR-based clock forwarding. Second on the list.
- **Known L/R skew (NOT the symptom, but real).** The dynamic test showed L and R of a given output frame come from adjacent input frames (L one frame older than R), because the transmitter latches L and R on opposite LRCK edges while the matrix updates both at once. It is a constant ~21 us interchannel offset (comb nulls >=24 kHz), inaudible, and not on the monitored channels. Fix later (one extra output-hold register so both channels latch from the same matrix frame). Do not confuse with the noise.

### Suggested next diagnostic steps
- Treat this as a reproduce -> isolate -> diagnose problem. The `/debug` workflow is a good fit and worth invoking.
- Nail down the 5 s onset: is it correlated with MMCM lock, reset deassertion, or purely codec-analog? Consider bringing `locked` / `rst_n` / a heartbeat out to LEDs to see what is happening at the 5 s mark.
- Get the RIGHT outputs monitored if at all possible (rules the matrix in/out further).
- Consider an ILA on the PCM buses (rx outputs, matrix out) to see whether the digital samples are clean at the point the analog goes noisy — if the digital PCM is clean when the audio is already hashy, it's the DAC-side clocking/analog, not the datapath.
- If digital is clean and analog is not: pursue clock-forwarding (ODDR) and codec reset/sequencing.

---

## What is on hardware right now

`phase3_top.sv` currently routes **IDENTITY** (each output = its own input at unity: JA_L->JA_L, JA_R->JA_R, JB_L->JB_L, JB_R->JB_R), set during debug to strip away cross-routes and fractional gains. Identity is still noisy on JA_L, which is why the datapath/gains were ruled out. The original demo routing (JA_L passthrough, JB_L->JA_R cross, 0.5*JA_L+0.5*JB_L on JB_L, JB_R passthrough) is preserved as a commented block in `phase3_top.sv` — restore it once the noise is solved.

---

## Verified project facts (carry forward)

- **Hardware:** Digilent Arty Z7-20 (Zynq-7000, xc7z020clg400-1), 2x Pmod I2S2 on JA and JB, both jumpers set SLV (FPGA is clock master). Board seated/confirmed OK by user.
- **Toolchain:** Vivado 2026.1, Digilent board files. Build: `vivado -source scripts/create_project.tcl` from repo root (defaults to Phase 3 now).
- **Command-line sim (trustworthy path):** Icarus Verilog via `make -f scripts/sim.mk all` (macOS: `brew install icarus-verilog`). Independent of Vivado/XSim. Six testbenches, all passing.
- **Clocking:** one MMCM (clk_wiz_audio IP, 125 MHz -> 12.288 MHz) + one divider (sclk = mclk/4 = 3.072 MHz, lrck = mclk/256 = 48 kHz) shared across BOTH Pmods. Single clock domain, no CDC. Clocks driven to Pmod pins via direct `assign` (not ODDR).
- **Matrix format:** 24-bit signed PCM samples; signed Q2.16 gains (unity 0x10000, half 0x08000, invert 0x30000, GAIN_WIDTH=18, GAIN_FRAC=16); truncation (not rounding) on descale; per-crosspoint DSP48 -> 16 DSP48 for N=4; 44-bit accumulator. Gains passed as one flat packed parameter GAINS_FLAT, GAIN[o][i] = GAINS_FLAT[(o*N+i)*GAIN_WIDTH +: GAIN_WIDTH].
- **Sim tool quirks (learned):** Icarus drops values through unpacked-array OUTPUT ports across module boundaries -> matrix uses packed-vector ports. Icarus `always_comb` doesn't retrigger on unpacked-array element writes -> matrix math folded into the clocked block. Both worked around; do not revert to unpacked-array ports.
- **MMCM in sim:** replaced by `src/sim/clk_wiz_audio_stub.sv` (sim-only, excluded from the Vivado project so it can't collide with the real IP).

## JB pin map (from Digilent master XDC, in constraints/phase3_arty_z7.xdc)
- DAC side: JB1=W14 (mclk), JB2=Y14 (lrck), JB3=T11 (sclk), JB4=T10 (sdin)
- ADC side: JB7=V16 (mclk), JB8=W16 (lrck), JB9=V12 (sclk), JB10=W13 (sdout)
- JA side (unchanged from Phase 1/2): da_mclk=Y18, da_lrck=Y19, da_sclk=Y16, da_sdin=Y17, ad_mclk=U18, ad_lrck=U19, ad_sclk=W18, ad_sdout=W19

---

## File inventory (Phase 3 work)

| Path | Notes |
|---|---|
| `src/rtl/pcm_matrix.sv` | N x N crosspoint matrix; packed ports; math in clocked block |
| `src/rtl/phase3_top.sv` | Top; **currently IDENTITY routing**; demo routing commented |
| `constraints/phase3_arty_z7.xdc` | JA + JB pins |
| `src/sim/tb_pcm_matrix.sv` | Matrix unit test (independent reference) |
| `src/sim/tb_phase3_datapath.sv` | End-to-end static test; reference currently set to identity |
| `src/sim/tb_phase3_dynamic.sv` | Dynamic per-frame test (tags + counters); identity |
| `src/sim/clk_wiz_audio_stub.sv` | Sim-only MMCM stub (excluded from Vivado) |
| `src/sim/tb_i2s_receiver.sv` | Phase 2 TB, fixed (delay-bit) |
| `src/sim/tb_i2s_transmitter.sv` | Phase 2 TB, fixed (R re-align) |
| `src/sim/tb_i2s_loopback.sv` | Phase 2 TB, rebuilt (hold-and-verify) |
| `scripts/sim.mk` | Icarus sim driver; `make -f scripts/sim.mk all` |
| `scripts/create_project.tcl` | Phase 3 default; explicit XDC; stub excluded |
| `docs/project_status_2026-08-07.md` | Phase 3 completion report (pre-hardware-debug) |

## Working preferences (carry forward)
Honest over embellishment; explicit "I don't know" over confident guessing; analogies when uncertain. RTL-capable user. Verify tool behavior by running probes, not asserting. Do not re-chase ruled-out hypotheses (power). Simulation-before-hardware discipline; phased milestones.
