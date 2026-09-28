# Phase 9 status: 2026-09-26 — network audio (AVB): design proposal

**Status: proposal only, nothing built.** The decisions in §8 come first. Every *checked* fact below was read from the build tree, the XSA or the bench on 2026-09-26, not recalled.

Order decided by the user (2026-09-26): after the single 8 × 8 USB device (Phase 8, done), **AVB comes before DSP**. Phase 7 is deferred because the planned DSP module library makes it large.

Roadmap Decision 1 still stands for v1: **gPTP + AAF streaming with static, hard-coded streams**; AVDECC / Milan is Phase 10.

**Revised 2026-09-26 (user decision): the time-shared core comes first** (§5, steps P9.A1–A6), before any AVB-specific step. Reasons: AVB doesn't fit the DSP budget without it; the matrix is the only core block today, so the core's internal interface is cheapest to redefine now; and Phase 7's DSP module library will be built on whatever that interface is.

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
| **The Cadence GEM driver (`macb`, 6.18.10) offloads CBS** (802.1Qav credit-based shaper) **on the top two TX queues**, plus **taprio** and **mqprio**; up to 8 queues. | `macb_main.c` (`macb_cbs_add`: "only top 2 queues support CBS"; `TC_SETUP_QDISC_{MQPRIO,CBS,TAPRIO}`) | ~~AVB class A/B shaping in hardware on the board's own Ethernet.~~ **Corrected 2026-09-28 (P9.6, §6.12): not on this chip.** The offloads are only enabled for configs with `MACB_CAPS_TC` (Versal); `zynqmp_config` doesn't have it, so on GEM0 shaping is software. GEM0 has **2 TX queues**. |
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

## 5. First: a time-shared core (P9.A, done before any AVB step)

### Why

4 Pmod + 8 USB + 8 AVB = **20 channels → 400 crosspoints > 360 DSP48E2**, before any Phase 7 DSP. The deeper problem: `pcm_matrix` spends one DSP48E2 per crosspoint, and each does **one** multiply per frame. A frame is **256 `mclk` cycles** (12.2919 MHz / 48.016 kHz), so every DSP is idle 255/256 of the time: about 0.4 % utilisation.

Time-shared at `mclk` alone (no faster clock), one DSP does ~250 MACs per frame, and the device does **~90,000 per frame**:

| Workload | Parallel (today) | Time-shared at `mclk` |
|---|---|---|
| 20 × 20 matrix (Pmod + USB + AVB) | 400 DSPs: doesn't fit | 2 |
| 32 × 32 matrix | 1024 | 4 |
| 64 × 64 matrix | 4096 | 16 by MAC count; **~22–32 with the schedule proposed in §5.1** (corrected in P9.A1) |
| 64 channels × 8 biquad bands (5 MACs each) | — | ~10 |

So the roadmap's full chain (input DSP → bus matrix → bus DSP → output matrix → output DSP) fits many times over. **Staying at `mclk` matters:** a faster core clock would have to follow `mclk` through the Phase 9 media-clock steering (§4). It remains an option for later, not a need.

### What "implemented correctly" means (proposed; the decisions are in §8)

- **A time-shared stream contract inside the core**, next to today's packed PCM contract: samples flow sequentially through each frame with a channel index, on `mclk`, frame-synchronous. Packed vectors don't scale: 64 channels is a 1536-bit bus between every pair of blocks, and serial blocks chain naturally. Front doors keep the packed contract at first, with **packed ↔ stream converters at the core boundary**, and can move to the stream form later. Both contracts go into `architecture_modules.md` §2.
- **Coefficients in RAM with a bank swap.** Two banks: software writes the inactive one, COMMIT swaps them at a frame boundary, and the new inactive bank is brought up to date afterwards (copy, or write-both). The **coefficient contract is unchanged** ("the whole bank changes on one frame"), and so is the register window, so `mixer_hw`, the OSC server and saved state don't notice. The clock crossing shrinks from a 2592-bit bank (most of Phase 8's 4193 CDC paths) to a single toggle.
- **Samples and coefficients in block RAM** (0 of 216 used today). The limits become memory ports and the schedule, not multipliers.
- **Latency:** one frame (~21 µs, a frame is computed while the next arrives). Stated in the contract and tested.
- **Saturation and arithmetic unchanged:** Q2.16 gains, 24-bit samples, a wide accumulator, saturate once at the output, so it stays bit-exact against the existing reference model.

### Steps

| Step | What | Verified by |
|---|---|---|
| P9.A1 | **Design proposal for the core contract** (stream format, framing, channel ordering, back-pressure or none, latency, RAM bank swap), written into this doc; decisions from the user | review |
| P9.A2 | Stream contract + the packed ↔ stream converters (generic, parameterised) | new TB, round trip bit-exact, mutation-tested |
| P9.A3 | Coefficient RAM with bank swap behind the existing `axil_coef_window` register layout | TB: the atomicity monitor from `tb_matrix_regs` (every frame sees one whole bank), across unrelated clocks |
| P9.A4 | **Time-shared `pcm_matrix`** (same parameters, same register window), N_IN × N_OUT MACs per frame on ⌈N_IN·N_OUT/~250⌉ DSPs | `tb_pcm_matrix`, `tb_pcm_matrix_rect`, `tb_matrix_regs`, the integration TBs: bit-exact against the reference model; a latency check |
| P9.A5 | Integration in `fpgamixer_top`; Vivado | timing, CDC report (expect far fewer crossings), **DSP count (144 → ~1–2)**, methodology gate |
| P9.A6 | Bench, no new hardware | USB ↔ matrix ↔ Pmods as in Phase 8 S3; `crosspoint_restore_test.py` set / check-hw / power pull as in S4 |

Alternative (not recommended): fewer USB or AVB channels and a parallel matrix.

### 5.1 P9.A1: core design proposal (2026-09-26, awaiting decisions C1–C7)

Branch `phase9/time-shared-core`, from `main` after the Phase 8 merge (`ea88a29`).

#### Facts this rests on (checked 2026-09-26 unless marked)

| Fact | Source | Consequence |
|---|---|---|
| A frame is **exactly 256 `mclk` cycles**: LRCK is bit 7 of a free-running 8-bit counter. Steering `mclk` (§4, M2a) changes the cycle's length, never the count. | `i2s_clock_divider.sv` | The schedule has a fixed budget of 256 cycles, known at elaboration. |
| The frame strobe (`jb_rx_valid`) fires **3 `mclk` after the LRCK falling edge** (receiver: 2 FF edge detect + registered pulse). The I2S transmitter loads **L 1 cycle after the LRCK fall** (strobe − 2, i.e. +254 of the previous frame) and **R 1 cycle after the LRCK rise** (strobe + 126). `pcm_link` captures `tx_flat` **on the strobe**. | `i2s_receiver.sv`, `i2s_transmitter.sv`, `pcm_link.sv` | These are the deadlines the core's output must meet (latency, C2). |
| Today `pcm_matrix` updates its outputs **1 cycle after the strobe**. | `pcm_matrix.sv` | So today: link and I2S-L carry frame *k* one frame later; **I2S-R carries it half a frame later.** See "A side finding" below. |
| Device: **360 DSP48E2, 216 RAMB36 (= 432 RAMB18), no URAM row**; Phase 8 uses 144 DSP, 0 BRAM. `pl_clk0` (AXI) = 100 MHz. | `build/p8_util.rpt`, `create_project.tcl` | Memory is free; the new core should use BRAM for coefficients. |
| DSP48E2 (UG579, *from the documentation, not re-read today*): 27 × 18 signed multiplier, 48-bit P accumulator with a dynamic OPMODE (so "P = M" on the first term of an output, "P = P + M" after it, with no bubble), optional A/B/M/P pipeline registers, and an **A cascade (ACOUT → ACIN)** that passes an operand to the neighbouring DSP one register later. | UG579 | A 24-bit sample on A and an 18-bit gain on B is exactly one multiplier. The A cascade is the textbook way for several DSPs to share one sample stream. |
| Accumulator range: \|sample\| ≤ 2²³, \|gain\| ≤ 2¹⁷, so \|product\| ≤ 2⁴⁰ and a sum of N products fits 48 signed bits for **N_IN ≤ 127**. | arithmetic | The DSP's own 48-bit P holds the exact sum; the result is **bit-identical** to today's reference model (whose accumulator is merely wider). N_IN > 127 is refused at elaboration. |
| RAMB36E2/RAMB18E2 (UG573, *from the documentation*): two ports with **independent clocks**, per-byte write enables (9-bit bytes in the 18/36/72-bit widths), 72-bit simple dual port. | UG573 | A coefficient bank can live in one RAM whose AXI port and `mclk` port run on their own clocks; the only clock crossing left is the bank-swap handshake. |

#### The schedule: output-major lanes, one systolic sample stream

```
                     frame strobe (cycle 0)
                     │
 inputs  ──packed──► pack→stream ─► sample buffer (N_IN × 24, LUTRAM/regs)
                                         │ one read per cycle: input i
                                         ▼
                     lane 0 (DSP) ─A cascade─► lane 1 (DSP) ─► … ─► lane L−1
                        ▲ gain(o,i)            ▲ gain, 1 cycle later      ▲
                     coefficient RAM: one word = L gains (one per lane)
                        │                      │                          │
                     y(o = l + L·j): descale + saturate (fabric) at the end of each output's sweep
                                         ▼
 outputs ◄─packed── stream→pack ◄── one beat per cycle, ascending channel order
```

- **Lane *l* computes outputs *l*, *l*+L, *l*+2L, …** For each of its outputs it sweeps all inputs *i* = 0 … N_IN−1, one MAC per cycle, P reset by OPMODE on *i* = 0. Every lane sweeps the **same input at the same time, one cycle apart** (lane *l* is *l* cycles behind lane 0), so the sample buffer needs **one read port for any number of lanes**, and the sample is handed down the DSP A cascade. Gains come from the coefficient RAM as one word per step holding the L lanes' gains, each delayed *l* cycles.
- **N_OUT not divisible by L:** the last pass has idle lanes. They run with their gain forced to 0 and their result discarded; the budget counts the idle slots, so nothing special happens in the datapath.
- **Output order falls out ascending:** lane *l* finishes output *l* + L·*j* one cycle after lane *l*−1 finishes *l*−1 + L·*j*, so results leave one per cycle as 0, 1, 2, …, provided N_IN ≥ L (checked at elaboration).
- **Budget.** Computation starts when the last input has arrived, so the output stream ends at about
  `D ≈ 1 + N_IN + ⌈N_OUT/L⌉ · N_IN + (L − 1) + PIPE` cycles after the strobe (PIPE ≈ 5: A/B, M, P registers + saturate).
  **L is the smallest lane count with D ≤ 250**, computed at elaboration (overridable; an impossible size is an `$error`):

| Size | Lanes L (= DSP48E2) | D (cycles after the strobe) |
|---|---|---|
| 12 × 12 (today) | 1 | ≈ 162 |
| 20 × 20 (Pmod + USB + AVB) | 2 | ≈ 227 |
| 32 × 32 | 6 | ≈ 236 |
| 64 × 64 | 32 (22 if the input load overlaps the previous frame's computation, +1 frame latency) | ≈ 229 |

  The §5 table's "16 DSPs for 64 × 64" assumed perfect packing. Output-major lanes cost N_IN cycles per output, and a lane must finish whole outputs. A split-input scheme (each lane sums part of the inputs, results added through the DSP P cascade) packs better. It isn't needed below ~40 × 40, so it is **not proposed now**, just noted as the scaling path.
- **Arithmetic unchanged:** Q2.16 gains, 24-bit samples, the exact sum in P, then `>>> 16` (truncate) and saturate once, in fabric. Bit-exact against the existing reference model by construction; the TBs prove it.
- **DSP inference, not instantiation:** a coding template Vivado maps onto DSP48E2 (with its pipeline registers and dynamic OPMODE), so XSim and Icarus keep running the same source. The build checks the result: DSP count = L, and no fabric adder on the accumulate path. Fallback if inference won't pack it: the DSP48E2 primitive behind a simulation model.

#### C1: the time-shared PCM stream contract (inside the core)

| Signal | Definition |
|---|---|
| `clk`, `rst_n` | `mclk`, as the packed contract |
| `frame` | the frame strobe, one pulse per frame (the same pulse the packed contract calls `valid`) |
| `s_valid` | one beat |
| `s_ch` | channel index, `$clog2(N)` bits |
| `s_data` | sample, signed, `SW` bits (24 today; a parameter, so Phase 7 can widen the internal format without a new contract) |

Rules (proposed):
- Each channel **exactly once per frame, in ascending order 0 … N−1**. Gaps (idle cycles) are allowed; every block emits contiguously today. Carrying `s_ch` costs a few wires and lets any consumer (and every TB monitor) check the order, the same reason the link checks TID.
- **All beats of frame *k* lie between strobe *k* and strobe *k*+1.** A block that can't finish inside the frame must say so and retime to the next frame (+1 frame of latency, stated). None does today.
- **No back-pressure (no `ready`).** Audio is isochronous and every schedule is static, so each producer's timing is known at elaboration and checked there; a `ready` would only add logic and a failure mode nobody can use.
- Each block **states its timing** as localparams: first beat and last beat, in cycles after the strobe. The converters' and the matrix's are in their headers and checked by the TBs.
- Front doors keep the packed contract. The core boundary gets two generic converters, **`pcm_pack2stream`** (packed + strobe → beats 0…N−1 on cycles 1…N) and **`pcm_stream2pack`** (beats → a staging register → all channels to the packed output on **one** edge, so downstream still sees a whole-frame update, as today).

Alternative considered: fixed TDM slots (channel = cycle offset, no `s_ch`, no `s_valid`). Fewer wires, but any block with a different timing breaks every block after it, silently. **Recommendation: the tagged form above.**

#### C2: latency

| Option | What | Link / I2S-L | I2S-R |
|---|---|---|---|
| **(a) in-frame** (recommended) | the core's packed output for frame *k* updates on one edge at cycle D of frame *k* (D stated, ≤ 250) | +1 frame, **the same as today** | +1.5 frames while D > 126 (today +0.5, which is the skew in the finding below: R and L of one DAC frame then come from the same core frame) |
| (b) frame-aligned | the output updates at strobe *k*+1 | **+2 frames** (the link captures on that same edge, so it sees the value from before it) | +1.5 |

(a) keeps today's latency on every path that matters and leaves 6+ cycles of margin before the link's capture and the I2S-L load. TBs check D exactly.

#### A side finding: the Pmod outputs probably have a one-sample L/R skew today

From the timing above (read from the RTL, **not measured**): the DAC's I2S frame starting at LRCK fall *n* is loaded with **L from core frame *k*−1** (loaded at strobe − 2, just before frame *k*'s result exists) and **R from core frame *k*** (loaded at strobe + 126, after it). If the CS4344 treats the L and R of one LRCK period as one instant, as I2S intends, **R leaves one sample ahead of L** on every Pmod. The bench's mono cables only carry L, so nobody could have heard it; nothing else is affected (all L outputs share one timing, and the link is frame-consistent).

With C2 (a) at 12 × 12 or 20 × 20, D > 126, so both halves of a DAC frame come from the same core frame and the skew disappears as a side effect. That's too fragile to rely on: it depends on D. **Proposal (C7): fix it where it belongs, in the `i2s_port` front door** (capture `tx_flat` once per frame, at one point, for both channels), as its own small step with a TB that checks L/R pairing, independent of the core. First confirm it in simulation (`tb_phase3_datapath` can show it with different L and R test signals).

#### C3: coefficients in RAM (the coefficient contract, new form)

The **meaning** of §3 stays ("the whole bank changes on one frame; the block doesn't know where the values came from"). The **form** changes, because a flat 400 × 18-bit vector (and its copy across the clock crossing) is exactly what doesn't scale:

