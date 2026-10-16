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

**What T1 is.** No DAW and no phase inversion: the script on the Mac is the generator, the recorder and the comparison. It plays a known pseudo-random signal out of one channel of a Mac audio device, the board routes that channel straight back (the channel-20 path), the script records the returning channel and compares every sample with what it sent. The comparison is digital and exact, so it is a null test without inverting anything; it also finds single wrong, dropped or repeated samples, which a waveform view can't show.

**Where things run.** The scripts run **on the Mac, in Terminal** (not on the board, not in Ableton). The board only routes. Ableton may stay open, but must not use the test channels.

**The Mac's devices.** The board's USB device is **"StudioRunner USB"** (`fpgamixer-usb-gadget.sh`); its channel k is the board's port **USB k**, both ways. The AVB device is whatever the Mac's AVB setup names it; its channel k is the board's port **AVB k**.

**Once, on the Mac:**
1. Put `loopback_null_test.py`, `osc_stress.py` and `osc_codec.py` in one folder (e.g. Downloads).
2. Terminal: `cd ~/Downloads` (that folder), then `pip3 install sounddevice`.
3. Audio MIDI Setup: StudioRunner USB and the AVB device at **48 kHz**, their output volume at **full** (0 dB).
4. `python3 loopback_null_test.py --list`: prints the Mac's audio devices with their numbers and names; note the names of StudioRunner USB and the AVB device (a unique part of a name is enough).

