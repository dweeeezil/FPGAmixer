# Phase 9 status: 2026-09-26 — network audio (AVB): design proposal

**Status: proposal only, nothing built.** The decisions in §8 come first. Every *checked* fact below was read from the build tree, the XSA or the bench on 2026-09-26, not recalled.

Order decided by the user (2026-09-26): after the single 8 × 8 USB device (Phase 8, done), **AVB comes before DSP**. Phase 7 is deferred because the planned DSP module library makes it large.

Roadmap Decision 1 still stands for v1: **gPTP + AAF streaming with static, hard-coded streams**; AVDECC / Milan is Phase 10.

---

## 1. What exists already

| Piece | State | Where |
|---|---|---|
| gPTP on the board's PS GEM0 | **spike PASS 2026-09-24**: 3–4 ns RMS, ≤ 22 ns worst over one hop, as slave and as grandmaster, against the Pi 5 + I350 (`gPTP.cfg`, `ptp4l` + `phc2sys`). Needed: the DP83867 PHY node, a fixed MAC, and `emio_enet0_tsu_inc_ctrl = 2'b11` | `gptp_spike_2026-09-24.md` |
| PS↔PL audio link | the generic front door: Audio Formatter → ALSA card on `mclk` time → `pcm_link` → core. One instance, 8 + 8 channels, used by USB | `phase8_status_2026-09-25.md` |
| USB front door | gadget + our bridge, which steers the Mac to `mclk` through the UAC2 feedback pitch: **USB follows whatever `mclk` does** | Phase 8 |
| core | `pcm_matrix` 12 × 12, **144 of 360 DSP48E2** (one per crosspoint) | Phase 8 P8.4 |
| audio clock | `mclk` = MMCM off the 25 MHz PL clock (the DP83867's CLK_OUT, i.e. the PHY's crystal): **12.2919 MHz, +324 ppm, free-running, not steerable** | roadmap §4 |

## 2. Checked facts (2026-09-26)

| Fact | Source | Consequence |
|---|---|---|
| **libavtp 0.2.0** is in `meta-openembedded/meta-multimedia` (enabled in our `bblayers.conf`). **alsa-plugins 1.2.7.1** has `PACKAGECONFIG[aaf]` → the **AAF PCM plugin** (an AVB talker/listener that looks like an ALSA device). | VM layer tree | The Linux half of an AVB front door can be "an ALSA card", like USB in Phase 8, and our bridge pattern carries over. Enable the PACKAGECONFIG; nothing to write for AAF packetisation. |
| **The Cadence GEM driver (`macb`, 6.18.10) offloads CBS** (802.1Qav credit-based shaper) **on the top two TX queues**, plus **taprio** and **mqprio**; up to 8 queues. | `macb_main.c` (`macb_cbs_add`: "only top 2 queues support CBS"; `TC_SETUP_QDISC_{MQPRIO,CBS,TAPRIO}`) | AVB class A/B shaping in hardware on the board's own Ethernet. |
| The board kernel has `NET_SCHED`, `MQPRIO`, `PTP_1588_CLOCK`, but **`NET_SCH_CBS`, `NET_SCH_ETF`, `NET_SCH_TAPRIO` are not set**. | board kernel `.config` | A kernel config fragment (like `fpgamixer-usb.cfg`). |
| **`emio_enet0_enet_tsu_timer_cnt[93:0]`, the GEM's 1588/gPTP time counter, is already an output of the PS in our BD** (exposed since the TSU was enabled in Phase 4). GEM TSU clock = IOPLL / **250 MHz**. | `fpgamixer_p8.xsa` (`.hwh`) | **The PL can timestamp its own audio frames in gPTP time, in hardware.** This makes a hardware-disciplined media clock realistic (§4). *To verify:* the counter's clock domain (the TSU clock, not exported to the PL today) and the cleanest way to sample it from `mclk`. |
| **PS PLLs support fractional mode, settable at runtime** via the PMU firmware (`zynqmp/pll.c`: `zynqmp_pm_set_pll_frac_data`, 16-bit fraction; ≈0.3 ppm steps at 12.288 MHz). | kernel source | A second way to make `mclk` steerable (§4, M2b). *Unknown:* whether a fraction change is glitch-free, and which PS PLLs are free (DP uses VPLL/RPLL). |
| linuxptp **4.4** (meta-xilinx) is available; the board already ran `ptp4l`/`phc2sys` in the spike. | layer tree, spike | gPTP is a service to package, not a problem to solve. |

## 3. The shape (modular, as before)

```
  network ── GEM0 (PS) ── Linux: ptp4l (gPTP), CBS qdiscs, AAF talker + listener (alsa-plugins aaf)
                                   │                         │ ALSA
                                   │ gPTP time               ▼
                                   │                   AVB bridge (Linux half of the AVB front door;
                                   │                   the Phase 8 bridge, generalised)
                                   │                         │ ALSA
                                   ▼                         ▼
  PL:  media-clock discipline ── mclk ──►  link #2 (Audio Formatter + pcm_link, 8+8)  ──►  core
       (timestamps frames against the    link #1 (USB, Phase 8)                          (matrix)
        GEM TSU counter, steers mclk)
