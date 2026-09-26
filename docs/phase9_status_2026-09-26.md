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

## 9. Open verification items (for the implementing session)

- The TSU counter's clock domain in the PL, and how to sample `emio_enet0_enet_tsu_timer_cnt` coherently (a TSU-domain clock to the PL, or a capture handshake).
- MMCM fine-phase-shift step size and rate limits for `clk_wiz_audio`; whether the Clocking Wizard exposes the PS port or the MMCM must be instantiated directly.
- The AAF plugin's timing model (talker pacing, presentation time, `SO_TXTIME`/ETF) on 6.18 + alsa-plugins 1.2.7.1, and libavtp's API level.
- The Pi's kernel: CBS/ETF qdiscs, and whether Debian ships the AAF plugin.

## 10. Log

- **2026-09-26:** proposal written (this doc) after Phase 8 P8.9. Nothing built.
- **2026-09-26:** revised by the user's decision: the time-shared core (§5, P9.A) goes first; P9.2 folded into it. The other §8 decisions are left for the Phase 9 session.
- **2026-09-26 (Phase 9 session):** Phase 8 merged (`ea88a29`); branch `phase9/time-shared-core`. **P9.A1:** core design proposal written (§5.1): output-major DSP lanes sharing one sample stream, a tagged stream contract, coefficients in a dual-clock RAM with a swap at the frame, `mixer_core`. Corrected the §5 table's 64 × 64 figure. Side finding from the RTL: a probable one-sample L/R skew on the Pmod DAC outputs today (C7). Awaiting decisions C1–C7.
