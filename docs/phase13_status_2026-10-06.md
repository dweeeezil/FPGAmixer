# Phase 13 status: 2026-10-06 — metering: design proposal

*Branch `phase13-metering`, from `phase12-levels-buses` at `2bf1346`. Covers controller-support step 6 (F4: the server's meter protocol) and F4a (the gateware peak detector), planned as "next" by Phase 12 decision L8.*

**State: decided 2026-10-06 (M1–M9 all as recommended, §5); steps 1–2 done in simulation (§6.1, §6.2); step 3 (Vivado) next.**

---

## 1. The goal

The app's Inputs, Buses and Outputs strips show live level meters for the board's 60 channels, fed by the stream the OSC standard defines ("Metering"). The meters must be honest: every peak between two updates is shown (nothing lost between polls), and each update covers exactly one window of audio for every channel of a zone.

## 2. What the contract already fixes (checked 2026-10-06)

| Fact | Source | Consequence |
|---|---|---|
| `/<name>/meter/subscribe <port:int> <rateHz:int> <zoneMask:int>` over TCP; mask bit 0 `inputChannel`, 1 `busChannel`, 2 `outputChannel`; rate clamped 1–120; lease 5 s, renewed every 2 s; mask 0 unsubscribes; closing TCP ends it; a new port moves the stream; malformed → error reply | standard "Metering"; app D39, D55 | the server's subscription logic is fully specified |
| Stream: UDP to the TCP peer's IP, `/<name>/meter/<zone> <blob>`, blob = big-endian `uint32 seq` + `N × int16` peaks in 0.01 dBFS, −32768 = silence; seq per zone per subscriber, from 0, +1 per message, wraps; **the peak is the highest since the previous message for that zone (nothing lost)**; tap = post-DSP of the zone | standard; app D53 (gaps = drops, late frames discarded) | per-subscriber, per-zone "max since my last message" |
| The app subscribes only to channel zones the config lists, at 30 Hz, for the visible tab's zones; resubscribes on every snapshot / reconnect; treats a reading older than 500 ms as silence | app D55, D70 | three zones of 20 channels, typically one subscriber at 30 Hz |
| The app's ballistics (decay, peak hold, clip latch at ≥ 0 dBFS) are client-side | app D54 | the mixer sends raw peaks only |
| The handoff for F4a (`../StudioRunner-controller/docs/handoff/hdl-dsp-library-peak-detector.md`): per-channel `max(|x|)`, −2²³ saturated to 2²³−1, **max since last read, clear on read**, an atomic snapshot across channels via a SNAP strobe, raw 24-bit magnitude (dB in the PS), ID suggestion `0x504B_5001`, the common header | handoff | the PL block's behaviour is specified; this proposal decides its shape here |
| The post-DSP taps exist since Phase 12: the outputs of the three `pcm_gain` stages inside `mixer_core` (streams `b`, `d`, `f`), on the stream contract, every channel once per frame | `mixer_core.sv` | no new audio block; the meters only listen |
| Controller-support decision C3: subscription, lease and stream behind a **`MeterSource`** interface, tested with a synthetic source enabled only by a server flag | controller status §2 | the server half can be built and tested before the gateware |
| The `HDL-DSP-Library` repo the handoff was written for doesn't exist on this PC | `C:\Users\dodec\Documents` | see M7 |

## 3. The shape

### 3.1 Gateware: tap ports + one peak meter per zone

```
mixer_core:  … pcm_gain (input levels) ─b─► … pcm_gain (bus levels) ─d─► … pcm_gain (output levels) ─f─► stream2pack
                        │                              │                                │
                  tap_in_* (stream)              tap_bus_* (stream)               tap_out_* (stream)
                        ▼                              ▼                                ▼
fpgamixer_top:   peak_regs_axil (in)            peak_regs_axil (bus)             peak_regs_axil (out)
                 0x8000_9000                    0x8000_A000                      0x8000_B000
```

- **`mixer_core` gets tap ports:** a copy of each level stage's output stream (`valid`, `ch`, `data`), the stream contract unchanged. A new seam ("tap"), generic: any listener (meters now; pre-fader meters, a spectrum view or a recorder later) attaches without touching the chain. Taps never affect the audio or D.
- **`pcm_peak`** (new PCM-core-side block, mclk): listens to a stream; per channel `peak = max(peak, |x|)` (with −2²³ → 2²³−1), kept in **two banks** in a small dual-clock RAM. The detector writes the *active* bank; at a **frame strobe** after a snapshot request it flips banks, so a window is always a whole number of frames and the same frames for every channel (atomic across channels by construction). The first beat of each channel in a new window overwrites instead of comparing, so no clearing pass is needed and a loud frame at the boundary isn't lost (the handoff's "clear means start at the current sample").
- **`peak_regs_axil`** (binding): `axil_coef_window` + `pcm_peak`'s bank, with the coefficient semantics read the other way: **COMMIT = SNAP** (request a flip), BUSY/QUEUED as for a commit, `COMMITS` = snapshots taken, `COEF[c]` = channel c's peak of the last closed window (24-bit magnitude, reads positive). Writes to `COEF[c]` are ignored. ID **`0x504B_5001`** ("PK"), CONFIG **`{N, TAP, 24, 0}`** (TAP 0/1/2 = input/bus/output, as the gain windows). Only the request/acknowledge toggles cross clocks (the `coef_bank_ram` pattern in reverse); the RAM is written on `mclk` and read on `aclk`, never the same bank at once.
- **Cost (estimate):** no DSPs; per zone one comparator, a little control, the bank in LUTRAM or one RAMB18. Three windows at 0x8000_9000 / A000 / B000 (the next free slots).

