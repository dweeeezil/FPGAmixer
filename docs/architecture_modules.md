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
| Platform | `src/rtl/media_clock_meter.sv` + `constraints/media_clock_meter.xdc` | Phase 9 (P9.3): measures `mclk` against a 1PPS (in the top: the inverse of the PS's `tsu_timer_cnt[45]`, the gPTP second of the board's own PHC). Captures cycle count, frame count and frame phase per edge; software computes ppm and phase. Its only crossing is the 1-bit PPS into a 2FF synchronizer (the XDC marks it false). P9.4 adds the steering |
| Control plane (binding) | `src/rtl/media_clock_stat_regs.sv` | the meter's read-only window (ID `0x4D43_5001`, CONFIG = nominal cycles per second), same pattern as `pcm_link_stat_regs` |
| Platform | `src/rtl/media_clock_steer.sv` + `constraints/media_clock_steer.xdc` | Phase 9 (P9.4b): a signed RATE → the MMCM's dynamic fine phase shift (12.3 ps per step, at most one per 14 PSCLK cycles = ±88 ppm at 100 MHz). Runs on `pl_clk0` (= PSCLK, decision S1); only LOCKED crosses (2FF). Positive RATE = `mclk` slower. The loop that sets RATE is in Linux (S3) |
| Control plane (generic) | `src/rtl/axil_reg_window.sv` | the third window type: RW + RO words for a block on the AXI clock (see §4.1) |
| Control plane (binding) | `src/rtl/media_clock_ctrl_regs.sv` | the steerer's window (ID `0x4D53_5001`, CONFIG = PSCLK Hz; RATE; steps, dropped, flags, VCO_HZ, PS_DIV) |
| Platform | `constraints/fpgamixer_genesys_zu.xdc` | pins, codec interface timing; names `u_clk/u_mmcm` and `u_jb|u_jc/u_fwd_*` |
| Platform | `scripts/create_project.tcl` | the PS block design, the address map, scoped constraint files |
| Front door | `src/rtl/i2s_port.sv` (+ `i2s_receiver`, `i2s_transmitter`, `oddr_out`) | one Pmod I2S2 ↔ 2 PCM channels, including its pin forwarding. Samples its output pair once per DAC frame, at the L load (Phase 9 fix of a one-sample L/R skew) |
| Front door | `src/rtl/pcm_link.sv` (+ `async_fifo`) | PS ↔ PL link, PL half: AMD Audio Formatter AXI4-Stream audio ↔ PCM contract, up to 8 ch each way; its only clock crossing is two `async_fifo`s. Knows nothing about USB/AVB (Phase 8: `phase8_status_2026-09-25.md`). **Two instances since P9.5:** `u_link` (link #1, used by USB) and `u_link2` (link #2, `INCLUDE_LINK2`, for AVB), identical, each with its own formatter and status window |
| Front door (Linux half of a link) | `yocto/meta-fpgamixer/recipes-kernel/fpgamixer-link-card/` + the card nodes in `recipes-bsp/device-tree/files/system-user.dtsi` | the ASoC machine driver that makes a formatter an ALSA card; **one DT node per link**, the card name from `fpgamixer,card-name` (default `FPGAmixerLink` = link #1; link #2 = `FPGAmixerLink2`, P9.5) |
| Generic | `src/rtl/async_fifo.sv` + `constraints/async_fifo.xdc` | dual-clock FIFO; XDC scoped to the module like `coef_bank_handoff.xdc` |
| Platform (image) | `yocto/meta-fpgamixer/recipes-kernel/`, `recipes-apps/fpgamixer-usb-gadget` | kernel fragments (USB device mode; since P9.6 CBS + ETF); the UAC2 gadget (USB front door, Linux half) |
| Front door (Linux half, generic) | `recipes-apps/fpgamixer-bridge-core/` (`bridge_core.{c,h}`, `bridge_convert.h`) | Phase 9 (P9.7): what every front-door bridge shares: capture → repack → playback at a fixed queue, one poll over both PCMs, xrun + coarse handling, logging, an optional servo hook. Knows no protocol |
| Front door (USB, Linux half) | `recipes-apps/fpgamixer-usb-bridge/` | gadget ↔ `FPGAmixerLink` on the core, plus the pitch servo that steers the Mac to `mclk` |
| Front door (AVB, Linux half) | `recipes-apps/fpgamixer-avb/` (+ `tools/avb_net.py`) | Phase 9 (P9.6/P9.7): from `/etc/fpgamixer/avb.conf`: TAI offset, stream VLAN, class A shaping (software CBS + ETF), the AAF ALSA devices `avb_tx` / `avb_rx` (alsa-plugins AAF); `fpgamixer-avb-bridge`: AAF ↔ `FPGAmixerLink2` on the core, **no servo** (both sides on the PHC's time) |
| Front door (AVB, control) | `tools/avb_entityd.py` + `avdecc_pdu.py`, `avdecc_model.py`, `avdecc_entity.py`, `msrp.py` (`fpgamixer-avb-entity.service`) | Phase 10: the board as an AVDECC entity (ADP/AECP/ACMP) and MSRP/MVRP participant: one 8-ch talker, one 8-ch listener; a controller's connection or format choice re-points the bridge (runtime file → `avb_net` → bridge restart). Knows nothing about the core; `avdecc_probe.py` is a minimal controller for tests |
| PCM core | `src/rtl/mixer_core.sv` | the whole core as one block, packed contract on both sides: `pcm_pack2stream` → `pcm_matrix` → `pcm_stream2pack`, plus the matrix's coefficient read port. Phase 9 (C4); the bus layer and DSP blocks go inside it |
| PCM core | `src/rtl/pcm_matrix.sv` + `src/rtl/pcm_matrix_pkg.sv` | N_IN × N_OUT crosspoint matrix, **time-shared** since P9.A4: LANES DSP48E2s (12 × 12: 1), stream in/out, coefficient read port. The package holds the lane choice and the latency formulas, shared with the platform layer |
| PCM core (generic) | `src/rtl/pcm_pack2stream.sv`, `src/rtl/pcm_stream2pack.sv` | core boundary: packed PCM contract ↔ PCM stream contract (§2.1) |
| Simulation (generic) | `src/sim/pcm_stream_monitor.sv` | checks a stream against §2.1 and a block's stated timing |
| Control plane (generic) | `src/rtl/axil_coef_window.sv` | AXI4-Lite slave, common header; coefficients through a store's request interface (since P9.A4; the shadow moved into `coef_bank_ram`) |
| Control plane (generic) | `src/rtl/coef_bank_handoff.sv` + `constraints/coef_bank_handoff.xdc` | a bank of registers across clocks, whole bank on one edge; the XDC is scoped to the module. Since Phase 9 used for the status windows (block clock → AXI clock) |
| Control plane (generic) | `src/rtl/coef_bank_ram.sv` + `constraints/coef_bank_ram.xdc` | Phase 9 (P9.A3): coefficient bank in RAM: shadow + two banks per lane, COMMIT = copy then swap at the frame strobe, a read port for time-shared blocks (§3). Store interface towards the window. Only the two toggles cross clocks; the XDC is scoped to the module (`create_project.tcl`, PS phases) |
| Simulation (tooling) | `scripts/xsim_regress.ps1` | every TB with XSim on Windows, each in a fresh directory; the counterpart of `scripts/sim.mk` (Icarus), keep the two in step |
| Generic | `src/rtl/coef_flat_reader.sv` | the same read port over a flat vector (non-PS builds, TBs) |
| Control plane (binding) | `src/rtl/matrix_regs_axil.sv` | the matrix's ID, CONFIG and bank size over the two generic parts |
| Control plane (generic) | `src/rtl/axil_stat_window.sv` | read-only AXI4-Lite status window, same header; its words arrive through a `coef_bank_handoff` used in reverse (block clock → AXI clock) |
| Control plane (binding) | `src/rtl/pcm_link_stat_regs.sv` | a `pcm_link`'s counters and fill watermarks (ID `0x4C4B_5001`); one instance per link (`u_link_stat`, `u_link2_stat`) |
| Control plane (software) | `tools/mixer_hw.py` | `RegWindow` (any window), `MatrixHW` (dB gains), `LinkStatHW` (windows `linkstat` and `linkstat2`; `mixer_hw.py link` / `link2`), `MediaClockHW` (ppm vs gPTP, `mixer_hw.py mclk`), `MediaClockSteerHW` (ppm ↔ RATE, `mixer_hw.py steer`), `WINDOWS` (address map) |
| Control plane (software) | `tools/osc_mixer_server.py` | OSC ↔ state tree; zone → `Backend` table (`BACKENDS`) |
| Control plane (software) | `tools/osc_codec.py` | the one OSC codec (messages, bundles) and the TCP framers (`len32`, `none`), plus the client links the tools use; shared by the server and every tool (since 2026-10-04) |
| Control plane (software) | `tools/mixer_state.py` | the parameter store: OSC-shaped tree, batched crash-safe saves, `.bak` / corrupt-file recovery (Phase 6) |
| Front door (AVB, Linux half) | `yocto/meta-fpgamixer/recipes-apps/fpgamixer-gptp/` | Phase 9 (P9.1): ptp4l + phc2sys on `end0` at boot, gPTP profile, role by BMCA (`priority1 250`: follows a better clock, grandmaster by one config value). Knows nothing about audio; the media clock (P9.3/4) reads the PHC's time in the PL |
| Platform (image) | `yocto/meta-fpgamixer/` | board DT fixes; `fpgamixer-osc` (server as a boot service); `fpgamixer-bench-network` (bench-only addressing, switchable); synced with `tools/` by `scripts/sync_buildhost.sh` |

---

## 2. PCM contract (the audio seam)

Every audio connection between blocks uses this, and only this:

| Signal | Definition |
|---|---|
| `clk` | the core audio clock, `mclk` (12.288 MHz, from `clk_wiz_audio`: +11 ppm nominal since P9.4a, and in `phase9` builds steered onto gPTP by `media_clock_steer` + `fpgamixer-mediaclock`, P9.4b) |
| `rst_n` | active-low, synchronous to `mclk` (`reset_sync`) |
| `valid` | one-`mclk` pulse per audio frame (48 kHz nominal) |
| `data` | flat packed vector, channel *c* at `[c*24 +: 24]`, signed two's-complement, 24-bit |

Rules:

- **One clock domain for the whole core.** A front door whose source runs on a different clock (USB host, network media clock, anything not derived from `mclk`) must bridge it **inside the front door** (elastic buffer, rate adaptation or ASRC), and present samples on `mclk` like the I2S receiver does. The core never contains a clock crossing for audio.
- **Packed vectors, not unpacked arrays**, on every port (Icarus drops unpacked-array outputs; see `pcm_matrix.sv` header).
- Channel counts are parameters. A block states its channel count; the platform layer decides which front-door channels feed which core inputs.

### 2.1 PCM stream contract (inside the core, since Phase 9)

Decided 2026-09-26 (`phase9_status_2026-09-26.md` §5.1, C1/C2/C6). Core blocks that are time-shared (the matrix from P9.A4, the Phase 7 DSP blocks) pass samples **one channel per beat** instead of as a packed vector. Front doors keep the packed contract; the core boundary converts.

| Signal | Definition |
|---|---|
| `clk`, `rst_n` | `mclk`, as the packed contract |
| `frame` | the frame strobe, shared by the whole core (the packed contract's `valid`) |
| `s_valid` | one beat |
| `s_ch` | channel index, `$clog2(N)` bits (1 bit for N = 1) |
| `s_data` | sample, signed, `SW` bits (24 today; a parameter) |

Rules:

- **Each channel exactly once per frame, in ascending order 0 … N−1.** Idle cycles between beats are allowed.
- **All beats of frame *k* lie between strobe *k* and strobe *k*+1.** A block that can't finish inside the frame retimes to the next one and states the extra frame of latency.
- **No back-pressure.** Schedules are static; each producer's timing is known at elaboration.
- **Every block states its timing** in its header: first and last beat in cycles after the strobe. Cycle numbering: the edge that samples `frame` high is edge 0, and cycle *c* is the interval after edge *c*. A frame is exactly 256 cycles (LRCK = `mclk`/256), whatever `mclk`'s steering does to the cycle's length.
- **The core's packed output updates on one edge at a stated cycle D of the same frame** (C2): today's latency to the link and the Pmods is kept. **D ≤ 250.** The earliest consumer is `i2s_port`, which samples the pair on edge 254 (needs the frame from cycle 253); `pcm_link` samples at the next strobe.
- Consumers may check `s_ch` (as the link checks TID). `src/sim/pcm_stream_monitor.sv` checks all of the above and is used by every core TB.

Boundary converters (generic, P9.A2): **`pcm_pack2stream`** captures the packed vector on the strobe and emits channels 0 … N−1 on cycles 1 … N. **`pcm_stream2pack`** collects beats by `s_ch` and moves all channels to its packed output together, one cycle after the beat for N−1; `err_o` pulses on an out-of-order beat or an incomplete frame.

Today's channel map (platform layer, `fpgamixer_top`, since Phase 8; grown in P9.5): ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R, **ch4–ch11 = PS↔PL link #1 channels 0–7** (in = what Linux plays into the link, e.g. the Mac's USB outputs 1–8; out = what Linux records), **ch12–ch19 = link #2 channels 0–7** (card `FPGAmixerLink2`, the AVB front door's; P9.5). Each `i2s_port` carries L at `[0 +: 24]` and R at `[24 +: 24]`, so the map is the concatenation `{link2, link, jc, jb}`. **New channels are appended, never interleaved**, so saved crosspoint indices keep their meaning as the core grows. Without a link (non-PS builds; link #2 also in `phase8` builds) its channels read as silence; the core is **20 × 20 in every build** (2 DSP48E2 lanes, D = 227).

---

## 3. Coefficient contract (core ← control plane)

Every tunable core block exposes its parameters as one flat **coefficient port**:

- in the `mclk` domain;
- changes only as a **whole bank on one `mclk` edge**, so every frame sees one consistent set (the block samples it on the frame's `valid`);
- the block has **no idea** whether the value came from a register, a constant, or a test bench. `pcm_matrix.gains_flat` is the first instance: the PS build drives it from `matrix_regs_axil`, the non-PS build ties it to `MATRIX_GAINS`, and the unit TB drives a constant.

**Form since Phase 9 (C3, built in P9.A3/A4): a read port.** A time-shared block drives an address and gets a word of coefficients one cycle later, one per lane (layout: rows round-robin over lanes, `coef_bank_ram.sv` header). The bank behind the port swaps **only on a frame strobe**, and a block does all of one frame's reads between two strobes, so every frame sees one whole bank. Served by `coef_bank_ram` in the PS build (via `matrix_regs_axil`) and by `coef_flat_reader` over a flat vector in non-PS builds (`MATRIX_GAINS`) and unit TBs. The register window didn't change. `pcm_matrix` is the first user; a flat `gains_flat`-style vector remains fine for a small block that isn't time-shared.

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

- **Three window types, one header** (since Phase 9): `axil_coef_window` (a coefficient bank with COMMIT, delivered to the audio clock), `axil_stat_window` (read-only snapshots from another clock), and **`axil_reg_window`** (plain read/write words plus read-only words for a block that runs **on the AXI clock itself**: no commit, no crossing; 0x00C counts accepted writes). Pick by where the block's logic runs, not by convenience: a block on `mclk` never gets an `axil_reg_window`.
- **Status windows** (since Phase 8) use the same header with the data flowing the other way: `axil_stat_window` shows read-only words that a `coef_bank_handoff` (src = the block's clock, dst = the AXI clock) delivers as one consistent snapshot per frame. CTRL reads 0 and 0x00C is a snapshot sequence number. There is no CLEAR: counters are free-running and software takes differences.
- Writes go to a shadow bank; COMMIT hands the whole bank to `mclk`. Since Phase 9 the shadow and two active banks are in RAM (`coef_bank_ram`): COMMIT copies the shadow into the idle bank and the block's side swaps at the next frame strobe (a toggle handshake), which satisfies §3. **A COMMIT contains exactly the writes completed before it:** while one is queued (issued during BUSY), further accesses wait until it launches, at most about a frame plus a copy. (Phase 5–8's `coef_bank_handoff` took the shadow as it was when a queued commit launched; see `phase9_status_2026-09-26.md` §5.4.)
- A block's register binding is small: it instantiates `axil_coef_window` (AXI slave, header, WSTRB by read-modify-write, requests to a store) + `coef_bank_ram` and supplies an ID, a CONFIG word and the bank geometry (see `matrix_regs_axil.sv`). `coef_bank_handoff` remains the primitive for the reverse direction (status windows).

**Address map** (`scripts/create_project.tcl`, `assign_bd_address`):

| Window | Block | Since |
|---|---|---|
| 0x8000_0000 | input → output matrix (`u_regs` / `u_core`), 12 × 12 since Phase 8, **20 × 20 since P9.5** | Phase 5 |
| 0x8000_1000 | PS↔PL link status (`u_link_stat`, read-only, ID `0x4C4B_5001`) | Phase 8 |
| 0x8000_2000 | media-clock meter (`u_mclk_stat`, read-only, ID `0x4D43_5001`): `mclk` vs the gPTP 1PPS; `phase9` builds | Phase 9 (P9.3) |
| 0x8000_3000 | media-clock steering (`u_mclk_ctrl`, read/write, ID `0x4D53_5001`): the rate for the MMCM's fine phase shift; `phase9` builds | Phase 9 (P9.4b) |
| 0x8000_4000 | PS↔PL **link #2** status (`u_link2_stat`, read-only, ID `0x4C4B_5001`, the same binding as link #1); `phase9` builds | Phase 9 (P9.5) |
| 0x8000_5000… | reserved: bus matrix, DSP blocks (moved up again in P9.5) | — |
| 0x8010_0000 (64K) | AMD Audio Formatter #1 registers (`link_formatter`, card `FPGAmixerLink`): **driver-owned** (`xlnx_formatter_pcm`), not a self-describing window; software never maps it | Phase 8 |
| 0x8011_0000 (64K) | AMD Audio Formatter #2 registers (`link2_formatter`, card `FPGAmixerLink2`): driver-owned, as #1; `phase9` builds | Phase 9 (P9.5) |

Driver-owned devices go at 0x801x_xxxx, so the 0x8000_x000 range stays for windows with the ID/CONFIG header.

Adding a block = one more SmartConnect master port, one more window, one more register-block instance. Nothing existing moves, and no constraint needs writing: the handoff's scoped XDC covers the new instance.

**Software does not scan for windows.** An access where no block is mapped is answered with a bus error, and Linux turns that into a kernel fault. `mixer_hw.WINDOWS` is therefore an explicit copy of this table, and each window is checked by its ID when opened.

### 4.2 Software: OSC zone → backend → window

- **Below the protocol: transport.** `tools/osc_codec.py` turns bytes into OSC messages and back. A TCP connection carries packets in one framing per port (`--tcp-framing len32|none`, default `len32`, the standard's "TCP framing"); a UDP datagram is one packet. A packet is a message or a bundle, and the protocol layer sees only messages, in order. Nothing above this layer knows the framing; `ClientRegistry` frames every TCP send.
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
| D1 ✅ | `src/rtl/phase3_top.sv` | Held everything: pins, I2S front doors, PS, control plane, core. The name was historical. | **Done 2026-09-25:** now `fpgamixer_top` (wiring only) + `audio_clocking` + two `i2s_port`s. The board XDC was renamed `fpgamixer_genesys_zu.xdc`; its 9 instance paths moved to `u_clk/u_mmcm` and `u_jb|u_jc/u_fwd_*`. **Not done on purpose:** a `mixer_core` wrapper. Around a single `pcm_matrix` it would be an empty layer; it arrives with the second core block (bus layer or DSP), when it has something to hold. **Added in Phase 9 (P9.A4)**, when the core came to hold the stream converters and the time-shared matrix. |
| D2 ✅ | `src/rtl/matrix_regs_axil.sv` | Fused three jobs: AXI4-Lite slave, shadow/commit bank, CDC handoff. A second block would have copied all three. | **Done 2026-09-25:** generic `axil_coef_window` + `coef_bank_handoff`; `matrix_regs_axil` is only the binding (ID, CONFIG, bank size), register map unchanged. The CDC constraints are in `coef_bank_handoff.xdc`, scoped with `SCOPED_TO_REF`, replacing `phase5_cdc.xdc`. `tb_matrix_regs` passes with only its parameter names changed. |
| D3 ✅ | `src/rtl/pcm_matrix.sv` | Square only (N×N). A bus layer or an 8-channel USB door needs N_IN ≠ N_OUT. | **Done 2026-09-25:** `N_IN`/`N_OUT` parameters, gains indexed `o*N_IN + i`. New `tb_pcm_matrix_rect` (3→5 and 5→2, random samples and gains vs a reference) passes; a deliberately wrong stride fails it (984 mismatches), which the 4×4 test can't see. The register CONFIG already reports inputs and outputs separately, so software was ready. |
| D4 ✅ | `tools/osc_mixer_server.py`, `tools/mixer_hw.py` | `Matrix` was hard-wired to zone `inputMatrix` and to one address. | **Done 2026-09-25:** `Backend` / `MatrixBackend` in a zone → backend table; `RegWindow` / `MatrixHW` and an explicit `WINDOWS` address map, each window checked by ID (no scanning, see §4.1). `--hw-base` removed. |

---

## 6. How upcoming work plugs in

| Work | Seam(s) used | New blocks |
|---|---|---|
| Bus layer (later; user decision 2026-09-25: not yet) | PCM contract between matrices; a new register window; zones `inputMatrix` / `busMatrix` | a `mixer_core` holding two `pcm_matrix` instances (N_IN × N_BUS, then N_BUS × N_OUT); a second `matrix_regs_axil` at the next free window (0x8000_5000 since P9.5); a `busMatrix` entry in `WINDOWS` and `BACKENDS`. All the needed seams exist since D1–D4. |
| Phase 6 persistence | control plane only | server-side; already restores and pushes the bank at startup |
| Phase 7 DSP | PCM contract + coefficient contract + a window per DSP block | one core block per DSP type |
| Phase 8/11 USB audio, Phase 9 AVB | **front door** | a generic **PS ↔ PL PCM stream bridge** (DMA or AXI-Stream FIFO into an elastic buffer that presents the PCM contract on `mclk`), shared by USB and AVB; the protocol side (ALSA/`f_uac2`, 1722) stays in Linux. **Proposal (2026-09-25, awaiting decisions):** `phase8_status_2026-09-25.md`: Audio Formatter → ALSA card on `mclk` time, `pcm_link` PL front door, new generic RO `axil_stat_window` |

**Phase 9 (AVB), proposed 2026-09-26** (`phase9_status_2026-09-26.md`): a **second link instance** (formatter + `pcm_link`, core channels 12–19 appended; **built in P9.5**, no new RTL, the card driver named per DT node) with an AVB front door whose Linux half is gPTP + CBS shaping + the alsa-plugins AAF talker/listener + a bridge. One new **platform** piece: `mclk` disciplined to gPTP (**done, P9.3/P9.4**), so the network disciplines the core's own clock and the core still never sees a foreign one. One **core** change with an unchanged interface: a time-multiplexed `pcm_matrix` (**done, P9.A**).

### Why there is no "quick USB" path (asked 2026-09-25)

USB device mode itself is available on this board (Type-C, DWC3, Linux `f_uac2` gadget), and getting the Mac to see a soundcard is quick. The audio then exists only in Linux memory. Getting it into the matrix needs:

1. the PS ↔ PL PCM stream bridge above (nothing moves sample data between the PS and the PL today; the only link is the control-register window), and
2. rate adaptation: the Mac's USB clock is independent of `mclk`, which itself runs +324 ppm fast (Roadmap §4), so without a feedback endpoint or ASRC the stream slips ~16 samples/s.

Any shortcut that skipped (1) or (2) would wire USB straight into the core and break §2. Built properly, the bridge is the same one Phase 9 needs, so it is scheduled as its own piece of work rather than a test hack.
