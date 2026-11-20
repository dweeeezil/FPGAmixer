# Proposal: LTC timecode display (2026-11-18)

**State:** plan approved (§8, the user, 2026-11-18). **Step A done (§9); next: step B.** Nothing is on the board or wired into the top yet. The controller's spec is `timecode_controller_spec_2026-11-18.md`.

**Goal:** the user picks an input port in the app, and the app shows the timecode arriving on that port. It is meant for an upcoming demo, so the plan favours low risk over features.

**Decided (the user, 2026-11-18):** timecode is assigned to an **input port** (Analog 1–4, USB 1–8, AVB 1–8), not a mixer channel.

Why a port:
- The channel taps are post-fader, so a muted channel would stop the decode.
- A port needs no mixer channel, so the LTC signal never has to be patched anywhere near a mix.

**Baseline:** `eq2` (complete, untested, `eq_proposal_2026-11-17.md` §7.9). `p15e` stays the last formally tested image.

---

## 1. What gets built

```
io_in (20 ports, the core's input, read only)
   │
   ├──────────────► mixer_core (unchanged)
   │
   └─► port select ─► ltc_decoder ─► register window 0x8001_1000
                                          │ read 60 times a second
                                     mixer_timecode.py (server)
                                          │ UDP, like the meters
                                     StudioRunner: picker + readout
```

**Scope of version 1:**
- LTC at 23.976, 24, 25, 29.97 (drop and non-drop) and 30 fps.
- Forward play at about 0.85× to 1.2× speed. Reverse and fast shuttle show "no timecode".
- Display only. Nothing in the mixer follows the timecode.
- The mixer reports the last decoded frame. The app adds the user's frame offset (§4).

**Not touched:** `mixer_core`, the insert router, the pools, the links, the bridges, the patch, snapshots.

## 2. The FPGA side

### 2.1 `src/rtl/ltc_decoder.sv` (new, generic)

Takes one signed sample per audio frame on `mclk`. It knows nothing about ports, registers or the mixer.

| Stage | What it does |
|---|---|
| Slicer | Sign with hysteresis at ±2^15 (about −48 dBFS). Polarity doesn't matter, because LTC carries its data in the transitions. |
| Interval | Counts samples between transitions. 7–15 = half bit, 16–31 = full bit, anything else = lost: restart. |
| Bits | A full bit is 0. Two half bits are 1. A half bit without its partner = lost: restart. |
| Frame | An 80-bit shift register. When the last 16 bits equal the sync word (`0011 1111 1111 1101` in the order sent) **and exactly 80 good bits have arrived since the previous sync**, it latches the 64 data bits and the samples since the previous sync, and counts one frame. So the first frame after any restart is never reported, because its start may be missing. |
| Lock | Locked while a sync word arrived in the last 4,800 samples (100 ms). |

| Rate (fps) | Samples per frame at 48 kHz | Samples per bit |
|---|---|---|
| 23.976 | 2,002 | 25.0 |
| 24 | 2,000 | 25 |
| 25 | 1,920 | 24 |
| 29.97 | 1,601.6 | 20.0 |
| 30 | 1,600 | 20 |

**Estimated cost:** a few hundred LUTs and registers, no DSPs, no block RAM. The design is at 30,290 of 70,560 LUTs today.

### 2.2 `src/rtl/timecode_regs_axil.sv` (new, the binding)

Built from existing, proven parts, with no new clock-crossing design:
- `axil_reg_window`: the register window;
- `coef_bank_handoff` twice: SOURCE from `aclk` to `mclk`, the status words from `mclk` to `aclk`. Its scoped XDC already covers every instance.

The binding holds the port mux. It captures the selected port from `io_in` on the frame strobe, the same edge on which `pcm_patch2stream` captures it.

| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | `0x5443_5001` ("TC") |
| 0x004 | CONFIG | RO | [7:0] number of ports (20) |
| 0x00C | WRITES | RO | writes accepted |
| 0x100 | SOURCE | RW | 0 = off, p + 1 = port p (the patch's convention); reset 0 |
| 0x104 | TC_LOW | RO | LTC bits 31:0 |
| 0x108 | TC_HIGH | RO | LTC bits 63:32 |
| 0x10C | FRAMES | RO | frames decoded (wraps) |
| 0x110 | FRAME_SAMPLES | RO | samples between the last two sync words |
| 0x114 | FLAGS | RO | bit 0 signal present, bit 1 locked |
| 0x118 | SNAPSHOTS | RO | changes while the block runs |

### 2.3 The platform

- `scripts/create_project.tcl`: `ctrl_smc2` gains one master, `M_AXI_TIMECODE` at **0x8001_1000**, 4 KB (free today, between the gain pool and the EQ).
- `fpgamixer_top.sv`: the new port and one instance. Its only audio connection is a read of `io_in`.
- The SDT is derived by hand from `eq2`'s, the method of `eq_proposal` §7.5, because `sdtgen` was blocked by Device Guard.

## 3. The server

**`tools/mixer_timecode.py` (new):** no OSC parsing and no hardware access of its own, in the shape of `mixer_meters.py`.
- Unpacks the 64 bits into hours, minutes, seconds, frames and the drop-frame flag, and rejects impossible values.
- Finds the rate from the mean of the last 16 `FRAME_SAMPLES`, and reports "running" only once the rate is known (about half a second).
- `TimecodeHub`: subscriptions and its own thread, which sleeps while nobody subscribes. It polls at 60 Hz, twice the fastest frame rate, so a 30 fps source is seen frame by frame with no doubled or skipped frames.
- A synthetic source for tests and the simulator, never with `--hw`.

**`tools/mixer_hw.py`:** `TimecodeHW` and the window. A bitstream without the decoder raises `WindowAbsent`, and the feature simply doesn't appear.

**`tools/osc_mixer_server.py`:** the setting, the subscribe handler, and restoring the source at boot.

**Two rules that protect the rest of the mixer:**
1. **The timecode value is never a parameter.** A parameter would be saved to the SD card about four times a second, and SD writes have disturbed USB audio before (H-F8).
2. **The stream never uses the TCP broadcast path.** That path shares the lock with every fader move and snapshot.

### The protocol (additive)

| What | Form |
|---|---|
| Setting | `system/timecodeSource`: enum, 0 = Off, p + 1 = port p, labels from `IO_PORTS`, default 0. Saved, synced between controllers, and untouched by snapshot recall |
| Subscribe (TCP) | `/<name>/timecode/subscribe <port:int>`; 0 unsubscribes; 5 s lease, renewed every 2 s, as for meters |
| Stream (UDP) | `/<name>/timecode <seq:int> <state:int> <hours:int> <minutes:int> <seconds:int> <frames:int> <fps:float> <dropFrame:int>` |
| `state` | 0 = no source selected, 1 = no timecode (the last value is held), 2 = running |
| Config | `capabilities` gains `"timecode"` |

Sent once per new frame, and twice a second otherwise. The current app ignores the new message kind.

## 4. The app (the user builds it)

The contract is `timecode_controller_spec_2026-11-18.md`; the normative summary is the *Timecode* section of `FPGA Mixer OSC Standard.md`.

- **Readout:** in `ConnectionBar`, between the device name and the connection pill.
- **Picker:** the ports, from `system/timecodeSource`'s labels.
- **Frame offset (the user, 2026-11-18):** a menu option in the app, to counter latency. It is the app's own display preference: the mixer always reports the decoded frame, so this needs no firmware. The spec gives the arithmetic, drop-frame included.

## 5. The steps

Each step ends with a check-in. The feature can be dropped after any of them, and the demo then runs on `eq2`.

**A. The decoder, on the PC.**
- `src/sim/ltc_gen.py` writes LTC as test vectors and as WAV files for the bench.
- `tb_ltc_decoder` checks every frame decoded exactly, at each rate and against:
  - inverted polarity;
  - −40 dBFS and a clipped square;
  - 0.85× and 1.2× speed;
  - added noise;
  - dropouts and recovery;
  - noise and music, which must never produce a lock.
- Mutants, and the testbench run on the synthesized netlist. That second check is the one that caught the `eq1` fault.

**B. The window and the build.**
- The binding, the top and `tb_top_windows`, then the full regression.
- **The Vivado gate, all required:**
  - WNS and WHS not negative, 0 critical warnings, methodology PASS;
  - **DSPs still 42 and BRAM tiles still 33**;
  - the RAM report unchanged from `eq2`.

**C. The server,** with tests on the synthetic source and on fake hardware.

**D. The app (the user),** against the spec, `MockDevice` and then the simulator's synthetic source.

**E. The image and the bench** (§6).

## 6. The bench

1. **Flash a second SD card.** Keep the `eq2` card untouched: the user brings it and older images to the demo as the fallback.
2. `sudo python3 /usr/lib/fpgamixer/mixer_hw.py timecode` prints the window and the source.
3. Play the 30 fps test WAV from the Mac into a USB port. Pick that port in the app: the time runs and matches the file.
4. Repeat with the 25 fps and 29.97 drop-frame files.
5. Stop the file: the readout holds and dims. Play it again: it recovers.
6. **Recommended before the demo:** one 5-minute T1 USB → USB null test on the new image. It is the direct proof that the rebuild left the audio path bit-exact. The rest of the checks stay in the batch test (`eq_proposal` §7.9).

## 7. Risks

| Risk | Likelihood | What contains it |
|---|---|---|
| The rebuild changes something else (as Vivado did on `eq1`) | Low | The Vivado gate, the T1 run, the `eq2` card |
| The hand-derived device tree is wrong | Low | The image fails to build, or the server refuses the window; the audio is unaffected |
| The decoder misreads real-world LTC | Low to medium | The step A test set; a display fault only |
| The server thread fails | Low | Its own thread, errors caught; control and audio don't depend on it |
| An app fault in the demo | Low to medium | Build the app on the Mac well before the demo; the last app build stays as a fallback |

## 8. Decided (the user, 2026-11-18)

- **Q1, scope:** forward play only for now.
- **Q2, the readout's place:** the connection bar.
- **Q3, the app:** the user does all the app work, from the spec. The user also adds a frame offset menu option, to counter latency.
- **Q4, the demo:** in a few days. It is tight, and the user brings older firmware images to boot from in an emergency.

## 9. Step A results (2026-11-18)

**Built:**
- `src/rtl/ltc_decoder.sv`, the decoder;
- `src/sim/ltc_gen.py`, an independent LTC encoder: the testbench's vectors and the bench's WAV files;
- `src/sim/tb_ltc_decoder.sv`, target `ltc` in `xsim_regress.ps1` and `sim.mk`;
- `scripts/mutants/ltc_decoder.json` and `scripts/netsim_ltc.ps1`.

**Checked, all in simulation:**

| Check | Result |
|---|---|
| RTL against the vectors | **PASS:** 884 frames exact over 35 segments, about 2 million samples |
| The same testbench on Vivado's synthesized netlist | **PASS** |
| Mutants | **25 / 25 killed** |
| Resources (out of context) | **98 LUTs, 249 registers, 0 DSPs, 0 BRAM** |

**The segments cover:** all six rates; the hour and day rollovers; dropped and kept minutes; inverted polarity; −40 dBFS, full scale and clipped signals; slow edges; noise; arbitrary user bits; 0.85× and 1.2× speed at 30, 25 and 24 fps; a dropout, a splice, a one-sample glitch and a damaged bit. Music, noise and steady tones never produce a frame or a lock.

**Two things the work changed:**
- A frame is reported only after a previous sync word. Without that rule, whether a segment's first frame appeared depended on the signal's polarity.
- The first mutant run left one survivor: a damaged 1 could be read as a 0, and the tests had no such case. The decoder was right; the "damaged bit" segment now proves it.

**Not checked yet:** real LTC from real equipment. The vectors come from our own encoder, written to the standard. The bench (§6) is the first test against another generator, if the WAV is replaced by one from a DAW.
