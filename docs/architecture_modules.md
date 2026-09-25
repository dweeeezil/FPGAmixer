# FPGAmixer — module boundaries and interface contracts

**Started:** 2026-09-25 (Phase 5). **Keep this current:** any change that adds a block, a clock crossing, a register window or an OSC zone updates this file in the same change.

The roadmap (`FPGAmixer_Architecture_Roadmap.md`) says *what* gets built and when. This document says *how the pieces are allowed to connect*, so each phase adds blocks instead of rewiring old ones.

---

## 1. The rule

The Phase 1–3 loopbacks were deliberately **I2S → PCM → PCM matrix → PCM → I2S** so that every stage is generic and can be rebuilt or replaced on its own. That principle extends to everything that follows:

> Every block talks to its neighbours only through one of the contracts below. A block never reaches around a contract to its neighbour's internals, not even "just for a quick test".

There are four kinds of block:

```
                 ┌──────────────── control plane ────────────────┐
                 │  OSC server ─► backend ─► register window ─►   │
                 │                 (per block)   CDC handoff      │
                 └───────────────────────────────────┬───────────┘
                                                     │ coefficient ports (§3)
   front doors (§2)            PCM core                      front doors
 I2S rx ──┐                ┌───────────────┐                ┌── I2S tx
 USB in ──┼─ PCM contract ─►  matrix (now)  ├─ PCM contract ─┼── USB out
 AVB in ──┘                │  bus/DSP later│                └── AVB out
                           └───────────────┘
                        platform: clocks, resets, PS, pins
```

| Kind | Knows about | Must NOT know about |
|---|---|---|
| **Front door** (I2S, later USB, AVB) | its own pins/protocol/clock, and the PCM contract | the matrix, DSP, the PS, registers |
| **PCM core block** (matrix, later bus matrix, DSP) | PCM in, PCM out, its coefficient port | where samples came from, where coefficients came from |
| **Control plane** (register windows, CDC handoff, OSC server) | coefficient banks, addresses, OSC zones | audio data, protocol details of front doors |
| **Platform** (top level, clocking, PS BD, XDC) | wiring the above together | any block's internals |

---

## 2. PCM contract (the audio seam)

Every audio connection between blocks uses this, and only this:

| Signal | Definition |
|---|---|
| `clk` | the core audio clock, `mclk` (12.288 MHz nominal, 12.2919 MHz actual, from `clk_wiz_audio`) |
| `rst_n` | active-low, synchronous to `mclk` (`reset_sync`) |
| `valid` | one-`mclk` pulse per audio frame (48 kHz nominal) |
| `data` | flat packed vector, channel *c* at `[c*24 +: 24]`, signed two's-complement, 24-bit |

Rules:

- **One clock domain for the whole core.** A front door whose source runs on a different clock (USB host, network media clock, anything not derived from `mclk`) must bridge it **inside the front door** (elastic buffer, rate adaptation or ASRC), and present samples on `mclk` like the I2S receiver does. The core never contains a clock crossing for audio.
- **Packed vectors, not unpacked arrays**, on every port (Icarus drops unpacked-array outputs; see `pcm_matrix.sv` header).
- Channel counts are parameters. A block states its channel count; the platform layer decides which front-door channels feed which core inputs.

Today's channel map (platform layer, `phase3_top`): ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R, in and out.

---

## 3. Coefficient contract (core ← control plane)

Every tunable core block exposes its parameters as one flat **coefficient port**:

