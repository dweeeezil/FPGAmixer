# Phase 11 status: 2026-09-30 — USB host mode (an interface on the board's Type-A)

**Branch:** `phase9/time-shared-core` (continued). **Starting image:** `p10e-names-20260930`.

**Status: decided (§6.1), nothing built yet. Resumed 2026-10-06 (§8: re-check against Phases 12–13, the Pmods, decision P1).** Next: bench step H-1 (what the MOTU M2 reports to Linux).

---

## 1. The goal, and the proposed reading of it

The user, 2026-09-30: *"My goal is to plug my USB interface into the board, and be able to access it from either my mac or PC through the board."*

**Proposed reading (to confirm, H0):** the interface's inputs and outputs become **channels of the mixer core**, reached through a **third front door** (USB host). The Mac or PC then reaches them through the doors that already exist, routed by the matrix:

- **Mac:** USB device mode ("StudioRunner USB", link #1) or AVB ("StudioRunner AVB", link #2);
- **PC:** USB device mode only (Windows has no AVB stack).

No USB pass-through: the board is a host on one port and a device on the other, and USB can't forward one to the other. What the Mac sees stays "StudioRunner USB" / "StudioRunner AVB", 8 × 8 each. The interface's channels reach those 8 × 8 through crosspoints.

## 2. Facts (checked 2026-09-30 unless marked)

| Fact | Source | Consequence |
|---|---|---|
| **USB1** (MIO 64–75) → USB2513B hub → 2 × Type-A + Mini PCIe; a separate controller from USB0 (Type-C, device mode). `&dwc3_1 { dr_mode = "host"; }` is in `system-user.dtsi` | Phase 8 §1, §9.2, §10 (deployed DTB checked then) | Host and device mode at the same time, no role switching |
| **`CONFIG_SND_USB_AUDIO=y`, `SND_USB=y`, `USB_XHCI_HCD=y`, `USB_DWC3_DUAL_ROLE=y`** on the board kernel | the board's `.config` on the VM (`genesys_zu3eg-amd-linux/linux-xlnx/6.18.10…`, dated 2026-09-30), re-checked | The driver is there; no kernel change. (The first SSH attempt timed out at an 8 s connect timeout; with 20 s it answered) |
| **`libsamplerate0` 0.2.2** and **`speexdsp` 1.2.1** recipes in poky | `sources/poky/meta/recipes-multimedia/` on the VM | The resampler needs no new layer |
| **The interface: MOTU M2**, **2 × 2 class compliant** (MOTU's driver only adds hidden loopback channels) | user, 2026-09-30 | Only **2 channels each way** are resampled; the other 6 link channels are written as zeros (the bridge always opens the link card at 8 ch, so `pcm_link` sees every TID). CPU cost is small. Its formats and rates: read at H-1 |
| **`seed_and_push` seeds identity on every index** (`0.0 if inp == out`) and walks only `n_in × n_out`; saved keys outside the core are left in the file, neither pushed nor deleted | `tools/osc_mixer_server.py` | H5 ("all off" for the new block) needs a small generic change (§6.1); the retire-don't-reuse rule for a removed block (§6.1) |
| **`alsaloop` can't drive the link card:** it forces 8 periods per buffer; the formatter allows 2–6 | Phase 8 §17 | The `alsaloop -S` resampling option from Phase 8 §5 / §9.2 is **out**. Resampling goes into our own bridge |
| `bridge_core` has one servo hook, `bridge_servo.update(queue_err, dt)`, and moves samples 1:1 (capture → repack → playback) | `recipes-apps/fpgamixer-bridge-core/bridge_core.h` | The servo seam exists; **a rate-changing stage does not**. It has to be added as a seam of its own (§3) |
| The formatter carries **2–8 channels per direction** per instance | Phase 8 §1 (PG330) | An interface with more than 8 in or 8 out needs either a cap at 8 or two links (H2) |
| Core size by lanes (`pcm_matrix_pkg`, same formulas): **20 → 2 lanes, D 227; 24 → 3, D 224; 28 → 4, D 233; 36 → 8, D 225** | computed from `core_latency()` | A third 8-ch link (28 × 28) costs **4 DSP48E2s** of 360, D ≤ 250 holds |
| Link #2 added a link with no new RTL: `pcm_link` + formatter + `pcm_link_stat_regs` + a DT card node with `fpgamixer,card-name` | Phase 9 §6.8–6.11 | Link #3 is the same recipe |

## 3. The shape

```
 interface ══USB══ Type-A ─ hub ─ USB1 (DWC3 host) ─ snd-usb-audio card (interface's clock)
                                                             │
 Linux ── USB-host front door, Linux half: fpgamixer-usbhost-bridge (bridge_core) ──────
            capture ─► repack ─► RATE STAGE (resampler) ─► FPGAmixerLink3 playback (mclk time)
            capture ◄─ repack ◄─ RATE STAGE (resampler) ◄─ FPGAmixerLink3 capture
                                  ▲ ratio set by a bridge_servo (PI on the link-side queue)
 ──────────────────────────────────────────────────────────────────────────────────────
 PL      formatter #3 ─► pcm_link u_link3 ─► core in/out 20–27 (28 × 28, 4 lanes)
```

- **Seams used:** front door (a third `pcm_link`, unchanged), control plane (a third `pcm_link_stat_regs` window, unchanged), platform (channel map, BD). **Front door, Linux half: one new seam**, a **rate stage** in `bridge_core`:
  - `struct bridge_rate { ctx; process(ctx, in, n_in, out, max_out) → n_out; set_ratio(ctx, r); describe; }`, optional per direction, between the repack and the playback write. NULL keeps today's 1:1 path, so the USB and AVB bridges are unchanged.
  - The **servo stays the servo**: its `update(queue_err, dt)` writes a ratio into the rate stage instead of a gadget pitch control. The same PI shape as the USB bridge, different actuator.
  - The rate stage knows no USB; the servo knows no resampler internals. The core never sees the interface's clock (§2 of `architecture_modules.md`).
- **Resampler:** **libsamplerate** (BSD-2-clause, in oe-core as `libsamplerate0`), built for a continuously varying ratio (`src_process` with `SRC_SINC_*`), float in/out. Alternative: speexdsp's resampler (integer ratios; each ratio change recomputes its filter). **CPU cost to measure on the board** before deciding the quality level: 2 directions × 8 ch × 48 kHz on the A53s, next to the USB and AVB bridges.
- **Interface discovery:** the interface can be plugged at any time. The bridge is configured with the interface's ALSA card id or USB product (`/etc/fpgamixer/usbhost.conf`), waits for the card to appear, and restarts cleanly when it's unplugged (like the AVB listener waiting for a stream). Starved link playback plays zeros (`pcm_link`, counted), so an unplugged interface is silence, not a fault.
- **Channel map:** `{link3, link2, link, jc, jb}`: interface in *k* → core in **20 + k**, core out **20 + k** → interface out *k*. Appended, so every saved crosspoint keeps its meaning.
- **Addresses (following P9.5):** formatter #3 at **0x8012_0000** (driver-owned range), link #3 status at **0x8000_5000**, reservations move to 0x8000_6000. BD: IRQ concat 4 → 6, DMA SmartConnect 4 → 6 slaves, control SmartConnect 7 → 9 masters, the same `link_mclk`. `psu_init` should stay identical (to check, as in P9.5).

### Rejected

- **Steer `mclk` to the interface** (no resampling): `mclk` is locked to gPTP for AVB, and one clock can't follow two masters.
- **ASRC in the PL:** heavy (filter banks, DSP), and Linux already has the samples.
- **Reuse link #1 or #2 for the interface:** couples two front doors; against modularity first.

## 4. What a user sees at the end

On the Mac/PC, "StudioRunner USB" still 8 × 8. Routing (OSC or `mixer_hw.py set`): interface in 1 → core out 4 = the Mac's input 1; Mac out 1 → core in 4 → core out 20 = the interface's output 1. Latency, estimated: interface ≈ its own buffer + one bridge period + the link queue + the resampler's delay (~1–2 ms) ≈ 8–12 ms one way; **to measure**.

## 5. Steps (proposed; each committed and verified on its own)

| Step | Content | Verified by |
|---|---|---|
| **H-1** | **No change:** plug the interface into a Type-A on `p10e`; read `/proc/asound/cards`, its `stream0` (channels, rates, formats, sync type) and `dmesg` | the bench; answers H1–H2 and the kernel-driver question |
| H.1 | `bridge_core`: the rate-stage seam + a libsamplerate stage; unit test (fixed ratio: tone frequency and frame counts; ratio steps: no discontinuity); **CPU measured on the board** with a standalone test binary | tests (VM); `top` on the board |
| H.2 | `fpgamixer-usbhost-bridge` + `usbhost.conf` + unit; first against **link #1** (no FPGA change) with the USB-device bridge stopped, to prove the servo and the resampler by ear before the FPGA work | bench: interface in → Pmods, Mac → interface out, both by ear; bridge log: queue steady, ratio settles |
| H.3 | Link #3 in the RTL and BD, core 28 × 28 (4 lanes); XSim; Vivado (timing, CDC, methodology gate); SDT (`psu_init` identical) | reports |
| H.4 | card node `FPGAmixerLink3`, `mixer_hw` `linkstat3`, restore test at 28 × 28 (784 levels), image; the bridge moved to link #3 | bench: three link cards; link #1 / #2 unchanged; the interface through link #3 by ear; restore across a power pull |
| H.5 | Soak: 60 min bridge log (queue steady, 0 coarse fixes after start-up) | the log |

H.2 before H.3 is on purpose: the software risk (resampler, servo, CPU, hot-plug) is proven on the existing bitstream before the FPGA build chain runs.

## 6. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| H0 | The reading in §1: the interface as a third front door, channels in the matrix, reached from the Mac/PC through the existing USB / AVB doors | **Yes** |
| H1 | **Which interface?** Model; channels in / out; the rates it runs; class-compliant (works on a Mac with no driver)? | H-1 reads it from Linux anyway |
| H2 | More than 8 channels one way: **cap at 8** (one link, 28 × 28), or **two links** (16 ch, 36 × 36, 8 lanes)? | Depends on H1. Cap at 8 unless the interface's 9th+ channels matter to you: the Mac only gets 8 × 8 per door anyway |
| H3 | Resampler: **libsamplerate** with a servo-set ratio, quality chosen after the CPU measurement | **Yes** |
| H4 | A rate-stage seam in `bridge_core` (optional per direction; USB/AVB bridges unchanged) | **Yes** |
| H5 | Seeding the new crosspoints: **all off**, or identity (interface in *k* → interface out *k*, i.e. its inputs on its own outputs at 0 dB)? | **All off.** Unlike the Mac/AVB loopbacks, identity here puts live inputs (mics) straight onto real speakers. This breaks the "one rule" of P8/P9.5, so it's your call |
| H6 | H.2 on link #1 first (the USB-device bridge stopped for the test), then the FPGA work | **Yes** |

### 6.1 Decisions (user, 2026-09-30)

The user's purpose: the interface holds their main headphone and mic preamps, so from the Mac's side the board becomes an AVB (or USB) → MOTU converter. It may be hidden once the board has its own analog IO, so it must **not get in the way** (CPU load in particular) and must be **easy to trim**.

| # | Decision |
|---|---|
| H0 | **Yes**, the reading in §1 |
| H1 | **MOTU M2**, 2 × 2 class compliant |
| H2 | **Cap at 8** (one link; moot at 2 × 2). Keep the blocks separate |
| H3 | **libsamplerate**, quality after the CPU measurement |
| H4 | **Yes**, and the feature must be **easy to trim** (below) |
| H5 | **All off** for the new crosspoints |
| H6 | **Yes** |

**Trimming (H4), how it's built so one switch per layer removes it:**

- **PL:** link #3 under its own define **`INCLUDE_LINK3`** and a `create_project.tcl` flag, as link #2. Without it the formatter, `pcm_link` and status window are gone and channels 20–27 read as silence; **the core stays 28 × 28** so saved indices keep their meaning (the P9.5 rule).
- **Linux:** its own recipe **`fpgamixer-usbhost`** (bridge, unit, `usbhost.conf`), one line in the image bbappend. The rate stage lives in **its own source file** (`bridge_rate_src.c`); only the host bridge links it and libsamplerate, so the USB and AVB bridges don't carry it.
- **DT:** the `FPGAmixerLink3` card node, removed with the define's build (the node references formatter #3).
- **Control plane:** the `linkstat3` window entry; `mixer_hw` already skips a window whose DT node is absent (the presence guard).

**Seeding (H5):** today's rule is identity everywhere, hard-coded. Proposed generic change: the server gets the **list of channel ranges seeded as identity** (a setting, default "all", so nothing changes until it's set); the board's setting is `0-19`, so link #3's block (20–27) seeds off. The server stays ignorant of what the channels are.

**Removing the block later (the user's question):** the state file stores only `inputMatrix/<in>_<out>/level`, generic indices, so levels recorded for 20–27 do no harm while the core doesn't have those channels: they are skipped. **One rule to keep:** if the block is removed, indices 20–27 are **retired, not reused**. Otherwise the next block appended at 20 (e.g. the board's own analog IO) would inherit the MOTU's saved levels. (Alternatively, delete those keys when a different block takes the indices.)

## 8. Resumed 2026-10-06 17:40 PDT: re-check against today's tree, and the Pmods

The user, 2026-10-06: *"I think it's time to ditch the pmods. … Let's finish implementing USB host mode so the board can talk to my headphones without the pmods."* The MOTU M2 becomes the board's analog I/O (headphones, mic preamps). Branch **`phase11-usb-host`**, from `phase13-metering` (`d3c1587` + the plans in `docs/plans/`).

### 8.1 What changed since §2–§5 (Phases 12 and 13), checked in the tree

| Then (§2–§5) | Now | Consequence |
|---|---|---|
| Core 28 × 28, one matrix, 4 lanes, D 233 | the core is a chain: 28 inputs → levels → 28 × 28 input matrix → 28 buses → levels → 28 × 28 bus matrix → levels → 28 outputs (`mixer_core_pkg`, `N_BUS = N`) | the chooser gives **10 + 10 lanes, D = 233** at 28/28/28 (`tb_mixer_core` covers this size already): 20 + 3 = **23 DSP48E2s** of 360. Every level stage and meter grows to 28 by parameter |
| Link #3 status window at **0x8000_5000** | 0x8000_5000–B000 are now the bus matrix, levels and meters | **link #3 status at 0x8000_C000** (the next free slot); formatter #3 at 0x8012_0000 unchanged |
| Control SmartConnect 7 → 9 masters | phase9 builds use **14** (7 + the 7 Phase 12/13 windows) | link #3 needs 2 more (formatter #3, its status window): **16, the SmartConnect maximum**. Fine for this phase; the next window after it needs a second SmartConnect (or a cascade). To record in `create_project.tcl` |
| Seeding: identity on every crosspoint; H5 "all off" for 20–27 | two matrices and three level stages | H5 applies to the **input matrix** only: input 20–27 → anything off. The bus matrix stays identity (bus k → output k carries nothing unless an input is routed to bus k), levels 0 dB. The "identity ranges" server setting (§6.1) becomes "input-matrix identity ranges" |
| Meters | none | the meters cover 20–27 by parameter (N = 28) |
| Restore test N = 20 | 860 registers | becomes 28 × 28: 784 + 784 input/bus crosspoints + 3 × 28 levels; the USB analysis unchanged |

### 8.2 The Pmods (decision P1)

What the Pmods hold up today, read from the tree:

- **The frame strobe** for the whole core, both links, the meters and the coefficient banks is **`jb_rx_valid`**, the Pmod JB I2S receiver's word strobe (`fpgamixer_top`). The I2S clock divider runs without a Pmod, so the strobe keeps working when the module is unplugged, but the RTL can't simply be deleted.
- **D_MAX = 250** comes from `i2s_port` sampling its pair on edge 254. Without the I2S transmitters the limit becomes the links' capture at the next strobe.
- **Core channels 0–3** are the Pmods' (in and out). Per §6.1's rule they would be **retired, not reused**.
- **Unplugged, their ADC data pins float:** `jb_ad_sdout` / `jc_ad_sdout` have no pull resistor in `fpgamixer_genesys_zu.xdc`, so channels 1–4 would read noise (visible on the meters, audible if routed).

| Option | What | For / against |
|---|---|---|
| **(a)** (recommended) | **Unplug the Pmods now; keep their RTL for this phase**, with a **PULLDOWN** on the two ADC data pins (in the H.3 bitstream) so channels 1–4 read silence. Remove the Pmod RTL properly with the channel-sources work, where physical ports stop defining channel numbers (`plan_channel_sources_2026-10-06.md`): a frame-strobe generator from the clock divider, D_MAX re-derived, ports 0–3 retired | no dead strips appear before patching exists; the build stays close to known-good; one XDC line |
| (b) | Remove the Pmod RTL in this phase | channels 0–3 become 4 permanently silent strips in the app until patching exists; the frame strobe and D_MAX change in the same build as link #3 (two risks in one bench) |

### 8.3 Steps, updated

H-1 (bench, no change, on the current image `p13-meters-20261006`) → H.1 (rate stage + libsamplerate, CPU on the board) → H.2 (the bridge on link #1, the USB-device bridge stopped; **by ear on the MOTU's headphones**, not the Pmods) → H.3 (link #3 at 0x8000_C000 / 0x8012_0000, core 28/28/28, the ADC pulldowns per P1; XSim, Vivado, SDT) → H.4 (card node, `mixer_hw` `linkstat3`, server seeding, restore test at 28, image; bench) → H.5 (60-min soak).

### 8.4 H-1: what the MOTU M2 reports (bench, 2026-10-06, image `p13-meters-20261006`, no change)

Plugged into a Type-A port with the board running; the user's terminal output:

| Item | Reading | Consequence |
|---|---|---|
| ALSA card | **3, id `M2`** ("MOTU M2 at usb-xhci-hcd.3.auto-1.1, high speed"), beside `FPGAmixerLink`, `FPGAmixerLink2`, `UAC2Gadget` | `snd-usb-audio` binds with no kernel change (H-1's question answered); the bridge opens it by id (`hw:M2`), not by number |
| USB | VID `07fd`, PID `000b`, bcdDevice 2.07, high speed, behind the board's USB2513B hub (`1-1.1`) | for `usbhost.conf` (the bridge can wait for this card id) |
| Playback | interface 1, **S32_LE, 24 valid bits, 2 ch (FL FR)**, rates 44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz, endpoint 0x02 **ASYNC**, 125 µs packets, **implicit feedback** from the capture endpoint 0x82 | the M2 is its own clock master; its capture stream paces its playback. Run it at **48 kHz**; the bridge **must resample** both ways (H3/H4 as decided) |
| Capture | interface 2, S32_LE, 24 bits, 2 ch, endpoint 0x82 ASYNC | the same clock as playback (one rate to estimate, not two) |
| Extra | `cdc_acm 1-1.1:1.5: ttyACM0` | the M2's control/serial port; ignored |

**H1 confirmed:** 2 × 2 (H2's cap at 8 is moot). S32_LE with 24 valid bits is left-justified (as the AAF devices' S32_BE), so one new converter pair (`s32le_to_s32` / `s32_to_s32le`) covers it.

### 8.5 H.1: the rate stage (VM): PASS

| File | What |
|---|---|
| `fpgamixer-bridge-core/bridge_core.{h,c}` | **`struct bridge_rate`** (start / process / set_ratio / describe / stop), optional per direction (`bridge_dir.resampler`; NULL keeps the 1:1 path, so the USB and AVB bridges are unchanged); **`play_channels`** (the first min(capture, playback) channels carried, extra playback channels zero: the link card always opens at 8); **S32_LE**. The data path became unpack → narrow → [rate] → widen → pack; a rate stage may return 0 frames (still filling), and its describe joins the 10 s log line |
| `fpgamixer-bridge-core/bridge_convert.h` | `s32le_to_s32` / `s32_to_s32le` (24 bits left-justified, little-endian; read as bytes, host-independent) |
| `fpgamixer-bridge-core/bridge_rate_src.{h,c}` (new) | the libsamplerate stage: int32 ↔ float / 2²³, `src_process` with `end_of_input = 0` (state kept across blocks), the ratio passed per block (libsamplerate moves to it smoothly), rounding and **clamping** to 24 bits on the way back. Its own file: only the host bridge links it and libsamplerate (H4) |
| `fpgamixer-bridge-core/test_bridge_rate.c` (new) | at 48 kHz in 256-frame blocks: frame counts follow the ratio; a 1 kHz tone's crossings per output frame scale by exactly 1/ratio at −1000, 0, +1000 ppm; a ratio step mid-stream: no sample jump above the tone's own slope; a full-scale square (Gibbs overshoot) against a float reference: every output equals the reference rounded and clamped; channel 1 stays silent. `--bench`: CPU per converter |
| `fpgamixer-bridge-core/test_bridge_convert.c` | S32_LE layout, sign, low byte dropped, round trips |

**Results (VM, gcc 13.3, libsamplerate 0.2.2 built from the Yocto download into `/tmp/lsr`; the VM's system packages untouched):** `test_bridge_convert` PASS; `test_bridge_rate` **PASS**: 480,000 in → 479,501 / 479,980 / 480,460 out at −1000 / 0 / +1000 ppm (the converter's ~20-frame delay), the tone's crossings within 2·10⁻⁴; the ratio step's largest sample step 548,370 vs the tone's slope 549,033; the square: 48,113 frames, **23,958 overshoots clamped, 0 mismatches**. Benchmark on the VM (x86, for scale only): sinc fastest 0.21 %, medium 0.40 %, best 1.18 % of a core per direction (2 ch). **The board's number comes from `fpgamixer-rate-test --bench` at the H.2 bench.**

**Mutation (VM, baseline first): 9 of 9 killed**: ratio ignored, no clamp at +/− full scale, the wrong scale back, the converter state reset every block, truncation instead of rounding, `set_ratio` ignored, an S32_LE logical shift, S32_LE bytes shifted.

### 8.6 H.2: the host bridge (code; bench next)

| File | What |
|---|---|
| `recipes-apps/fpgamixer-usbhost/files/fpgamixer-usbhost-bridge.c` (new) | two directions: **A** interface capture (S32_LE, 2 ch) → resample → link playback (S24_LE, 8 ch); **B** link capture (8 ch) → resample → interface playback (2 ch). Each direction's ratio from a **PI servo on its playback queue** (the USB bridge's constants: KP 0.5 ppm/frame, KI 0.05 ppm/frame·s, ±1000 ppm, anti-windup); a queue above target lowers the ratio (fewer frames), the same sign both ways. Period 192 (4 ms), 4 periods, target 2 periods. **Hot plug:** exits when the card id is absent or disappears (a 1 s check), systemd restarts it every 2 s |
| `…/files/fpgamixer-usbhost-bridge.service`, `…/files/usbhost.conf` (new) | `EnvironmentFile=/etc/fpgamixer/usbhost.conf` (card `M2`, link, channels 2, quality `fastest`); `Restart=always`, `RestartSec=2`; **`Conflicts=fpgamixer-usb-bridge.service`** while the link is #1 (H.2; removed in H.4) |
| `…/fpgamixer-usbhost_1.0.bb` (new) | builds the bridge and **`fpgamixer-rate-test`** (the unit test and `--bench`, on the board); `DEPENDS` alsa-lib, libsamplerate0; the unit installed **but not enabled** (H.2 starts it by hand) |
| `recipes-extended/images/edf-linux-disk-image.bbappend` | `fpgamixer-usbhost` in the image: the one line that trims the Linux half |

**Compile check (bitbake, the board's toolchain):** `fpgamixer-usbhost`, `fpgamixer-usb-bridge`, `fpgamixer-avb` all compile with `-Wall -Wextra`, **0 warnings** (the latter two prove the changed core still builds them unchanged).

**First H.2 bench (2026-10-07, image `p11h2-usbhost-20261006`, user's terminal):**

- `fpgamixer-rate-test` on the board: **PASS**, the same numbers as on the VM (the aarch64 build is bit-identical in behaviour).
- **CPU per direction, 2 ch, on one A53 core:** sinc fastest **8.2 %**, medium 16.9 %, best 56.3 %, linear 0.9 %. Both directions together at "fastest": ~16 % of one of four cores. Quality stays **fastest** (decision H3: chosen after the measurement; "best" would cost more than a whole core for both directions).
- The bridge started (it stopped the USB device bridge, by `Conflicts=`), both directions ~48,000 frames/s, **xruns 0/0, coarse fixes 0** over 80 s; the queues within ±62 frames of target. **The servos hadn't settled** in 80 s: A's ratio +71 → +93 → +24 ppm, B's −10 → −60 ppm (A and B should end up equal and opposite: the same two clocks). Tuning is for the soak (H.5).
- **By ear: only noise from the M2's headphones.** Suspect, from reading the code: the rate stage is the first consumer that uses a link card's **whole** int32 capture word; every earlier bridge only took its low three bytes, and `bridge_convert.h`'s "sign-extended" for the formatter's S24_LE capture was never measured. If the top byte isn't the sign, every negative sample reaching the resampler on direction B is a huge positive one. **Fix (`b43be18`):** `s24le_to_s32` sign-extends from bit 23 on unpack, whatever the top byte holds (tested; a mutant without it fails 3 checks); no change for the USB/AVB bridges, which never read the top byte. Image `p11h2b` built with it.
- **Measured (bench, 2026-10-07):** with the bridge stopped, `speaker-test` (S24_LE sine, 440 Hz) into `hw:FPGAmixerLink` and `arecord` from it (the core's identity routing returns it): the raw capture words through a zero crossing read `…00070414, 00011ece, 00fb3894` on the tone's channel. **The formatter's S2MM writes the top byte as 0x00, not as the sign.** So `bridge_convert.h`'s "sign-extended" was wrong for capture, harmless for every bridge until the resampler, and the fix above is the right one (not a workaround).
- **H.2 bench on `p11h2b` (2026-10-07): PASS.** User: *"Everything sounds great."* The M2's input → the board (resampled, link #1, the core's identity routing) → the M2's headphones, both directions clean by ear; the log's first lines show both directions running (~48,000 frames/s; the rest of each line was cut off by the terminal width, so the ratios weren't read).
- **P1 decided by the user (2026-10-07): (b), remove the Pmod RTL now**, "so long as it doesn't break anything. The pmods are terrible and I never want to go back to them."
- **Channel placement decided by the user (2026-10-07): the M2 takes the Pmods' slots, core channels 0–3** (app strips 1–4), instead of being appended at 20–27. The core stays **20 × 20 × 20** (no new DSPs, D = 249 unchanged, no dead strips). Link #3 is built like links #1/#2 (8 channels; the bridge and the card driver unchanged); its channels 0–3 are core 0–3 (the M2 uses 0–1), 4–7 are dropped in and zero out. The Pmods' indices are reused, not retired: the M2 *is* the board's analog I/O now, saved Pmod routes would carry over sensibly, and every flash resets the state anyway. Its input-matrix crosspoints start **all off** (H5).
- **Image `p11h2b-usbhost-20261007`** (layer `b43be18`, bitstream `p13` unchanged): 15,088 tasks, all succeeded, 4 min 3 s; `VERSION` `b43be18`. **`build/sd/p11h2b-usbhost-20261007.wic.xz`** (MD5 `b36663e1…`, same on both ends).

### 8.7 H.3: the Pmods out, link #3 in (RTL + BD, 2026-10-07)

- **Pmods removed (P1 = b).** `fpgamixer_top` has one port, `sysclk`. The XDC keeps only the sysclk pin, its clock and the MMCM's `CLOCK_DEDICATED_ROUTE`. `audio_clocking` no longer makes `sclk`/`lrck`; it makes **`frame`**, one `mclk` cycle in every 256 (the 48 kHz strobe the core and every link used to take from the Pmod receiver's `rx_valid`). The I2S RTL, the Phase 1/2 tops and their testbenches moved to `src/archive/` (README there); the runners lost the `rx`, `tx`, `txphase`, `loopback`, `phase3`, `dynamic` targets.
- **Channel map:** `core_in = {link2_rx, link_rx, link3_rx[3:0]}`, `{link2_tx, link_tx, host_tx} = core_out`, `link3_tx = {4 × 0, host_tx}`. The PL-reset input matrix is identity only from channel 4 (H5: 0–3 all off).
- **Block design** (`create_project.tcl`, `include_link3`, phase9): `link3_formatter` (the same `add_link_formatter` proc) on **M14 at 0x8012_0000**, its DMA on `link_dma_smc` S04/S05 (6 slaves), its IRQs on `link_irqs` In4/In5 (6 inputs); `M_AXI_LINK3STAT` (`pcm_link_stat_regs u_link3_stat`) on **M15 at 0x8000_C000**. Control SmartConnect: **16 masters, its limit**. Both follow the Phase 12/13 windows, so M07–M13 don't move. Define `INCLUDE_LINK3`. No PS8 setting changes.
- **XSim:** 15/15 PASS. `tb_top_windows` now drives the link wires (link #3's channels 4–7 carry a marker that must not reach the core), checks the strobe's 256-cycle spacing, the channel map both ways and input matrix 0←0 = 0 at reset. **Mutants 3/3 killed:** H5 seeding dropped; two strobes per frame; host channels reordered.
- **Vivado build `p11h3`** (2026-10-06 20:51–21:07 PDT, `fb77e8c`; Vivado 2026.1): **WNS +4.716 ns, WHS +0.010 ns, 0 failing**; methodology gate PASS (no Critical Warnings). Utilization vs `p13`: **DSPs 11 (unchanged)**, BRAM 6.5 tiles (unchanged), LUTs 16,709 → 21,627, registers 27,141 → 35,180 (the third formatter, its DMA SmartConnect ports, `u_link3`). CDC vs `p13`: every existing instance's count identical; the additions are only `u_link3` (1,028 CDC-1, the same async-FIFO pattern as `u_link`'s 1,220, fewer because its tx channels 4–7 are constant zero), `u_link3_stat` (249, like the other status windows) and 2 on `u_ps`. XSA `build/fpgamixer_p11h3.xsa`.
- **SDT** (`build/sdt`; `p13`'s kept as `build/sdt.p13`): `psu_init.*`, `zynqmp*.dtsi` **identical**; `pcw.dtsi` adds exactly `M_AXI_LINK3STAT@8000c000`; `pl.dtsi` adds `link3_formatter: audio_formatter@80120000` (IRQs 93/94) and the new `firmware-name`; `system-top.dts` the two address-map entries. `sdtgen` ran first time.
- `create_project.tcl`'s Vivado sim top was the archived `tb_phase3_datapath` (a CRITICAL WARNING at project creation); now `tb_mixer_core`. The `phase1`/`phase2` variants no longer build from this tree; `phase3` builds but has no audio.

### 8.8 H.4: the software side (written 2026-10-07; image after the H.3 build)

- **Device tree** (`system-user.dtsi`): card node `fpgamixer-link3` → `&link3_formatter`, `fpgamixer,card-name = "FPGAmixerLink3"`, `xlnx,tx`/`xlnx,rx` back to it (the same rules as links #1/#2).
- **`mixer_hw`:** window `linkstat3` at 0x8000_C000 (`LinkStatHW`); CLI `link3 [seconds]`.
- **Server seeding (H5):** `--identity-from N`: input-matrix crosspoints with no stored level are 0 dB on the diagonal from input N on, the rest off, as in the PL's reset. The board's `fpgamixer-osc.service` passes `--identity-from 4`. The bus matrix stays a full identity. Stored levels on 0–3 are restored as usual. Tests: two new (`InProcess`); **mutants 3/3 killed** (seeding ignores it; the no-bus-layer path drops it; the bus matrix gets it too).
- **USB host bridge:** `usbhost.conf` → `hw:FPGAmixerLink3`; the unit loses `Conflicts=` and is **enabled**; `StartLimitIntervalSec=0` so systemd never gives up on it. With no interface plugged in, the bridge now **waits in-process** (a 1 s check, logged once) instead of exiting into a restart every 2 s, which would have logged a line every 2 s for as long as the M2 is unplugged.
- **Restore test** (`crosspoint_restore_test.py`): `PMOD` → `HOST`; the second audible route moved from core output 2 (JC_L) to 1 (the M2's R), and the analog passthrough from 2→2 to 1→1. Still 400 levels, the same duplicate profile (only the intended −6 / −12 pairs).
- Docs: README (front doors, hardware, the diagram), the roadmap row and §5, `architecture_modules.md`, the `D_MAX` comments (the bound came from `i2s_port`; kept).
- **Image `p11h3-usbhost-20261007`** (2026-10-07 04:16 UTC; layer `4f5b29b`; bitstream `p11h3`, `gen-machine-conf` from the new SDT, GMC_EXIT 0): 15,088 tasks, all succeeded, 7 min 1 s; the same 22 warnings as `p13`. Checked: the deployed bitstream MD5 `58d7e3f6…` = the XSA's; the DTB has `fpgamixer-link3` (card `FPGAmixerLink3`) on `audio_formatter@80120000` and `M_AXI_LINK3STAT@8000c000`; rootfs `VERSION` `4f5b29b`, `fpgamixer-usbhost-bridge.service` enabled (alongside the USB device bridge), `usbhost.conf` on `hw:FPGAmixerLink3`, the OSC unit with `--identity-from 4`, `mixer_hw` `linkstat3`. **`build/sd/p11h3-usbhost-20261007.wic.xz`** (109 MB, MD5 `d18f09be…`, same on both ends).
- **What a user sees after flashing:** the M2's inputs (app strips 1–2) are routed nowhere until patched (H5); the M2's outputs carry buses 1–2 (bus matrix identity), which nothing feeds until an input is routed to them. To hear the Mac in the M2's headphones: input matrix USB 1→bus 1, USB 2→bus 2 (core 4→0, 5→1).

**Image `p11h2-usbhost-20261006`** (2026-10-07 03:06 UTC; layer at the clean commit `19d1fe6`; bitstream unchanged, `p13`, MD5 `d1531052…`; no `gen-machine-conf`): 15,088 tasks, all succeeded, 4 min 21 s. Checked in the rootfs: `VERSION` `19d1fe6`; `/usr/bin/fpgamixer-usbhost-bridge`, `/usr/bin/fpgamixer-rate-test`, `/etc/fpgamixer/usbhost.conf`, `libsamplerate.so.0.2.2`, the unit **not enabled** (no `multi-user.target.wants` link), the USB device bridge still enabled. **`build/sd/p11h2-usbhost-20261006.wic.xz`** (109 MB, MD5 `47c9fbe7…`, same on both ends).

## 7. Log

- **2026-09-30:** proposal written from the Phase 8 §9.2 scope, the P9.5 link template and `bridge_core`. Build VM unreachable at the first try (8 s connect timeout).
- **2026-09-30:** decisions H0–H6 (§6.1): MOTU M2, 2 × 2; all off; trimmable. VM reached: `SND_USB_AUDIO=y` confirmed, libsamplerate0 / speexdsp recipes present. Next: bench H-1.
- **2026-10-06 17:40 PDT:** resumed after Phases 12–13; user: retire the Pmods, the MOTU becomes the board's headphone/mic I/O. §8: addresses moved (link #3 status 0x8000_C000), SmartConnect at its 16-master limit, core 28/28/28 = 23 DSPs, D 233, H5 narrowed to the input matrix, floating ADC pins found; decision P1 asked.
- **2026-10-07:** H.2 PASS by ear (after the S24_LE sign fix). P1 = (b); the M2 on core 0–3, core stays 20/20/20. H.3 RTL + BD written (§8.7), XSim 15/15, mutants 3/3; Vivado build `p11h3` next.
