# Hardening status: 2026-10-10 — before the DSP library

**Branch:** `hardening` (from `main` after the Phase 14–15 merge, tag `phase15-baseline`).
**Why:** *"I'd like to do as much hardening as makes sense before the HDL library. I don't want to make a building on an unfinished foundation."* (user, 2026-10-10)

---

## 1. Decisions (user, 2026-10-10)

| # | Question | Decision |
|---|---|---|
| HD1 | Branches | merge Phases 14–15 to `main` (done 2026-10-10, merge commit, tag `phase15-baseline`) |
| HD2 | The core's frame budget (D = 251 of 255: the chain is full) | **A: let the core span more than one frame.** *"A couple samples of latency is negligible."* A block that can't finish in its frame continues in the next (the stream contract already allows it); latency is counted in frames + cycles. Proposal to come (§4 step 5) |
| HD3 | Where the DSP blocks live | **The HDL library is its own repo** (exists; location to be given). The core, the stream/coefficient contracts and the platform stay here |
| HD4 | Coefficient changes | **Click-free** (smoothed) — part of the block template |
| HD5 | A template block | yes: every library block starts from it (stream in/out, coefficient read port, register window binding, TB harness, mutation harness) |
| HD6 | Multi-input blocks (sidechains) | their extra inputs are **picked like channel sources** (the same UX as Phase 15's `source`) |
| HD7 | Spatial processor / binauralizer | **its own section of the mixer, not a plugin** (later) |

## 2. What the user has already tested on the board (p15a, daily studio use since 2026-10-08)

| Test | Result |
|---|---|
| Sine loopback + cancellation, ~1.5 h (not sample-exact) | no visible deviations |
| AVB + USB running together, ~5 h | no issues |
| Boot and recovery: many reboots and power cuts over a week as the studio router | fine; **occasionally needs a reboot before the network (AVB) connects** — "may be my impatience": to be timed (§3, T6) |
| M2 analog loopback through many layers | no audible glitches |
| Meter calibration | calibrated |

## 3. Tests to run

| # | Test | Proves | Status |
|---|---|---|---|
| T1 | **Bit-exact loopback null test** (`tools/loopback_null_test.py`, on the Mac): a deterministic pseudo-random 24-bit sequence out, back in, every sample checked; USB → USB, AVB → AVB, USB → AVB | bit transparency at unity, exact latency (same-device paths), zero slips across clock domains over hours | tool to write |
| T2 | **24 h soak**, all three front doors, with T1 running | no FIFO under/overruns, bridge corrections, gPTP or servo excursions over a day | after the tools |
| T3 | **Control changes under load**: `tools/osc_stress.py` changes levels, patches, counts and recalls snapshots everywhere except a protected path, while T1 checks that path | coefficient banks swap atomically in silicon; control never disturbs audio | tool to write |
| T4 | **Health summary** (`mixer_hw.py health` + service restart counts): one paste at the start and end of T2 | makes T2/T3 cheap to read | tool to write |
| T5 | F1–F9 checks on the board (`osc_mixer_test.py` from the Mac) | the controller contract on the real board | open |
| T6 | Time from power-on to the AVB stream connected, several boots | whether the "occasional reboot" is a real fault | open |
| T7 | M2 cable loopback through the null-test tool's analog mode (latency, resampler continuity) | the host front door's rate stage over hours | optional (user did by ear) |

No AVB switch on the bench: the multi-hop soak stays open.

## 4. Steps

1. Merge + tag (HD1). **Done.**
2. Tools: T1 null test (+ unit tests), T4 health summary, T3 stress tool (+ a test against the simulator). **Done (§4.1).**
3. Image with the health summary; the user runs T1 short, then starts T2 with T1 running; T3 during it.
4. T5, T6.
5. The multi-frame core proposal (HD2) and the block template (HD4–HD6), for the library.

### 4.1 Step 2: the tools (2026-10-10)

- **`tools/loopback_null_test.py`** (T1, runs on the Mac; standard library + `sounddevice`, no numpy): a deterministic xorshift sequence of 2¹⁷ 24-bit samples (2.73 s, ±−20 dBFS, never 0), each output channel c carrying it c × 16384 samples ahead; every received sample checked; **error** (one wrong sample, the sequence continues), **slip** (±n samples dropped/repeated), **lost** (no lock: silence, noise, a reroute), each with its time; a duplex stream (one device both ways) also reports the source channel and the round-trip latency in samples; the Mac's own over/underflows are counted apart. 11 unit tests (`test_loopback_null_test.py`: clean runs from silence in odd block sizes, across the period, a dropped sample = slip −1, three repeated = +3, a corrupted LSB = error, a dropout = lost + relock at the same place, decisions across block edges, noise never locks, source and latency, the output tape).
- **`tools/osc_stress.py`** (T3, any machine): batches of sets + a ping per batch (the round trip = the mixer's responsiveness), a snapshot `apply` of 40 random changes every 7 s, a channel-count change every 13 s (then the new config, as an app would), a save + load every 29 s; never touches the protected path or anything feeding it (buses into a protected output, inputs into a protected bus, group partners), **nor, by default, any output on an Analog port (the speakers) and what feeds it**, never assigns an Analog port or a protected output's port, never hides a protected channel; saves "Before stress" first and restores the counts and that snapshot at the end; checks the protected parameters against their starting values from a fresh config at every report. Tests (`test_osc_stress.py`): the protection closure on a hand-made config; a 6 s run against the simulator at 2000 sets/s with recalls, count changes and save/loads: nothing protected changed, nothing refused, the mix exactly restored; the check sees a protected change.
- **`fpgamixer-health`** (T4, on the board, `sudo`; installed by `fpgamixer-osc` from `tools/fpgamixer_health.sh`): uptime, load, memory; every fpgamixer service's state and restart count; ptp4l's last offset and the max over the last 60, faults since boot; each bridge's latest status line (cumulative xruns and coarse fixes); then **`mixer_hw.py health`**: the three links' counters (underruns, starved, overruns, TID errors, fill range, running), mclk vs gPTP over the last second, the steering, patched channel counts. Test: `test_mixer_hw.Health` (fake windows).

- **Mutants** (baseline clean first): **17/17** killed in the end. The first run killed 14; the three survivors each exposed a gap, now closed: *zeros in the sequence* (a zero is a one-in-1.7-million event at −20 dBFS: tested at 1 LSB amplitude instead), *Analog ports assigned* (invisible to the run test: a direct test of 4000 draws, both ways), *counts may hide a protected channel* (the tool didn't count that as a protected change: it does now, `hidden_protected`, plus a test of 20 count changes).

- **Linux** (VM, synced tree `63475b3`): 263 tests OK; `sh -n fpgamixer_health.sh` OK.
- **Image `p15b-health-20261010`** (layer `63475b3`, bitstream `p15a` unchanged, no `gen-machine-conf`): all tasks succeeded, 4 min 17 s, the usual 23 warnings. Checked: bitstream MD5 `3feb511b…`; rootfs `VERSION` `63475b3`, `/usr/bin/fpgamixer-health`, `/usr/bin/awk`, `mixer_hw.py` has `health_lines`. **`build/sd/p15b-health-20261010.wic.xz`** (MD5 `b9a2d41d…`, same on both ends).

## 6. How to run the tests

**On the Mac, once:** `pip3 install sounddevice`; copy `tools/loopback_null_test.py`, `tools/osc_stress.py`, `tools/osc_codec.py` into one folder. In Audio MIDI Setup: the FPGAmixer USB device and the AVB device at **48 kHz**, their output volume at **full**.

**A null-test path** (in the app; pick channels and ports your studio isn't using, e.g. input 20 → bus 20 → output 20):
1. input 20 `source` = the port the Mac plays into (e.g. USB 8);
2. input 20 level 0 dB; `inputMatrix` 20 → bus 20 at 0 dB and **nothing else into bus 20**; bus 20 level 0 dB;
3. `busMatrix` bus 20 → output 20 at 0 dB and **nothing else into output 20**; output 20 level 0 dB;
4. output 20 `destination` = the port the Mac records from (e.g. USB 8).

**T1, short first (5 min), then long:**
- USB → USB: `python3 loopback_null_test.py --device <USB name> --out 8 --in 8 --minutes 5`
- AVB → AVB: the same with the AVB device and AVB ports.
- USB → AVB: patch the source to a USB port and the destination to an AVB port; `--out-device <USB name> --in-device <AVB name>`.
(`--list` shows the device names; a part of the name is enough.) Healthy: `locked`, the `samples ok` count growing, errors/slips/losses 0, the same latency at every report, `PASS` at the end.

**T2 (24 h):** `sudo fpgamixer-health` on the board, start T1 USB → AVB with `--minutes 1440 --log t1.log`, leave the studio running normally, `sudo fpgamixer-health` again at the end; paste both and the end of the log.

**T3 (during T2 or on its own):** `python3 osc_stress.py --host amd-edf.local --in 20 --bus 20 --out 20 --minutes 30 --log stress.log` while T1 runs on that path. Healthy: `protected: OK` every report, `refused 0`, `PASS`; T1 still clean.

## 7. Log

- **2026-10-10:** Phases 14–15 merged to `main`, tag `phase15-baseline`; branch `hardening`. Decisions HD1–HD7. Roadmap updated.
