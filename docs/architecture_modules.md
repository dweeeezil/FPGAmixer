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

### 1.1 Where each block lives (after the D1–D4 refactor, 2026-09-25)

| Kind | RTL / software | Role |
|---|---|---|
| Platform | `src/rtl/fpgamixer_top.sv` | wires everything; owns the channel map, the reset routing (`MATRIX_GAINS`) and the choice of gain source (PS or constant) |
| Platform | `src/rtl/audio_clocking.sv` | MMCM → `mclk`, `rst_n`, shared `sclk`/`lrck` |
| Platform | `constraints/fpgamixer_genesys_zu.xdc` | pins, codec interface timing; names `u_clk/u_mmcm` and `u_jb|u_jc/u_fwd_*` |
| Platform | `scripts/create_project.tcl` | the PS block design, the address map, scoped constraint files |
| Front door | `src/rtl/i2s_port.sv` (+ `i2s_receiver`, `i2s_transmitter`, `oddr_out`) | one Pmod I2S2 ↔ 2 PCM channels, including its pin forwarding |
| PCM core | `src/rtl/pcm_matrix.sv` | N_IN × N_OUT crosspoint matrix |
| Control plane (generic) | `src/rtl/axil_coef_window.sv` | AXI4-Lite slave, common header, shadow bank |
| Control plane (generic) | `src/rtl/coef_bank_handoff.sv` + `constraints/coef_bank_handoff.xdc` | COMMIT + CDC; the XDC is scoped to the module, so every instance is constrained |
| Control plane (binding) | `src/rtl/matrix_regs_axil.sv` | the matrix's ID, CONFIG and bank size over the two generic parts |
| Control plane (software) | `tools/mixer_hw.py` | `RegWindow` (any window), `MatrixHW` (dB gains), `WINDOWS` (address map) |
| Control plane (software) | `tools/osc_mixer_server.py` | OSC ↔ state tree; zone → `Backend` table (`BACKENDS`) |
| Control plane (software) | `tools/mixer_state.py` | the parameter store: OSC-shaped tree, batched crash-safe saves, `.bak` / corrupt-file recovery (Phase 6) |

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

Today's channel map (platform layer, `fpgamixer_top`): ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R, in and out. Each `i2s_port` carries L at `[0 +: 24]` and R at `[24 +: 24]`, so the map is just `{jc, jb}` concatenation.

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
- Each block gets its own **4 KB window**, and every window starts with the same self-describing header (`axil_coef_window`), so software can verify what it opened and read its geometry instead of hard-coding it:

| Offset | Register | |
|---|---|---|
| 0x000 | ID | block type + version (`0x4D58_5001` = matrix, v1) |
| 0x004 | CONFIG | block geometry (matrix: outputs, inputs, gain width, frac bits) |
| 0x008 | CTRL | bit0 COMMIT (write), BUSY/QUEUED (read) |
| 0x00C | COMMITS | commits applied |
| 0x100… | coefficients | block-specific |

- Writes go to a shadow bank; COMMIT hands the whole bank to `mclk` (toggle handshake in `coef_bank_handoff`). This is what satisfies the "whole bank on one edge" rule in §3.
- A block's register binding is small: it instantiates `axil_coef_window` + `coef_bank_handoff` and supplies an ID, a CONFIG word and a bank size (see `matrix_regs_axil.sv`, about 40 lines of logic).

**Address map** (`scripts/create_project.tcl`, `assign_bd_address`):

| Window | Block | Since |
|---|---|---|
| 0x8000_0000 | input → output matrix (`u_regs` / `u_matrix`) | Phase 5 |
| 0x8000_1000… | reserved: bus matrix, DSP blocks | — |

Adding a block = one more SmartConnect master port, one more window, one more register-block instance. Nothing existing moves, and no constraint needs writing: the handoff's scoped XDC covers the new instance.

**Software does not scan for windows.** An access where no block is mapped is answered with a bus error, and Linux turns that into a kernel fault. `mixer_hw.WINDOWS` is therefore an explicit copy of this table, and each window is checked by its ID when opened.

### 4.2 Software: OSC zone → backend → window

- The OSC address `/<name>/<set|get>/<zone>/<index>/<module>` selects a **zone**; each zone is served by one **backend** that knows one block type and one register window.
- Today: zone `inputMatrix` → `MatrixBackend` (in `BACKENDS`, `tools/osc_mixer_server.py`) → `MatrixHW` (`tools/mixer_hw.py`) → window `matrix`, 0x8000_0000. Zones with no backend are stored and echoed generically.
- Adding a block on the software side = a window entry in `mixer_hw.WINDOWS`, a `Backend` subclass, and one entry in `build_backends()`.
- A backend validates and converts units (dB → Q2.16), and the echo carries the value actually applied.
- **Stored state mirrors the OSC tree.** The state file (`mixer_state.json`) is the address tail `<zone>/<index>/<module>` as nested JSON objects, with the values as leaves; the zones are the top-level keys, and nothing wraps them:
  ```json
  {
    "system":       { "deviceName": "FOHmixer" },
    "inputChannel": { "0": { "level": -6.0 } },
    "inputMatrix":  { "0_0": { "level": 0.0, "delay": 2.39 } }
  }
  ```
  The mixer name (the address root) lives only at `system.deviceName`. A value can't sit where the tree has a branch, or the other way round; such a set is ignored, not stored or echoed. That's the tree's only rule, and addresses that follow the standard's `zone/index/module` shape never hit it. Every stored value is finite, so the file is strict JSON: the server remaps NaN and −inf to −99.9 (off) and +inf to +99.9 before applying, storing or echoing a value. Full rules, including durability: the docstring of `tools/mixer_state.py`. This format is a contract, not an implementation detail. Phase 6 persistence and any future server read and write the same tree, and adding a zone or module never changes the format.
