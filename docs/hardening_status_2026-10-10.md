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
| T1 | **Bit-exact loopback null test** (`tools/loopback_null_test.py`, on the Mac): a deterministic pseudo-random 24-bit sequence out, back in, every sample checked; USB → USB, AVB → AVB, USB → AVB | bit transparency at unity, exact latency (same-device paths), zero slips across clock domains over hours | **PASS** (USB → USB 5 min; USB → AVB and AVB → USB 6 h, on `p15a`: §7) |
| T2 | **24 h soak**, all three front doors, with T1 running | no FIFO under/overruns, bridge corrections, gPTP or servo excursions over a day | **PASS, 6 h** (user's verdict, §7) |
| T3 | **Control changes under load**: `tools/osc_stress.py` changes levels, patches, counts and recalls snapshots everywhere except a protected path, while T1 checks that path | coefficient banks swap atomically in silicon; control never disturbs audio | tool built and tested; **not run on the board yet** |
| T4 | **Health summary** (`mixer_hw.py health` + service restart counts): one paste at the start and end of T2 | makes T2/T3 cheap to read | built; ships only in a fixed image (`p15b` withdrawn, H-F6) |
| T5 | F1–F9 checks on the board (`osc_mixer_test.py` from the Mac) | the controller contract on the real board | open |
| T6 | Time from power-on to the AVB stream connected, several boots | whether the "occasional reboot" is a real fault | open; **a candidate cause found (§8.1): the first gPTP lock at boot steps the clock, maybe back**; fixed with H-F4 if so |
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

**The Mac's devices.** The board's USB device is **"Topology Control"** (corrected by the user 2026-10-17: the f_uac2 gadget's default control-interface string, which macOS shows as the name; the gadget script's "StudioRunner USB" product string isn't what macOS displays; the user used "Topology Control" in every run); its channel k is the board's port **USB k**, both ways. The AVB device is **"StudioRunner AVB:StudioRunner AVB"** (entity:stream); its channel k is the board's port **AVB k**.

**Once, on the Mac:**
1. Put `loopback_null_test.py`, `osc_stress.py` and `osc_codec.py` in one folder (e.g. Downloads).
2. Terminal: `cd ~/Downloads` (that folder), then `pip3 install sounddevice`.
3. Audio MIDI Setup: Topology Control (USB) and StudioRunner AVB at **48 kHz**, their output volume at **full** (0 dB).
4. `python3 loopback_null_test.py --list`: prints the Mac's audio devices with their numbers and names; check the names of the USB device (Topology Control) and the AVB device (a unique part of a name is enough).

**The channel-20 path** (in the app; ports the studio isn't using):
1. input 20 `source` = **USB 8** (the Mac's output 8 on Topology Control comes in here);
2. input 20 level 0 dB; `inputMatrix` 20 → bus 20 at 0 dB and **nothing else into bus 20**; bus 20 level 0 dB;
3. `busMatrix` bus 20 → output 20 at 0 dB and **nothing else into output 20**; output 20 level 0 dB;
4. output 20 `destination` = **USB 8** (goes back to the Mac's input 8 on Topology Control).

**T1, 5 minutes per path** (the numbers after `--out`/`--in` are the Mac device's channel numbers = the USB / AVB port numbers used in the patch):
- USB → USB (path as above): `python3 loopback_null_test.py --device "Topology Control" --out 8 --in 8 --minutes 5`
- AVB → AVB (source AVB 8, destination AVB 8): `python3 loopback_null_test.py --device "StudioRunner AVB:StudioRunner AVB" --out 8 --in 8 --minutes 5`
- USB → AVB (source USB 8, destination AVB 8): `python3 loopback_null_test.py --out-device "Topology Control" --in-device "StudioRunner AVB:StudioRunner AVB" --out 8 --in 8 --minutes 5`
If `--list` shows Topology Control as two devices (one input, one output), use the `--out-device` / `--in-device` form for USB → USB too (then without latency).
Healthy: `locked`, the `samples ok` count growing, `errors 0, slips 0, losses 0`, the same latency every report (one-device runs), `PASS` at the end.

**T2 (24 h):** `sudo fpgamixer-health` on the board, start T1 USB → AVB with `--minutes 1440 --log t1.log`, leave the studio running normally, `sudo fpgamixer-health` again at the end; paste both and the end of the log.
On **`p15a`** (no `fpgamixer-health`), the snapshot is, on the board (appends to `/home/amd-edf/soak-health.txt`):
`sudo sh -c '{ echo ===; date -u; cut -d" " -f1 /proc/uptime; for u in osc ptp4l phc2sys mediaclock usb-bridge usbhost-bridge avb-entity avb-bridge; do echo "$u $(systemctl show fpgamixer-$u -p ActiveState -p NRestarts | tr "\n" " ")"; done; for u in usb-bridge usbhost-bridge avb-bridge; do journalctl -u fpgamixer-$u -n 40 --no-pager -o cat | grep xruns | tail -2; done; journalctl -u fpgamixer-ptp4l -n 2 --no-pager -o cat; for c in link link2 link3 mclk steer; do python3 /usr/lib/fpgamixer/mixer_hw.py $c; done; } 2>&1 | tee -a /home/amd-edf/soak-health.txt'`
On the Mac, `caffeinate -i` in front of the null test keeps the Mac awake for the 24 h.

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
- **2026-10-15: T1 AVB → AVB, second run** (device `StudioRunner AVB:StudioRunner AVB`: the Mac names AVB devices entity:stream; my instructions had the name wrong twice): **the Mac's 8 AVB inputs are 100% digital zeros**, 0 Mac-side glitches, while the app's meters show the test signal arriving at the board (input 20, from AVB 8) and leaving it (output 20, to AVB 8). So at this moment **board → Mac over AVB delivers silence; Mac → board works.** Candidate: the Mac's listener not (re)connected to the board's talker after today's reflash/reboot, i.e. T6 ("occasionally needs a reboot before the network connects"). To confirm independently of the tool (a DAW on the AVB inputs) and on the board (the AVB bridge's core → net rate, the entity's ACMP log). `fpgamixer-health` now prints each bridge's latest line **per direction** (it showed one line only).
- **2026-10-15: board → Mac AVB silent: what the board says.** The Mac is subscribed (`talker connected to listener … (1 total)`), but **`B core->net: 0 frames/s`** with coarse fixes climbing ~5,000 per log line: the AAF talker never takes a period (every write "no room"), the bridge drops them (H-F1's counting hides the stall). `A net->core` runs at 48,000 frames/s but has **352,432 capture xruns** this boot. Timeline (ptp4l, phc2sys): **8193 s Ethernet link down** (~6 s; the board becomes grandmaster), 8206 s the Mac is master again, **48 min UNCALIBRATED** (normally seconds), 11073 s SLAVE, 11075 s **CLOCK_REALTIME stepped by 1,759 s**. Nothing AVB-related differs between `p15a` and `p15b` (`git diff 230b8c0 63475b3`: only `mixer_hw.py health` and the recipe line installing `fpgamixer-health`; bitstream identical): the trigger is the link drop, which p15a's sessions probably never hit. **`systemctl restart fpgamixer-avb-bridge` did not bring the stream back**, so not (only) the bridge: suspects the MSRP talker declaration not re-sent after link up (the entity log shows its MSRP lines once, at boot), and the clock (presentation times off → the Mac drops PDUs). Findings so far: **H-F3** a link drop leaves gPTP unlocked for 48 min; **H-F4** the AVB talker doesn't recover from a link drop / clock step; **H-F5** the stall is invisible (H-F1). `journalctl -u fpgamixer-avb-bridge -b | grep` doesn't finish on the board (the boot's log is too large): only `-n` reads from now on.
- **2026-10-15: board → Mac AVB still silent after a bridge restart, an entity restart, a Mac-side reconnect and a clean board reboot.** Saved this boot's logs on the board before the reboot (`/home/amd-edf/avbfail-*.log`: ptp4l, phc2sys, entity, avb-net, mediaclock, the bridge's last 5000 lines, the kernel). Since the bridge restart: `B core->net` 48,000 frames/s, 0 coarse fixes; 8,000 packets/s leave `end0.2` and the wire (`end0` TX 1.99 M packets, 0 errors), CBS and mqprio drop nothing; the runtime stream config (the Mac's choices): **S32_BE both ways, tx `mtt_us` 13** (the Mac's SET_STREAM_INFO; presentation = launch + 1000 µs uncertainty + 13 µs); the Mac's AVB inputs: zeros on all 8 channels, also in Ableton. ptp4l between 8206 and 11073 s: **no summaries at all** (no Sync from the Mac for 48 min, while it kept announcing), then a first offset of **1,759 s**: the Mac's gPTP time base restarted at the link drop; phc2sys let go of the PHC at 8206 s as designed (the "two servos" idea was wrong). **The user: the board → Mac direction worked on `p15a` and is broken on `p15b`.** Not yet decided: the images' AVB code is the same by the diff, but the images themselves haven't been compared (the VM's package manifests, kernel, DTB: VM off). Next: a Mac restart (the one party not reset since the link drop), then `p15a` reflashed for a direct A/B; the manifest comparison when the VM is up.
- **2026-10-16: A/B: `p15a` reflashed → board → Mac AVB works** (the user). With `p15b` it failed after a fresh flash and reboots, so **the images differ beyond the source diff** (`mixer_hw.py health` + the recipe line). **Finding H-F6:** what in the `p15b` image breaks board → Mac AVB. To compare on the VM, without touching the board: the two images' package manifests, the kernel, the DTB, the boot files, `/etc` and `/usr/lib/fpgamixer`. Until it's found, **`p15b` is withdrawn** (don't flash it) and `p15a` is the baseline. The 24 h soak (T2) runs on `p15a`: no `fpgamixer-health` there, so the start/end snapshot is one command over the tools `p15a` has (§6).
- **2026-10-16/17: T1/T2 on `p15a`, both directions at once** (the user ran 6 h, not 24: the Mac can't be tied up for a day). Start snapshot (318 s after boot): every service up, 0 restarts; ptp4l rms 10–12 ns; mclk +0.000 ppm vs gPTP, steering −30.50 ppm, locked, 0 dropped steps; AVB 48,000 frames/s both ways; the M2 bridge settled (±35 ppm).
  - **USB → board → AVB (`in 8`, 360 min): 1,036,795,918 samples bit-exact, 0 errors, 0 losses, 2 slips**, 0 Mac-side over/underflows. The user saw both slips coincide with AirPods connecting to the Mac (macOS reconfiguring its audio); not reproduced on purpose.
  - **AVB → board → USB (`in 7`, 1,059 min): 1,388,351,262 samples bit-exact (482 min), 0 errors, 7 slips, 6 losses**; the slips again with the AirPods, and the long unlocked time when the user disconnected the Mac and slept without stopping the test (the user is sure of it).
  - **Verdict (the user's, 2026-10-17): passed, "cautiously overriding the FAILs"**: 2.4 billion samples with no corrupted sample in either direction, the slips explained by the Mac (AirPods, sleep), weeks of daily use as the studio router. Recorded as such; a deliberate AirPods repro would make the explanation evidence, and stays optional.
  - The user: **a better clocking situation eventually** ("we're still not at a perfect 12.288 MHz"). Today mclk is steered onto gPTP (+0.000 ppm against the grandmaster, the Mac) from a fractional MMCM on the 25 MHz reference (~−30 ppm of correction); a review of the options is on the next list.
- **2026-10-17 (user's corrections):** **H-F6 dropped** ("not too concerned with it at the moment"); kept from it: a short T1 on both AVB directions before any new image replaces `p15a`, and `p15b` stays withdrawn. **The Mac's USB device is "Topology Control"**, not "StudioRunner USB" (my instructions had it wrong; the user substituted it in every run, so all the USB results stand, the 58 ms round trip included). Optional: give the gadget's control interface a proper name in `fpgamixer-usb-gadget.sh`.
- **2026-10-17: session ends.** Next session's prompt: `docs/prompt_after_hardening_2026-10-17.md`.
- **2026-10-17 (new session): H-F4 root cause found in the AAF plugin's source and fixed in the bridge core (§8.1).** The plugin's media clock is an absolute `timerfd` on `CLOCK_REALTIME`; stepped **back**, it stays silent for as long as the step, with no error: exactly the 2026-10-15 symptom (`B core->net: 0 frames/s`, every write "no room", no xrun). The bridge now restarts the AAF PCMs on every clock step (a cancel-on-set `timerfd`), and has a stall watchdog on the talker. The same step happens at **every boot** (the first gPTP lock), a candidate for T6. Unit test + 10/10 mutants on the VM (as root, real clock steps); the three bridges cross-compile clean. **Not on the board yet**: no image built.

## 8. Fixes

### 8.1 H-F4 (and maybe T6): the AAF PCMs after a clock step (2026-10-17)

**The mechanism, from the source** (`alsa-plugins-1.2.7.1/aaf/pcm_aaf.c`, the tarball in the VM's `downloads/`):
- the media clock is `timerfd_create(CLOCK_REALTIME)`, armed by `aaf_mclk_start` with `TFD_TIMER_ABSTIME` at "now + one period" (talker) or at the first PDU's presentation time + one period (listener), repeating every period;
- the talker sends a period, and the listener presents one, only on a timer tick (`aaf_timer_timeout` → `aaf_tx_frames` / `aaf_present_frames`);
- **`CLOCK_REALTIME` stepped back by d** (phc2sys following a grandmaster whose time jumped back): the absolute timer next fires d later. The **talker** sends nothing and reports nothing: its buffer stays full, every bridge write is "no room" (counted as a coarse fix, H-F5), `0 frames/s`. The **listener**'s pointer freezes and every PDU is dropped as "presentation time in the past" (its clock reads the old time), so it stalls silently too;
- **stepped forward**: d's worth of ticks at once, the talker underruns at once (`-EPIPE`), the bridge's xrun recovery restarts it: self-healing already;
- `snd_pcm_drop` + `prepare` + `start` (the bridge's restart) re-arms the timer from the new time (`aaf_stop` → `aaf_mclk_reset`, `aaf_start` → `aaf_mclk_start_playback`, or a socket flush and a fresh start on the next PDU for the listener). That is why `systemctl restart fpgamixer-avb-bridge` brought the sending back.

**It fits the 2026-10-15 timeline:** the clock stepped by 1,759 s at 11,075 s, and the talker stalled from then on. The **352,432 capture xruns** on `A net->core` match the 48 min before it (8,206 → 11,073 s), while the board's clock disagreed with the Mac's new time base: each listener start armed its timer seconds away, its 8 ms buffer overran (`-EPIPE`) ~125 times a second, and the bridge restarted it; 48 min × 125/s ≈ 360,000.

**At every boot too (a T6 candidate).** The board has no RTC. ptp4l's first lock steps the PHC to the Mac's gPTP time (seconds since the Mac booted, so the board reads 1970), and phc2sys then steps `CLOCK_REALTIME`. If the bridge's AAF PCMs were already started then, and the step was back (the board booted at a later time than the Mac's: e.g. systemd's build-time epoch), they stall until a bridge restart. The entity restarts the bridge whenever the Mac connects or sets the stream format (`avb_entityd.apply`), so whether a boot ends stalled depends on the order of those two events: "occasionally needs a reboot". **To confirm:** which way the boot step goes (on the board: `journalctl -b -o short-monotonic --no-pager -u fpgamixer-phc2sys -n 20`, the first `CLOCK_REALTIME` step's sign) and, with the new image, `clock steps 1` in the bridge's first lines after a boot.

**Nothing else on the board runs on that clock:** `avb_entityd.py` (ADP, ACMP, MSRP timers), `mediaclock.py` and the bridges' own timing all use `CLOCK_MONOTONIC`; ptp4l and the media clock work on the PHC.

**The fix (in `fpgamixer-bridge-core`, opt-in per direction, `bridge_watch.h`):**
- **Clock-step restart** (`bridge_dir.realtime`, `BRIDGE_RT_CAP` / `BRIDGE_RT_PLAY`): each direction polls a `timerfd` armed with `TFD_TIMER_CANCEL_ON_SET`, which every step of `CLOCK_REALTIME` wakes (`clock_settime`, `settimeofday`, `adjtimex ADJ_SETOFFSET`, what phc2sys and `date -s` use) and slewing never does. On a step it restarts the PCMs marked as running on that clock, before anything else is read or written; logged (`the system clock was stepped; restarting the playback`), counted.
- **Playback stall watchdog** (`bridge_dir.stall_s`): a playback that is started (or prepared) and consumes nothing (frames written since its start minus its delay doesn't grow) for `stall_s` is restarted; logged, counted. The backstop for anything else that freezes a sink silently. Only for sinks that always consume once running; **not** for the USB gadget's playback, which legitimately waits while the Mac isn't recording (H-F1).
- **The AVB bridge** uses both: A (`net->core`) restarts its capture (the listener) on a step; B (`core->net`) restarts its playback (the talker) on a step, and has the watchdog at 0.5 s (the talker sends every 2 ms). The USB and USB-host bridges are unchanged (both fields 0).
- The 10 s line of a direction that uses them ends in `, clock steps N, stalls N`. Nothing parses the end of that line (`fpgamixer-health` prints it whole).

**Files:** `fpgamixer-bridge-core/bridge_watch.h` (new: the detector and the watchdog, no ALSA), `test_bridge_watch.c` (new), `mutate_bridge_watch.py` (new), `bridge_core.{c,h}` (the two fields, a third poll slot, the frames-written count, the log suffix), `fpgamixer-avb/files/fpgamixer-avb-bridge.c` (the settings); the three recipes list `bridge_watch.h`.

**Checked (VM, gcc 13.3, kernel 6.8):**
- `test_bridge_watch` **PASS as root**: the watchdog (off never fires; steady consumption never; no consumption fires exactly at `stall_s`, not a period before; an idle PCM never, and its idle time doesn't count once active; a reset restarts the count; a count that goes back isn't progress); the detector on **real clock steps**: quiet without one, +1 ms and −1 ms each wake `poll()` and read as one step, quiet again after, and still sees the next step; a 100 µs `adjtime` slew is not a step. Without root the test says SKIPPED and fails, so it can't pass without the steps.
- **Mutants: 10/10 killed** (`sudo python3 mutate_bridge_watch.py`). The first run had one survivor, "not re-armed after a step": the kernel keeps a cancel-on-set timer watching after the `ECANCELED` read, so the re-arm was dead code. Removed (the test's second step proves the behaviour).
- `bitbake fpgamixer-avb fpgamixer-usb-bridge fpgamixer-usbhost -c compile -f`: all succeeded, no warnings (`-Wall -Wextra`); the AVB binary carries the new log strings.
- **Not tested off the board:** the bridge loop itself (no ALSA on the VM, and no paced test sink). The board test below covers it.

**Board test (the user runs it; ~2 min of disturbed AVB, not while the studio needs it).** It reproduces the incident's shape without pulling a cable: put the clock 60 s ahead with phc2sys stopped, then let phc2sys step it **back** onto gPTP time. On the Mac, Terminal, start the board → Mac AVB null test so the outage is timed: `python3 loopback_null_test.py --out-device "Topology Control" --in-device "StudioRunner AVB:StudioRunner AVB" --out 8 --in 8 --minutes 5` (the channel-20 path with source USB 8, destination AVB 8, §6). Then on the board (`ssh amd-edf@amd-edf.local` from the Mac):
1. `sudo systemctl stop fpgamixer-phc2sys`
2. `sudo date -s "@$(( $(date +%s) + 60 ))"`: the clock 60 s ahead. The null test most likely loses lock on both images: the board's presentation times are now 60 s off gPTP time, and the Mac should drop its packets (if it doesn't, note it: it doesn't change the test).
3. Wait ~10 s, then `sudo systemctl start fpgamixer-phc2sys`: phc2sys steps the clock back 60 s onto gPTP time.
4. **`p15a` (before the fix):** the null test stays lost **~60 s more**, then relocks by itself (the talker's timer catches up): H-F4 reproduced and timed. **New image:** relocks within ~1–2 s.
5. `journalctl -u fpgamixer-avb-bridge -n 12 --no-pager -o cat`: on `p15a`, `B core->net: 0 frames/s` lines with climbing coarse fixes; on the new image, `the system clock was stepped` lines for A and B, then `48000 frames/s` with `clock steps 2` (forward and back).
Then the cable test on the new image: pull the board's Ethernet cable for ~6 s; AVB should come back without manual steps once gPTP relocks; `journalctl -u fpgamixer-ptp4l -n 30 --no-pager -o short-monotonic` shows how long the relock took (H-F3: 48 min last time, the Mac sending no Sync).

**Still open from the incident:** H-F3 (no Sync from the Mac for 48 min after the link drop) is the Mac's side; the board now survives it (it waits, then steps and restarts), but why the Mac stopped is unexplained. The cable test shows whether it repeats. The saved evidence (`/home/amd-edf/avbfail-*.log`) was from the `p15b` card; the reflash to `p15a` most likely removed it.