- **Block side (mclk):** a **read port**: the block drives an address and gets a word of L coefficients one cycle later. The bank behind it changes only at a frame strobe, and all of one frame's reads see one bank (the schedule's reads all fall inside one frame).
- **Control-plane side:** a new generic **`coef_bank_ram`**:
  - **shadow** RAM (AXI clock): what software writes and reads back, as the flat shadow register bank does today;
  - **two active banks** in one dual-clock RAM: port A (AXI clock) writes, port B (`mclk`) reads;
  - **COMMIT:** copy shadow → the inactive bank (≈ N_COEF cycles at 100 MHz: 1.4 µs at 12 × 12, 4 µs at 20 × 20), then a **toggle request** to `mclk`, which flips the bank select **at the next frame strobe** and toggles an acknowledge back. The next COMMIT's copy overwrites the old bank completely, so no "bring the inactive bank up to date" step is needed. **AXI writes stall during the copy** (a few µs of AWREADY low), so a commit contains exactly the writes completed before it, as today;
  - **BUSY / QUEUED / COMMITS** behave as today (a COMMIT during BUSY is queued, latest shadow wins);
  - **the only clock crossings are the two toggles** (plus the dual-clock RAM, which is safe by construction since the bank being written is never the bank being read). The scoped-XDC pattern of `coef_bank_handoff` carries over. Phase 8's 2592 bank-crossing paths go away;
  - **reset:** after `aresetn` an init engine writes the reset bank (identity) into the shadow and runs a normal COMMIT, so a reset still means "identity is in effect", via the ordinary path. A reset of either domain alone never falls back to an older bank (the bank select doesn't reset with `mclk`; the details are settled and tested in P9.A3).
- **The block binding maps the address:** `matrix_regs_axil` turns register index *k* = o·N_IN + i into (lane, word) for the RAM layout the matrix reads. `coef_bank_ram` knows nothing about matrices. The **register map is unchanged**, so `mixer_hw`, the OSC server and saved state don't notice.
- **`coef_flat_reader`** (generic, small): the same read port over a flat vector, for **non-PS builds** (tied to `MATRIX_GAINS`) and **unit TBs**. The block still can't tell where its coefficients come from.

#### C4: a `mixer_core` wrapper, now

D1 postponed `mixer_core` until the core held more than one block. It now holds three (pack→stream, matrix, stream→pack). **Proposal:** add it now. It has the packed contract on both sides and the matrix's coefficient read port, so `fpgamixer_top` changes by one instance and the front doors see nothing new. The bus layer and Phase 7 blocks go inside it later, chained by the stream contract.

#### C5–C6

- **C5: DSP inference** (above), primitive as the fallback.
- **C6: `SW` stays 24 inside the core for now**, as a parameter of the stream contract. Whether Phase 7 widens it (headroom between chained blocks, as consoles do) is a Phase 7 decision.

#### Verification plan (P9.A2–A6)

- **P9.A2 converters:** round trip packed → stream → packed, bit-exact, N = 1, 12, 20; a stream monitor checks order, one beat per channel, all beats inside the frame and the stated first/last-beat cycles; mutation-tested (a swapped channel, a beat pushed past the frame).
- **P9.A3 `coef_bank_ram` + binding:** `tb_matrix_regs`'s atomicity monitor (every frame sees one whole bank) on the new read port, unrelated clocks; COMMIT during BUSY; writes stalled during the copy; reset of either side alone; read-back equals the shadow; the register map byte for byte.
- **P9.A4 time-shared matrix:** `tb_pcm_matrix` and `tb_pcm_matrix_rect` through `mixer_core` + `coef_flat_reader`, **bit-exact against the unchanged reference model** at 4 × 4, 3 → 5, 5 → 2, 12 × 12, 20 × 20 (L = 2, the uneven-pass case) and 7 × 5 with L forced to 3; the latency D checked to the cycle; the stream monitor on the output. Mutation: a lane's gain delay off by one, OPMODE reset on the wrong input.
- **P9.A5 build:** DSP48E2 = 1 at 12 × 12; BRAM a few; the CDC report down from 4193 crossings to the link FIFOs + the toggles; timing and the methodology gate.
- **P9.A6 bench:** as Phase 8 S3 (USB ↔ matrix ↔ Pmods by ear, link counters clean) and S4 (`crosspoint_restore_test.py` set / check-hw / power pull).

#### Decisions needed (C1–C7)

| # | Question | Recommendation |
|---|---|---|
| C1 | Stream contract: tagged beats (`frame`, `s_valid`, `s_ch`, `s_data`), ascending, once per frame, inside the frame, no back-pressure, timing stated per block? | **Yes** |
| C2 | Latency: (a) in-frame, output updates at a stated cycle D ≤ 250, or (b) one whole frame? | **(a)**, same latency as today |
| C3 | Coefficients: RAM read port on the block, generic `coef_bank_ram` (shadow + two banks, copy then swap at a frame, writes stall during the copy, reset through a normal commit), `coef_flat_reader` for non-PS builds and TBs; register map unchanged? | **Yes** |
| C4 | Add `mixer_core` now (converters + matrix)? | **Yes** |
| C5 | DSP inference (template), primitive only as a fallback? | **Yes** |
| C6 | Core sample width 24, as a parameter; widening decided in Phase 7? | **Yes** |
| C7 | The probable Pmod L/R skew: confirm in simulation, then fix in `i2s_port` as its own small step (before or after the core)? | **Confirm now, fix right after P9.A2** (small, independent, and the bench can hear it only with stereo cables) |

**Decided by the user, 2026-09-26: all as recommended.** C1 tagged stream contract; C2 (a) in-frame latency; C3 `coef_bank_ram` + `coef_flat_reader`, register map unchanged; C4 `mixer_core` now; C5 DSP inference; C6 `SW` = 24 as a parameter; C7 the L/R skew fixed in `i2s_port` right after P9.A2.

### 5.2 P9.A2: the stream contract and the boundary converters (simulation): PASS

| File | What |
|---|---|
| `src/rtl/pcm_pack2stream.sv` (new, generic) | captures `in_flat` on the strobe (a shift register, so the front doors may change it mid-frame); beats 0 … N−1 on cycles 1 … N, contiguous. `$error` if N doesn't fit the frame |
| `src/rtl/pcm_stream2pack.sv` (new, generic) | stages beats by `s_ch`; on the beat for N−1 all channels move to `out_flat` on one edge (cycle N+1 behind `pcm_pack2stream`), `valid_o` pulses. `err_o` pulses on a beat that isn't the expected next channel, and on a strobe that finds a frame incomplete. A frame whose last beat never comes isn't delivered; audio is never blocked |
| `src/sim/pcm_stream_monitor.sv` (new, sim) | the reusable contract checker: order, once per frame, inside the frame, stated first/last-beat cycles, contiguity |
| `src/sim/tb_pcm_stream.sv` (new) + `sim.mk` target `stream` | below |
| `docs/architecture_modules.md` | new §2.1 (the contract), file map, §3 note on the coming coefficient read port |

**`tb_pcm_stream` (XSim 2026.1): PASS.**

| Part | Result |
|---|---|
| round trip N = 1, 12, 20 (random samples each frame; the packed input also scrambled mid-frame) | 40 frames each, **bit-exact**; output changes only on the `valid_o` edge, at **cycle N+1** exactly; the monitor sees beats 0 … N−1 on cycles 1 … N, contiguous; `err_o` never |
| `pcm_stream2pack` alone, N = 5, beats written by the TB | idle gaps between beats: delivered, no error. Channels 1 and 2 swapped: exactly 3 `err_o` (the beats for 2, 1 and 3 each arrive unexpected), frame still delivered. Last beat missing: `err_o` at the next strobe, output unchanged |

**Mutation check** (mutated copies compiled from the scratchpad; the sources untouched):

| Mutant | Result |
|---|---|
| M1: wrong channel tag (`s_ch ^ 1`) | FAIL (N = 1 never delivers; 566,397 / 878,893 errors at N = 12 / 20 by the time-out) |
| M2: stage written at the neighbour's slot | FAIL, 40 of 40 frames wrong at N = 12 and 20, and part 2. (N = 1 can't see it: one channel.) |
| M3: not atomic (each beat straight to the output) | FAIL, 440 / 760 errors ("changed without `valid_o`") |
| M4: capture one cycle late (timing) | FAIL, 160 errors per size (first/last beat cycle, `valid_o` cycle) |

Not run: the Icarus path (`make -f scripts/sim.mk stream`); Icarus isn't installed on this PC. The target is written in the same form as the others.

**Found along the way:** a Python heredoc run through the Bash tool dropped the backslash line continuations in the new `sim.mk` rule, the known failure mode. Caught by the check afterwards and fixed with the editor.

### 5.3 C7: the Pmod L/R skew, confirmed and fixed in the front door (simulation): PASS

**Confirmed first, on the unchanged RTL.** `tb_phase3_dynamic` tags every input sample with its frame number and already printed the pairing, but it only compared each channel with itself: `locked: JB_L=100005 JB_R=200006 JC_L=300005 JC_R=400006`. **In one DAC frame, L carries input frame 5 and R carries frame 6: R leaves one sample ahead of L on both Pmods.** Cause, as read in P9.A1: the transmitter loads L at the LRCK fall (2 cycles before the matrix has frame *k*) and R at the rise (after it).