- The Python server is **interim**; the final server is a separate design. The backend/window split is the part meant to survive into it.

---

## 5. Known seams that are not clean yet (debt)

Listed honestly, so they're fixed deliberately rather than worked around. None of them blocks Phase 5 bring-up; the plan is to fix them **after** the Phase 5 build is proven on the Pmods, so the refactor can be checked against a known-good baseline (the same method as Phases 1–3).

| # | Where | Problem | Fix |
|---|---|---|---|
| D1 ✅ | `src/rtl/phase3_top.sv` | Held everything: pins, I2S front doors, PS, control plane, core. The name was historical. | **Done 2026-09-25:** now `fpgamixer_top` (wiring only) + `audio_clocking` + two `i2s_port`s. The board XDC was renamed `fpgamixer_genesys_zu.xdc`; its 9 instance paths moved to `u_clk/u_mmcm` and `u_jb|u_jc/u_fwd_*`. **Not done on purpose:** a `mixer_core` wrapper. Around a single `pcm_matrix` it would be an empty layer; it arrives with the second core block (bus layer or DSP), when it has something to hold. |
| D2 ✅ | `src/rtl/matrix_regs_axil.sv` | Fused three jobs: AXI4-Lite slave, shadow/commit bank, CDC handoff. A second block would have copied all three. | **Done 2026-09-25:** generic `axil_coef_window` + `coef_bank_handoff`; `matrix_regs_axil` is only the binding (ID, CONFIG, bank size), register map unchanged. The CDC constraints are in `coef_bank_handoff.xdc`, scoped with `SCOPED_TO_REF`, replacing `phase5_cdc.xdc`. `tb_matrix_regs` passes with only its parameter names changed. |
| D3 ✅ | `src/rtl/pcm_matrix.sv` | Square only (N×N). A bus layer or an 8-channel USB door needs N_IN ≠ N_OUT. | **Done 2026-09-25:** `N_IN`/`N_OUT` parameters, gains indexed `o*N_IN + i`. New `tb_pcm_matrix_rect` (3→5 and 5→2, random samples and gains vs a reference) passes; a deliberately wrong stride fails it (984 mismatches), which the 4×4 test can't see. The register CONFIG already reports inputs and outputs separately, so software was ready. |
| D4 ✅ | `tools/osc_mixer_server.py`, `tools/mixer_hw.py` | `Matrix` was hard-wired to zone `inputMatrix` and to one address. | **Done 2026-09-25:** `Backend` / `MatrixBackend` in a zone → backend table; `RegWindow` / `MatrixHW` and an explicit `WINDOWS` address map, each window checked by ID (no scanning, see §4.1). `--hw-base` removed. |

---

## 6. How upcoming work plugs in

| Work | Seam(s) used | New blocks |
|---|---|---|
| Bus layer (later; user decision 2026-09-25: not yet) | PCM contract between matrices; a new register window; zones `inputMatrix` / `busMatrix` | a `mixer_core` holding two `pcm_matrix` instances (N_IN × N_BUS, then N_BUS × N_OUT); a second `matrix_regs_axil` at window 0x8000_1000; a `busMatrix` entry in `WINDOWS` and `BACKENDS`. All the needed seams exist since D1–D4. |
| Phase 6 persistence | control plane only | server-side; already restores and pushes the bank at startup |
| Phase 7 DSP | PCM contract + coefficient contract + a window per DSP block | one core block per DSP type |
| Phase 8/11 USB audio, Phase 9 AVB | **front door** | a generic **PS ↔ PL PCM stream bridge** (DMA or AXI-Stream FIFO into an elastic buffer that presents the PCM contract on `mclk`), shared by USB and AVB; the protocol side (ALSA/`f_uac2`, 1722) stays in Linux |

### Why there is no "quick USB" path (asked 2026-09-25)

USB device mode itself is available on this board (Type-C, DWC3, Linux `f_uac2` gadget), and getting the Mac to see a soundcard is quick. The audio then exists only in Linux memory. Getting it into the matrix needs:

1. the PS ↔ PL PCM stream bridge above (nothing moves sample data between the PS and the PL today; the only link is the control-register window), and
2. rate adaptation: the Mac's USB clock is independent of `mclk`, which itself runs +324 ppm fast (Roadmap §4), so without a feedback endpoint or ASRC the stream slips ~16 samples/s.

Any shortcut that skipped (1) or (2) would wire USB straight into the core and break §2. Built properly, the bridge is the same one Phase 9 needs, so it is scheduled as its own piece of work rather than a test hack.