- in the `mclk` domain;
- changes only as a **whole bank on one `mclk` edge**, so every frame sees one consistent set (the block samples it on the frame's `valid`);
- the block has **no idea** whether the value came from a register, a constant, or a test bench. `pcm_matrix.gains_flat` is the first instance: the PS build drives it from `matrix_regs_axil`, the non-PS build ties it to `MATRIX_GAINS`, and the unit TB drives a constant.

Smoothing (click-free gain changes) is a property of the core block, added later as a lowpass/ramp on the coefficient *inside* the block, so the contract doesn't change.

---

## 4. Control plane

### 4.1 Hardware: one register window per core block

- The PS reaches the PL through `M_AXI_HPM0_LPD` → SmartConnect → one AXI4-Lite port per block.
- Each block gets its own **4 KB window**, and every window starts with the same self-describing header, so software discovers blocks instead of hard-coding them:

| Offset | Register | |
|---|---|---|
| 0x000 | ID | block type + version (`0x4D58_5001` = matrix, v1) |
| 0x004 | CONFIG | block geometry (matrix: outputs, inputs, gain width, frac bits) |
| 0x008 | CTRL | bit0 COMMIT (write), BUSY/QUEUED (read) |
| 0x00C | COMMITS | commits applied |
| 0x100… | coefficients | block-specific |

- Writes go to a shadow bank; COMMIT hands the whole bank to `mclk` (toggle handshake, see `matrix_regs_axil.sv`). This is what satisfies the "whole bank on one edge" rule in §3.

**Address map** (`scripts/create_project.tcl`, `assign_bd_address`):

| Window | Block | Since |
|---|---|---|
| 0x8000_0000 | input → output matrix (`u_regs` / `u_matrix`) | Phase 5 |
| 0x8000_1000… | reserved: bus matrix, DSP blocks | — |

Adding a block = one more SmartConnect master port, one more window, one more register-block instance. Nothing existing moves.

### 4.2 Software: OSC zone → backend → window

- The OSC address `/<name>/<set|get>/<zone>/<index>/<module>` selects a **zone**; each zone is served by one **backend** that knows one block type and one register window.
- Today: zone `inputMatrix` → `Matrix` (in `tools/osc_mixer_server.py`) → `MatrixHW` (`tools/mixer_hw.py`) → window 0x8000_0000. Everything else is stored and echoed generically.
- A backend validates and converts units (dB → Q2.16), and the echo carries the value actually applied.
- The Python server is **interim**; the final server is a separate design. The backend/window split is the part meant to survive into it.

---

## 5. Known seams that are not clean yet (debt)

Listed honestly, so they're fixed deliberately rather than worked around. None of them blocks Phase 5 bring-up; the plan is to fix them **after** the Phase 5 build is proven on the Pmods, so the refactor can be checked against a known-good baseline (the same method as Phases 1–3).

| # | Where | Problem | Fix |
|---|---|---|---|
| D1 | `src/rtl/phase3_top.sv` | Holds everything: pins, I2S front doors, PS, control plane, core. The name is historical. | Split into `i2s_port` (pins ↔ PCM contract, includes the ODDR forwarders), `mixer_core` (matrix now, bus/DSP later), control-plane instances; the top only wires. Moving the ODDRs *down* a level changes the `u_fwd_*` paths in the XDC, so the XDC is updated in the same change (the 2026-09-22 failure was an unplanned level *above* the top, not this). |
| D2 | `src/rtl/matrix_regs_axil.sv` | Fuses three jobs: AXI4-Lite slave, shadow/commit bank, CDC handoff. A second block would copy all three. | Split into a generic `axil_coef_window` (AXI + header + shadow bank, parameterized by coefficient count/width and ID/CONFIG) and a generic `coef_bank_handoff` (commit + CDC). The matrix then only supplies its ID, CONFIG and bank size. |
| D3 | `src/rtl/pcm_matrix.sv` | Square only (N×N). A bus layer or an 8-channel USB door needs N_IN ≠ N_OUT. | `N_IN`/`N_OUT` parameters. The register CONFIG already reports inputs and outputs separately, so software is ready. |
| D4 | `tools/osc_mixer_server.py` | `Matrix` is hard-wired to zone `inputMatrix`. | Zone → backend table, one entry per register window (found via ID/CONFIG). |

---

## 6. How upcoming work plugs in

| Work | Seam(s) used | New blocks |
|---|---|---|
| Bus layer (later; user decision 2026-09-25: not yet) | PCM contract between matrices; a new register window; zones `inputMatrix` / `busMatrix` | second `pcm_matrix` instance (N_IN × N_BUS then N_BUS × N_OUT), window 0x8000_1000. Needs D3, easier after D1/D2. |
| Phase 6 persistence | control plane only | server-side; already restores and pushes the bank at startup |
| Phase 7 DSP | PCM contract + coefficient contract + a window per DSP block | one core block per DSP type |
| Phase 8/11 USB audio, Phase 9 AVB | **front door** | a generic **PS ↔ PL PCM stream bridge** (DMA or AXI-Stream FIFO into an elastic buffer that presents the PCM contract on `mclk`), shared by USB and AVB; the protocol side (ALSA/`f_uac2`, 1722) stays in Linux |

### Why there is no "quick USB" path (asked 2026-09-25)

USB device mode itself is available on this board (Type-C, DWC3, Linux `f_uac2` gadget), and getting the Mac to see a soundcard is quick. The audio then exists only in Linux memory. Getting it into the matrix needs:

1. the PS ↔ PL PCM stream bridge above (nothing moves sample data between the PS and the PL today; the only link is the control-register window), and
2. rate adaptation: the Mac's USB clock is independent of `mclk`, which itself runs +324 ppm fast (Roadmap §4), so without a feedback endpoint or ASRC the stream slips ~16 samples/s.

Any shortcut that skipped (1) or (2) would wire USB straight into the core and break §2. Built properly, the bridge is the same one Phase 9 needs, so it is scheduled as its own piece of work rather than a test hack.
