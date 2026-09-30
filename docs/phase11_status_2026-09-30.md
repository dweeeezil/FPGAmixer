# Phase 11 status: 2026-09-30 — USB host mode (an interface on the board's Type-A)

**Branch:** `phase9/time-shared-core` (continued). **Starting image:** `p10e-names-20260930`.

**Status: design proposal. Nothing is built.** The decisions in §6 come first, and one of them (H1) needs a fact only the bench can give: what the interface reports to Linux.

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
| `CONFIG_SND_USB_AUDIO=y` on the board kernel | Phase 8 §10 (P8.1 `.config`) | **Not re-checked:** the build VM didn't answer SSH today. The bench step H-1 (§5) checks it directly: a card in `/proc/asound` proves the driver |
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

## 7. Log

- **2026-09-30:** proposal written from the Phase 8 §9.2 scope, the P9.5 link template and `bridge_core`. Build VM unreachable, so the kernel config check moved to bench step H-1.
