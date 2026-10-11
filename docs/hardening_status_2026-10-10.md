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
2. Tools: T1 null test (+ unit tests), T4 health summary, T3 stress tool (+ a test against the simulator).
3. Image with the health summary; the user runs T1 short, then starts T2 with T1 running; T3 during it.
4. T5, T6.
5. The multi-frame core proposal (HD2) and the block template (HD4–HD6), for the library.

## 5. Log

- **2026-10-10:** Phases 14–15 merged to `main`, tag `phase15-baseline`; branch `hardening`. Decisions HD1–HD7. Roadmap updated.