### 3.2 Server: `MeterSource` + subscriptions

- **`MeterSource`** (interface): `zones()` → `{zone: N}`; `sample()` → `{zone: [linear peak per channel]}` covering everything since the previous `sample()`.
  - `HardwareMeterSource`: SNAP on the three windows, wait for BUSY to clear (≤ one frame), read 3 × 20 words. Present only with the windows (all three or none, like the bus layer; an older bitstream has no meters and the server says so).
  - `SyntheticMeterSource` (flag `--meter-source synthetic`, tests and the simulator only): deterministic levels per channel that follow the channel's `level`, so tests and the app's demo can see cause and effect.
- **One sampler thread** runs while anyone is subscribed, at the **highest subscribed rate**. Each tick it calls `sample()` once and folds the result into **every subscriber's per-zone running max**; a subscriber whose period has elapsed gets its messages (one per subscribed zone, its own sequence), and its maxima restart. So every subscriber sees every peak once, whatever the rates, and the PL has exactly one reader.
- **Conversion** (PS side, as the handoff asks): `round(100 · 20·log10(peak / 2²³))`, clamped to int16; peak 0 → −32768. Full scale (0x7FFFFF) reads 0 (0.00 dBFS); 1 LSB −138.47 dBFS.
- **Subscriptions** as the standard: TCP `meter/subscribe` with three integers (`i`, or `f` with an integral value), port 1–65535, rate clamped 1–120, mask bits for zones the mixer doesn't have ignored, lease 5 s, renew/move/unsubscribe rules, ended by the TCP connection closing; a malformed request gets an error reply. Datagrams go to the TCP peer's address from one UDP socket of the server's. Meter sends never take the control lock (they don't touch state), so they can't delay echoes, and a stalled controller's UDP can't block anything.
- `mixer_hw.py meter <window>` for the bench: one SNAP + read, printed in dBFS. It takes a window away from the server's next sample (one tick shows less), which is fine for a bench tool; said in its help.

## 4. Verification plan

- **RTL:** `tb_pcm_peak` (+ binding): random streams vs a model of windows; a one-sample transient between two SNAPs reported by the next SNAP only; −2²³ doesn't wrap; atomicity: every channel of a snapshot covers the same frames (unrelated clocks, SNAPs at random times, including back to back and during BUSY); first beat of a window overwrites. `tb_mixer_core` and `tb_top_windows` extended (taps match the level stages' outputs; the three peak windows answer with ID/CONFIG/TAP and see their own zone). Mutation-tested.
- **Vivado + SDT** as Phase 12 (D unchanged = 249; DSP count unchanged = 11).
- **Server:** subscription rules end to end through the socket harness with the synthetic source (rates, lease expiry, move, unsubscribe, malformed → error, per-zone sequences, two subscribers at different rates both seeing a planted transient once, mask bits for absent zones ignored); the hardware source against fake windows on the VM; `app_config_problems`-style decoding of the blob as the app does it. Mutation-tested.
- **Bench (lean):** the app's meters move with USB audio on the input, bus and output tabs; a level change moves the right meter; one clip (0 dBFS) shows on the right strip. No recording.