**The channel-20 path** (in the app; ports the studio isn't using):
1. input 20 `source` = **USB 8** (the Mac's output 8 on StudioRunner USB comes in here);
2. input 20 level 0 dB; `inputMatrix` 20 → bus 20 at 0 dB and **nothing else into bus 20**; bus 20 level 0 dB;
3. `busMatrix` bus 20 → output 20 at 0 dB and **nothing else into output 20**; output 20 level 0 dB;
4. output 20 `destination` = **USB 8** (goes back to the Mac's input 8 on StudioRunner USB).

**T1, 5 minutes per path** (the numbers after `--out`/`--in` are the Mac device's channel numbers = the USB / AVB port numbers used in the patch):
- USB → USB (path as above): `python3 loopback_null_test.py --device "StudioRunner" --out 8 --in 8 --minutes 5`
- AVB → AVB (source AVB 8, destination AVB 8): `python3 loopback_null_test.py --device "<AVB name>" --out 8 --in 8 --minutes 5`
- USB → AVB (source USB 8, destination AVB 8): `python3 loopback_null_test.py --out-device "StudioRunner" --in-device "<AVB name>" --out 8 --in 8 --minutes 5`
If `--list` shows StudioRunner USB as two devices (one input, one output), use the `--out-device` / `--in-device` form for USB → USB too (then without latency).
Healthy: `locked`, the `samples ok` count growing, `errors 0, slips 0, losses 0`, the same latency every report (one-device runs), `PASS` at the end.

**T2 (24 h):** `sudo fpgamixer-health` on the board, start T1 USB → AVB with `--minutes 1440 --log t1.log`, leave the studio running normally, `sudo fpgamixer-health` again at the end; paste both and the end of the log.

**T3 (during T2 or on its own):** `python3 osc_stress.py --host amd-edf.local --in 20 --bus 20 --out 20 --minutes 30 --log stress.log` while T1 runs on that path. Healthy: `protected: OK` every report, `refused 0`, `PASS`; T1 still clean.

## 7. Log

- **2026-10-10:** Phases 14–15 merged to `main`, tag `phase15-baseline`; branch `hardening`. Decisions HD1–HD7. Roadmap updated.
- **2026-10-15:** `p15b` flashed; first `fpgamixer-health` (102 s after boot) read and judged:
  - services all up, 0 restarts; mediaclock LOCKED, mclk +0.000 ppm vs gPTP, steering locked at −29.19 ppm (the crystal's offset), 0 dropped steps;
  - **health script fixed** (ships with the next image): ptp4l logs one-second summaries (`rms … max …`), not per-sync offsets, so "no offsets logged" was the script; the "4 faults" were the normal start-up transitions through UNCALIBRATED. Now: last rms, worst max, faults/timeouts, slave/master transitions;
  - link counters since power-up include the boot (overruns 2452 on every link = the PL running before Linux reads; large `starved` = frames before each stream started): only differences between two readouts count. `fill 0..0` is normal: the formatter delivers each frame just in time; the queue lives in ALSA's buffer on the PS side;
  - **finding H-F1:** the USB bridge's "coarse fixes" count every period dropped while the Mac isn't recording from the board (20,002 in ~100 s here: `B pl->mac: 0 frames/s`, link #1 NOT RUNNING). Harmless (a documented start-up case), but it buries real corrections. To fix: count idle drops apart from real coarse fixes;
  - the board's clock read 1970 (no time source at that point of the boot): log times on the board are uptime-relative only;
  - the patch was blank: reflashing replaces the card, state and on-board snapshots included (as every reflash).
- **2026-10-15:** §6 rewritten after the user's feedback that the steps were vague: where each thing runs, the Mac device names ("StudioRunner USB"), what the null test does without phase inversion.
- **2026-10-15: first T1 run (USB → USB, 5 min): FAIL, and the tool was at fault, not the board.** 1.70 M samples matched, 25,045 errors, 447,507 lock losses, 1 slip, **0 Mac-side over/underflows**, latency 10,220 samples (213 ms). A path that loses lock 1,500 times a second while Ableton nulls stay clean points at the comparison. Cause (most likely): PortAudio converts CoreAudio's floats to int32 **with dither by default**, moving the low bits of the 32-bit word (1/256 of a 24-bit step, ~−186 dBFS: invisible in a DAW null); the tool compared all 32 bits. The 213 ms is mostly PortAudio's default "high" latency buffers. **Fixed:** dither off, comparison at 24 bits with rounding (`to24`: up to ±127 32-bit LSBs is the same sample, one 24-bit LSB is still an error), `--latency low` by default. New test `test_noise_below_24_bits_is_not_an_error`; 2 new mutants killed (exact compare, truncation). The user's point stands: the board's week of daily use and their nulls are evidence; a test tool must be validated before its verdicts count.
- **2026-10-15: T1 USB → USB, 5 min: PASS** (fixed tool): **14,395,171 samples, all bit-exact at 24 bits**, errors 0, slips 0, losses 0, 0 Mac-side over/underflows; the received channel identified as out 8; **round-trip latency 2,781 samples (57.9 ms)**, the Mac's low-latency buffers included. The tool and the user's nulls now agree.
  - **Finding H-F2:** 58 ms round trip Mac → board → Mac over USB is long for monitoring while tracking. To break down (the Mac's buffers, the USB bridge's queue targets each way, the link FIFOs, the core's frame) and see what can shrink; not a fault.
- Next: T1 AVB → AVB and USB → AVB (5 min each), then T2.
- **2026-10-15: T1 AVB → AVB, 5 min: never locked** (0 samples, 0 Mac-side glitches); the tool said nothing about why. And my instructions named the AVB device "FPGAmixer": the entity is **"StudioRunner AVB"** since 2026-09-30 (`avb.conf`), so which device opened is unknown (the tool printed the argument, not the device). The AVB stream format is `S24_3BE` (24-bit), so a bit-exact match is possible. **Tool made self-diagnosing:** prints the devices actually opened; records every input channel of the input device; while a test channel isn't locked, each report shows per input channel the peak (vs the −20 dBFS sent), the share of exact zeros and whether the sequence is there intact (then: a channel mix-up, named), inverted, or cut to 16 bits; event printing capped at 20 per report. **New: `MainLoop` tests run `main()` end to end over a fake sound library** (a delayed software loopback: PASS with latency 700 and the source; an inverted loop: FAIL naming "inverted"; an unknown device: exit 2), so the audio side of the tool is tested too, not only the checker.