**Fix (`src/rtl/i2s_port.sv`, front door only):** the port samples the pair **once per DAC frame, when L is loaded** (its own 1 FF LRCK-fall detect, the same cycle as the transmitter's), sends L directly and holds R for the rising edge. So both halves always come from one core frame, whatever the core's timing. One 24-bit register and one flip-flop per port. The core, the link and every other front door are untouched.

- **Latency:** L's load time is unchanged; R is loaded one frame later than before (+1.5 frames after the strobe instead of +0.5). The DAC treats one LRCK period's pair as one instant, so what matters is that the pair now carries one input frame: **both channels have L's latency, which is what L always had.** Before, R was one sample early relative to L.
- **The deadline this states for the core:** the transmitter and the hold sample `tx_flat` on edge 254 of a frame, so the core's packed output must hold the new frame from **cycle 253**. C2's D ≤ 250 leaves 3 cycles; P9.A4's TBs check D. The link samples later (at the next strobe).

**Verification (XSim):** `tb_phase3_dynamic` gains a pairing check (L and R counters equal in every output frame).

| RTL | `tb_phase3_dynamic` | `tb_phase3_datapath` |
|---|---|---|
| `i2s_port` before the fix (from `HEAD`) | **FAIL**: every frame "JB/JC L/R pair from different frames: L 005, R 006" | PASS (static values can't show it) |
| fixed | **PASS**, `locked: JB_L=100005 JB_R=200005 JC_L=300005 JC_R=400005`, 24 frames, tags + counters + pairs | PASS |

The unmodified TB on the old RTL is the mutation check: the new check fails on exactly the bug it targets. `tb_i2s_tx_pin_phase` wasn't rerun: `i2s_transmitter` is unchanged, and the hold feeds only its `right_data`.

**On the bench:** not audible with the mono cables (L only). With stereo cables it would show as a one-sample L/R offset before the fix. It goes into the next bitstream with the core (P9.A5); no separate build.

### 5.4 P9.A3: the coefficient bank in RAM (simulation): PASS

| File | What |
|---|---|
| `src/rtl/coef_bank_ram.sv` (new, generic control plane) | shadow RAM (aclk) + **two banks per lane** in dual-clock RAM (port A aclk write, port B mclk read, `ram_style = "block"`); **store interface** on aclk (`st_valid/ready/we/idx/wdata`, `st_rvalid/rdata`) for the window; COMMIT = copy shadow → inactive bank, then a toggle; the swap happens **on the next frame strobe**; BUSY / QUEUED / COMMITS as before. Layout: rows round-robin over lanes (row *r* → lane *r* mod L, word (*r* div L)·ROW_LEN + *c*); for the matrix a row is an output. Reset: an init engine writes the reset bank into the shadow and runs a normal (uncounted) commit; **the toggles have no reset** (the bank in use *is* `ack_tgl`), so a reset of either side alone can't select an older bank |
| `src/rtl/coef_flat_reader.sv` (new, generic) | the same read port over a flat vector, for non-PS builds and TBs |
| `constraints/coef_bank_ram.xdc` (new) | scoped: 10 ns `-datapath_only` on the two toggles. The data crosses inside the BRAM. Enters `create_project.tcl` with the module in P9.A5 |
| `src/sim/tb_coef_bank_ram.sv` (new) + `sim.mk` target `coefram` | below |

Not changed yet: `axil_coef_window` and `matrix_regs_axil` still use the flat shadow + `coef_bank_handoff`. They move to the store interface **in P9.A4**, together with the matrix, `mixer_core` and `fpgamixer_top`, so every commit on the branch still builds.

**`tb_coef_bank_ram` (XSim), aclk 100 MHz vs mclk 12.2919 MHz, strobe every 256 mclk: PASS.** Two geometries: 5 rows × 7 on **3 lanes** (the uneven case: the last pass has an idle lane) and the real 12 × 12 on 1 lane. Every coefficient is tagged {version, index}; a reader on the mclk port reads the whole bank in cycles 1 … DEPTH after every strobe, as the time-shared matrix will.

| Check | 5 × 7 / 3 lanes | 12 × 12 / 1 lane |
|---|---|---|
| after reset: the reset bank in effect, COMMITS 0 | ✓ | ✓ |
| readback of a written value and of a reset value | ✓ | ✓ |
| layout: every coefficient at its word/lane, idle lane slots 0; `coef_flat_reader` decodes identically | ✓ | ✓ |
| random bursts (1–3 full versions back to back, the next version written at once after each COMMIT): **no frame reads two banks**, versions never go back | 64 versions, **64 seen at the port**, COMMITS +64, QUEUED for 105,093 aclk cycles | 38, **38 seen**, +38, 34,365 |
| aclk reset alone with a copy in flight, **at both bank parities**: only the reset bank (or the in-flight one) appears, then the reset bank stays; COMMITS 0 | ✓ | ✓ |

**Mutation check** (scratch copies, source untouched): all five fail.

| Mutant | Result |
|---|---|
| C1 swap without waiting for the strobe | FAIL: torn frames, 10 of 64 / 38 versions seen |
| C2 a queued commit takes the shadow at launch (the old handoff's rule) | FAIL: torn frames, versions merged |
| C3 lane index off by one in the copy | FAIL: LAYOUT at 3 lanes (invisible at 1 lane, as expected) |
| C4 `req_tgl` reset by `aresetn` | FAIL: after the aclk reset, an older / partly copied bank appears |
| C5 writes accepted during the copy | FAIL: 27 / 14 errors |

**Found by this TB: a design choice corrected.** The first run tore 7 frames at 12 × 12. A commit issued while BUSY is queued, and the first version launched it with the shadow *as it was at launch*, i.e. including writes made after the COMMIT (the TB writes the next version straight away). That is `coef_bank_handoff`'s documented "latest wins" rule, which the proposal carried over. From software's side it can apply a half-written bank for a frame. **Now:** while a commit is queued, the store isn't ready for writes, so **a commit holds exactly the writes completed before it**. Cost: a write straight after a COMMIT that had to queue waits for the previous swap, at most about one frame + a copy (≈ 22 µs at 12 × 12); an AXI write is simply held that long. `mixer_hw` writes and commits without polling, so its bulk restore (one COMMIT) is unaffected, and OSC-rate single changes see at most that stall. (The Phase 8 matrix still has the old rule until P9.A4 replaces it; `axil_stat_window`'s reverse handoff has no writes, so the rule doesn't matter there.)

### 5.5 P9.A4: the switch-over to the time-shared core (simulation): PASS

One commit, so that every commit on the branch builds: the matrix, its register binding and the top change together.

| File | What |
|---|---|
| `src/rtl/pcm_matrix_pkg.sv` (new) | the schedule's arithmetic in one place: `matrix_lanes` (smallest lane count with D ≤ 250), `matrix_passes`, `matrix_lat_first/last`, `core_latency`. The top level sizes the coefficient store with it, so the store and the matrix can't disagree |
| `src/rtl/pcm_matrix.sv` (rewritten) | **time-shared**: stream in (the beat for N_IN−1 starts the schedule, so it depends on order, not on its producer's timing), stream out, coefficient read port. Output-major lanes; the sample goes down the lanes register to register (A cascade), each lane's gain delayed to match; P restarts on input 0; one shared descale/saturate. Data registers have no reset (they must pack into the DSP48E2); control flags do. Refuses at elaboration: no lane count fits the frame, LANES > N_IN or N_OUT, N_IN > 127, operands wider than one DSP multiply |
| `src/rtl/mixer_core.sv` (new, C4) | `pcm_pack2stream` → `pcm_matrix` → `pcm_stream2pack`; packed on both sides |
| `src/rtl/axil_coef_window.sv` (rewritten) | same register map; coefficients through the store's request interface; WSTRB by read-modify-write; one FSM serves both AXI channels (the store takes one request at a time) |
| `src/rtl/matrix_regs_axil.sv` | `axil_coef_window` + `coef_bank_ram` (rows = outputs, so register index = store index; no address arithmetic); ports: the read port instead of `gains_flat`; `mrst_n` dropped (the store's mclk side has no reset) |
| `src/rtl/fpgamixer_top.sv` | `mixer_core u_core` replaces `pcm_matrix u_matrix`; PS builds: `matrix_regs_axil` → read port; non-PS: `coef_flat_reader u_gains` over `MATRIX_GAINS` |
| `scripts/create_project.tcl` | `coef_bank_ram.xdc` scoped to `coef_bank_ram` in the PS phases (the handoff XDC stays, for the status window) |
| `scripts/sim.mk` | `MIXCORE` list (package first); `matrix`, `matrix_rect`, `regs` and the integration targets updated |
| `scripts/xsim_regress.ps1` (new) | every TB with XSim, each in a fresh directory with a time limit (below) |
| TBs | `tb_pcm_matrix`: the same vectors and reference through `mixer_core` + `coef_flat_reader`, plus D. `tb_pcm_matrix_rect`: rewritten as a sweep (below). `tb_matrix_regs`: its atomicity monitor now **rebuilds the bank the matrix actually read in each frame** from the read port; `wait_idle` + one core output before the bank checks (BUSY clears when the swap is acknowledged, possibly before that frame's reads are done) |

**`tb_pcm_matrix_rect` (XSim): bit-exact at every size**, 60 frames each, new random samples and gains every frame (extremes over-represented: ±full scale, −2.0, just under +2.0), against the same 64-bit reference as the parallel matrix; D checked to the cycle; the matrix's output stream checked by `pcm_stream_monitor` against the stated first/last-beat cycles; `err_o` never.

| Size | Lanes (DSP48E2) | D (cycles after the strobe) | Errors |
|---|---|---|---|
| 3 → 5 | 1 | 24 | 0 |
| 5 → 2 | 1 | 21 | 0 |
| **12 × 12** (today) | **1** | **162** | 0 |
| **20 × 20** (Pmod + USB + AVB) | **2** | **227** | 0 |
| 7 → 5, LANES forced to 3 (idle lane in the last pass) | 3 | 28 | 0 |
| 32 × 32 | 6 | 231 | 0 |
| 1 → 1 | 1 | 8 | 0 |

The D values are the §5.1 estimates exactly (162, 227). `tb_pcm_matrix` (the 4 × 4 arithmetic corner cases: routing, truncation, both saturation limits, phase invert): all 28 checks, D = 26.

**Mutation check** (scratch copies of `pcm_matrix.sv`):

| Mutant | `tb_pcm_matrix_rect` | `tb_pcm_matrix` |
|---|---|---|
| X1 a lane's gain not delayed | FAIL on every multi-lane size (415 / 154 / 999 errors); 1-lane sizes can't see it | pass (1 lane) |
| X2 accumulator restarts on input 1, not 0 | FAIL, every size except 1 → 1 | FAIL, 10 checks |
| X3 logical instead of arithmetic descale | FAIL, every size | FAIL, 7 checks |
| X4 no sample cascade (every lane gets lane 0's sample) | FAIL on every multi-lane size | pass (1 lane) |

X1 and X4 are exactly why the sweep includes multi-lane sizes that today's 12 × 12 doesn't use.

**Integration (`tb_phase3_datapath`, `tb_phase3_dynamic`, the whole non-PS top): PASS.** `tb_phase3_dynamic` prints the same `locked: JB_L=100005 JB_R=200005 JC_L=300005 JC_R=400005` as after the C7 fix: the Pmod path's latency is unchanged, and the pairs stay together.

**`tb_matrix_regs` (AXI + `coef_bank_ram` + core, unrelated clocks): PASS**, every register check as before (ID, CONFIG `0x0404_1210`, reset identity and read-back, writes invisible before COMMIT, COMMIT atomic with COMMITS 1, a COMMIT while BUSY queued (`CTRL = 0x3`) and then the bank with COMMITS 3, WSTRB lanes), plus the matrix outputs under each bank.

**Full regression, `scripts/xsim_regress.ps1` (XSim 2026.1): ALL PASS, 13 of 13**: `rx`, `tx`, `txphase` (210 transitions, all while SCLK low), `loopback`, `matrix`, `matrix_rect`, `stream`, `coefram`, `regs`, `link`, `linkstat`, `phase3`, `dynamic`. The Icarus path (`sim.mk`) was updated in step but not run (Icarus isn't installed on this PC).

**A tooling snag, recorded:** `xvlog` hung (10 min of CPU, empty log) when recompiling in the old `build/xsim_top` directory; the same files compile in seconds in a fresh directory, both in groups and all together. Not diagnosed further; the new regression script always uses fresh directories.

### 5.6 P9.A5: the Vivado build: clean

`create_project.tcl` (`current_phase = phase8`: the block design didn't change) + `build.tcl p9a5`, Vivado 2026.1, ~10 min. XSA: `build/fpgamixer_p9a5.xsa`. Reports: `build/p9a5_{timing,util,cdc,clocks,exceptions}.rpt` (not tracked, like all of `build/`).

| | Phase 8 (`p8`) | **P9.A5 (`p9a5`)** |
|---|---|---|
| WNS / WHS | +1.628 / +0.010 ns | **+2.300 / +0.005 ns**, 0 failing endpoints |
| worst setup path | `pl_clk0`: AXI write → the 144-way shadow decode | the codec RX-sampling check (`jc_ad_sdout` → `u_jc/u_rx/sdata_r_reg`), the deliberate razor since Phase 3.5. `pl_clk0` alone: **+5.256 ns**, now inside AMD's formatter |
| methodology gate | clean | **PASS**, 0 critical warnings |
| **DSP48E2** | 144 (40 %) | **1 (0.28 %)** |
| BRAM | 0 | **1 RAMB18** (the coefficient banks) |
| LUTs / FFs | 8453 / 19505 | **6865 / 12629** |
| **CDC crossings** | 4193 | **1473, every one with an exception** (1471 max-delay, 2 false paths) |

**What mapped where (synthesis report):**
- `u_regs/u_bank` lane RAM: **one RAMB18, 512 × 18, port A written on `pl_clk0`, port B read on `mclk`**, so the coefficients cross inside the BRAM as designed. The shadow (256 × 18) and the sample buffer (16 × 24) are LUTRAM, each on one clock.
- The matrix: **one DSP48E2, dynamic OPMODE, MREG + PREG, 48-bit P**: the accumulate is inside the DSP. **Noted:** the A/B input registers stayed in fabric (AREG/BREG not packed). That's functionally the same, costs a few dozen FFs and doesn't matter at 12 MHz. With more lanes the sample cascade runs through fabric registers rather than ACOUT/ACIN. To look at if a larger core ever needs the timing.

**CDC report, by structure:**

| Structure | Crossings | Type |
|---|---|---|
| **matrix gains (`u_regs/u_bank`)** | **2** (was 2592) | CDC-3: `req_tgl → req_s1`, `ack_tgl → ack_s1`, ASYNC_REG, 10 ns max-delay from the scoped `coef_bank_ram.xdc`. No bank register crosses; the data crosses inside the BRAM |
| link FIFOs (`u_link/u_{rx,tx}_fifo`), unchanged | 1216 + 4 Gray buses | as Phase 8 (LUTRAM read paths CDC-1/15, Gray pointers CDC-6) |
| link status snapshot (`u_link_stat/u_handoff`), unchanged | 247 + 2 toggles | as Phase 8 |
| formatter internals, unchanged | 2 | AMD's own |

Not checked here: the bench (P9.A6).

### 5.7 P9.A6: bench: PASS (2026-09-26, image `p9a6-core-20260926`)

| Check | Result (read from the terminal logs) |
|---|---|
| boot | flash, full power-off, boot; SSH straight away with the bench login |
| `mixer_hw.py info` | `matrix 12 in x 12 out, Q2.16 (ID 0x4d585001, CONFIG 0x0c0c1210)`, BUSY/QUEUED clear, **COMMITS 1** (the OSC server's start-up push; the store's own reset commit isn't counted, as designed); linkstat present |
| S3 by ear (user) | USB → JB-L / JC-L and USB → Mac: "everything works just as it did before" |
| `mixer_hw.py link 10` | **48,018.1 / 48,018.0 frames/s**, underruns 0, starved 0, overruns 0, tid_errors 0, rx_running True |
| S4 `set` (Pi → board over OSC) | **144 sent, 144 echoed as sent, 0 differ** (each set is a write + COMMIT through the new store) |
| S4 `check-hw` before the power pull | **144/144** gain registers match |
| power pulled (the SSH session dropped: "closed by remote host"), rebooted, nothing typed | |
| S4 `check-hw` after | **144/144** |
| bridge start-up log | only the 7 start lines were in the journal when read (cards opened, both pitches start at 1000324); **no status line yet, so the coarse fix's effect on direction B is not observed yet**. Open item |

So the time-shared core with its RAM coefficient bank behaves on hardware exactly as the parallel matrix did, through the same register window, the same OSC server and the same saved state.

**P9.A (the time-shared core) is done.** Totals: DSP48E2 144 → 1, CDC crossings 4193 → 1473, LUTs −19 %, FFs −35 %; 20 × 20 fits on 2 DSPs.

#### Image notes

**SDT** (`sdtgen` on `fpgamixer_p9a5.xsa` → `build/sdt`; the Phase 8 one kept as `build/sdt.p8` and `~/edf/sdt.p8` on the VM): `psu_init.tcl`, `zynqmp.dtsi`, `pcw.dtsi`, `system-top.dts` **identical** to Phase 8; `pl.dtsi` differs only in `firmware-name` (`fpgamixer_p9a5.bit.bin`). So the PS configuration and the device tree didn't change; only the bitstream did.

**Layer sync:** the VM's copy was from `169eaa5-dirty` (P8.9), older than the bridge fix committed in `b2dd92a`. Synced at `89ebfc4` (clean). The synced `fpgamixer-usb-bridge.c` has the coarse correction and `HOLD_S`.

**Image built 2026-09-26:** `gen-machine-conf` (exit 0) + `bitbake edf-linux-disk-image xilinx-bootbin`: 14,821 tasks, all succeeded, 6 min 48 s, 23 warnings (the usual runqueue-deadlock / "image not supported" set). Checked: the deployed `download-genesys-zu3eg.bit` MD5 = Vivado's `fpgamixer_p9a5.bit` (`4df4e23e…`); the rootfs's `/usr/bin/fpgamixer-usb-bridge` has the "coarse fixes" status line, i.e. **the Phase 8 servo fix is in an image for the first time**. Copied to **`build/sd/p9a6-core-20260926.wic.xz`** (MD5 `f861eeaa…`, same on both ends).


## 6. Proposed steps

Each step is verified and committed separately; the status doc and `architecture_modules.md` are updated with it.

| Step | What | Verified by |
|---|---|---|
| P9.0 | Branch from `main` after the Phase 8 PR merges; flash the pending Phase 8 image fixes (bridge coarse correction) along the way | bench |
| **P9.A1–A6** | **The time-shared core, §5. Done first.** | see §5 |
| P9.1 | **gPTP as a service**: linuxptp recipe + config (`gPTP.cfg`), `ptp4l` + `phc2sys` units, role per §8. Linux-only, so it may run alongside P9.A if convenient | bench: offset vs the Pi, as in the spike, now from boot |
| P9.3 | **Media clock, measurement first**: PL timestamps of `mclk` frames against the TSU counter, in a status window; read the real ppm vs gPTP from Linux | bench: a stable, plausible offset (≈ +324 ppm vs a gPTP GM) |
| P9.4 | **Media clock, steering**: MMCM fine phase shift + the discipline loop; `mclk` locked to gPTP | bench: timestamp error bounded; audio unaffected (Pmods, USB) |
| P9.5 | **Link #2** (second formatter + `pcm_link`, card "FPGAmixerLink2"), core 20 × 20 | TBs; Vivado; `aplay`/`arecord` + link counters as in S2 |
| P9.6 | **Shaping + AAF**: kernel fragment (CBS/ETF/TAPRIO), alsa-plugins `aaf` + libavtp, mqprio/CBS setup (class A) on GEM0; static stream IDs/MACs | bench: AAF stream board → Pi and Pi → board (captured with tcpdump/Wireshark; timestamps sane) |
| P9.7 | **AVB bridge**: AAF ALSA devices ↔ link #2, presentation-time aware | bench: audio Pi → board → Pmods, board → Pi; with the media clock locked, no drift over an hour |
| P9.8 | Soak: multi-hop through an AVB switch (if available), long run, power cycle | bench |

### 6.1 P9.1: gPTP as a boot service (Linux only)

**Checked first (VM, 2026-09-26):** linuxptp **4.4** comes from meta-xilinx (`linuxptp_4.4.bb`; meta-oe's 4.1 is shadowed). Its package ships `ptp4l@.service` / `phc2sys@.service`, **disabled**, and they don't fit: `ptp4l@` reads `/etc/linuxptp/ptp4l.conf` (= `default.cfg`, not the gPTP profile) and `phc2sys@` has no `-f`, so it would wait for ptp4l forever (the spike's §2.4 trap). `summary_interval` is a `[global]` option (default 0 = every second). ptp4l, phc2sys, pmc and ethtool install to `/usr/sbin`. Until now linuxptp reached the image only through the VM's **untracked** `local.conf` (added for the spike).

| File (`yocto/meta-fpgamixer/`) | What |
|---|---|
| `recipes-apps/fpgamixer-gptp/files/fpgamixer-gptp.cfg` (new) → `/etc/fpgamixer/gptp.cfg` | linuxptp 4.4's `gPTP.cfg` verbatim, plus two marked changes: **`priority1 250`** (worse than the Pi's 248, so the board follows while the Pi is there) and **`summary_interval 4`** (a follower summary every 16 s: offset rms/max over the window, frequency, path delay) |
| `.../fpgamixer-ptp4l.service` (new) | `ptp4l -f /etc/fpgamixer/gptp.cfg -i end0`, after `end0` exists, `Restart=always` |
| `.../fpgamixer-phc2sys.service` (new) | `phc2sys -a -r -f /etc/fpgamixer/gptp.cfg`: follows ptp4l's port state; as follower steers `CLOCK_REALTIME` to the PHC, as grandmaster touches nothing |
| `.../fpgamixer-gptp_1.0.bb` (new) | installs the three, both units enabled, `RDEPENDS = linuxptp`, config as a conffile |
| `recipes-extended/images/edf-linux-disk-image.bbappend` | + `fpgamixer-gptp linuxptp-configs ethtool` |
| VM `build/conf/local.conf` | its `IMAGE_INSTALL:append = " linuxptp linuxptp-configs ethtool"` commented out ("moved into meta-fpgamixer"); backup `local.conf.pre-p9.1` |

**Design choices:**
- **The role is chosen by BMCA, not forced** (`slaveOnly` was the spike's method). Decision 2 wants the board as a follower now and as grandmaster eventually. With BMCA the same image does both: grandmaster is **one value** (`priority1` below 248), or simply no better clock on the link.
- **This is cheap only because of how the media clock is planned:** P9.3/P9.4 lock `mclk` to the **board's own PHC**. As follower the PHC carries the grandmaster's time; as grandmaster it *is* the reference. So the media clock never needs to know the gPTP role.
- **phc2sys is included now** because, as far as I know, the alsa-plugins AAF plugin expects the system clock synchronized to the PHC (**to verify in P9.6**, §9). It also gives the RTC-less board real time whenever the grandmaster's PHC carries it (on the Pi: `phc2sys` from its system clock to `eth4`, a bench step).

**Build (2026-09-26):** `bitbake fpgamixer-gptp` then the image, 14,840 tasks, all succeeded, the usual 23 warnings. Checked in the rootfs: `/etc/fpgamixer/gptp.cfg` (`priority1 250`, `summary_interval 4`, `transportSpecific 0x1`); `fpgamixer-{ptp4l,phc2sys}.service` enabled (links in `multi-user.target.wants`); linuxptp's `ptp4l@` / `phc2sys@` installed but **not** enabled; bitstream unchanged (`p9a5`, `4df4e23e…`). Image **`build/sd/p91-gptp-20260926.wic.xz`** (MD5 `2a5b89f2…`, same on both ends).

**First boot: the port stayed FAULTY. Found and fixed.**
- Pi: ptp4l healthy, MASTER after the board's reboot link flap; it never saw a foreign master. Board: `portState FAULTY`, `peerMeanPathDelay 0`, `gmPresent false`, gmIdentity = itself, for > 8 min. The link itself was up (SSH ran over it).
- Board journal, 12.7 s after boot: `driver rejected most general HWTSTAMP filter`, **`ioctl SIOCSHWTSTAMP failed: Invalid argument`**, then `INITIALIZING to FAULTY`.
- Cause, from the board kernel's source: `macb_hwtstamp_set()` returns `-EINVAL` when `!netif_running(dev)` (`macb_main.c:4232`), i.e. while `end0` is not administratively up. The unit started ptp4l as soon as the `end0` *device* existed, before the bench network brought it up. ptp4l sets hardware timestamping only once at start-up, and its fault recovery doesn't retry it, so the fault is permanent. The spike never hit this: ptp4l was always started by hand after `end0` was up.
- Confirmed: `systemctl restart fpgamixer-ptp4l` with `end0` up → **SLAVE, peerMeanPathDelay 459 ns** (the spike: 457.9 ns).
- **Fix:** `fpgamixer-ptp4l.service` gets `ExecStartPre=/usr/sbin/ip link set dev end0 up` (idempotent, independent of whatever configures addresses; carrier changes are ptp4l's own business). To be verified from a cold boot.

Side observation, not a board issue: the Pi's `phc2sys` (system clock → I350 PHC) swings ±10 µs with read delays alternating ~1 µs / ~19 µs, the Pi reading its I350 over PCIe. It only affects how closely the Pi's PHC follows its wall time, not gPTP on the link. To look at later.

**Bench (P9.1), 2026-09-26: PASS** (image `p91-gptp-20260926` + the fixed `fpgamixer-ptp4l.service` copied over by hand; the next image carries it).

| Check | Result |
|---|---|
| cold boot with the fixed unit | **SLAVE with no manual step**: `link down → FAULTY` at 9.6 s (no carrier yet), `link up → LISTENING` 13.8 s, new foreign master (the Pi) 17.7 s, **SLAVE at 20.2 s**, path delay 459 ns |
| **failover** (the Pi's ptp4l died when its SSH session closed) | board `SLAVE to MASTER on ANNOUNCE_RECEIPT_TIMEOUT_EXPIRES`, "assuming the grand master role", no configuration change: BMCA as decision 2 intends |
| **failback** (the Pi's ptp4l restarted) | 0.4 s later: `MASTER to UNCALIBRATED`, `UNCALIBRATED to SLAVE` |
| board time | real UTC (journal dates Sep 27 UTC, where it used to start at 2025-05-29): phc2sys `-a -r` works |
| **offset, Pi PHC not steered** (set once, below) | windows 3–7 after the failback: **2–3 ns RMS, 6–9 ns max**, frequency **−26.64 … −26.66 ppm ± 6 ppb**, path delay 459–460 ns. The spike: 3–4 ns RMS, 22 ns worst, ≈ −26 ppm, 458 ns |
| offset, Pi PHC steered by the Pi's `phc2sys` (the first run) | **2–3.6 µs RMS, up to 7 µs**, frequency −4 … −6 ppm ± 4–6 ppm: see the next paragraph |

**Why the first run was 1000× worse: the grandmaster's clock was being yanked, not the board.** The suggested Pi step `phc2sys -s CLOCK_REALTIME -c eth4 -w` steered the grandmaster's PHC continuously from the Pi's system clock. Its log shows the Pi reads the I350's PHC over PCIe in two modes, **~19.3 µs or ~1.0 µs**. With the delay steady at 19.3 µs the offset held at −5 … +60 ns; each flip between the modes jumped it by **±9–11 µs**, with the frequency correction swinging **+12 … +30 ppm** (phc2sys assumes the read sits in the middle of its window, and a 19 µs asymmetric PCIe read breaks that). The board followed faithfully. Its average correction, −5 ppm instead of −26, is the spike's −26 ppm plus the Pi's ≈ +21 ppm trim. **Bench recipe now:** set the Pi's PHC once and leave it free: `phc_ctl eth4 freq 0 set adj 37` (TAI), then `ptp4l -f …/gPTP.cfg -i eth4 -m`. If the Pi's PHC must follow its wall time later, `phc2sys -N` (several reads per update, the shortest kept) is the thing to try.

**Open:** a ≥ 20 min soak from boot (only ~1.5 min of clean windows were read); the bridge start-up log (still not read).

### 6.2 P9.3 proposal: measuring `mclk` against gPTP time (2026-09-26, awaiting decisions T1–T4)

#### Facts (checked 2026-09-26)

| Fact | Source | Consequence |
|---|---|---|
| `tsu_timer_cnt[93:0]` is "synchronized to tsu_clk"; ours is the **internal** IOPLL / 6 = 250 MHz reference. Upper 48 bits seconds, lower 46 ns / sub-ns. | UG1085 v2.5 (local copy; docs.amd.com was down), pp. 1059–1060; `.hwh` | Any PL use of the counter is a clock crossing from a 250 MHz clock the PL doesn't have. |
| **1PPS "can be obtained from the inverse of bit 45 … with any TSU clock source."** Bit 45 is the ns field's MSB (2²⁹ ns): the inverse rises exactly when the ns count wraps, i.e. **on every gPTP second**. | UG1085 p. 1061 | One wire carries the gPTP second boundary into the PL. It works in either gPTP role, since it comes from the board's own PHC. |
| Exporting the TSU clock (`fmio_gem_tsu_clk_to_pl_bufg` / `_from_pl`): the manual only says the loop is "recommended … whenever exposed". It **does not say** what `to_pl_bufg` carries with the internal-PLL source, or whether the TSU then depends on the PL. The internal source "required no additional signal connections". | UG1085 p. 1060; PS IP `bd.tcl` | Undocumented, a PS change (`psu_init`), and a possible boot-order dependency (the PS runs before the bitstream is loaded). **Not proposed.** |
| `tsu_timer_cmp_val`: high while the upper 70 bits equal a programmed value (≈ 256 ns granularity). | UG1085 p. 1060 | A second possible timing source, needs software to program the compare. Not needed now. |
| **The MMCM today:** 25 MHz × 40.625 / 82.625, VCO 1015.6 MHz → 12.2920 MHz = **+324.0 ppm**; fine phase shift **off**. One fine-phase step = VCO/56 = 17.6 ps. | `clk_wiz_audio_clk_wiz.v`; arithmetic | **M2a can't remove +324 ppm:** that needs **18.4 M steps/s**, more than the MMCM's phase-shift interface can do (a step takes ≈ 12 PSCLK cycles, so ≈ 8 M/s at a 100 MHz PSCLK; UG572, *from the documentation, to re-read*). |
| **Closest single-MMCM settings** from 25 MHz (search over D 1–106, M and O0 in ⅛ steps, VCO 800–1600 MHz): no setting within 5 ppm. **All-integer D = 1, M = 58, O = 118: VCO 1450 MHz, +11.03 ppm**; fractional D = 2, M = 123.125, O = 125.25: −6.17 ppm. | search script (this session) | With the integer setting, steering must cover +11 ppm plus the crystals' error (board vs Pi measured 26 ppm), about **±60 ppm = ~5 M steps/s** at 12.3 ps per step: feasible. Integer dividers also avoid any fine-PS restriction on fractional dividers (to verify in UG572). |

#### What P9.3 builds (measurement only; `mclk` is not touched)

```
 PS: tsu_timer_cnt[45] ──(inverted: 1PPS, rises on each gPTP second)──► PL
                                                                        │ 2FF (ASYNC_REG) into mclk
 mclk ─► free-running 32-bit cycle counter ─► captured on each PPS rise ─┤
         frame phase (LRCK counter, 0..255) ─► captured with it          │
                                                                         ▼
                   media_clock_meter (platform) ─► status window 0x8000_2000 ─► Linux
```

- **`media_clock_meter`** (new, platform layer: it measures the platform's clock and knows nothing about audio data): on each PPS rising edge it captures the free-running `mclk` cycle count and the frame phase (the 8-bit LRCK divider count), and counts PPS edges and "implausible intervals" (Δ outside ±1000 ppm, e.g. when ptp4l steps the PHC). Resolution: **±1 `mclk` (81 ns) per edge**, i.e. **±0.08 ppm per 1-second interval**, averaging down over longer windows.
- **Status window** (the generic `axil_stat_window` + reverse `coef_bank_handoff`, like the link's): ID `0x4D43_5001` ("MC"), CONFIG = the nominal cycles per second (12,288,000); words: PPS count, last capture, the capture before it, frame phase, implausible count. At **0x8000_2000**, the next free slot (the bus/DSP reservations move up one).
- **BD:** export `emio_enet0_enet_tsu_timer_cnt` (already a PS output) to the RTL. **No PS setting changes**, so `psu_init` stays identical (to be checked as in P9.A6). An XDC entry for the one-bit async input (the synchronizer's ASYNC_REG pair; the PS pin has no PL clock).
- **Software:** `mixer_hw.py mclk [seconds]`: frequency offset vs gPTP in ppm (per interval, and averaged), the frame phase at each second, implausible count.
- **Bench:** expected ≈ **+324 ppm vs the Pi's gPTP time, plus the PL crystal's own error** (unknown so far: the 26 ppm measured in the spike was the PS crystal); stable to ≪ 1 ppm over minutes; the frame phase at the PPS advancing by that offset × 1 s each second (324 µs ≈ 15.6 frames/s), a consistency check between the two captured values.

**Why this also serves P9.4 and the grandmaster role.** 48,000 frames per second is an integer, so the lock target is simple: `mclk` locked means **exactly 12,288,000 cycles per PPS and a fixed frame phase at the PPS**, so every gPTP second starts on a frame boundary. That is the AVB media-clock phase reference. It's the board's own PHC's PPS in either gPTP role.

#### Decisions needed (T1–T4)

| # | Question | Recommendation |
|---|---|---|
| T1 | Timing source: **1PPS from `tsu_timer_cnt` bit 45** into a 2FF synchronizer (no PS change, ±81 ns per edge), rather than exporting the TSU clock (undocumented, PS change) or the compare output (needs software)? | **1PPS.** A finer capture (the PPS timed with a faster PL clock) can come later if P9.4's numbers ask for it. |
| T2 | The PL only captures (cycle count, frame phase, counters); **frequency and phase are computed in software** from the status window? | **Yes.** 1 Hz data is easy in Linux, and nothing is lost. |
| T3 | New RO status window **`media_clock` at 0x8000_2000**, bus/DSP reservations moved up one slot? | **Yes.** |
| — | **Decided by the user, 2026-09-26: T1–T4 all as recommended.** | |
| T4 | **For P9.4, recorded now:** retune the MMCM to the integer setting (+11 ppm, VCO 1450 MHz) with fine phase shift enabled, as P9.4's first sub-step, and use P9.3's meter to confirm the ≈ 313 ppm change end to end before any steering. The loop itself: PL phase-stepping at a rate register, Linux running the PI loop on the 1 Hz captures (to decide in P9.4). | **Yes to the plan.** The retune changes `mclk` by 313 ppm, so the USB bridge's starting pitch (1000324) changes with it. |

### 6.3 P9.3: the media-clock meter: PASS (bench 2026-09-27)

**Bench (image `p93-mclk-20260926`, Pi as grandmaster with its PHC set once, not steered):**

| Check | Result |
|---|---|
| `mixer_hw.py info` | `mclk @ 0x80002000: media-clock meter, nominal 12288000 …` (ID `0x4d435001`, CONFIG `0x00bb8000`), next to the matrix and link windows |
| gPTP from the image's unit | SLAVE from boot, path delay 460 ns (the P9.1 fix confirmed from an image) |
| `mclk` | reference alive; 62 edges, **2 implausible, both at start-up** (the board's PHC stepped while ptp4l synchronized), none after |
| **`mclk 60`** | **mean +315.336 ppm** vs gPTP over 60 intervals; single intervals +314.209 … +315.674 ppm, neighbours mostly ±1 cycle (±0.08 ppm) |
| consistency | e.g. 12,291,879 cycles = 48,015 frames + 39 cycles: frame phase 228 → 11 and frames +48,016. The cycle, frame and phase captures agree every second |

**What was learned:**
- **The PL's 25 MHz crystal (the DP83867's) runs −8.66 ppm** against the grandmaster (the Pi's free-running I350): (1 + 315.336 ppm) / (1 + 324.0 ppm) − 1. First measurement of it; the spike's −26 ppm was the PS crystal, a different one.
- **Prediction for P9.4's retune** (nominal +11.03 ppm): the meter should read **≈ +2.4 ppm**, a 312.97 ppm step. The steering then only has to take out a few ppm plus drift.
- **Drift:** about **−0.5 ppm over the minute** (12,291,879 → 12,291,872 cycles), smooth, most likely warm-up of one of the crystals (the board had just been powered up).
- **A 2-second dip** at #80–81: −1.4 ppm, then back. The PPS comes from the board's PHC, which ptp4l steers, so a servo correction on the board is the likely cause. **To correlate with the ptp4l journal in P9.4**, whose loop has to ride through such events (filtering, or the `implausible` rule).

### 6.3.1 P9.3 implementation

| File | What |
|---|---|
| `src/rtl/media_clock_meter.sv` (new, platform) | generic: a 1PPS in (async), a frame strobe; 2FF + edge detect; free-running 32-bit `mclk` count; on each PPS edge captures count (and the previous one), frame count, frame phase; counts edges and implausible intervals (outside nominal ± 1000 ppm) |
| `src/rtl/media_clock_stat_regs.sv` (new, binding) | ID `0x4D43_5001`, CONFIG = 12,288,000; 7 words at 0x100 (PPS_COUNT, CYC_AT_PPS, CYC_AT_PREV, FRAMES_AT_PPS, PHASE_AT_PPS, IMPLAUSIBLE, CYC_NOW); `coef_bank_handoff` in reverse + `axil_stat_window`, as the link's |
| `constraints/media_clock_meter.xdc` (new, scoped) | false path into the synchronizer's first stage |
| `src/rtl/fpgamixer_top.sv` | under `INCLUDE_MCLK`: `u_mclk_meter` (PPS = `~tsu_timer_cnt[45]`, frame = `jb_rx_valid`) + `u_mclk_stat` |
| `scripts/create_project.tcl` | **new `phase9` variant** (= phase8 + `INCLUDE_MCLK`; phase8 still builds what it did): BD port `tsu_timer_cnt` ← `emio_enet0_enet_tsu_timer_cnt`, SmartConnect M03 → `M_AXI_MCLKSTAT` at 0x8000_2000, the scoped XDC. `current_phase = phase9` |
| `tools/mixer_hw.py` | `MediaClockHW` (+ `mclk_ppm`, `interval`, `ref_alive`), `WINDOWS["mclk"]`, CLI `mclk [seconds]` |
| `tools/test_mixer_hw.py` | 4 tests: words, interval across a 2³² wrap, ppm, reference not seen, wrong ID refused |
| `scripts/sim.mk` (`mclk`), `scripts/xsim_regress.ps1` | the new TB |

**`tb_media_clock_meter` (XSim): PASS.** A TSU model (250 MHz, ns counter, PPS = the inverse of its MSB, a "second" scaled to 1 ms so NOMINAL = 12,288) and two meters on one PPS, `mclk` at +296 ppm and +2.5 ppm (the ps timescale's nearest values):

| | Intervals | Mean (cycles) | Expected | Every interval |
|---|---|---|---|---|
| meter A | 39 | 12291.641 | 12291.656 | floor or ceil of expected |
| meter B | 39 | 12288.026 | 12288.031 | floor or ceil of expected |

Also checked: frame count × 256 + frame phase advances by exactly each interval (the captures agree); 0 implausible in steady running; **exactly +1** for a PHC step (+300 µs) and **+1** for a 2-second PPS dropout; the window reads back ID, CONFIG and all seven words. Mutants, all FAIL: the PPS taken as a level instead of an edge; `cyc_prev` not updated; no plausibility check; frame phase not reset on the strobe.

**Software:** `test_mixer_hw` + `test_mixer_state` on the VM: **32/32**. Mutant: `interval()` without the modulo 2³² → the wrap test fails.

**Regression:** `xsim_regress.ps1` **14/14**.

**Build `p93` (Vivado 2026.1, `phase9`):**

| | P9.A5 (`p9a5`) | **P9.3 (`p93`)** |
|---|---|---|
| WNS / WHS | +2.300 / +0.005 ns | **+2.762 / +0.010 ns**, 0 failing, methodology gate PASS, 0 critical warnings |
| DSP / RAMB18 | 1 / 1 | 1 / 1 |
| LUTs / FFs | 6865 / 12629 | 7057 / 13418 |
| CDC crossings | 1473 | **1715, all with exceptions**: the new window's snapshot (240 bank bits: 256 minus 16 constant zeros) + 2 toggles |

- **The PPS crossing** (checked on the routed checkpoint): the synchronizer's input is a LUT1 (the inverter) straight off the PS pin, which has no PL clock, so **no timed path ends at `pps_s1_reg/D`**. The false path has nothing to cut; it's a documented safeguard. Both synchronizer stages carry ASYNC_REG.
- **Image built 2026-09-26:** `gen-machine-conf` (exit 0) + bitbake, 14,840 tasks, all succeeded, 23 warnings (the usual). Checked: deployed bitstream MD5 = Vivado `p93` (`c6e4262e…`); rootfs has `mixer_hw.py` with `MediaClockHW` and the **fixed `fpgamixer-ptp4l.service`** (`ExecStartPre … end0 up`); the DTB has `M_AXI_MCLKSTAT@80002000`. Copied to **`build/sd/p93-mclk-20260926.wic.xz`** (MD5 `33828acc…`).
- **SDT** (`build/sdt`, the previous one kept as `build/sdt.p9a5`): **`psu_init.tcl` / `psu_init.c` / `zynqmp.dtsi` identical**, so exporting the counter changed no PS setting. The device tree gains `M_AXI_MCLKSTAT@80002000` (which `mixer_hw`'s presence guard needs) and its address-map entries.

### 6.4 P9.4a: the MMCM retune: PASS (bench 2026-09-27)

**Audio, by ear (user):** after re-routing, heard on the Pmods. `mixer_hw.py dump` first showed the reflash's identity bank; `mixer_hw.py set 0 4 0` and `set 2 5 0` (hardware only, not saved; COMMITS 2 and 3) routed USB 1 → JB_L and USB 2 → JC_L. So the codecs, the ODDR-forwarded Pmod clocks and the USB path all work with `mclk` moved by −313 ppm.

**Bench (image `p94a-retune-20260927`):**

| Check | Result |
|---|---|
| **`mixer_hw.py mclk 60`** | **mean +0.852 ppm** vs gPTP; single intervals +0.814 … +0.895 ppm (12,288,010–011 cycles); **48,000 frames per gPTP second** |
| vs P9.3 | +315.336 → +0.852: a step of **−314.49 ppm**, predicted −312.97 from the dividers. The −1.5 ppm left over is drift of the two crystals: P9.3's reading was still falling after power-up, and the Pi (the reference) had been rebooted, so its I350 was cold again. Not separable here, and it is the few-ppm range the loop absorbs |
| `link 10` (the Mac streaming) | 48,001.9 / 48,001.8 frames/s, 0 underruns, 0 starved, 0 overruns, 0 TID errors |
| audio on the Pmods | first silent: **the reflash reset the saved routing** (`mixer_state.json`), so the board seeded identity (no USB → Pmod routes). **Re-routed: heard** (above) |
| bridge start-up | both pitches start at **1000011** (the new `PITCH_START`). A settles smoothly (1000011 → 1000039 in a minute) |

**Findings along the way (none caused by the retune):**
- **The board's system clock went back to 1970.** The Pi had been rebooted and its ptp4l restarted **without** `phc_ctl … set`, so its PHC counted from 0, and the board's `phc2sys -a -r` set `CLOCK_REALTIME` from it (the bridge journal jumps from "Sep 27 20:10" to "Jan 01 00:10"). Harmless for audio. But **`phc2sys` trusts whatever time the grandmaster carries**: an open design item (a plausibility guard, e.g. never step the system clock to before the image's build date). Bench rule: after the Pi reboots, `phc_ctl eth4 freq 0 set adj 37` before ptp4l.
- **The Pi's ptp4l faulted repeatedly before its reboot:** `timed out while polling for tx timestamp` / `send peer delay response failed` / `rogue peer delay response` (the I350/igb TX-timestamp timeout, a known Linux issue). If it recurs, raise `tx_timestamp_timeout` in the Pi's config. Pi-side only.
- **USB bridge, direction B at start-up (open, a bridge issue, not P9.4):** while the Mac isn't reading yet (5 frames/s), the **coarse fix fires 30,052 times in 10 s**, i.e. it spins. After the Mac starts, B's pitch still swings (1000207 → 1000240 → 1000013 over a minute, queue +188 → −139 frames). The Phase 8 coarse-fix + hold change doesn't prevent the start-up swing. Needs its own look: detect an idle Mac and don't correct then; re-check the PI gains against a 1-period coarse band.

#### Build and changes

**UG572 checked first** (docs.amd.com, "Dynamic Phase Shift Interface in the MMCM", read 2026-09-27): each PSEN pulse shifts the selected outputs by **1/56 of the VCO period**; a shift takes **exactly 12 PSCLK cycles** (PSDONE); the outputs "gradually drift … in a linear fashion" (no step at the pins); **no maximum** shift (it wraps). So one step every 12 PSCLK cycles is the rate limit (≈ 8.3 M steps/s at 100 MHz). The fractional-divide page wasn't reachable (the site was partly down); it doesn't matter, since the dividers are now integers.

| Change | What |
|---|---|
| `scripts/create_project.tcl` | `clk_wiz_audio` **forced to D = 1, M = 58, O = 118** (VCO 1450 MHz, 12.28814 MHz, **+11.03 ppm** nominal; fine-phase step 12.3 ps). The wizard ignores direct divider values ("disabled parameter"), and asking for 12.288136 MHz gets the same ratio as fractional 43.5 / 88.5 (VCO 1087.5 MHz), so it's set in **override mode** (`OVERRIDE_MMCM`). Both tried in a throwaway project first |
| `src/rtl/audio_clocking.sv` | header: the new setting and the measured history |
| `fpgamixer-usb-bridge.c` | `PITCH_START` 1000324 → **1000011** (the new nominal), so the Mac doesn't start 313 ppm off |

**Deviation from T4, recorded:** fine phase shift is **not enabled yet**. Enabling it adds the PSCLK/PSEN/PSINCDEC/PSDONE ports, and which clock drives PSCLK is a design choice for the steering step: `pl_clk0` (100 MHz, up to ≈ 100 ppm of correction, PS builds only) or `mclk` itself (one step per 12 cycles ≈ 1 M steps/s × 12.3 ps ≈ **12 ppm** of correction, enough now that only a few ppm are left, and present in every build). So it moves to P9.4b, with the loop.

**Build `p94a`:** the generated MMCM has `DIVCLK_DIVIDE 1`, `CLKFBOUT_MULT_F 58.000`, `CLKOUT0_DIVIDE_F 118.000`. **WNS +2.762 / WHS +0.010 ns** (the worst path is still the codec RX-sampling check), methodology PASS, 0 critical warnings. The timing engine derives `mclk` as 81.379 ns. **Jitter, from Vivado's clock analysis** (the wizard's own figure isn't recomputed in override mode): discrete jitter **289 → 187 ps**, `mclk` clock uncertainty **149 → 100 ps**. The higher, integer-ratio VCO is cleaner. CDC 1715, all constrained (unchanged). SDT: only `firmware-name` differs from P9.3's (`psu_init` identical).

**Image built 2026-09-27** (after the VM had been stopped by the user for memory; the first sync attempt timed out and was redone): 14,840 tasks, all succeeded, 23 warnings (the usual). Deployed bitstream MD5 = Vivado `p94a` (`28a94771…`); `fpgamixer-usb-bridge` recompiled in this build (`do_compile: Succeeded`, with the synced `PITCH_START 1000011`). **`build/sd/p94a-retune-20260927.wic.xz`** (MD5 `57f99068…`).

**Prediction for the bench:** the meter reads **≈ +2.4 ppm** (+11.03 nominal, −8.66 for the PL crystal vs the Pi), i.e. **312.97 ppm below P9.3's +315.34**, modulo the crystal's drift. The USB path should work as before, with the bridge's pitch settling ~313 ppm lower than before (≈ 1000030 instead of ≈ 1000345).

### 6.5 P9.4b proposal: steering `mclk` onto gPTP (2026-09-27, awaiting decisions S1–S5)

#### Facts (checked 2026-09-27)

| Fact | Source | Consequence |
|---|---|---|
| Fine phase shift: 1/56 VCO per step (**12.3 ps** at 1450 MHz), **12 PSCLK cycles** per step, gradual (linear) at the outputs, no maximum (wraps) | UG572 (§6.4) | A continuous stream of steps is a frequency offset: **Δf/f = steps/s × 12.3 ps**. Stepping is **glitch-free**, as the codecs need. |
| **PSCLK: 0.01–450 MHz** in the slowest grade (up to 550); **VCO 800–1600 MHz** in every grade | DS925, "MMCM Switching Characteristics" (read 2026-09-27) | Any of the PSCLK candidates below is legal. Max slew = PSCLK / 12 × 12.3 ps. |
| **In override mode, `USE_DYN_PHASE_SHIFT` alone adds the PS ports but selects no output**: the generated MMCM had `CLKOUT0_USE_FINE_PS("FALSE")`. Forcing `MMCM_CLKOUT0_USE_FINE_PS` → `"TRUE"`. | throwaway project, generated `*_clk_wiz.v` | **A silent trap:** the ports would exist and steering would do nothing. The build script must force it and print it; the bench proves it by the meter moving. |
| After P9.4a, `mclk` is **+0.85 ppm** vs the bench grandmaster (drifting by tenths of a ppm per minute after power-up). | §6.4 | On this bench the loop has to take out ≈ 1 ppm. A different grandmaster can need much more: 802.1AS allows a clock **±100 ppm** off nominal (*as I recall the standard; not re-read*), and our own crystal adds its part. |
| The meter (P9.3) gives, every gPTP second: the cycle count (frequency, ±0.08 ppm) and the **frame phase at the second** (±1 `mclk` = 81 ns). | §6.3 | The loop can lock **phase**, not just frequency. |

#### What P9.4b builds

```
  Linux: fpgamixer-mediaclock (1 Hz)             PL (pl_clk0 domain)                   MMCM
  reads the meter (frame phase + interval) ──►  rate register ──► NCO ──PSEN/PSINCDEC──► CLKOUT0 phase
  PI on the phase error at the gPTP second      (steps per second,   one step per ≥ 12     (fine PS)
  writes the step rate                           signed)              PSCLK, waits PSDONE
        ▲                                                                                    │ mclk
        └───────────────── media_clock_meter (P9.3): frame phase at each 1PPS ◄─────────────┘
```

- **`media_clock_steer`** (new, platform): a signed step-rate register drives a phase accumulator (NCO) in the PSCLK domain. On each overflow it issues one PSEN with PSINCDEC = the sign, and waits for PSDONE before the next. Positive rate = the phase increments = `mclk` slower. Rate resolution (32-bit fraction at 100 MHz) ≈ 0.02 steps/s ≈ 3·10⁻⁷ ppm: negligible. It counts steps issued and PSDONEs seen (status), and saturates at the hardware maximum.
- **The loop in Linux** (`fpgamixer-mediaclock`, a small Python service using `mixer_hw`): once per new PPS capture, phase error = frame phase at the second − target, frequency error from the interval, a PI with a bandwidth of about 0.02 Hz (a minute-scale time constant, well above the ±81 ns measurement noise), then a new rate. It uses the meter's `implausible` counter: a PHC step or a lost PPS **freezes the rate (holdover)** and re-acquires phase. Logs one line per 10 s (phase error, rate in ppm, state), like the bridge.
- **The lock target (S4):** every gPTP second begins at the same point of the frame grid, so 48,000 frames per gPTP second exactly and a fixed frame phase at the second. That's the AVB media-clock relationship (sample *n* ↔ gPTP time *t₀ + n/48000*). It holds in either gPTP role, since the PPS is the board's own PHC.
- **Nothing downstream changes:** USB follows `mclk` through the bridge, the Pmods are on `mclk`, the core never sees a foreign clock. The network *disciplines* the box's one clock.

#### Decisions needed

| # | Question | Recommendation |
|---|---|---|
| S1 | **PSCLK:** `pl_clk0` (100 MHz → ±102 ppm max slew, **corrected in P9.4b1 to ±88 ppm**: a step takes 14 PSCLK cycles, not 12, see §6.6; PS builds only, where gPTP exists anyway; the rate register is written in that same domain, so no new crossing), `mclk` (**±12 ppm**, every build, but not enough for a ±100 ppm grandmaster), or a second MMCM output at a few hundred MHz (±300 ppm, one more clock domain)? | **`pl_clk0`.** Non-PS builds tie PSEN low (no gPTP there to lock to). |
| S2 | **Where the rate register lives:** a new generic **RW register window** (`axil_reg_window`: the common header + plain RW words used in the AXI domain, no commit, since a single word needs no bank semantics), as the steering block's own window at **0x8000_3000** (bus/DSP reservations move up again)? Or add writable words to the meter's read-only window? | **New generic RW window, own slot.** It keeps "read-only status" and "control" as two window types, each reusable. |
| S3 | **The loop in Linux (1 Hz PI), the PL only an NCO**? The alternative is the whole loop in the PL. | **Linux.** 1 Hz data, easy to tune and log, holdover and re-acquire in plain code; the PL part stays tiny. The loop can move to the PL later if a front door ever needs it without Linux. |
| S4 | **Lock phase** (a fixed frame phase at every gPTP second), not just frequency? | **Yes, phase.** Costs nothing extra and is what AVB needs. The target frame phase is a configurable constant (default: the frame boundary). |
| S5 | **Loss of reference** (PPS gone, PHC stepped, ptp4l restarting): hold the last rate (holdover), re-acquire when valid again; never step `mclk`'s phase abruptly (only slew, at most the S1 limit)? | **Yes.** A phase jump would be an audible glitch; a slew isn't. |

**Decided by the user, 2026-09-27: S1–S5 all as recommended** (PSCLK = `pl_clk0`; a new generic RW window; the loop in Linux; phase lock; holdover, slew only).

**Steps:** P9.4b1 RTL (steerer + RW window + MMCM fine PS forced and printed) with a TB (an MMCM phase-shift model: steps → phase → a frequency the meter sees); P9.4b2 build + image; P9.4b3 the service and the bench: lock from boot, phase error at the second vs time, rate converging to ≈ −0.85 ppm on this bench, audio unaffected, holdover through a Pi ptp4l restart.

### 6.6 P9.4b1: the steering hardware (simulation): PASS

| File | What |
|---|---|
| `src/rtl/media_clock_steer.sv` (new, platform) | signed RATE (2⁻³² steps per PSCLK cycle) → a 32-bit phase accumulator → step requests into a signed backlog (opposite requests cancel, saturates at ±255, the excess counted as DROPPED) → one PSEN at a time, the next on the same edge that sees PSDONE. **RATE > 0 = increments = `mclk` slower.** Held in reset while the MMCM isn't locked (2FF on LOCKED). Counts completed increments and decrements |
| `constraints/media_clock_steer.xdc` (new, scoped) | false path into the LOCKED synchronizer |
| `src/rtl/axil_reg_window.sv` (new, generic) | **the third window type** (decision S2): the common header, RW words (per-byte WSTRB, reset values), RO words, 0x00C = accepted writes; AXI clock only, no commit, no crossing |
| `src/rtl/media_clock_ctrl_regs.sv` (new, binding) | ID `0x4D53_5001`, CONFIG = PSCLK Hz; RATE (RW); STEPS_INC, STEPS_DEC, DROPPED, FLAGS (locked, busy), VCO_HZ, PS_DIV (RO), so software converts ppm with what the hardware reports |
| `src/rtl/audio_clocking.sv`, `src/sim/clk_wiz_audio_stub.sv` | the MMCM's `psclk/psen/psincdec/psdone`. The stub answers the handshake (PSDONE 12 cycles after PSEN) with no clock effect |
| `src/rtl/fpgamixer_top.sv` | under `INCLUDE_MCLK`: `u_mclk_steer` on `ctrl_aclk` (= PSCLK), `u_mclk_ctrl`; otherwise PSEN tied low |
| `scripts/create_project.tcl` | `USE_DYN_PHASE_SHIFT` + **`MMCM_CLKOUT0_USE_FINE_PS` forced, printed, and checked** (the script stops if it isn't set: the override-mode trap, §6.5); SmartConnect M04 → `M_AXI_MCLKCTRL` at **0x8000_3000**; the scoped XDC |
| `tools/mixer_hw.py` | `MediaClockSteerHW` (ppm ↔ RATE from CONFIG / VCO_HZ / PS_DIV; the user-facing sign is **+ppm = `mclk` faster**, the opposite of RATE; clamps at the maximum), `WINDOWS["mclkctl"]`, CLI `steer [ppm]` |
| `tools/test_mixer_hw.py` | 4 tests: geometry and the maximum, sign and scale (±50 ppm = RATE ∓174,375,672, as in the TB; the first version of this test expected ∓174,37x, off by 1000, and failed on the VM: the test was wrong, the code right), round trips, clamping, wrong ID |

**`tb_media_clock_steer` (XSim): PASS.**

| Part | Result |
|---|---|
| window | ID, CONFIG = 100 MHz, VCO_HZ = 1.45 GHz, PS_DIV = 56; **WSTRB** (bytes 0 and 2 → `11BB33DD`); a RO word not writable; WRITES +2 |
| not locked | a nonzero RATE gives **no PSEN**; FLAGS.locked 0 → 1 after lock |
| rate → steps | +1/64 per cycle: **1000** in 64,000 cycles, increments only; −1/64: **1000** decrements; the +50 ppm rate: **8120** in 200,000 cycles (computed 8120.0) |
| saturation | RATE = +½: **10,000 steps in 140,000 cycles = one per 14**, DROPPED counting |
| protocol (every cycle) | PSEN never longer than one cycle, never during a step in flight, never while unlocked |
| **end to end** (an MMCM model moving its edges 12.315 ps per completed step, the real `media_clock_meter`, a TSU-model 1PPS) | rate 0: 12288.125 cycles per (scaled) second; **+50 ppm of steps: −48.8 ppm; −50 ppm: +50.9 ppm** (±4.1 ppm is the quantization of the 40-interval means). Sign and scale confirmed through the meter |

**Mutants, all FAIL:** direction inverted (wrong-direction steps, 10 errors); not waiting for PSDONE (60,088 "PSEN in flight"); not gated by LOCKED (197,051 "PSEN while not locked"); the negative rate's magnitude wrong (−1/64 gave 4571 steps).

**Found by this TB: the maximum slew is ±88 ppm, not ±102.** A step can't start until PSDONE has pulsed, so one step takes **14** PSCLK cycles (PSEN, 12, PSDONE, then PSEN), not 12. The first version also needed a cycle to see PSDONE (one per 15, 8667 steps where 10,000 were expected); fixed to reissue on the PSDONE edge. At 100 MHz: 7.14 M steps/s × 12.315 ps = **±87.97 ppm**. The proposal's S1 row is corrected. Consequence: a grandmaster more than ~±85 ppm from our crystal can't be followed at 100 MHz. 802.1AS's ±100 ppm is the worst case, not the typical one; if it's ever needed, a faster PSCLK (an MMCM output at a few hundred MHz, DS925 allows 450) would do it.

**Regression:** `xsim_regress.ps1` **15/15** (the integration TBs with the new MMCM ports).

**Not run yet:** the Python tests of `mixer_hw` (they need Linux; the build VM was off; they run before the image is built).

**Build `p94b` (`phase9`):** `clk_wiz_audio forced: D=1 M=58.000 O=118.000 dyn_ps=true clkout0_fine_ps=true`. **WNS +2.717 / WHS +0.010 ns**, methodology PASS, 0 critical warnings; 1 DSP, 1 RAMB18, 7505 LUTs; CDC 1715, all constrained (LOCKED into the steerer has no PL clock: not in the report, like the PPS). **Checked on the routed checkpoint:** the implemented MMCME4 has `CLKOUT0_USE_FINE_PS=TRUE`, M 58, O 118; PSCLK = `clk_pl_0`; PSEN (slack 8.185 ns), PSINCDEC (8.109 ns) and PSDONE (7.117 ns) are **timed** on `pl_clk0`. SDT: `psu_init` identical; the DT gains `M_AXI_MCLKCTRL@80003000`.

**Image built 2026-09-27:** 14,859 tasks, all succeeded, 23 warnings (the usual). Deployed bitstream MD5 = `p94b` (`d83bddea…`); the rootfs has `mediaclock.py` + `fpgamixer-mediaclock.service` **without an enable link** (installed, disabled), `mixer_hw.py` with `MediaClockSteerHW`; the DTB has `M_AXI_MCLKCTRL@80003000`. **`build/sd/p94b-steer-20260927.wic.xz`** (MD5 `842f6651…`).

### 6.6.1 P9.4b bench (2026-09-27, image `p94b-steer-20260927`): open loop PASS, closed loop LOCKED

**Open loop** (`mixer_hw.py steer`, the meter over 20 s each):

| Setting | Measured | Implied baseline (measured − setting) |
|---|---|---|
| none | **+0.960 ppm** | +0.960 |
| `steer 2` (+2 ppm, faster) | **+2.913 ppm** | +0.913 |
| `steer -2` | **−1.139 ppm** | +0.861 |

Against the first baseline the steps look like +1.953 / −2.099 ppm ("fairly close, not exact"). But the implied baseline falls steadily, by ≈ 0.05 ppm per window: the crystals' drift (as in P9.3/P9.4a). **Against that drift both steps are 2.00 ppm**; the full swing is 4.052 ppm for 4 commanded. Sign: `+2` issued **decrements** (4,879,904 counted), `−2` **increments** (42,779,585), **0 dropped**. The window reports `step 12.315 ps, max +/-88.0 ppm`, MMCM locked. Sign and scale are confirmed on hardware, not only in the model.

**Closed loop** (`systemctl start fpgamixer-mediaclock`, started with the −2 ppm left from the test):

| Time | State | Freq error | Phase error | Correction |
|---|---|---|---|---|
| +5 s | ACQUIRE → **LOCKED** | | | |
| +11 s | LOCKED | +0.651 ppm | −19 cycles (−1546 ns) | −0.297 ppm |
| +21 s | | +0.081 | +10 (+814 ns) | −0.786 |
| +41 s | | −0.081 | +2 (+163 ns) | −0.763 |
| +51 s | | −0.081 | **0** | −0.740 |
| +61 s … +162 s | | 0 ± 0.081 (the meter's ±1 cycle) | **−1 … −3 cycles (−81 … −244 ns)** | −0.720 → −0.522 |

- **Locked in 5 s; phase inside ±3 cycles (±244 ns) after ≈ 40 s**, held there for the 2.5 minutes read.
- The correction walked from −0.81 to −0.52 ppm: the loop **tracking the crystals' drift** (≈ −0.1 ppm/min, the same drift the open-loop baseline showed).
- The standing **−2 cycles** is the type-2 loop's predicted ramp error: 0.1 ppm/min × TAU (5 s) × 4 TAU (20 s) ≈ 170 ns ≈ 2 cycles (§6.7). Exactly as designed; a longer TAU would grow it.
- With the loop running: `link 10` 48,001.9 / 48,001.9 frames/s, 0 underruns / starved / overruns / TID errors.
- **By ear with the loop locked (user): the Pmods played cleanly** throughout the steering test.

Pi side: ptp4l as grandmaster with its PHC set once (`phc_ctl eth4 freq 0 set adj 37`). Its log's "selected best master clock 00183e…" (the board) followed by "assuming the grand master role" is linuxptp naming the best *foreign* record before its state decision keeps the local clock as GM, not a role change.

### 6.6.2 P9.4b holdover and soak (2026-09-27): PASS. **P9.4 done.**

Same image; the loop service started by hand (not yet enabled at boot in this image); audio from the Mac on the Pmods throughout.

**Holdover, part 1: the grandmaster lost for ~1 min, then back.** No loop state change at all (as designed: the 1PPS keeps coming from the board's own PHC, which ptp4l leaves running at its last rate when the board takes over as grandmaster, and slews when it follows again).

**Holdover, part 2: a reference step.** The Pi's ptp4l stopped, its PHC re-set (a jump of milliseconds, since it had been running free), ptp4l restarted. The board's ptp4l **stepped** its PHC on re-syncing:

| Time | Event |
|---|---|
| 21:55:43 | LOCKED, phase −1 cycle, correction −0.205 ppm |
| **21:55:48.15** | **LOCKED → HOLDOVER** (an implausible interval); correction **frozen at −0.1836 ppm** (the last good second's value) |
| **21:55:54.17** | **HOLDOVER → ACQUIRE** after **6 s** |
| 21:56:03 | ACQUIRE: frequency error −1.628 ppm, phase +53 cycles (+4.3 µs), correction +1.276 ppm |
| **21:56:09** | **ACQUIRE → LOCKED**, 15 s after holdover ended |
| 21:56:13 → 21:57:04 | phase +37 → −9 → −10 → −6 → −4 → −2 cycles |
| 21:57:34 | phase **0**, about 100 s after the step; ±1 cycle from then on |

- **By ear (user): no glitches** throughout, as S5 intends: `mclk` was only slewed (the largest correction was +1.28 ppm).
- `link 10` afterwards: 48,001.5 frames/s each way, 0 underruns / starved / overruns / TID errors.
- **Observation, not a fault:** during ACQUIRE the frequency error read −1.6 ppm. That wasn't `mclk` drifting: straight after a step, ptp4l's servo on the board is still settling the PHC's frequency, so the reference itself moved for a few seconds and the loop followed it. **Possible refinement:** enter ACQUIRE only after a few consecutive plausible and *consistent* intervals. Not needed now.

**Soak: 60 minutes** (after the holdover test):

| | Result |
|---|---|
| loop state | LOCKED all hour, apart from the one part-2 sequence (HOLDOVER → ACQUIRE → LOCKED); 358 ten-second samples |
| phase | **−1 … +1 cycles (±81 ns) in steady state**, the meter's own floor; −10 … +53 over the whole hour including the re-acquisition |
| correction | settled at **+0.02 … +0.07 ppm** (it had been −0.5 ppm an hour earlier: the crystals had finished warming up); −0.94 … +1.28 over the hour including the re-acquisition |
| gPTP | 16-s summaries **2–4 ns RMS, 7–10 ns max**, path delay 458–459 ns, frequency ≈ −26.86 ppm: the spike's numbers. (A one-line awk over the hour reported "worst 4.99 ms RMS / 30.9 ms max": the one window straight after the Pi's PHC reset, before the step. Expected; the command didn't exclude it.) |

### 6.7 P9.4b3: the loop (`fpgamixer-mediaclock`), written; on hardware after the open-loop test

| File | What |
|---|---|
| `tools/mediaclock.py` (new) | `MediaClockLoop`, the control law **with no I/O** (fed one reference second at a time), and the service around it (`mixer_hw` windows `mclk` + `mclkctl`, 5 Hz poll, one update per new PPS capture, a log line every 10 s). States **ACQUIRE** (remove 80 % of the measured frequency error per second until < 0.2 ppm for 3 s) → **LOCKED** (a type-2 PI on the phase error: `u = u_int − e/TAU`, `u_int −= e/(TAU·4TAU)`) ↔ **HOLDOVER** (an implausible interval or no PPS for 1.5 s: the correction is frozen, S5; back to ACQUIRE when valid). Clamped at 95 % of the hardware maximum. `--tau`, `--target`, `--dry-run`, `-v` |
| `tools/test_mediaclock.py` (new) | against a simulated `mclk` whose meter captures carry the real ±1-cycle quantization, the correction applied one second late as on the board; runs anywhere (no mmap) |
| `recipes-apps/fpgamixer-mediaclock/` (new) | the script (from `tools/`, like `fpgamixer-osc`) + a unit, **installed but not enabled** until the loop has passed the bench |

**`test_mediaclock`: 8/8 on this PC.** From this bench's +0.852 ppm with the frame grid anywhere: LOCKED in < 30 s, correction → −0.852 ppm (±0.01), phase within **±2 cycles (±163 ns)** over the last 100 s; no overshoot beyond 1.3× the initial error; a +50 ppm offset locks at −50 ppm; −0.5 ppm/min drift held within 12 cycles (< 1 µs); holdover freezes the correction bit-exactly for the 10 invalid seconds and re-locks; +200 ppm clamps at 80 ppm without claiming lock; a target phase of 100 is held. **Mutants, all FAIL:** phase sign flipped (4 failures), holdover zeroing the correction (1), no phase wrap (3), acquisition sign flipped (4 + 2 errors). (A first mutation run was invalid, since Python reused a cached bytecode of the previous mutant, betrayed by the baseline failing too. Rerun with `PYTHONDONTWRITEBYTECODE=1` and a fresh directory per mutant.)

**Found while testing: TAU had to come down from 20 s to 5 s.** A type-2 loop follows a frequency *ramp* only with a standing phase error of ramp × TAU × 4 TAU. The crystals drift about −0.5 ppm/min after power-up (P9.3), which at TAU = 20 s needs 13 µs, more than half a frame, so the loop slipped (max error 127 cycles). At TAU = 5 s: 11 cycles (0.9 µs) under that drift, and still ±1 cycle (the meter's floor) when steady; 10 s gives 41 cycles.

### 6.8 P9.5 plan: link #2 and a 20 × 20 core (2026-09-27, awaiting decisions L1–L5)

The AVB front door's PL half is a **second PS↔PL link**: the same Audio Formatter + `pcm_link` + status window as Phase 8's, giving a second ALSA card for the AAF talker/listener and the AVB bridge (P9.6/P9.7). Nothing in it is AVB-specific. Its channels are appended as core channels **12–19** (decision 6), so the core grows to **20 × 20**, which the time-shared matrix does on **2 DSP48E2s** (D = 227 cycles, `tb_pcm_matrix_rect` already covers 20 × 20, §5.5).

#### Checked in the tree (2026-09-27)

| Fact | Where | Consequence |
|---|---|---|
| **The ALSA machine driver hard-codes the card name** (`card.name = "FPGAmixerLink"`, DAI link "FPGAmixer link"). A second instance would register a second card with the same name, and ALSA would rename one (`…_1`) in probe order. | `recipes-kernel/fpgamixer-link-card/files/fpgamixer-link-card.c` | **Phase 8's note that the driver was "written for N instances from the start" is wrong** (§9.2 of the Phase 8 doc). A small driver change is needed: the name from the device tree (L2). |
| The formatter's two IRQs go through a 2-port `xlconcat` into `pl_ps_irq0` (8 bits wide); its DMA masters through a 2-slave SmartConnect into `S_AXI_HPC0_FPD`; `aud_mclk` / `aud_mreset` come from the RTL's `link_mclk` / `link_mreset` ports. | `create_project.tcl` | Link #2: `xlconcat` → 4 ports, DMA SmartConnect → 4 slaves, **the same `link_mclk`** (the formatter runs on `mclk`, now gPTP-locked, so card #2 runs at the network's media rate, as AAF needs). **No PS setting changes** (`pl_ps_irq0` and HPC0 are already enabled); `psu_init` should stay identical (to verify). |
| `system-user.dtsi` says "the real mclk is 12.2919 MHz" | the card node's comment | stale since P9.4a: fix in passing |
| `crosspoint_restore_test.py`: `N = 12`, 144 levels; `osc_mixer_server.py` simulator `--matrix-size` default 12 | `tools/` | grow to 20 / 400; the hardware path already reads the size from the matrix window's CONFIG |
| `MatrixBackend.seed_and_push` fills only missing crosspoints and reads N from CONFIG | `tools/osc_mixer_server.py` (Phase 8 migration test) | a saved 12 × 12 state keeps all 144 values at their indices on a 20 × 20 core; the 256 new ones are seeded |

#### What P9.5 builds

| Piece | Change |
|---|---|
| `create_project.tcl` (`phase9`) | `link2_formatter` (8 + 8, as #1) on control SmartConnect **M05** at **0x8011_0000** (driver-owned range); its DMA on the shared SmartConnect (4 slaves); IRQs on the concat (4 ports); ports `M_AXIS_LINK2_MM2S`, `S_AXIS_LINK2_S2MM`, `M_AXI_LINK2STAT` (M06, **0x8000_4000**) |
| `fpgamixer_top.sv` | `u_link2` (`pcm_link`, generic, unchanged) + `u_link2_stat` (`pcm_link_stat_regs`, unchanged); **N = 20**, channel map `{link2, link, jc, jb}`; identity reset bank 20 × 20; `matrix_lanes(20,20)` = 2 |
| `fpgamixer-link-card.c` | card and DAI-link names from an optional DT property (L2); default unchanged, so link #1 stays `FPGAmixerLink` (the USB bridge opens it by name) |
| `system-user.dtsi` | a second card node (`fpgamixer_link2`, name `FPGAmixerLink2`) + `xlnx,tx/rx` on `&link2_formatter` |
| `tools/` | `mixer_hw.WINDOWS["linkstat2"]` + `mixer_hw.py link [2] [s]`; restore test at 20 × 20 (400 levels; the audio analysis stays the 64 USB → USB); simulator default 20 |
| docs | `architecture_modules.md` (address map, channel map, file map), this doc |

**Verification:** `xsim_regress` (the integration TBs at 20 × 20); Vivado (2 DSP, timing, CDC = Phase 8's link structures ×2, methodology gate), SDT (`psu_init` identical; the DT gains the second formatter); image; **bench**: two cards (`aplay -l`), `speaker-test -D plughw:FPGAmixerLink2 -c 8` routed to the Pmods by ear, link #2 counters clean, **link #1 / USB unchanged**, the media-clock loop still locked, the restore test at 400 crosspoints across a power pull.

#### Decisions needed

| # | Question | Recommendation |
|---|---|---|
| L1 | Link #2 = a second instance of Phase 8's link (formatter + `pcm_link` + status window), no new RTL? | **Yes.** |
| L2 | Card naming: a DT property on the card node (e.g. `fpgamixer,card-name`) giving the ALSA card and DAI-link names, default `FPGAmixerLink`; link #2 = **`FPGAmixerLink2`**? | **Yes.** Names are stable whatever the probe order, and link #1 keeps its name. |
| L3 | Addresses: formatter #2 at **0x8011_0000**, link #2 status at **0x8000_4000**, reservations moved to 0x8000_5000? | **Yes.** |
| L4 | Seeding the 256 new crosspoints: **identity** (AVB in *k* → AVB out *k*, a network loopback for bench tests, the same rule as USB), or all off? | **Identity**: one rule for the whole matrix; a saved state overrides it. |
| L5 | The `phase9` build variant grows to include link #2 (rather than a new `phase9b`)? | **Yes.** `phase9` is the branch's working variant; `phase8` stays as it was. |

**Decided by the user, 2026-09-27: L1–L5 all as recommended.** Implementation moves to a fresh session (opening prompt: `docs/prompt_phase9_p95.md`).

### 6.9 P9.5a: link #2 in the RTL and the BD, core 20 × 20 (simulation + Vivado): clean

Seams used: **front door** (a second `pcm_link`, unchanged), **control plane** (a second `pcm_link_stat_regs` window, unchanged), **platform** (the channel map and the BD). No new RTL module; the core's interface didn't change, only its size.

| File | What |
|---|---|
| `src/rtl/fpgamixer_top.sv` | `N_LINK2 = 8`, **N = 4 + 8 + 8 = 20**; channel map `{link2, link, jc, jb}`; under the new define **`INCLUDE_LINK2`**: `u_link2` (`pcm_link`, same parameters and frame strobe as `u_link`) and `u_link2_stat` (`pcm_link_stat_regs`), the BD ports `M_AXIS_LINK2_MM2S`, `S_AXIS_LINK2_S2MM`, `M_AXI_LINK2STAT`. Without it (non-PS builds, `phase8`) `link2_rx = 0`, so the core is 20 × 20 in every build. The identity reset bank, `LANES` (= 2) and the coefficient store's size all follow from N through the existing functions |
| `scripts/create_project.tcl` | `phase9` gains `include_link2` (decision L5). The formatter's BD code moved into a proc, **`add_link_formatter`**, called for link #1 (same cell, ports, SmartConnect port and address as before) and for `link2_formatter`: M05 at **0x8011_0000**; DMA on `link_dma_smc` slaves S02/S03 (4 slaves); IRQs on `link_irqs` In2/In3 (4 inputs) into `pl_ps_irq0`; the **same `link_mclk` / `link_mreset`**. `M_AXI_LINK2STAT` on M06 at **0x8000_4000** (decision L3). Control SmartConnect 5 → 7 masters. Define set `INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK INCLUDE_LINK2` |

**Simulation.** `xsim_regress.ps1`: **ALL PASS, 15/15**. The two integration TBs (`tb_phase3_datapath`, `tb_phase3_dynamic`: the whole non-PS top) now run the 20 × 20 core: a probe compiled against the same files printed **`N=20 LANES=2 D=227`** for the elaborated top (not a stale 12 × 12), and `tb_phase3_dynamic` prints the same `locked: JB_L=100005 JB_R=200005 JC_L=300005 JC_R=400005` as before, so the Pmod path's latency is unchanged at D = 227 (≤ 250, §2.1). `tb_pcm_matrix_rect` already covered 20 × 20 bit-exact (§5.5). **What simulation can't see:** link #2's channels are silent in every simulated build (it needs the BD), so the `{link2, link}` order is checked only on the bench; `pcm_link` itself is unchanged and covered by `tb_pcm_link`.

**Build `p95`** (Vivado 2026.1, `phase9`; logs `build/p95_{create,build}.log`, reports `build/p95_*.rpt`, XSA `build/fpgamixer_p95.xsa`):

| | P9.4b (`p94b`) | **P9.5 (`p95`)** |
|---|---|---|
| WNS / WHS | +2.717 / +0.010 ns | **+2.505 / +0.004 ns**, 0 failing endpoints; methodology gate **PASS**, 0 critical warnings |
| worst setup path | the codec RX-sampling check | the same (`fwd_sclk_jb_ad` → `mclk`, the razor since Phase 3.5); `pl_clk0` alone +5.048 ns, `mclk` alone +76.2 ns |
| **DSP48E2** | 1 | **2** (both `pcm_matrix` lanes: dynamic OPMODE, MREG + PREG, 48-bit P, as planned) |
| RAMB18 | 1 | **3**: the two lane banks (512 × 18 each, written on `pl_clk0`, read on `mclk`) and the shadow (400 × 18; at 144 words it had been LUTRAM) |
| LUTs / FFs | 7505 / 13707 | **12,633 / 22,877** (17.9 % / 16.2 %): formatter #2, the extra SmartConnect ports, link #2 and its window (not broken down by hierarchy) |
| **CDC crossings** | 1715 | **3186, every one with an exception** (max-delay or false path) |

**CDC by structure:** link #2 is an exact copy of link #1: `u_link/` **1220** and `u_link2/` **1220** (FIFO LUTRAM read paths + Gray pointers), `u_link_stat/` **249** and `u_link2_stat/` **249**, formatter-internal `xpm_cdc` 2 each; `u_mclk_stat/` 242 and the matrix's `u_regs/u_bank` 2 toggles unchanged. 1715 + 1220 + 249 + 2 = 3186.

**BD warnings:** the same accepted set as Phase 8 (BD 41-3281 "connected on both sides by SmartConnects", now also for `link2_formatter`; BD 41-237 AxUSER 4 → 1 into HPC0), plus the pre-existing "No files matched '*'" (also in `p8_create.log`). The BD address report: `SEG_M_AXI_LINK2STAT_Reg 0x80004000 4K`, `SEG_link2_formatter_reg0 0x80110000 64K`, and both of formatter #2's DMA masters see HPC0 DDR_LOW / DDR_HIGH as #1's do.

Not checked here: SDT, image, bench (P9.5b onward).

### 6.10 P9.5b: the second card, the tools at 20 × 20, SDT

| File | What |
|---|---|
| `recipes-kernel/fpgamixer-link-card/files/fpgamixer-link-card.c` | decision L2: optional DT property **`fpgamixer,card-name`**. Absent: exactly Phase 8's names (card `FPGAmixerLink`, DAI link "FPGAmixer link", stream "FPGAmixer link PCM"), which the USB bridge opens as `hw:FPGAmixerLink`. Present: that string for the card and the DAI link, "`<name> PCM`" for the stream; refused (probe fails, logged) if empty or longer than the 15-character ALSA id, so no two cards can end up with shortened, ambiguous ids. Header comment: the stale "12.2919 MHz" replaced |
| `recipes-bsp/device-tree/files/system-user.dtsi` | node `fpgamixer_link2: fpgamixer-link2` (`audio-formatter = <&link2_formatter>`, `fpgamixer,card-name = "FPGAmixerLink2"`) + `xlnx,tx` / `xlnx,rx` on `&link2_formatter` (the Phase 8 oops trap, §14 of the Phase 8 doc). **Link #1's node is left without the property on purpose**, so the bench exercises both paths. The stale "real mclk is 12.2919 MHz" comment fixed. This layer revision needs a P9.5+ XSA (it references `link2_formatter`) |
| `tools/mixer_hw.py` | `WINDOWS["linkstat2"] = 0x8000_4000` (`LinkStatHW`); CLI **`link2 [seconds]`** (the `link` code on the other window); `info` column widened |
| `tools/crosspoint_restore_test.py` | **N = 20, 400 levels.** The 144 Phase 8 levels unchanged (checked against the previous file: identical), so the 64-crosspoint USB audio analysis is the same. The 256 new ones in ranges of their own: AVB → AVB −6.25 … −37.75 (the USB pattern on the quarter dB), USB → AVB −38 … −45.875, AVB → Pmod −46 … −49.875, Pmod → AVB −64 … −67.875, AVB → USB −78 … −85.875 (lowest, so an AVB source later barely touches the USB tone measurement) |
| `tools/osc_mixer_server.py` | simulator `--matrix-size` default 12 → **20**; with `--hw` the size already came from CONFIG |
| `tools/test_mixer_hw.py` | **`test_state_from_12x12_migrates_onto_20x20`**: a full bench-like 12 × 12 state restored onto a fake 20 × 20 window: all old values at `k = out·20 + in`, the AVB diagonal seeded on (L4), every other new crosspoint off, exactly 21 nonzero gains, the store keeps the old values, one COMMIT. **`test_windows_map`**: `linkstat2` at 0x8000_4000, no two windows on one base, all inside the window range |

**Deviation from §6.8, recorded:** the plan said `mixer_hw.py link [2] [s]`. That is ambiguous with the existing `link <seconds>` (`link 2` already means "over 2 seconds"), so link #2 is a separate command, `link2 [seconds]`.

**Checks:**
- `test_mixer_hw` + `test_mixer_state` on the VM: **38/38** (36 + the 2 new); `test_mediaclock` here 8/8: **46/46**.
- **Mutants, all caught:** `linkstat2` at 0x8000_5000 (`test_windows_map` FAIL); AVB crosspoints not seeded (the identity rule limited to inputs < 12: migration test FAIL); the bank stride hard-coded to 12 (migration test FAIL). Run with `PYTHONDONTWRITEBYTECODE=1`, a fresh directory per mutant, and a check that the mutation actually changed the file (one first attempt matched nothing and was rejected as invalid, not counted).
- **`check-hw` self-test** against a fake 20 × 20 window holding the pattern's codes: **400/400**; with one planted wrong register: **399/400**, naming it (`15_17`, AVB 3 → AVB 5).
- Driver: `bitbake -f -c compile fpgamixer-link-card` against the 6.18.10 kernel: exit 0, **0 compiler warnings**.
- **The formatter driver is multi-instance safe** (read in the VM's kernel source): `xlnx_formatter_pcm` keeps no global state, registers its component per device, and spawns its `xlnx_snd_card` child with `PLATFORM_DEVID_AUTO` (that driver numbers instances with an IDA). So two formatters give two components and two harmless "platform node not found" lines.

**SDT** (`sdtgen` on `fpgamixer_p95.xsa` → `build/sdt`; the P9.4b one kept as `build/sdt.p94b`): **`psu_init.tcl`, `psu_init.c`, `zynqmp.dtsi` identical** to P9.4b's, so the second formatter changed no PS setting. `pl.dtsi` adds `link2_formatter: audio_formatter@80110000` (the same clocks as #1, IRQs **GIC SPI 91/92**, #1 has 89/90) besides the new `firmware-name`; `pcw.dtsi` adds `M_AXI_LINK2STAT@80004000` (which `mixer_hw`'s presence guard needs); `system-top.dts` only the two address-map entries.

**Image built 2026-09-27** (layer synced at `d6854b7`, clean): `gen-machine-conf` exit 0, bitbake 14,859 tasks, all succeeded, 6 min 42 s, 24 warnings: the usual 23 plus "`fpgamixer-link-card` do_compile tainted from a forced run" (the compile check above; harmless). Checked: deployed bitstream MD5 = Vivado `p95` (`2e22f414…`); the DTB has `audio_formatter@80110000` and `@80100000` each with `xlnx,tx`/`xlnx,rx`, nodes `fpgamixer-link` and `fpgamixer-link2` (`fpgamixer,card-name = "FPGAmixerLink2"`), `M_AXI_LINK2STAT@80004000`; the rootfs's `mixer_hw.py` has `linkstat2`, the module has the `card-name` code, and **`fpgamixer-mediaclock` is enabled at boot** (first image with it). **`build/sd/p95-link2-20260927.wic.xz`** (MD5 `a2977a67…`, same on both ends).

### 6.11 P9.5 bench (2026-09-28 UTC, image `p95-link2-20260927`)

| Check | Result (read from the terminal) |
|---|---|
| cards (`aplay -l`) | card 0 **`FPGAmixerLink`** ("FPGAmixer link PCM", the driver's default names: no property), card 1 **`FPGAmixerLink2`** ("FPGAmixerLink2 PCM", from `fpgamixer,card-name`), card 2 `UAC2Gadget`. Cards 0 and 2 held by the USB bridge (subdevices 0/1), card 1 free |
| windows (`mixer_hw.py info`) | matrix **20 in × 20 out** (CONFIG `0x14141210`, COMMITS 1 = the server's start-up push); `linkstat2 @ 0x80004000` ID `0x4c4b5001`, 8 + 8 ch, FIFO 64 words, snapshots advancing; `linkstat`, `mclk`, `mclkctl` as before |
| media-clock loop from boot (first image with the unit enabled) | active since boot; **LOCKED**, phase −2 … 0 cycles (≤ 163 ns), correction ≈ −0.3 ppm; the steerer `locked`, 0 dropped |
| link #2 → Pmods | `set 0 12 0`, `set 2 13 0` (hardware only; COMMITS 2, 3); `speaker-test -D plughw:FPGAmixerLink2 -c 8 -t sine -f 440`: **heard (user): 440 Hz routed to the Pmods**, so core inputs 12/13 are link #2's channels 1/2 (the `{link2, link, jc, jb}` order, which simulation couldn't see) |
| `mixer_hw.py link2 10` during it | **48,001.5 frames/s** each way; underruns 0, starved 0, overruns 0, tid_errors 0; `rx_running` True. (`rx_fill` 0 as for link #1: the formatter delivers at the frame rate, Phase 8 §16) |
| **link #1 / USB unchanged** | the Mac playing through the bridge: `mixer_hw.py link 10` **48,001.6 / 48,001.5 frames/s** (once while link #2 was also streaming, once after), all error counters 0; **by ear (user): USB heard on the Pmods, "everything just fine"** |
| restore test `set` (Pi → board over OSC) | **400 sent, 400 echoed as sent, 0 differ** |
| `check-hw` before the power pull | **400/400** gain registers match the pattern |
| power pulled (no shutdown), rebooted, nothing typed on the board but the login (the first `ssh board` hit "No route to host" while it booted) | |
| `check-hw` after | **400/400**: all 400 levels, the 256 AVB crosspoints included, restored from the saved state |
| audio after the pull (user) | **restores by itself a few seconds after boot**, USB 1/2 on JB-L / JC-L at the pattern's −6 dB |

**Not done this time, recorded:** the Mac-recorded audio analysis of the 64 USB → USB crosspoints (`analyze` / `compare`). Its pattern and code are unchanged from Phase 8 (S4, passed), and `check-hw` covers every register; the AVB → AVB crosspoints get an audio check once there is an AVB source (P9.7).

**P9.5 done.** Link #2 is a second, unchanged instance of Phase 8's link, `FPGAmixerLink2` has a fixed name, the core is 20 × 20 on 2 DSP48E2s, and link #1, USB and the media-clock loop behave as before.

### 6.12 P9.6 proposal: shaping + AAF streams (2026-09-28, awaiting decisions A1–A8)

P9.6 makes the board an AVB talker and listener at the Linux level: two AAF ALSA devices (one stream each way) on `end0`, shaped as class A, talking to the Pi. It doesn't touch link #2 or the core yet; connecting the AAF devices to `FPGAmixerLink2` is P9.7's bridge. Seam: **the AVB front door's Linux half** (like the UAC2 gadget for USB); nothing here knows about the matrix.

#### Facts (checked 2026-09-28)

| Fact | Source | Consequence |
|---|---|---|
| **The ZynqMP GEM has no TC offload in this driver.** `macb_setup_tc` refuses without `NETIF_F_HW_TC`, which is set only for configs with `MACB_CAPS_TC` (`versal_config` has it, **`zynqmp_config` doesn't**) | 6.18.10 `macb_main.c` (VM kernel source) | CBS / ETF / mqprio run in **software** on the board. That's how the plugin's own documentation sets them up anyway (with `offload 1` where the NIC can) |
| **GEM0 has 2 TX queues** (`tx-0`, `tx-1`); the GEM serves the higher queue first | board `/sys/class/net/end0/queues/`; `macb_probe_queues` (DCFG6) | mqprio with **2 traffic classes**: best effort on queue 0, class A on queue 1 |
| **The running kernel has only `mqprio` built in; CBS, ETF, TAPRIO are off**, as §2 said. (A first reading of a stale `.config` from another machine's build, the 2026-09-21 `amd_cortexa53_mali_common` one, showed CBS/TAPRIO `=y`: wrong tree, discarded.) `VLAN_8021Q=y`, `PACKET=y` | board `modules.builtin`; `linux-genesys_zu3eg-standard-build/.config` | A kernel fragment, like `fpgamixer-usb.cfg`. AMD's `meta-xilinx-tsn` (in our `bblayers.conf`) has a `tsn-extra.cfg`, not applied to our machine; only its two lines are needed |
| **The AAF plugin's media clock is a `timerfd` on `CLOCK_REALTIME`**, one tick per ALSA period, started at "now + one period" (talker) or at the first PDU's presentation time + one period (listener). Presentation time = tick + `time_uncertainty` + `mtt`; the talker hands each PDU its launch time with `SO_TXTIME` on **`CLOCK_TAI`** | `alsa-plugins-1.2.7.1/aaf/pcm_aaf.c` (the tarball in the VM's `downloads/`) | **The AAF devices run on the system clock.** With `phc2sys` that is the PHC, and `mclk` is locked to the PHC (P9.4), so AAF and link #2 are locked to each other: P9.7's bridge needs a fixed buffer, **no rate adaptation** (unlike USB) |
| **The plugin hard-codes TAI − UTC = 37 s** (`TAI_TO_UTC(t) = t − 37 s`) when it arms the timer from a `CLOCK_TAI` reading. Its documentation: "requires … TAI offset is properly set in the kernel" | same | **On the board today `CLOCK_TAI − CLOCK_REALTIME` = 0** (measured: −4.8 µs, the read gap). The plugin would arm its timer 37 s in the past and fire ~37 s of periods at once. **Must be fixed first** (A3) |
| `phc2sys` sets the kernel's TAI offset **only if the grandmaster's time properties say UTC offset valid *and* time traceable**; `ptp4l`'s defaults don't. It still uses `currentUtcOffset` (37) to put `CLOCK_REALTIME` at UTC, which is why the board's clock shows real UTC | linuxptp 4.4 `phc2sys.c` / `pmc_agent.c` | Either the grandmaster announces the flags (the plugin documentation's `pmc … SET GRANDMASTER_SETTINGS_NP … currentUtcOffsetValid 1 … timeTraceable 1`), or the board sets its kernel TAI offset itself |
| **The talker relies on ETF** to release each PDU at its launch time. Without ETF, `SO_TXTIME` is set but ignored: each period's PDUs go out as a burst | plugin source + `doc/aaf.txt` | ETF (software, `clockid CLOCK_TAI`) under the CBS on the board |
| Formats: **S16_BE, S24_3BE, S32_BE, FLOAT_BE** only; the AAF bit-depth field is always the format's width | plugin source | The plugin can't say "24-bit audio in a 32-bit sample" (what Milan does, *as I recall; to check in Phase 10*). S24_3BE is honest for our 24-bit core |
| **As grandmaster, `phc2sys -a -r` (our P9.1 unit) leaves `CLOCK_REALTIME` alone** (§6.1) | P9.1 | With the board as GM the AAF devices would run on the free system clock while `mclk` follows the PHC: they'd drift apart. `-a -rr` makes `CLOCK_REALTIME` a possible *source*, so as GM the PHC follows the system clock and the two stay locked (A8) |
| **Pi:** Raspberry Pi OS has `libavtp0` / `libavtp-dev`; `libasound2-plugins` isn't installed (whether Debian's build includes `aaf` is **to check**); **the Pi kernel has no `sch_cbs`, `sch_etf`, `sch_taprio`** (only `mqprio`); the I350 `eth4` has 8 queues, 1 enabled | Pi (`apt-cache`, `modinfo`, `ethtool -l`) | The Pi can be talker and listener but **can't shape**: its talker sends a burst per period. Harmless on a point-to-point cable; recorded as a bench limitation (P9.8 with a switch would want a shaped talker) |
| The Pi runs no `phc2sys` (§6.1: its PCIe PHC read is bimodal and yanked the grandmaster by ±10 µs when *it* steered the PHC) | P9.1 | For the plugin the Pi's **system clock must follow its PHC**: `phc2sys -s eth4 -c CLOCK_REALTIME -w` (the other direction: the GM PHC stays free, and the read noise lands on the Pi's system clock, µs against a 2 ms `mtt`; `-N 5` keeps the fastest of 5 reads) |

#### What P9.6 builds

| Piece | What |
|---|---|
| `recipes-kernel/linux-xlnx/files/fpgamixer-avb.cfg` (new) | `CONFIG_NET_SCH_CBS=y`, `CONFIG_NET_SCH_ETF=y`; listed in the bbappend next to `fpgamixer-usb.cfg` |
| alsa-plugins `aaf` | a bbappend in our layer: `PACKAGECONFIG:append = " aaf"` (pulls libavtp from meta-multimedia); the image installs the aaf plugin package and `tcpdump` (bench) |
| `recipes-apps/fpgamixer-avb/` (new) | **`/etc/fpgamixer/avb.conf`** (one place for the stream parameters: interface, VLAN, MACs, stream IDs, class A numbers); **`fpgamixer-avb-net.service`** (after `end0` is up and before anything streams: VLAN interface, `mqprio` + `cbs` + `etf` on `end0`, kernel TAI offset per A3); **`/etc/asound.conf`** defining `avb_tx` / `avb_rx` (AAF PCMs). A script, not C: it runs `ip` / `tc` once at boot |
| `fpgamixer-phc2sys.service` | `-a -r` → `-a -rr` (A8) |
| bench (Pi, documented, not in the image) | `libasound2-plugins` (or alsa-plugins' `aaf` built against Debian's libavtp), `phc2sys -s eth4 -c CLOCK_REALTIME -w -N 5`, the `pmc` GM settings, the same `asound.conf` with the directions swapped; no shaping |

**Class A numbers, 8 ch, S24_3BE, 6 frames per PDU (125 µs):** AAF payload 144 B + AVTP header 24 B; on the wire with VLAN tag, FCS, preamble and gap **210 B × 8000 PDU/s = 13.44 Mbit/s**. The shaper is set with headroom (software CBS counts frame bytes, not wire bytes): idleslope **16,000 kbit/s**, sendslope −984,000, hicredit ≈ 25 B (1522-byte interfering frame), locredit ≈ −207 B (to be recomputed with the final numbers in the build step). ETF: `clockid CLOCK_TAI delta 500000` (0.5 ms, the plugin documentation's value), no offload.

**mqprio:** `num_tc 2 map 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 queues 1@0 1@1 hw 0`: socket priority 3 (the plugin's `prio`) → TC 1 → queue 1 → CBS → ETF; everything else, gPTP included, best effort on queue 0.

#### Decisions needed (A1–A8)

| # | Question | Recommendation |
|---|---|---|
| A1 | Kernel fragment: **CBS + ETF built in**, software only (no offload on this GEM); leave TAPRIO out (AVB has no gate schedule)? | **Yes.** |
| A2 | TX setup: **mqprio, 2 classes on the 2 queues, software CBS (idleslope 16 Mbit/s) + software ETF under it**, done by a boot service from one config file? | **Yes.** |
| A3 | **The kernel TAI offset (37 s)**: the board sets it itself at boot (so the plugin works whatever the grandmaster announces), **and** the bench grandmaster (Pi) announces a valid, traceable UTC offset with `pmc` (the Pi's own plugin needs it too)? | **Both.** `phc2sys` still overrides the board's value if a grandmaster ever announces a different, traceable one (a leap second) |
| A4 | Stream format: **AAF INT_24BIT (S24_3BE), 8 ch, 48 kHz, 6 frames/PDU**, `mtt` 2000 µs, `time_uncertainty` 125 µs, `ptime_tolerance` 125 µs? (Milan's 32-bit container stays a Phase 10 question: the plugin can't express it) | **Yes.** |
| A5 | Addressing, static: stream ID = talker MAC + `:0000` (board `00:18:3E:05:06:48:0000`, Pi = the I350 port's MAC); destination MACs **`91:E0:F0:00:FE:00`** (board → Pi) and **`91:E0:F0:00:FE:01`** (Pi → board), from the 1722 MAAP address range's block kept out of dynamic allocation (*from memory: to check against 1722 Annex B before we build*) | **Yes**, with the range checked first |
| A6 | **VLAN 2, PCP 3** (the AVB default for class A) on a VLAN interface (`end0.2`, egress priority 3 → PCP 3), from the start, rather than untagged frames on the point-to-point cable? gPTP stays untagged on `end0`. The Pi needs `eth4.2` too | **Yes, VLAN 2 now.** Cheap here, and what a switch (P9.8) and Milan (Phase 10) expect |
| A7 | Device names **`avb_tx`** / **`avb_rx`** in `/etc/asound.conf`, installed by `fpgamixer-avb`; the image gains the aaf plugin, libavtp and `tcpdump`? | **Yes.** |
| A8 | `fpgamixer-phc2sys`: **`-a -r` → `-a -rr`**, so the system clock (the plugin's) and the PHC (`mclk`'s) stay locked in the grandmaster role too? The follower role is unchanged | **Yes.** Without it, board-as-GM + AAF drifts |
| — | **Decided by the user, 2026-09-28: A1–A8 all as recommended.** | |

**Steps and verification:**
- **P9.6a** (image): the fragment, the aaf plugin, `fpgamixer-avb`, the `phc2sys` change. Checked: the kernel `.config` of **our** machine's build (not another tree), the rootfs contents, `tc -s qdisc` on the board, `CLOCK_TAI − CLOCK_REALTIME` = 37 s from boot.
- **P9.6b** (bench): the Pi set up as above. **Board → Pi:** `speaker-test -D avb_tx` on the board, `tcpdump` on the Pi: 8000 PDUs/s, VLAN 2 / PCP 3, contiguous sequence numbers, presentation times ≈ capture time + `mtt`, PDUs spaced ~125 µs (ETF) rather than in bursts; `arecord -D avb_rx` on the Pi receives the tone. **Pi → board:** the reverse, `arecord -D avb_rx` on the board. **Nothing else disturbed:** gPTP offsets (the summaries), the media-clock loop LOCKED, USB and link #2 as in P9.5.
- Not in P9.6: audio into the matrix (P9.7), long runs (P9.8).

### 6.13 P9.6a: the board's AVB network side, and the Pi's plugin

**A5's address range, checked:** IEEE 1722-2016's MAAP **dynamic allocation pool is `91:E0:F0:00:00:00` – `91:E0:F0:00:FD:FF`** (Table B.9; OpenAvnu's `maap.h`: base `0x91E0F0000000`, size `0xFE00`) and **`91:E0:F0:00:FF:00` is MAAP's own protocol address** (Table B.10). So `FE:00` / `FE:01` can never be claimed by a MAAP device. That `FE:xx` is *the locally administered block* is still from memory (a 2010 P1722 draft comment shows the table's layout being filled in); Table B.9 itself wasn't read.

| File | What |
|---|---|
| `tools/avb_net.py` (new) | the boot-time setup, from **one config file**: (1) the kernel TAI offset via `adjtimex(ADJ_TAI)` (A3; `struct timex` in ctypes, checked against the C header on the VM: size 208, `constant` at 48, `tai` at 160); (2) `end0.2`, VLAN 2, `egress-qos-map 3:3` (A6); (3) `mqprio` (2 classes, only priority 3 → TC 1 → queue 1) + `cbs` on class `100:2` + `etf` (`CLOCK_TAI`, delta 500 µs), all software (A2); (4) the AAF devices `avb_tx` / `avb_rx` **written to `/etc/alsa/conf.d/50-fpgamixer-avb.conf`** (A7). CBS credits and the ALSA text are *derived* from the config: frame 190 B, 8000 PDU/s, **13,440 kbit/s on the wire**; idleslope 16,000, sendslope −984,000, hicredit 25, locredit −187. Refuses: an idleslope below the stream's rate, an unknown format, a malformed address or stream ID (the plugin's listener drops PDUs with another stream ID **silently**, a debug print only). `--dry-run` prints everything and changes nothing |
| `tools/test_avb_net.py` (new) | 12 tests, run anywhere: the repo's `avb.conf` as decided, the refusals, the numbers above, the qdisc chain (parents, map, `hw 0`, no ETF offload), the VLAN command, the ALSA text of both devices |
| `recipes-apps/fpgamixer-avb/` (new) | `avb.conf` → `/etc/fpgamixer/avb.conf` (conffile); `fpgamixer-avb-net.service` (oneshot, after `end0` exists, **before `fpgamixer-ptp4l`**: replacing the root qdisc resets the TX queues); RDEPENDS the AAF plugin package (`libasound-module-pcm-aaf`), `iproute2-tc` (**the image had `ip` but no `tc`**), `python3-ctypes` |
| `recipes-kernel/linux-xlnx/files/fpgamixer-avb.cfg` (new) | `NET_SCH_CBS=y`, `NET_SCH_ETF=y` (A1), in the bbappend next to the USB fragment |
| `recipes-multimedia/alsa/alsa-plugins_%.bbappend` (new) | `PACKAGECONFIG:append = " aaf"` (pulls libavtp) |
| image bbappend | + `fpgamixer-avb tcpdump` |
| `fpgamixer-phc2sys.service` | `-a -r` → **`-a -rr`** (A8). **Checked in linuxptp 4.4's source** (`reconfigure()` / `compare_domains()`): the PTP domain has source priority 1, `CLOCK_REALTIME`'s domain 0, so while the port is SLAVE the PHC is the source exactly as before; only when no port is SLAVE (grandmaster) does the system clock become the source and the PHC follow it |
| `tools/pi_avb_asound.conf` (new) | the Pi's mirror of the two devices (bench only; kept in step by hand) |

**Why the ALSA file is generated and not static:** a static file in `conf.d` that `include`s a generated one would make *every* ALSA program on the board fail (the USB bridge too) whenever the generated file is missing; a generated file is simply absent until the service has run.

**The Pi (bench, steps run by the user, 2026-09-28):** `eth4` MAC **`50:7c:6f:8e:40:5b`** (now in `avb.conf` as the Pi's stream ID); Debian trixie's `libasound2-plugins` 1.2.12 **has no AAF plugin**, so it was built from `alsa-plugins-1.2.12.tar.bz2` (SHA-256 `7bd8a83d…66f2`, the same file downloaded on the VM) against Debian's `libavtp-dev` 0.2.0: `configure` "AAF plugin: yes", `make -C aaf` clean, `libasound_module_pcm_aaf.so` installed in `/usr/lib/aarch64-linux-gnu/alsa-lib/`. **The AAF source is identical in 1.2.7.1 (the board) and 1.2.12 (the Pi): `diff` 0 lines**, so both ends run the same plugin code.

**`pmc` syntax, checked in linuxptp 4.4 (`pmc_common.c`):** `SET GRANDMASTER_SETTINGS_NP` takes exactly 11 values, and the keyword is **`ptpTimescale`**; the plugin documentation's `pTimescale` is from an older linuxptp and would be refused.

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
| 4 | ~~**Matrix:** time-multiplex it now, freeing DSPs for Phase 7?~~ | **Decided 2026-09-26: yes, first** (§5). Its own design decisions come in P9.A1: the core stream contract (format, framing, back-pressure), the RAM bank swap, latency. |
| 5 | **Peers:** Pi only for v1? Is an AVB switch available for the soak, and which? Any AVB/Milan device available to test against? | Pi first; the rest when available. |
| 6 | **Channel map:** AVB at core channels 12–19 (appended after USB, as the Phase 8 rule says)? | **Yes.** |

### 8.1 Decisions (user, 2026-09-26, after P9.A)

| # | Decision |
|---|---|
| 1 | **M2a:** `mclk` disciplined to gPTP by MMCM fine phase shift; ASRC (M3) stays the fallback. |
| 2 | **The board follows the Pi** on the bench **for now**; the board should **eventually act as grandmaster** too. So the media-clock design must work in both roles (as GM, `mclk` free-runs and the board's gPTP time is the reference; as follower, `mclk` locks to the GM). |
| 3 | **8 + 8 channels, class A, 48 kHz.** |
| 4 | Decided earlier (P9.A, done). |
| 5 | **Pi first.** The user suggests the **I350 could act as an AVB switch**, which would also make the **Mac** a possible peer. Not a v1 dependency; to verify when it comes up (P9.8 / Phase 10): the I350 is a 4-port NIC. A Linux bridge on the Pi with linuxptp across the ports could relay gPTP for a multi-hop test, but the I350 has no hardware CBS (§7), so it would be a software stand-in rather than a conformant AVB bridge. macOS AVB (to my knowledge, unverified) connects streams through AVDECC, which is Phase 10, and needs an AVB-capable Ethernet port. |
| 6 | **AVB at core channels 12–19**, appended after USB; core 20 × 20 (2 DSP48E2). |

## 9. Open verification items (for the implementing session)

- The TSU counter's clock domain in the PL, and how to sample `emio_enet0_enet_tsu_timer_cnt` coherently (a TSU-domain clock to the PL, or a capture handshake).
  - **Partly checked (2026-09-26, `fpgamixer_p9a5.xsa` `.hwh` and the PS IP `zynq_ultra_ps_e_v3_5`):** `emio_enet0_enet_tsu_timer_cnt[93:0]` is a PS output with **no associated clock** in the BD. It counts in the GEM TSU clock domain: `GEM_TSU_REF_CTRL` = IOPLL / 6 = **250 MHz, internal** (`PSU__GEM__TSU__IO` unset, `PSU__GEM__TSU__ENABLE = 0`). That clock is **not exported** today.
  - The PS IP can export it: `fmio_gem_tsu_clk_to_pl_bufg` (out) / `fmio_gem_tsu_clk_from_pl` (in), enabled by `PSU__TSU__BUFG_PORT_PAIR` (0 today). The IP's BD script requires the two to be **looped back when the TSU clock source is EMIO**. **To read in UG1085 ch. 34 before designing P9.3:** does `to_pl_bufg` carry the internal 250 MHz reference when the source isn't EMIO, and does enabling the pair make the TSU depend on the PL? It must not, since the PS runs before the bitstream is loaded. It would also change `psu_init`, the first PS change since Phase 4.
  - If exporting is unsafe, the fallbacks need no PS change: **1PPS from one counter bit** (UG1085 Table 34-16; the spike doc §6) into a 2FF synchronizer, giving ±1 `mclk` (81 ns) per edge, i.e. 0.08 ppm per second for frequency, or a multi-sample read of the slow-changing high bits. Chosen in P9.3, with the numbers.
- MMCM fine-phase-shift step size and rate limits for `clk_wiz_audio`; whether the Clocking Wizard exposes the PS port or the MMCM must be instantiated directly.
- The AAF plugin's timing model (talker pacing, presentation time, `SO_TXTIME`/ETF) on 6.18 + alsa-plugins 1.2.7.1, and libavtp's API level. **Answered 2026-09-28 (§6.12):** a `CLOCK_REALTIME` timer per period, `SO_TXTIME` on `CLOCK_TAI` through ETF, a hard-coded 37 s TAI offset; it needs `CLOCK_REALTIME` locked to the PHC (so yes, `phc2sys`) *and* the kernel TAI offset set, which the board doesn't have today.
- The Pi's kernel: CBS/ETF qdiscs, and whether Debian ships the AAF plugin. **Answered in part (§6.12):** no `sch_cbs` / `sch_etf` / `sch_taprio` modules (only `mqprio`); Debian has libavtp; whether its `libasound2-plugins` contains `aaf` is still to check.

## 10. Log

- **2026-09-26:** proposal written (this doc) after Phase 8 P8.9. Nothing built.
- **2026-09-26:** revised by the user's decision: the time-shared core (§5, P9.A) goes first; P9.2 folded into it. The other §8 decisions are left for the Phase 9 session.
- **2026-09-26 (Phase 9 session):** Phase 8 merged (`ea88a29`); branch `phase9/time-shared-core`. **P9.A1:** core design proposal written (§5.1): output-major DSP lanes sharing one sample stream, a tagged stream contract, coefficients in a dual-clock RAM with a swap at the frame, `mixer_core`. Corrected the §5 table's 64 × 64 figure. Side finding from the RTL: a probable one-sample L/R skew on the Pmod DAC outputs today (C7). Awaiting decisions C1–C7.
- **2026-09-26:** decisions C1–C7: all as recommended. **P9.A2 PASS** (§5.2): stream contract in `architecture_modules.md` §2.1, `pcm_pack2stream` / `pcm_stream2pack`, `pcm_stream_monitor`, `tb_pcm_stream` bit-exact at N = 1, 12, 20, 4 mutants all caught. Next: C7 (Pmod L/R skew), then P9.A3.
- **2026-09-26: C7 PASS** (§5.3): the L/R skew confirmed in `tb_phase3_dynamic` (L frame 5, R frame 6), fixed in `i2s_port` (the pair sampled once, at the L load); the TB now checks pairing and fails on the old RTL. Core deadline stated: packed output valid from cycle 253. Next: P9.A3 (`coef_bank_ram`).
- **2026-09-26: P9.A3 PASS** (§5.4): `coef_bank_ram` + `coef_flat_reader` + scoped XDC; `tb_coef_bank_ram` at 5 × 7 / 3 lanes and 12 × 12 / 1 lane, 5 mutants caught. Corrected: a queued commit no longer picks up writes made after it (writes stall while queued). Next: P9.A4, the switch-over (window on the store interface, time-shared matrix, `mixer_core`, top).
- **2026-09-26: P9.A4 PASS** (§5.5): time-shared `pcm_matrix` (1 lane at 12 × 12, D = 162), `mixer_core`, `axil_coef_window` on the store, `matrix_regs_axil` on `coef_bank_ram`, top switched; bit-exact at 7 sizes / lane counts, 4 matrix mutants caught; `xsim_regress.ps1` 13/13. Next: P9.A5, the Vivado build (DSP count, CDC, timing, methodology gate).
- **2026-09-26: P9.A5 clean** (§5.6): WNS +2.300 / WHS +0.005 ns, methodology gate PASS, **1 DSP48E2** (was 144), 1 RAMB18, CDC 1473 crossings (was 4193) all with exceptions, the matrix's share 2 toggles (was 2592). Next: P9.A6, the image and the bench.
- **2026-09-26: P9.A6 PASS** (§5.7), image `p9a6-core-20260926`: matrix window 12 × 12, link 48,018 frames/s clean, S3 by ear as before, S4 144/144 set → check-hw 144/144 → power pull → 144/144. **P9.A done.** Open: the bridge's coarse fix not yet observed at start-up. Next: the AVB decisions (§8).
- **2026-09-26:** AVB decisions recorded (§8.1): M2a; board follows the Pi now, grandmaster later; 8 + 8 class A 48 kHz; Pi first (I350-as-switch / Mac noted, to verify); AVB at core ch 12–19. **P9.1 built** (§6.1): `fpgamixer-gptp` (ptp4l + phc2sys at boot, role by BMCA, `priority1 250`), linuxptp moved from the VM's `local.conf` into the layer; image `p91-gptp-20260926`, bench pending. §9 item 1 partly checked (the TSU counter's clock isn't exported; a PS option exists, to read in UG1085).
- **2026-09-26: P9.1 PASS** (§6.1): first boot FAULTY (macb refuses `SIOCSHWTSTAMP` while `end0` is down; the unit now brings it up first), then SLAVE from a cold boot; failover to grandmaster and failback both automatic; **2–3 ns RMS / ≤ 9 ns** once the Pi's PHC was no longer steered by its noisy `phc2sys` (which had caused 2–3 µs). Open: 20-min soak, bridge log.
- **2026-09-27: P9.3 PASS** (§6.3): the meter on hardware reads **mclk = +315.34 ppm vs gPTP** (60 s mean, ±0.08 ppm per interval), so the PL crystal is −8.66 ppm vs the Pi; `psu_init` unchanged; gPTP SLAVE from boot from the image. Next: P9.4, starting with the MMCM retune (T4), predicted to read ≈ +2.4 ppm.
- **2026-09-27: P9.4a PASS on the meter** (§6.4): MMCM 25 × 58/118; **mclk now +0.85 ppm vs gPTP** (from +315.34), 48,000 frames per gPTP second; link clean; jitter 289 → 187 ps. Audio by ear: heard, after re-routing (the reflash had reset it). **P9.4a done.** New open items: `phc2sys` follows a bogus grandmaster time (board clock went to 1970 after the Pi rebooted), USB bridge direction B still swings at start-up and its coarse fix spins while the Mac is idle.
- **2026-09-27: P9.4b on hardware** (§6.6.1): open-loop `steer ±2` moved the meter by exactly 2.00 ppm against the crystals' drift (sign confirmed by the step counters); **the loop locked in 5 s and holds the frame phase at −1 … −3 cycles (≤ 244 ns)** while tracking ≈ −0.1 ppm/min drift; link clean with the loop running; **by ear with the loop locked: clean** (user). `fpgamixer-mediaclock` switched to enabled-at-boot for the next image. Then (§6.6.2) **holdover PASS** (grandmaster loss: no state change; a reference step: HOLDOVER 6 s, re-LOCKED 15 s later, phase back to 0 in ~100 s, no audible glitch) and **a 60-min soak PASS** (phase ±1 cycle steady, gPTP 2–4 ns RMS). **P9.4 done.** Next: P9.5 (link #2, core 20 × 20). (This entry was first spliced into the middle of the P9.A6 line by an edit anchored on a phrase inside it; moved here.)
- **2026-09-27: P9.5 planned** (§6.8); decisions **L1–L5 all as recommended**. Found: the ALSA card driver hard-codes its card name (not multi-instance, contrary to the Phase 8 doc). Implementation handed to a fresh session: `docs/prompt_phase9_p95.md`.
- **2026-09-27: P9.5a clean** (§6.9): link #2 (`u_link2` + `u_link2_stat`, `INCLUDE_LINK2`) and `link2_formatter` (0x8011_0000; status 0x8000_4000) in the `phase9` variant, formatter BD code shared through `add_link_formatter`; core **20 × 20** in every build (probe: N 20, 2 lanes, D 227). `xsim_regress` 15/15; build `p95` WNS +2.505 / WHS +0.004 ns, methodology PASS, **2 DSP48E2**, 3 RAMB18, CDC 3186 all constrained (link #2 = a copy of link #1's structures). Next: P9.5b (card driver + DT + tools), SDT, image, bench.
- **2026-09-27: P9.5b** (§6.10): card driver named by `fpgamixer,card-name` (default unchanged), DT node `FPGAmixerLink2`, `mixer_hw` `linkstat2` / `link2`, restore test at 400 levels (the 144 old ones unchanged), simulator default 20; Python 46/46, 3 mutants caught, check-hw self-test 400/400 and 399/400 planted; driver 0 warnings. SDT: `psu_init` identical, `link2_formatter@80110000` (SPI 91/92) and `M_AXI_LINK2STAT@80004000` present. Next: the image, then the bench.
- **2026-09-28 (UTC): P9.5 PASS on the bench** (§6.11, image `p95-link2-20260927`): cards `FPGAmixerLink` + `FPGAmixerLink2` by name; matrix 20 × 20; the media-clock loop LOCKED from boot (first image with it enabled); **440 Hz into `FPGAmixerLink2` heard on the Pmods** via core inputs 12/13; link #2 48,001.5 frames/s clean; **link #1 / USB unchanged** (48,001.5 frames/s clean, heard); restore test **400 set / 400 echoed, check-hw 400/400 → power pull → 400/400**, audio back by itself. **P9.5 done.** Next: the P9.6 proposal (shaping + AAF).
- **2026-09-28: P9.6 proposal** (§6.12): found that the ZynqMP GEM has **no TC offload** in `macb` (only Versal; §2 corrected) and 2 TX queues; our kernel has mqprio but not CBS/ETF; the AAF plugin runs on `CLOCK_REALTIME` with a hard-coded 37 s TAI offset, and **the board's kernel TAI offset is 0 today**; the Pi can't shape (no CBS/ETF modules) and needs `phc2sys` for its system clock. Awaiting decisions A1–A8.