## 5. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| **M1** | Where the detector attaches | **Tap ports on `mixer_core`** (copies of the level stages' output streams) and the peak meters in the platform layer, each inside its window binding. Keeps the chain untouched and makes "listen to a stream" a reusable seam. (Alternative: detectors inside `mixer_core` with a read port out: the core would grow a control-plane-facing bank it doesn't need.) |
| **M2** | Read semantics | **SNAP on demand, the flip at the next frame strobe, one reader (the server)**; the server fans out to subscribers. (Alternative: free-running hardware windows the server polls: no write path, but a late poll by a busy Linux loses a window's peaks.) |
| **M3** | Taps | **Post-level for the three channel zones now** (the standard's post-DSP). Pre-level (`meter/<zone>_pre`, reserved) later as three more instances on three more taps. |
| **M4** | Register windows | **0x8000_9000 / A000 / B000**, binding `peak_regs_axil` over `axil_coef_window` (COMMIT = SNAP), ID `0x504B_5001`, CONFIG `{N, TAP, 24, 0}`, all three in every PS build, presence as a set. |
| **M5** | Server sampling | **One sampler at the highest subscribed rate, per-subscriber per-zone running maxima**, sends off the control lock, one UDP socket. Sampler stops when nobody is subscribed. |
| **M6** | Scale | Magnitude of the 24-bit sample against **2²³ = 0 dBFS**; silence (−32768) only for an exact 0; int16 clamp. |
| **M7** | Where the HDL lives | **Here** (`src/rtl/pcm_peak.sv`, `peak_regs_axil.sv`), like every other core block; the `HDL-DSP-Library` repo doesn't exist yet. The handoff note in the controller repo can then be retired (your edit; I don't touch that repo). If you do start the library, the block moves there with its TB unchanged. |
| **M8** | Synthetic source | **Server flag only** (`--meter-source synthetic`, refused together with `--hw`), as C3 decided: never on the board. |
| **M9** | Name | Roadmap **Phase 13, "metering"** (F4 + F4a); controller-support step 6 points at it. |

**Decided by the user, 2026-10-06: all as recommended.** M1 tap ports on `mixer_core`, meters in the window bindings; M2 SNAP on demand, flip at the frame strobe, the server the only reader; M3 post-level taps on the three channel zones; M4 windows 0x8000_9000 / A000 / B000, ID `0x504B_5001`, CONFIG `{N, TAP, 24, 0}`; M5 one sampler at the highest subscribed rate, per-subscriber maxima; M6 2²³ = 0 dBFS, −32768 only for 0; M7 the HDL lives here; M8 synthetic source by server flag only; M9 roadmap Phase 13.

## 6. Steps (after the decisions)

1. RTL: `pcm_peak` + `peak_regs_axil` + `tb_pcm_peak`; tap ports on `mixer_core` (`tb_mixer_core` checks them).
2. Top + BD: three windows (`tb_top_windows` extended), `create_project.tcl`.
3. Vivado build, SDT.
4. Server: `MeterSource`, subscriptions, sampler, the hardware and synthetic sources; `mixer_hw` `PeakHW` + `meter` CLI; tests.
5. Image, bench.

Each step: build, test, commit, this doc updated.

### 6.1 Step 1: the peak meter and the tap ports (simulation): PASS

| File | What |
|---|---|
| `src/rtl/pcm_peak.sv` (new) | the meter: one accumulator per channel on `mclk` (`max(|x|)`, −2²³ → 2²³−1), one update per beat; on a requested frame strobe all accumulators are copied into the **closed** bank on one edge and cleared; the AXI side reads the closed bank. The `axil_coef_window` store interface: `commit` = SNAP, `busy` while the copy is in flight, `queued` for a SNAP during BUSY, `commits` = snapshots; reads wait while busy or queued, writes are ignored |
| `src/rtl/peak_regs_axil.sv` (new) | the binding: `axil_coef_window` + `pcm_peak`, ID `0x504B_5001`, CONFIG `{N, TAP, 24, 0}`, `PEAK[c]` at 0x100 + 4c, the tap stream as input |
| `constraints/pcm_peak.xdc` (new) | scoped: the two toggles and the `closed` → `st_rdata` path (multicycle by protocol, as `coef_bank_handoff`), 10 ns datapath-only; enters `create_project.tcl` in step 2 |
| `src/rtl/mixer_core.sv` | **tap ports** `tap_in_*`, `tap_bus_*`, `tap_out_*`: copies of the three level stages' output streams; the chain is unchanged |
| `src/sim/tb_pcm_peak.sv` (new) | the binding with a stream, unrelated clocks, N = 5, against a model with its own windows (closed at a strobe where the DUT's synchronized request is pending): 41 snapshots at random times, random samples with extremes and gaps, a beat on the strobe edge in ~¼ of frames; a queued SNAP pair yields exactly two snapshots; **a read straight after SNAP comes back from that snapshot's window**; a one-sample transient reported once, by the next snapshot only; the most negative sample reads full scale; writes ignored; COMMITS = windows closed (48) |
| `src/sim/tb_mixer_core.sv` | the taps at all seven sizes: the stream contract at their stated last beats, and **every tap beat equal to the model at that point of the chain** (after the input levels, after the bus levels, the output) |

**Two changes from the proposal (§3.1), both simplifications:** the banks are **flip-flops**, not a dual-clock RAM (a per-beat read-modify-write on `mclk` plus an `aclk` read would need three RAM ports): 2 × N × 24 flops per meter, about 1k at 20 channels. And there is no `fresh` flag: since a window always starts at a frame strobe, clearing the accumulators to 0 at the copy is the same as starting at each channel's first sample. The CDC is then the two toggles plus one multicycle path (`closed` → `st_rdata`, captured only while the protocol holds it stable).

**Results (XSim 2026.1):** `peak` PASS, `core` PASS; **full regression 21 of 21**.

**Mutation test: 12 of 12 killed**, after the first run found a weak spot in my TB: "reads allowed while a snapshot is in flight" survived, because the model's closed window at read time was still the previous one in both cases. The no-wait test now also requires the window to have closed before the read returns. Killed: flip not aligned to the strobe (193 checks), accumulators not cleared (98), the most negative sample not saturated (62), a strobe-edge beat dropped (4), reads during BUSY (5), a SNAP during BUSY dropped, COMMITS not counted, a signed compare (125), CONFIG fields swapped; and in the core the bus tap before the bus levels, the input tap before the input levels, the output tap's channel from the wrong stream.

### 6.2 Step 2: the meter windows in the top and the BD (simulation): PASS

| File | What |
|---|---|
| `src/rtl/fpgamixer_top.sv` | the core's tap ports wired in every build; in `INCLUDE_PS` builds `u_inmtr_regs` / `u_busmtr_regs` / `u_outmtr_regs` (`peak_regs_axil`, TAP 0/1/2) on the taps, `ctrl_aclk` and the frame strobe, on `M_AXI_INMTR` / `BUSMTR` / `OUTMTR` |
| `scripts/create_project.tcl` | `pcm_peak.xdc` scoped to `pcm_peak` in the PS phases; SmartConnect `NUM_MI` = base + 7; the three ports on the next masters (**phase9: M11–M13**) at **0x8000_9000 / A000 / B000**; `ASSOCIATED_BUSIF` extended |
| `src/sim/ps_sys_wrapper_stub.sv`, `src/sim/tb_top_windows.sv` | three more masters; each meter's ID and CONFIG (`0x14T0_1800`); after the per-window changes, one SNAP to close the window from before them, then **every channel of every meter** against its zone's value (input levels, bus levels, outputs) |

**Results:** full regression **21 of 21** (`linkstat` first failed to start: Defender; passed on the rerun). **Mutation: 4 of 4 valid mutants killed** (bus meter on the output tap, input meter on the bus tap, the output meter with TAP 1, meters without a frame strobe: timeout); one malformed mutant (an input/output swap written with a placeholder the runner correctly rejected) was replaced by the single-edit "input meter on the bus tap".
