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
   front doors (§2)            PCM core (since Phase 12)          front doors
 USB host─┐           ┌──────────────────────────────────┐        ┌── USB host
 USB dev ─┼─ PCM ────►│ levels → input matrix → levels → │─ PCM ──┼── USB dev
 AVB in ──┘ contract  │ bus matrix → levels   (DSP later)│ contr. └── AVB out
                      └──────────────────────────────────┘
                        platform: clocks, resets, PS, pins
```

| Kind | Knows about | Must NOT know about |
|---|---|---|
| **Front door** (USB device, USB host, AVB; I2S until Phase 11) | its own pins/protocol/clock, and the PCM contract | the matrix, DSP, the PS, registers |
| **PCM core block** (matrix, later bus matrix, DSP) | PCM in, PCM out, its coefficient port | where samples came from, where coefficients came from |
| **Control plane** (register windows, CDC handoff, OSC server) | coefficient banks, addresses, OSC zones | audio data, protocol details of front doors |
| **Platform** (top level, clocking, PS BD, XDC) | wiring the above together | any block's internals |

### 1.1 Where each block lives (after the D1–D4 refactor, 2026-09-25)

| Kind | RTL / software | Role |
|---|---|---|
| Platform | `src/rtl/fpgamixer_top.sv` | wires everything; owns the **I/O port map** (Phase 15; the channel map before), the channel and bus counts (`N` = 20, `N_BUS` = N, Phase 12), the reset state (`IN_MX_GAINS`, `BUS_MX_GAINS`: identity; `LEVEL_GAINS`: unity; the patch: all None with the PS, identity without, decision CS5) and the choice of coefficient source (PS or constant) |
| Platform | `src/rtl/audio_clocking.sv` | MMCM → `mclk`, `rst_n`, and `frame`: the 48 kHz strobe, one `mclk` cycle in 256, that the core and every link run on (Phase 11 H.3; it was the Pmod receiver's `rx_valid` and the shared `sclk`/`lrck` before) |
| Platform | `src/rtl/media_clock_meter.sv` + `constraints/media_clock_meter.xdc` | Phase 9 (P9.3): measures `mclk` against a 1PPS (in the top: the inverse of the PS's `tsu_timer_cnt[45]`, the gPTP second of the board's own PHC). Captures cycle count, frame count and frame phase per edge; software computes ppm and phase. Its only crossing is the 1-bit PPS into a 2FF synchronizer (the XDC marks it false). P9.4 adds the steering |
| Control plane (binding) | `src/rtl/media_clock_stat_regs.sv` | the meter's read-only window (ID `0x4D43_5001`, CONFIG = nominal cycles per second), same pattern as `pcm_link_stat_regs` |
| Platform | `src/rtl/media_clock_steer.sv` + `constraints/media_clock_steer.xdc` | Phase 9 (P9.4b): a signed RATE → the MMCM's dynamic fine phase shift (12.3 ps per step, at most one per 14 PSCLK cycles = ±88 ppm at 100 MHz). Runs on `pl_clk0` (= PSCLK, decision S1); only LOCKED crosses (2FF). Positive RATE = `mclk` slower. The loop that sets RATE is in Linux (S3) |
| Control plane (generic) | `src/rtl/axil_reg_window.sv` | the third window type: RW + RO words for a block on the AXI clock (see §4.1) |
| Control plane (binding) | `src/rtl/media_clock_ctrl_regs.sv` | the steerer's window (ID `0x4D53_5001`, CONFIG = PSCLK Hz; RATE; steps, dropped, flags, VCO_HZ, PS_DIV) |
| Platform | `constraints/fpgamixer_genesys_zu.xdc` | since Phase 11 H.3 only `sysclk`: its pin, its clock, the MMCM's `CLOCK_DEDICATED_ROUTE` (names `u_clk/u_mmcm`). The Pmod pins and codec timing are in its git history |
| Platform | `scripts/create_project.tcl` | the PS block design, the address map, scoped constraint files |
| (archived) | `src/archive/rtl/i2s_port.sv` (+ `i2s_receiver`, `i2s_transmitter`, `i2s_clock_divider`, `oddr_out`) | the Pmod I2S2 front door, Phases 1–10; **removed in Phase 11 H.3** (decision P1), kept for reference (`src/archive/README.md`) |
| Front door | `src/rtl/pcm_link.sv` (+ `async_fifo`) | PS ↔ PL link, PL half: AMD Audio Formatter AXI4-Stream audio ↔ PCM contract, up to 8 ch each way; its only clock crossing is two `async_fifo`s. Knows nothing about USB/AVB (Phase 8: `phase8_status_2026-09-25.md`). **Three instances:** `u_link` (link #1, used by USB device mode), `u_link2` (link #2, `INCLUDE_LINK2`, P9.5, for AVB) and `u_link3` (link #3, `INCLUDE_LINK3`, Phase 11 H.3, for USB host mode: formatter at 0x8012_0000, status window at 0x8000_C000), identical, each with its own formatter and status window |
| Front door (Linux half of a link) | `yocto/meta-fpgamixer/recipes-kernel/fpgamixer-link-card/` + the card nodes in `recipes-bsp/device-tree/files/system-user.dtsi` | the ASoC machine driver that makes a formatter an ALSA card; **one DT node per link**, the card name from `fpgamixer,card-name` (default `FPGAmixerLink` = link #1; link #2 = `FPGAmixerLink2`, P9.5) |
| Generic | `src/rtl/async_fifo.sv` + `constraints/async_fifo.xdc` | dual-clock FIFO; XDC scoped to the module like `coef_bank_handoff.xdc` |
| Platform (image) | `yocto/meta-fpgamixer/recipes-kernel/`, `recipes-apps/fpgamixer-usb-gadget` | kernel fragments (USB device mode; since P9.6 CBS + ETF); the UAC2 gadget (USB front door, Linux half) |
| Front door (Linux half, generic) | `recipes-apps/fpgamixer-bridge-core/` (`bridge_core.{c,h}`, `bridge_convert.h`) | Phase 9 (P9.7): what every front-door bridge shares: capture → repack → playback at a fixed queue, one poll over both PCMs, xrun + coarse handling, logging, an optional servo hook. Knows no protocol |
| Front door (USB, Linux half) | `recipes-apps/fpgamixer-usb-bridge/` | gadget ↔ `FPGAmixerLink` on the core, plus the pitch servo that steers the Mac to `mclk` |
| Front door (USB host, Linux half) | `recipes-apps/fpgamixer-usbhost/` (+ `bridge_rate_src.{c,h}` in bridge-core) | Phase 11: a class-compliant interface on the Type-A port (the MOTU M2) ↔ a link card, through `bridge_core`'s rate stage (libsamplerate, `fastest`) and a PI ratio servo per direction, since the interface runs on its own clock. Config `/etc/fpgamixer/usbhost.conf`; exits when the card goes and systemd restarts it |
| Front door (AVB, Linux half) | `recipes-apps/fpgamixer-avb/` (+ `tools/avb_net.py`) | Phase 9 (P9.6/P9.7): from `/etc/fpgamixer/avb.conf`: TAI offset, stream VLAN, class A shaping (software CBS + ETF), the AAF ALSA devices `avb_tx` / `avb_rx` (alsa-plugins AAF); `fpgamixer-avb-bridge`: AAF ↔ `FPGAmixerLink2` on the core, **no servo** (both sides on the PHC's time) |
| Front door (AVB, control) | `tools/avb_entityd.py` + `avdecc_pdu.py`, `avdecc_model.py`, `avdecc_entity.py`, `msrp.py` (`fpgamixer-avb-entity.service`) | Phase 10: the board as an AVDECC entity (ADP/AECP/ACMP) and MSRP/MVRP participant: one 8-ch talker, one 8-ch listener; a controller's connection or format choice re-points the bridge (runtime file → `avb_net` → bridge restart). Knows nothing about the core; `avdecc_probe.py` is a minimal controller for tests |
| PCM core | `src/rtl/mixer_core.sv` | the whole core as one block, packed contract on both sides. Since Phase 12: converter → `pcm_gain` (input levels) → `pcm_matrix` (input matrix, N_IN → N_BUS) → `pcm_gain` (bus levels) → `pcm_matrix` (bus matrix, N_BUS → N_OUT) → `pcm_gain` (output levels) → converter; every block saturates to 24 bits. **Since Phase 15 the converters are the I/O patch** (`pcm_patch2stream`, `pcm_stream2patch`): the packed sides are P_IN / P_OUT I/O ports, not channels, and there are seven coefficient read ports. Phase 9 (C4) as converters + one matrix; Phase 7 DSP blocks go into the chain |
| PCM core (generic) | `src/rtl/pcm_patch2stream.sv`, `src/rtl/pcm_stream2patch.sv` | Phase 15 (CS1): the core boundary with the patch. Input: packed P ports → stream of N channels, channel k = the port its `source[k]` names (0 = None: silence), any port to any number of channels; beats in cycles 2 … N+1 (+1 against `pcm_pack2stream`: the table read). Output: stream of N channels → packed P ports, channel c to the port its `destination[c]` names; ports no channel names are silent, two channels on one port: the later wins; output 2 cycles after the last beat (+1 against `pcm_stream2pack`). Tables through read ports (ROW_LEN 1, entry = port + 1) |
| PCM core (tap seam) | `mixer_core` tap ports | Phase 13: `tap_in_*` / `tap_bus_*` / `tap_out_*`, copies of the three level stages' output streams (stream contract). Listeners attach outside the chain and can't affect audio or D |
| Control plane (meter) | `src/rtl/pcm_peak.sv` + `constraints/pcm_peak.xdc` | Phase 13 (F4a): per-channel `max(|x|)` of a tap stream on `mclk`; a SNAP (aclk) closes the window at the next frame strobe: all accumulators copied to the closed bank on one edge and cleared. The `axil_coef_window` store interface (commit = SNAP). CDC: two toggles + one multicycle path, scoped XDC. One reader |
| Control plane (binding) | `src/rtl/peak_regs_axil.sv` | Phase 13: a meter's window (ID `0x504B_5001`; CONFIG = N, TAP, 24, 0; `PEAK[c]` at 0x100 + 4c) |
| Simulation | `src/sim/matrix_packed_sim.sv` | the Phase 9 core body (converters + one matrix), so the matrix TBs keep testing the matrix on its own |
| PCM core | `src/rtl/pcm_matrix.sv` + `src/rtl/pcm_matrix_pkg.sv` | N_IN × N_OUT crosspoint matrix, **time-shared** since P9.A4: LANES DSP48E2s (12 × 12: 1), stream in/out, coefficient read port. The package holds the lane choice and the latency formulas, shared with the platform layer |
| PCM core (generic) | `src/rtl/pcm_gain.sv` | Phase 12: per-channel gain stage on the stream contract, one DSP48E2 time-shared over N channels, coefficient read port addressed by `s_ch` (ROW_LEN 1, LANES 1); every beat out exactly `GAIN_LAT` (4) cycles after it came in. Used for the input, bus and output levels; the place for mute (gain 0), gain smoothing and the meter taps |
| PCM core | `src/rtl/mixer_core_pkg.sv` | Phase 12: the chain's arithmetic in one place: `GAIN_LAT`, last-beat cycles per stream, the core's D, and the lane chooser for both matrices (`chain_l1`/`chain_l2`), on top of `pcm_matrix_pkg`'s per-matrix formulas |
| PCM core (generic) | `src/rtl/pcm_pack2stream.sv`, `src/rtl/pcm_stream2pack.sv` | core boundary: packed PCM contract ↔ PCM stream contract (§2.1) |
| Simulation (generic) | `src/sim/pcm_stream_monitor.sv` | checks a stream against §2.1 and a block's stated timing |
| Control plane (generic) | `src/rtl/axil_coef_window.sv` | AXI4-Lite slave, common header; coefficients through a store's request interface (since P9.A4; the shadow moved into `coef_bank_ram`); read back sign-extended, or zero-extended with `COEF_SIGNED` = 0 (Phase 15, for tables of numbers) |
| Control plane (generic) | `src/rtl/coef_bank_handoff.sv` + `constraints/coef_bank_handoff.xdc` | a bank of registers across clocks, whole bank on one edge; the XDC is scoped to the module. Since Phase 9 used for the status windows (block clock → AXI clock) |
| Control plane (generic) | `src/rtl/coef_bank_ram.sv` + `constraints/coef_bank_ram.xdc` | Phase 9 (P9.A3): coefficient bank in RAM: shadow + two banks per lane, COMMIT = copy then swap at the frame strobe, a read port for time-shared blocks (§3). Store interface towards the window. Only the two toggles cross clocks; the XDC is scoped to the module (`create_project.tcl`, PS phases) |
| Simulation (tooling) | `scripts/xsim_regress.ps1` | every TB with XSim on Windows, each in a fresh directory; the counterpart of `scripts/sim.mk` (Icarus), keep the two in step |
| Generic | `src/rtl/coef_flat_reader.sv` | the same read port over a flat vector (non-PS builds, TBs) |
| Control plane (binding) | `src/rtl/matrix_regs_axil.sv` | the matrix's ID, CONFIG and bank size over the two generic parts. **Two instances since Phase 12:** `u_regs` (input matrix, 0x8000_0000) and `u_busmx_regs` (bus matrix, 0x8000_5000) |
| Control plane (binding) | `src/rtl/patch_regs_axil.sv` | Phase 15: a patch table's window (ID `0x5054_5001`; CONFIG = N, P, **DIR** (0 input: sources, 1 output: destinations), entry width; `ENTRY[c]` at 0x100 + 4c, unsigned, the OSC value: 0 = None, port + 1) over `axil_coef_window` (`COEF_SIGNED` 0) + `coef_bank_ram`, so a repatch lands whole on one frame. Two instances: `u_inpatch_regs`, `u_outpatch_regs` |
| Control plane (binding) | `src/rtl/gain_regs_axil.sv` | Phase 12: a gain stage's window (ID `0x474E_5001`; CONFIG = N, **TAP** (0 input, 1 bus, 2 output), width, frac; `GAIN[c]` at 0x100 + 4c) over the same two generic parts, bank N × 1 on one lane. Three instances: `u_inlvl_regs`, `u_buslvl_regs`, `u_outlvl_regs` |
| Simulation | `src/sim/ps_sys_wrapper_stub.sv` | the BD wrapper's stand-in for a PS build without links or media clock: five AXI4-Lite master BFMs + `ctrl_aclk`/`ctrl_aresetn`, so `tb_top_windows` checks the real top's window wiring. Excluded from the Vivado project |
| Control plane (generic) | `src/rtl/axil_stat_window.sv` | read-only AXI4-Lite status window, same header; its words arrive through a `coef_bank_handoff` used in reverse (block clock → AXI clock) |
| Control plane (binding) | `src/rtl/pcm_link_stat_regs.sv` | a `pcm_link`'s counters and fill watermarks (ID `0x4C4B_5001`); one instance per link (`u_link_stat`, `u_link2_stat`) |
| Control plane (software) | `tools/mixer_hw.py` | `RegWindow` (any window), `MatrixHW` (dB gains; windows `matrix` and, since Phase 12, `busmatrix`), `GainHW` (Phase 12: per-channel dB levels; `InputLevelHW` / `BusLevelHW` / `OutputLevelHW` check the TAP; windows `inlevel`, `buslevel`, `outlevel`), `PeakHW` (Phase 13: SNAP + read; `InputMeterHW` / `BusMeterHW` / `OutputMeterHW` check the TAP; windows `inmeter`, `busmeter`, `outmeter`; `mixer_hw.py meter`), `WindowAbsent` (the device-tree guard's refusal), `PatchHW` (Phase 15: `InputPatchHW` / `OutputPatchHW` check the DIR; windows `inpatch`, `outpatch`, together = `PATCH`; `mixer_hw.py patch`), **`IO_PORTS`** (the I/O port map's labels, an explicit copy of `fpgamixer_top`'s, checked against the patch windows' port count), `LinkStatHW` (windows `linkstat` and `linkstat2`; `mixer_hw.py link` / `link2`), `MediaClockHW` (ppm vs gPTP, `mixer_hw.py mclk`), `MediaClockSteerHW` (ppm ↔ RATE, `mixer_hw.py steer`), `WINDOWS` (address map) |
| Control plane (software) | `tools/osc_mixer_server.py` | OSC ↔ state tree; zone → `Backend` table (`BACKENDS`) |
| Control plane (software) | `tools/mixer_params.py` | the parameter model: `ModuleSpec` (metadata + value rules; `option_labels` → `optionLabels`, Phase 15), `ZoneSpec`, `Model.resolve`; no sockets, no hardware (since 2026-10-04) |
| Control plane (software) | `tools/mixer_snapshots.py` | Phase 14: the snapshot format (envelope check), name rules, limits and the on-board store of named snapshots; recall itself is the server's (`handle_snapshot`, `fit_snapshot`, `recall_snapshot`) through the model and `Backend.apply_many` (§4.2) |
| Control plane (software) | `tools/mixer_meters.py` | Phase 13 (F4): `MeterSource` (the PL's meters, or a synthetic one for tests), `MeterHub` (subscriptions, 5 s lease, one sampler at the highest subscribed rate, per-subscriber per-zone maxima and sequences, the UDP stream); no OSC parsing (the server's `handle_meter_subscribe` validates) |
| Control plane (software) | `tools/osc_discovery.py` | discovery: `advertise(name)`; `DnssdAdvertiser` publishes `_studiorunner._tcp` through systemd-resolved (`.dnssd` file), `NoAdvertiser` otherwise (since 2026-10-04) |
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

- **One clock domain for the whole core.** A front door whose source runs on a different clock (USB host, network media clock, anything not derived from `mclk`) must bridge it **inside the front door** (elastic buffer, rate adaptation or ASRC), and present samples on `mclk` like `pcm_link` does (the USB host bridge's resampler is that rate adaptation, in its Linux half). The core never contains a clock crossing for audio.
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
- **The core's packed output updates on one edge at a stated cycle D of the same frame** (C2): today's latency to the links is kept. **D ≤ 255** since Phase 15 (CS11): the only consumers are the `pcm_link`s, which capture `tx_flat` on the next strobe edge (256). (It was 250 while `i2s_port`, the Pmods' front door, sampled on edge 254.) Today D = 251 (20 → 20 → 20 on 4 + 4 lanes, with the patch converters).
- Consumers may check `s_ch` (as the link checks TID). `src/sim/pcm_stream_monitor.sv` checks all of the above and is used by every core TB.

Boundary converters (generic, P9.A2): **`pcm_pack2stream`** captures the packed vector on the strobe and emits channels 0 … N−1 on cycles 1 … N. **`pcm_stream2pack`** collects beats by `s_ch` and moves all channels to its packed output together, one cycle after the beat for N−1; `err_o` pulses on an out-of-order beat or an incomplete frame. **Since Phase 15 the core uses the patch converters** instead (`pcm_patch2stream`: beats on cycles 2 … N+1; `pcm_stream2patch`: output 2 cycles after the last beat; §1.1); the plain pair stays for the matrix TBs (`matrix_packed_sim`).

**Since Phase 15 this is the I/O port map, not the channel map:** the core's packed sides are the I/O ports below, and the patch (OSC `source` / `destination`, entry = port + 1) says which port each core channel uses; PS builds start with nothing patched (CS5). Until then core channel k *was* port k, which is what the rest of this paragraph describes (read "port" for "ch"). Today's map (platform layer, `fpgamixer_top`, since Phase 8; grown in P9.5; **ch0–3 changed in Phase 11 H.3**): **ch0–ch3 = PS↔PL link #3 channels 0–3** (card `FPGAmixerLink3`, the USB host front door: the MOTU M2 uses 0–1; link #3's channels 4–7 aren't connected, in reads nothing and out sends silence). They were the Pmods (JB_L, JB_R, JC_L, JC_R) until then; the M2 took their slots on purpose (it *is* the board's analog I/O now), and their input-matrix crosspoints start all off (H5). **ch4–ch11 = PS↔PL link #1 channels 0–7** (in = what Linux plays into the link, e.g. the Mac's USB outputs 1–8; out = what Linux records), **ch12–ch19 = link #2 channels 0–7** (card `FPGAmixerLink2`, the AVB front door's; P9.5). The map is the concatenation `{link2, link, link3[0:3]}`. **New channels are appended, never interleaved**, so saved crosspoint indices keep their meaning as the core grows. Without a link (non-PS builds; link #2 also in `phase8` builds) its channels read as silence; the core is **20 × 20 in every build**: since Phase 12, 20 inputs → 20 buses → 20 outputs, with levels on all three (4 + 4 matrix lanes + 3 gain DSPs, D = 249; the single matrix was 2 lanes, D = 227).

---

## 3. Coefficient contract (core ← control plane)

Every tunable core block exposes its parameters as one flat **coefficient port**:

- in the `mclk` domain;
- changes only as a **whole bank on one `mclk` edge**, so every frame sees one consistent set (the block samples it on the frame's `valid`);
- the block has **no idea** whether the value came from a register, a constant, or a test bench. `pcm_matrix.gains_flat` is the first instance: the PS build drives it from `matrix_regs_axil`, the non-PS build ties it to `MATRIX_GAINS`, and the unit TB drives a constant.

**Form since Phase 9 (C3, built in P9.A3/A4): a read port.** A time-shared block drives an address and gets a word of coefficients one cycle later, one per lane (layout: rows round-robin over lanes, `coef_bank_ram.sv` header). The bank behind the port swaps **only on a frame strobe**, and a block does all of one frame's reads between two strobes, so every frame sees one whole bank. Served by `coef_bank_ram` in the PS build (via `matrix_regs_axil`) and by `coef_flat_reader` over a flat vector in non-PS builds (the reset banks; `MATRIX_GAINS` until Phase 12) and unit TBs. The register window didn't change. `pcm_matrix` is the first user; a flat `gains_flat`-style vector remains fine for a small block that isn't time-shared.

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
| 0x8000_0000 | input matrix (`u_regs` / `u_core`), 12 × 12 since Phase 8, **20 × 20 since P9.5**; input → output until Phase 12, **input → bus since** (zone `inputMatrix`) | Phase 5 |
| 0x8000_1000 | PS↔PL link status (`u_link_stat`, read-only, ID `0x4C4B_5001`) | Phase 8 |
| 0x8000_2000 | media-clock meter (`u_mclk_stat`, read-only, ID `0x4D43_5001`): `mclk` vs the gPTP 1PPS; `phase9` builds | Phase 9 (P9.3) |
| 0x8000_3000 | media-clock steering (`u_mclk_ctrl`, read/write, ID `0x4D53_5001`): the rate for the MMCM's fine phase shift; `phase9` builds | Phase 9 (P9.4b) |
| 0x8000_4000 | PS↔PL **link #2** status (`u_link2_stat`, read-only, ID `0x4C4B_5001`, the same binding as link #1); `phase9` builds | Phase 9 (P9.5) |
| 0x8000_5000 | bus matrix (`u_busmx_regs`, `matrix_regs_axil`, ID `0x4D58_5001`, N_BUS → N_OUT; zone `busMatrix`); every PS build (`M_AXI_BUSMX`) | Phase 12 |
| 0x8000_6000 | input levels (`u_inlvl_regs`, `gain_regs_axil`, ID `0x474E_5001`, TAP 0; zone `inputChannel`); every PS build (`M_AXI_INLVL`) | Phase 12 |
| 0x8000_7000 | bus levels (`u_buslvl_regs`, TAP 1; zone `busChannel`; `M_AXI_BUSLVL`) | Phase 12 |
| 0x8000_8000 | output levels (`u_outlvl_regs`, TAP 2; zone `outputChannel`; `M_AXI_OUTLVL`) | Phase 12 |
| 0x8000_9000 | input peak meter (`u_inmtr_regs`, `peak_regs_axil`, ID `0x504B_5001`, TAP 0; tap `tap_in`; `M_AXI_INMTR`); every PS build | Phase 13 |
| 0x8000_A000 | bus peak meter (`u_busmtr_regs`, TAP 1; `M_AXI_BUSMTR`) | Phase 13 |
| 0x8000_B000 | output peak meter (`u_outmtr_regs`, TAP 2; `M_AXI_OUTMTR`) | Phase 13 |
| 0x8000_C000 | PS↔PL **link #3** status (`u_link3_stat`, read-only, ID `0x4C4B_5001`, the same binding as links #1/#2; on `ctrl_smc` M15 until Phase 15, now on **`ctrl_smc2`**, the second control SmartConnect cascaded from that master: same address and port); `phase9` builds | Phase 11 (H.3) |
| 0x8000_D000 | input patch (`u_inpatch_regs`, `patch_regs_axil`, ID `0x5054_5001`, DIR 0; zone `inputChannel`, module `source`; `M_AXI_INPATCH`); every PS build, behind the second SmartConnect (BD: Phase 15 step 3) | Phase 15 |
| 0x8000_E000 | output patch (`u_outpatch_regs`, DIR 1; zone `outputChannel`, module `destination`; `M_AXI_OUTPATCH`) | Phase 15 |
| 0x8000_F000… | reserved: DSP blocks | — |
| 0x8010_0000 (64K) | AMD Audio Formatter #1 registers (`link_formatter`, card `FPGAmixerLink`): **driver-owned** (`xlnx_formatter_pcm`), not a self-describing window; software never maps it | Phase 8 |
| 0x8011_0000 (64K) | AMD Audio Formatter #2 registers (`link2_formatter`, card `FPGAmixerLink2`): driver-owned, as #1; `phase9` builds | Phase 9 (P9.5) |
| 0x8012_0000 (64K) | AMD Audio Formatter #3 registers (`link3_formatter`, card `FPGAmixerLink3`, the USB host front door): driver-owned, as #1; SmartConnect M14; `phase9` builds | Phase 11 (H.3) |

Driver-owned devices go at 0x801x_xxxx, so the 0x8000_x000 range stays for windows with the ID/CONFIG header.

Adding a block = one more SmartConnect master port (since Phase 15 on `ctrl_smc2`: `ctrl_smc` is full), one more window, one more register-block instance. Nothing existing moves, and no constraint needs writing: the handoff's scoped XDC covers the new instance.

**Software does not scan for windows.** An access where no block is mapped is answered with a bus error, and Linux turns that into a kernel fault. `mixer_hw.WINDOWS` is therefore an explicit copy of this table, and each window is checked by its ID when opened.

### 4.2 Software: OSC zone → backend → window

- **Below the protocol: transport.** `tools/osc_codec.py` turns bytes into OSC messages and back. A TCP connection carries packets in one framing per port (`--tcp-framing len32|none`, default `len32`, the standard's "TCP framing"); a UDP datagram is one packet. A packet is a message or a bundle, and the protocol layer sees only messages, in order. Nothing above this layer knows the framing; `ClientRegistry` frames every TCP send.
- **Address root.** One parser (`split_after_mixer_name`) accepts the current name or the alias `mixer`, for TCP and UDP alike; the name rules are `name_problem`. Every `set` from either transport takes one path (`handle_set`), with a reply function for TCP and none for UDP, which never replies.
- The OSC address `/<name>/<set|get>/<zone>/<index>/<module>` selects a **zone**; each zone is served by one **backend** that knows one block type and one register window.
- Today (Phase 12): `inputChannel` → `GainBackend` → `InputLevelHW` → window `inlevel` (0x8000_6000); `inputMatrix` → `MatrixBackend` → `MatrixHW` → `matrix` (0x8000_0000, input → bus); `busChannel` → `GainBackend` → `BusLevelHW` → `buslevel` (0x8000_7000); `busMatrix` → `MatrixBackend` → `MatrixHW` → `busmatrix` (0x8000_5000); `outputChannel` → `GainBackend` → `OutputLevelHW` → `outlevel` (0x8000_8000). All five share one `level` module (`level_module`, controller D77). The four bus-layer windows are opened together or not at all (`mixer_hw.BUS_LAYER`, absence = `WindowAbsent` from the device-tree guard): on an older bitstream only `inputMatrix` is served, input → output; a partial set, sizes that don't chain, or a different gain format are refused at startup.
- **A backend describes its own zone** (`Backend.describe()` → a `ZoneSpec`: shape and module list, plus each module's `ModuleSpec`: type, unit, range, default, options, group, read-only; `tools/mixer_params.py`). The server builds one parameter model from all backends plus the `system` settings (`build_model`), and that model is the only description of what the mixer has: every set and get is resolved against it, and anything it doesn't name is refused with an error reply (zones without a backend are no longer stored generically, since 2026-10-04). The config reply (amendment B) is built from the same model (`Model.config`): zones, modules and system settings from the descriptions, values from the state (sparse).
- **Ordering.** `ClientRegistry.lock` is the server's one ordering lock: a change (backend apply, store, echo), every TCP send, and the config snapshot (read and send) each run under it. That is what contract F3 needs (nothing broadcast between a snapshot's read and its send), and it also keeps echoes in store order and packets whole. A controller that stops reading is dropped after 5 s. The final server can replace the lock with per-controller queues fed in commit order; the guarantees are the contract, the lock is the implementation.
- Adding a block on the software side = a window entry in `mixer_hw.WINDOWS`, a `Backend` subclass (including its `describe()`), and one entry in `build_backends()`.
- The value rules (clamp, snap, round, enum options, kind) are the module's (`ModuleSpec.apply`), applied before the backend sees a value; the backend converts units (dB → Q2.16) and returns the value actually applied, which is what is stored and echoed.
- **Stored state mirrors the OSC tree.** The state file (`mixer_state.json`) is the address tail `<zone>/<index>/<module>` as nested JSON objects, with the values as leaves; the zones are the top-level keys, and nothing wraps them:
  ```json
  {
    "system":       { "deviceName": "FOHmixer" },
    "inputChannel": { "0": { "level": -6.0 } },
    "inputMatrix":  { "0_0": { "level": 0.0, "delay": 2.39 } }
  }
  ```
  The mixer name (the address root) lives only at `system.deviceName`. A value can't sit where the tree has a branch, or the other way round; such a set is ignored, not stored or echoed. That's the tree's only rule, and addresses that follow the standard's `zone/index/module` shape never hit it. Every stored value is finite, so the file is strict JSON: every value passes its module's rules before it is applied, stored or echoed (NaN and −inf remapped to −99.9, +inf to +99.9, then clamped to the module's range), and paths are stored in canonical form (`1_2`, never `01_002`). Full rules, including durability: the docstring of `tools/mixer_state.py`. This format is a contract, not an implementation detail. Phase 6 persistence and any future server read and write the same tree, and adding a zone or module never changes the format.
- **Snapshots (Phase 14).** `tools/mixer_snapshots.py` owns the snapshot JSON's envelope (`snapshotVersion`, `values` keyed like the config's `values`, informational `name`/`savedAt`/`source`/`zones`), the name rules and limits, and the store of named files (`/var/lib/fpgamixer/snapshots`, crash-safe writes like the state file). It knows no OSC, model or hardware. The server's `handle_snapshot` is the protocol (standard "Snapshots"); a recall goes through the same model (`fit_snapshot`: `Model.resolve` + `ModuleSpec.apply`, any refusal refuses the whole recall) and the same backends, through **`Backend.apply_many`**, which a windowed backend implements as one bank write and one COMMIT; then store and echo under the ordering lock, like a `set`. The snapshot format is a second contract next to the state file's (a controller keeps these files); the state file is unchanged. A future block gets snapshots for free once its backend exists (`apply_many` falls back to per-value `apply`).
- **Virtual groups (Phase 14).** Each channel zone's backend lists a `vgroup` module (int 0..64, a stored parameter that never reaches a window). A module opts into linking with `ModuleSpec.linked` (metadata `linked: true`; today `level`), so a future module links by declaring it, not by special cases. `apply_set` asks `link_targets` (under the ordering lock) for every parameter a set applies to: the same module on the channel's group members (channel zones only: matrix crosspoints never link, so grouped channels stay independently routable); one target is the old path, several go through `Backend.apply_many` (one COMMIT), then are stored and echoed, the requested one first. A snapshot recall bypasses linking (it sets stored values as they are).
- **I/O patch and channel counts (Phase 15).** A channel zone may now take its modules from **more than one window**: `GainBackend` serves `level` through its gain window and, with a `PatchPart`, `source` (input) or `destination` (output) through a patch window, so a backend routes each module to the window that implements it (`vgroup`, `name` stay stored-only). Labels come from `mixer_hw.IO_PORTS` as the enum's `optionLabels`. Nothing is seeded (CS5). The move rule (one output channel per destination) runs in `apply_set` (`destination_holders`) and in a recall (`recall_destinations`), each as one `apply_many`. **Counts** are `system` settings that exist only with the patch; `apply_topology` sets each backend's shown size (`GainBackend.count`, `MatrixBackend.set_shape`), rebuilds the model and trims the meter blobs (`MeterHub.set_visible`). A hidden channel keeps its stored values; its backend writes `hide`'s value to the hardware instead (source or destination None, bus level off), so the PL needs nothing new for counts. A count change is echoed, then `/<name>/config/changed` (standard *Config changed*). `apply_set` resolves under the ordering lock, since the model can now change.
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
| Bus layer + channel levels (**Phase 12, `phase12_status_2026-10-04.md`; core built in simulation**) | stream contract between the blocks; one register window per block; zones `inputChannel`, `inputMatrix` (now input → bus), `busChannel`, `busMatrix`, `outputChannel` | `mixer_core` = levels → `pcm_matrix` (N_IN × N_BUS) → levels → `pcm_matrix` (N_BUS × N_OUT) → levels (`pcm_gain`, `mixer_core_pkg`); a second `matrix_regs_axil` at 0x8000_5000 and `gain_regs_axil` × 3 at 0x8000_6000–8000 (step 3); backends in step 5 |
| Phase 6 persistence | control plane only | server-side; already restores and pushes the bank at startup |
| Phase 7 DSP | PCM contract + coefficient contract + a window per DSP block | one core block per DSP type |
| Phase 8/11 USB audio, Phase 9 AVB | **front door** | a generic **PS ↔ PL PCM stream bridge** (DMA or AXI-Stream FIFO into an elastic buffer that presents the PCM contract on `mclk`), shared by USB and AVB; the protocol side (ALSA/`f_uac2`, 1722) stays in Linux. **Proposal (2026-09-25, awaiting decisions):** `phase8_status_2026-09-25.md`: Audio Formatter → ALSA card on `mclk` time, `pcm_link` PL front door, new generic RO `axil_stat_window` |

**Phase 9 (AVB), proposed 2026-09-26** (`phase9_status_2026-09-26.md`): a **second link instance** (formatter + `pcm_link`, core channels 12–19 appended; **built in P9.5**, no new RTL, the card driver named per DT node) with an AVB front door whose Linux half is gPTP + CBS shaping + the alsa-plugins AAF talker/listener + a bridge. One new **platform** piece: `mclk` disciplined to gPTP (**done, P9.3/P9.4**), so the network disciplines the core's own clock and the core still never sees a foreign one. One **core** change with an unchanged interface: a time-multiplexed `pcm_matrix` (**done, P9.A**).

### Why there is no "quick USB" path (asked 2026-09-25)

USB device mode itself is available on this board (Type-C, DWC3, Linux `f_uac2` gadget), and getting the Mac to see a soundcard is quick. The audio then exists only in Linux memory. Getting it into the matrix needs:

1. the PS ↔ PL PCM stream bridge above (nothing moves sample data between the PS and the PL today; the only link is the control-register window), and
2. rate adaptation: the Mac's USB clock is independent of `mclk`, which itself runs +324 ppm fast (Roadmap §4), so without a feedback endpoint or ASRC the stream slips ~16 samples/s.

Any shortcut that skipped (1) or (2) would wire USB straight into the core and break §2. Built properly, the bridge is the same one Phase 9 needs, so it is scheduled as its own piece of work rather than a test hack.