```

- **AVB is a front door** with a Linux half (gPTP, shaping, AAF talker/listener, bridge) and a PL half (a **second `pcm_link` + formatter instance** → ALSA card "FPGAmixerLink2"). Nothing in the link, the driver or the core is AVB-specific. That was the point of the Phase 8 link design.
- **The media clock is the new platform piece** (§4). Everything else reuses Phase 8.

## 4. The decision that matters: the media clock

AVB listeners play samples at **presentation times in gPTP time**, and a talker's stream carries its media clock in its timestamps. Today's `mclk` is +324 ppm off and free-running, so ~16 samples/s slip against any network stream (roadmap §4).

| Option | What | For | Against |
|---|---|---|---|
| **M1: board = the only media clock** | board is gPTP grandmaster, our `mclk` is the reference, our talker's timestamps express it; foreign streams are resampled | smallest change | every received stream needs ASRC; a +324 ppm clock is a poor network citizen; Milan devices expect a gPTP-locked media clock |
| **M2: `mclk` disciplined to gPTP** (recommended) | make `mclk` steerable and lock it to gPTP time (and later to a stream's or CRF's media clock) | **one clock for the whole box**: core, Pmods, USB (the Mac already follows `mclk` via feedback) and AVB. Bit-exact streams, no resampling; the AVB-native design, and what Milan needs | new platform hardware: a steerable clock + a discipline loop |
| M3: ASRC at the AVB door | keep `mclk` free, resample each stream in the AVB front door | any source, independent clocks | sound quality and latency; needs care or DSP resources; still leaves the box off the network clock |

**M2 in more detail**, two steering options:

- **M2a: MMCM fine phase shift** (PL only). UltraScale+ MMCMs support dynamic fine phase shift (PSINCDEC); stepping the phase at a controlled rate is a continuous frequency offset. The discipline loop can run entirely in the PL: timestamp every Nth `mclk` frame against the TSU counter, compare with the ideal 48 kHz grid, PI, phase-step rate. **No PS change**, resolution far below 1 ppm. *To verify:* the fine-phase-shift step size on this MMCM configuration, and glitch-freedom at the codecs (the ODDR-forwarded Pmod clocks tolerate slow phase walk).
- **M2b: a PS PLL in fractional mode** feeding a `pl_clk`, trimmed by Linux through the clock framework. Simpler RTL, but the loop runs in software, it changes the PS configuration (psu_init), and glitch-free trimming is unconfirmed.

**Recommendation: M2a**, with the PL measuring and Linux (or the PL) closing the loop. It keeps the rule "the core never sees a foreign clock": the network *disciplines* the core's own clock. **ASRC (M3) stays the fallback** for a future stream whose media clock we can't lock to.

Consequence to note: while `mclk` is steered, the codec interface timing is unchanged (same clock tree); STA is re-run for the new clocking.

## 5. The DSP budget: the matrix must stop costing one DSP per crosspoint

4 Pmod + 8 USB + 8 AVB = **20 channels → 400 crosspoints > 360 DSP48E2**, before any Phase 7 DSP. Proposal: **time-multiplex `pcm_matrix`**. A frame is 256 `mclk` cycles, so one DSP can do up to ~250 MACs per frame (more with a faster core clock). 20 × 20 fits in 2 DSPs; 32 × 32 in 4–5. Same ports, same coefficient contract, same register window, so nothing around it changes, and **~140 DSPs are freed for Phase 7**. It's a core-block change verified by the existing matrix TBs (bit-exact against the reference model) plus a latency check.

Alternative (not recommended): fewer USB or AVB channels.

## 6. Proposed steps

Each step is verified and committed separately; the status doc and `architecture_modules.md` are updated with it.

| Step | What | Verified by |
|---|---|---|
| P9.0 | Branch from `main` after the Phase 8 PR merges; flash the pending Phase 8 image fixes (bridge coarse correction) along the way | bench |
| P9.1 | **gPTP as a service**: linuxptp recipe + config (`gPTP.cfg`), `ptp4l` + `phc2sys` units, role per §8 | bench: offset vs the Pi, as in the spike, now from boot |
| P9.2 | **TDM `pcm_matrix`** (same interface) | all matrix TBs bit-exact; new latency check; Vivado DSP count |
| P9.3 | **Media clock, measurement first**: PL timestamps of `mclk` frames against the TSU counter, in a status window; read the real ppm vs gPTP from Linux | bench: a stable, plausible offset (≈ +324 ppm vs a gPTP GM) |
| P9.4 | **Media clock, steering**: MMCM fine phase shift + the discipline loop; `mclk` locked to gPTP | bench: timestamp error bounded; audio unaffected (Pmods, USB) |
| P9.5 | **Link #2** (second formatter + `pcm_link`, card "FPGAmixerLink2"), core 20 × 20 | TBs; Vivado; `aplay`/`arecord` + link counters as in S2 |
| P9.6 | **Shaping + AAF**: kernel fragment (CBS/ETF/TAPRIO), alsa-plugins `aaf` + libavtp, mqprio/CBS setup (class A) on GEM0; static stream IDs/MACs | bench: AAF stream board → Pi and Pi → board (captured with tcpdump/Wireshark; timestamps sane) |
| P9.7 | **AVB bridge**: AAF ALSA devices ↔ link #2, presentation-time aware | bench: audio Pi → board → Pmods, board → Pi; with the media clock locked, no drift over an hour |
| P9.8 | Soak: multi-hop through an AVB switch (if available), long run, power cycle | bench |

## 7. Bench and peers

- **Pi 5 + I350**: the known-good gPTP peer from the spike. For AAF it needs libavtp + the alsa-plugins AAF plugin (Debian packaging to be checked; building them is fine) and software CBS/ETF (the I350 has no Qav hardware). It can be talker, listener and gPTP grandmaster.
- **An AVB switch** would give the multi-hop soak (the roadmap's open item). Is one available?
- **Milan / AVB gear at work**: useful later (Phase 10) as an interop target.

## 8. Decisions needed from the user

| # | Question | Recommendation |
|---|---|---|
| 1 | **Media clock:** M2 (discipline `mclk` to gPTP) with M2a (MMCM fine phase shift), M3 (ASRC) as the fallback? | **Yes, M2a.** One clock for the whole box; USB already follows `mclk`. |
| 2 | **gPTP role on the bench:** the board as grandmaster, or the Pi as grandmaster (board follows)? Long term (with Milan gear) the board is usually a follower. | **Board follows the Pi** on the bench, so the discipline loop is exercised the way it will be used; GM mode stays tested. |
| 3 | **Streams and channels:** one 8-channel AAF stream each way (48 kHz, class A)? Sample format for AAF: 24-bit in 32 (what Milan uses is to be confirmed in Phase 10)? | **8 + 8, class A, 48 kHz.** |
| 4 | **Matrix:** time-multiplex it now (P9.2), freeing DSPs for Phase 7? | **Yes.** |
| 5 | **Peers:** Pi only for v1? Is an AVB switch available for the soak, and which? Any AVB/Milan device available to test against? | Pi first; the rest when available. |
| 6 | **Channel map:** AVB at core channels 12–19 (appended after USB, as the Phase 8 rule says)? | **Yes.** |

## 9. Open verification items (for the implementing session)

- The TSU counter's clock domain in the PL, and how to sample `emio_enet0_enet_tsu_timer_cnt` coherently (a TSU-domain clock to the PL, or a capture handshake).
- MMCM fine-phase-shift step size and rate limits for `clk_wiz_audio`; whether the Clocking Wizard exposes the PS port or the MMCM must be instantiated directly.
- The AAF plugin's timing model (talker pacing, presentation time, `SO_TXTIME`/ETF) on 6.18 + alsa-plugins 1.2.7.1, and libavtp's API level.
- The Pi's kernel: CBS/ETF qdiscs, and whether Debian ships the AAF plugin.

## 10. Log

- **2026-09-26:** proposal written (this doc) after Phase 8 P8.9. Nothing built.
