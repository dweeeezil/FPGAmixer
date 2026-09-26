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

### 5.7 P9.A6: image built; bench pending

**SDT** (`sdtgen` on `fpgamixer_p9a5.xsa` → `build/sdt`; the Phase 8 one kept as `build/sdt.p8` and `~/edf/sdt.p8` on the VM): `psu_init.tcl`, `zynqmp.dtsi`, `pcw.dtsi`, `system-top.dts` **identical** to Phase 8; `pl.dtsi` differs only in `firmware-name` (`fpgamixer_p9a5.bit.bin`). So the PS configuration and the device tree didn't change; only the bitstream did.

**Layer sync:** the VM's copy was from `169eaa5-dirty` (P8.9), older than the bridge fix committed in `b2dd92a`. Synced at `89ebfc4` (clean). The synced `fpgamixer-usb-bridge.c` has the coarse correction and `HOLD_S`.

**Image built 2026-09-26:** `gen-machine-conf` (exit 0) + `bitbake edf-linux-disk-image xilinx-bootbin`: 14,821 tasks, all succeeded, 6 min 48 s, 23 warnings (the usual runqueue-deadlock / "image not supported" set). Checked: the deployed `download-genesys-zu3eg.bit` MD5 = Vivado's `fpgamixer_p9a5.bit` (`4df4e23e…`); the rootfs's `/usr/bin/fpgamixer-usb-bridge` has the "coarse fixes" status line, i.e. **the Phase 8 servo fix is in an image for the first time**. Copied to **`build/sd/p9a6-core-20260926.wic.xz`** (MD5 `f861eeaa…`, same on both ends).

**Bench plan (Phase 8 S3 + S4 on the new core):**
1. `mixer_hw.py info`: matrix window 12 in × 12 out, Q2.16 (the register map unchanged).
2. Bridge start-up (`journalctl -u fpgamixer-usb-bridge -b`): the coarse fix instead of the old +650 ppm swing in direction B.
3. S3: Mac → USB 1/2 → JB-L / JC-L by ear; `mixer_hw.py link 10`: 0 underruns/overruns/TID errors.
4. S4: `crosspoint_restore_test.py set` (Pi) → `check-hw` (board) 144/144 → power pull → `check-hw` 144/144.

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
- **2026-09-26:** decisions C1–C7: all as recommended. **P9.A2 PASS** (§5.2): stream contract in `architecture_modules.md` §2.1, `pcm_pack2stream` / `pcm_stream2pack`, `pcm_stream_monitor`, `tb_pcm_stream` bit-exact at N = 1, 12, 20, 4 mutants all caught. Next: C7 (Pmod L/R skew), then P9.A3.
- **2026-09-26: C7 PASS** (§5.3): the L/R skew confirmed in `tb_phase3_dynamic` (L frame 5, R frame 6), fixed in `i2s_port` (the pair sampled once, at the L load); the TB now checks pairing and fails on the old RTL. Core deadline stated: packed output valid from cycle 253. Next: P9.A3 (`coef_bank_ram`).
- **2026-09-26: P9.A3 PASS** (§5.4): `coef_bank_ram` + `coef_flat_reader` + scoped XDC; `tb_coef_bank_ram` at 5 × 7 / 3 lanes and 12 × 12 / 1 lane, 5 mutants caught. Corrected: a queued commit no longer picks up writes made after it (writes stall while queued). Next: P9.A4, the switch-over (window on the store interface, time-shared matrix, `mixer_core`, top).
- **2026-09-26: P9.A4 PASS** (§5.5): time-shared `pcm_matrix` (1 lane at 12 × 12, D = 162), `mixer_core`, `axil_coef_window` on the store, `matrix_regs_axil` on `coef_bank_ram`, top switched; bit-exact at 7 sizes / lane counts, 4 matrix mutants caught; `xsim_regress.ps1` 13/13. Next: P9.A5, the Vivado build (DSP count, CDC, timing, methodology gate).
- **2026-09-26: P9.A5 clean** (§5.6): WNS +2.300 / WHS +0.005 ns, methodology gate PASS, **1 DSP48E2** (was 144), 1 RAMB18, CDC 1473 crossings (was 4193) all with exceptions, the matrix's share 2 toggles (was 2592). Next: P9.A6, the image and the bench.
