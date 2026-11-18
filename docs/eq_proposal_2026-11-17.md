# Proposal: the parametric EQ, the second insert type (2026-11-17)

**State:** plan decided (§4, the user, 2026-11-17); step A in progress.

**Supersedes** the fixed-stage plan in `library_foundation_proposal_2026-10-10.md` §13: the EQ is now a **pool** behind the insert router (`insert_architecture_proposal_2026-10-31.md`), not a core stage.

**Decided (the user):**
- **A state-variable filter**, the trapezoidal "TPT" form (2026-11-09: *"I'd assume we should go with variable-state unless there's a strong argument against it"*; there is none, see §1).
- **8 bands per EQ**, each of any type.
- **Coefficients computed in the server**; the FPGA only multiplies.
- From the insert work:
  - 32 slots;
  - linked through virtual groups;
  - the controller treats it as a generic pool type (`docs/inserts_controller_spec_2026-10-31.md`).

---

## 1. The filter

Each band is one TPT state-variable section (Simper's linear trapezoidal SVF). With `g = tan(π f / fs)` and `k` the damping, the server computes six coefficients:

```
a1 = 1 / (1 + g (g + k))     a2 = g a1     a3 = g a2          (the filter)
m0, m1, m2                                                     (the output mix, per band type)
```

Per sample (two states per band, `ic1`, `ic2`):

```
v3 = v0 - ic2
v1 = a1 ic1 + a2 v3
v2 = ic2 + a2 ic1 + a3 v3
ic1 = 2 v1 - ic1      ic2 = 2 v2 - ic2
out = m0 v0 + m1 v1 + m2 v2
```

That is 7 multiplies per band per sample. The band types differ only in `m0`, `m1`, `m2` (and `g`, `k` for the shelves):

| Type | m0, m1, m2 |
|---|---|
| Peak (bell) | 1, k (A² − 1), 0, with k = 1 / (Q A) |
| Low shelf | 1, k (A − 1), A² − 1, with g = tan(π f / fs) / √A |
| High shelf | A², k (1 − A) A, 1 − A², with g = tan(π f / fs) · √A |
| High-pass | 1, −k, −1 |
| Low-pass | 0, 0, 1 |

where A = 10^(gain / 40).

**Identity is exact:** `m0 = 1, m1 = m2 = 0` makes `out = v0`, whatever the states hold. That is a Peak at 0 dB, or a band switched off. So a flat or bypassed EQ is bit-exact, which the null tests and the insert router's bit-exact front edits need.

**Why it was chosen** (for the record): a biquad can go briefly unstable, or zipper, while its coefficients glide between two settings. This form is stable for any positive `g` and `k`, so the existing coefficient smoother (the faders' one, 5.3 ms) can sit on its port, and no crossfade is needed inside the block. It also gives every band type from one structure, and it is well-behaved at low frequencies in fixed point.

**One thing the prototype must confirm, not assume:**
- The smoother interpolates the six *derived* coefficients (a1 … m2), not `g` and `k`.
- An intermediate set of interpolated a's isn't exactly a filter of some `g`, `k`.
- So step A checks that every intermediate set of fast sweeps stays stable and click-free.
- If it doesn't, the fallback is to smooth `g` and `k` in the block instead. That needs a divider, so it would be decided with numbers, at the milestone.

## 2. The steps

**A. The prototype (Python, no RTL).** It decides the number formats from measured numbers, and it becomes the block's reference model.
- **A floating-point reference** of the design formulas and the filter, checked against the textbook responses.
- **A fixed-point model**, bit for bit what the hardware will do:
  - 24-bit audio in and out;
  - states wider (likely 32–40 bits);
  - coefficients in a format that holds their range (`m0` up to A² = 5.6 at +15 dB; `m1` grows as Q gets small).

  The DSP48E2 multiplies 27 × 18 bits, so the formats decide whether a multiply takes 1 DSP or 2.
- **Measured, for every type at the extremes** (20 Hz and 20 kHz, ±15 dB, Q 0.1 and 10):
  - the response error against the reference;
  - the noise floor (the hard case: a 20 Hz shelf);
  - identity bit-exact;
  - fast sweeps through the smoother's exact fixed-point steps, staying stable;
  - a full-scale input, which must not overflow.
- **Where it lives:** the library (`HDL-DSP-Library/model/`), next to the block it models. The server's coefficient maths (FPGAmixer `tools/mixer_eq.py`) is a copy that a test checks against the library's model through the submodule, so the two can't drift.
- **Milestone: I report the numbers and the chosen formats before any RTL.**

**B. The block `lib_svf_eq` (library, from the template).**
- **Shape:** 32 slots × 8 bands in series = 256 sections per frame, about 1,800 multiplies.
- **Timing:** a pool must finish its run inside the frame (the router checks it): its last output at most about 220 cycles after its last input.
  - **2 lanes**, each one section per cycle, fully pipelined, run band 1 for every slot, then band 2, and so on.
  - Each band of a slot waits for its previous band. With 32 slots interleaved there is time for that.
  - The total is about 130–160 cycles.
- **Cost:**
  - **about 14 DSPs** (7 per lane), or up to 28 if the formats need double multiplies;
  - the states in about one BRAM per lane;
  - the coefficients (1,536 words) in a `coef_bank_ram` with a `coef_smooth` on its port, as for the gain pool.
- **Identity, bypass and band on/off** are all the server's coefficients. The block has no bypass logic.
- **Its TB:** bit-exact against the prototype's fixed-point model, both pool contract rules (finishes within the frame, exact identity), and mutants.

**C. FPGAmixer.**
- **The second pool:**
  - `mixer_hw.POOLS` gains `("eq", "eqpool")`;
  - the router gets `NP` = 2;
  - its window at 0x8001_1000 on the second SmartConnect (a block-design change, a new device-tree node);
  - its bank and smoother in `fpgamixer_top`.
- **The server:**
  - `PoolType("eq", …)` with the modules below;
  - an `EqPoolDriver` that turns them into coefficients (`mixer_eq.py`) and writes the window;
  - its tests.
- Then the regression, `tb_top_windows` with an EQ insert, a Vivado check, and the image.

**D. The bench (yours).**
- The null gate.
- **Bit-exact with an EQ inserted flat** (USB → USB).
- **By ear:**
  - sweep a band fast;
  - boost and cut;
  - the shelves, high-pass and low-pass;
  - no zipper noise, no clicks.
- **A response spot check:** a sine at a few frequencies through a known setting, read on the meters.

## 3. The modules (the pool zone `eq`, per slot; group `eq`; all linked)

| Module | Type | Range | Default |
|---|---|---|---|
| `eq_on` | bool | | 1 |
| `eq_bandN_on` (N = 1 … 8) | bool | | 1 |
| `eq_bandN_type` | enum, labels | Peak, Low shelf, High shelf, High-pass, Low-pass | Peak |
| `eq_bandN_freq` | float, Hz | 20 … 20,000 | spread (below) |
| `eq_bandN_gain` | float, dB | −15 … +15 | 0 |
| `eq_bandN_q` | float | 0.1 … 10 | 1.0 |

- That is 41 modules per slot. The names follow the app's mock (`eq_band1_freq`, …).
- **The defaults are the identity:** every band a Peak at 0 dB, so inserting an EQ changes nothing until a band is moved, and a fresh slot passes the router's bit-exact front edit.
- **Default frequencies:** 30, 80, 200, 500, 1.2 k, 3 k, 7 k and 15 kHz (log-spaced), so a band is near wherever the user reaches.
- `eq_on` 0, or a band's `on` 0, gives identity coefficients (exact bypass).
- A high-pass or low-pass band ignores `gain`. Its slope is 12 dB per octave, and `q` sets the resonance (0.71 = Butterworth). For 24 dB per octave, use two bands.

## 4. Questions for the user

- **Q1, band types:** Peak, Low shelf, High shelf, High-pass, Low-pass, as above.
  - Recommended. They cover a console EQ.
  - Notch and band-pass are cheap to add later (just other `m` values), so they can come when wanted.
- **Q2, ranges:** gain ±15 dB, Q 0.1–10, 20 Hz–20 kHz.
  - Recommended (the common console ranges).
  - Alternatives: ±18 dB, or Q up to 16 for narrow cuts. A wider range costs coefficient bits, which step A will show.
- **Q3, the default layout:** 8 Peaks at 0 dB, log-spaced (above). Recommended: it is exactly identity.
  - The alternative is a console-style layout (band 1 a high-pass, bands 2 and 8 shelves).
  - That would need band 1's `on` to default to 0, to stay identity.
- **Q4, where the reference model lives:** in the library, with the server's copy of the coefficient maths checked against it by a test. Recommended.
  - The alternative is one copy in FPGAmixer `tools/`, imported by the library's TB through a path. That couples the library to FPGAmixer, which the library rules (HD3) avoid.

**Decided (the user, 2026-11-17):** Q1 yes (the five types), Q2 yes (±15 dB, Q 0.1–10, 20 Hz–20 kHz), Q3 yes (8 Peaks at 0 dB, log-spaced). Q4: the user read it as *where the prototype runs*, and wants it run on the PC, not the PS ("running on the PS vs my PC won't change how python behaves"). That is the plan: the prototype, its study and the block's TB all run on the PC; the question was only which repository holds the files. The recommendation stands (the library's `model/`). The only EQ code on the PS is the server's coefficient maths (step C), which is production, not a test; a PC-side test checks it against the prototype.

## 5. Step A results (2026-11-17; the milestone before RTL)

**Code** (HDL-DSP-Library, local):
- `model/svf_eq.py`: the reference model, with the bit-true `FixedBand` and the chosen format `EQ_FMT`;
- `model/eq_study.py`, with its output `model/eq_study_report.txt`;
- `model/test_svf_eq.py`: 15 tests, all passing.

Everything is pure Python, run on the PC.

**The measurements:**
- **The grid:** 680 designs (the five types × 8 frequencies 20 Hz–20 kHz × gains ±15 dB × Q 0.1–10).
- **The ranges:** the `m` coefficients reach |32.5| (a high shelf at Q 0.1), so 6 integer bits. The smallest `a3` is 7 × 10⁻⁷ (20 Hz).

**Finding 1: the structure.**
- The plan's `a` form (coefficients a1, a2, a3, m0, m1, m2; 7 multiplies) is **stable on every path the smoother can take**: 9,702 glides between extreme settings, worst spectral radius 0.99994, and power-on from all-zero coefficients too.
- The rewritten `g` form (6 multiplies) is cheaper but **unstable while gliding**: radius up to 8.6, and the bit-true sweeps saturate.
- So: **the `a` form**, with the existing smoother on its port and no crossfade inside the block.

**Finding 2: the formats** (the chosen one: `EQ_FMT`).

| | bits | why |
|---|---|---|
| a1..a3 | 26 (24 fraction) | response error from rounding ≤ **0.0036 dB** over every design (20 bits: 0.063 dB) |
| m0..m2 | 25 (18 fraction, 6 integer) | ≤ 0.0035 dB with the a's; fewer fraction bits add error |
| signals and states | 35 (27 fraction, 7 headroom) | a state can reach 92 × full scale (a 20 kHz, Q 10, +15 dB peak) |

**Finding 3: low-frequency noise and a deadband, and the cure.**
- With plain rounding at 27 fraction bits, the worst case (a 20 Hz shelf at +15 dB) leaves **−125 dBFS** of arithmetic noise.
- A 20 Hz high-pass that gets digital silence **sticks at a constant 24 LSB** (−110 dBFS of DC) forever: the classic fixed-point deadband (the integrator's update rounds to zero).
- **Error feedback** (each state sum's rounding remainder carried into the next sample: two registers and two adders per band, no multiplies) fixes both:
  - worst **−143 dBFS** (a broad +15 dB peak), and 8 of the 9 hard cases at the 24-bit output's own floor (−147.8 to −149.2, floor −149.3);
  - **0 LSB** after the input stops.
- Rounding toward zero (the other classic remedy) was worse: −96 dBFS, stuck at 339 LSB.

| Option | worst noise | after silence | DSPs (2 lanes) |
|---|---|---|---|
| 27 fraction bits, plain rounding | −125 dBFS | stuck at 24 LSB | 28 |
| **27 fraction bits + error feedback (chosen)** | **−143 dBFS** (others at the floor) | **0** | **28** |
| 31 fraction bits + error feedback | at the floor everywhere (−149.2) | 0 | 42 |

**Finding 4: glides.**
- Big jumps within one type behave like a sweep: peaks 20 Hz ↔ 20 kHz, shelves, high-pass and low-pass, no saturation anywhere.
- A broad peak swept across the test tone boosts it on the way, which is correct.
- **Changing a band's type is the exception:** the in-between mix of two different types can be a louder shape (+13 dB in the worst case, a 20 Hz low shelf → a 20 kHz high shelf).
- **The cure is the server's, no hardware:** a type change goes through flat.
  - Old filter with the flat mix, which is exact identity whatever the filter does, so the filter can glide silently.
  - Then the new filter with the flat mix.
  - Then the new mix: a crossfade from dry to the new type.
  - Measured: **0.101 FS against a steady 0.100**.
  - Cost: the new type sounds after about 0.2 s.
  - A snapshot recall that changes types does the same.

**Finding 5: cost.**
- **28 DSP48E2** (2 lanes × 14: four 26 × 35-bit and three 25 × 35-bit multiplies, 2 DSPs each), about 8 % of the device.
- The states and remainders: 256 sections × ~118 bits, about one BRAM per lane.
- The coefficients: 256 × 6 words in a `coef_bank_ram` plus `coef_smooth`.

**Question for the user (Q5):** the noise floor.
- **27 fraction bits + error feedback**, 28 DSPs. Recommended: −143 dBFS in the worst case is far below any converter on the bench (the M2's are around −115 to −120), and every other case is at the 24-bit floor.
- The alternative: **31 fraction bits**, 42 DSPs, at the 24-bit floor in every case.

**Decided (the user, 2026-11-17): Q5, 27 fraction bits + error feedback, 28 DSPs** (`EQ_FMT` as it stands).

## 6. Step B plan: the block `lib_svf_eq` (2026-11-17, for the user's review)

A library block from the template, generic: S slots × B bands, no knowledge of FPGAmixer. It is bit-exact against `model/svf_eq.py`'s `FixedBand` with `EQ_FMT`.

**The pool contract** (`insert_router`): a stream of S channels (the slots) in, one out, each frame. It must finish its run inside the frame: its last output at most 221 cycles after its last input at S = 32.

**The schedule: two lanes, alternating bands.**
- Lane 0 runs the even bands (1, 3, 5, 7 in the UI's numbering), lane 1 the odd ones, each one section per cycle, fully pipelined (about 15 cycles deep, P).
- Lane 0 does band 1 for slots 0 … 31, lane 1 follows P cycles behind with band 2 for the same slots, then lane 0 does band 3, and so on.
- A band's slot result goes through a 32-entry buffer to the other lane's next band.
- Lane 1's band-8 results come out in slot order, one per cycle, so they **are** the output stream: no output buffer.
- The period per band pair is max(32, 2P) cycles. The last output is about 4 × 32 + 2P ≈ 160 cycles after the last input, inside the 221.
- **So an EQ insert adds no latency** beyond the router's fixed 9 frames.

**Each lane:**
- 7 multiplies, 14 DSP48E2: four 26 × 35 for the filter, three 25 × 35 for the mix;
- the error-feedback remainders added into the two filter sums;
- one rounding per sum, saturation, as `FixedBand`;
- its states (ic1, ic2, e1, e2: 118 bits per section, 128 sections) in a simple dual-port RAM (about one BRAM).

**The coefficients:**
- 6 per section, register index k = (slot × B + band) × 6 + j, j = a1, a2, a3, m0, m1, m2, each a 26-bit signed word;
- the bank (`coef_bank_ram`) with `LANES` = 6, so one read returns a section's six, and `PORTS` = 2, one per lane, on one handshake (the library change made for the router);
- a `coef_smooth` on each port (the lanes read disjoint sections);
- `coef_swap` on the last input beat, so a frame's reads all see one bank, as in the template.

**The window** (`lib_svf_eq_regs_axil`):
- ID `0x4551_5001` ("EQ");
- CONFIG: slots, bands, coefficient width;
- 1,536 coefficients, so **8 KB**, not the usual 4 KB. In step C that means the block design gives this one window an 8 KB range (the address map has room at 0x8001_2000 … 0x8001_3FFF; the plan's 0x8001_1000 moves to 0x8001_2000, so it starts on an 8 KB boundary).

**Tests (on the PC):**
- `model/eq_vectors.py` writes test vectors from the model:
  - random designs per slot and band (every type, the extremes);
  - frames of random 24-bit input;
  - the coefficients changed mid-run;
  - the expected outputs, bit for bit.
- The library's regression script runs it before XSim, so vectors are never stale and never checked in.
- `tb_lib_svf_eq` checks:
  - every output sample, bit-exact;
  - the stream contract;
  - the last output beat inside the pool budget;
  - identity bit-exact;
  - each section's coefficients read exactly once per frame.
- Then mutants: wrong rounding, no error feedback, a band skipped, lanes swapped, a stale state, and so on.

**Not in step B:** the router's second pool, the window in the block design, the server's `mixer_eq.py` and the type-change-through-flat sequence. Those are step C.

**Question for the user:** none of substance. The one visible consequence is the 8 KB window and its address (above). Unless you object, step B is built as planned and I check in with the results before step C.

**Decided (the user, 2026-11-17):** build step B as planned.

### 6.1 Step B built (2026-11-17; the library, local, not pushed)

**What was built** (`HDL-DSP-Library/blocks/svf_eq/`):
- `lib_svf_eq_pkg.sv`: the formats, the schedule (`LANE_LAT` 12, `D1` 13, the period), `lat_first`/`lat_last`, `fits`, `coef_index`, the flat section's coefficients;
- `lib_svf_eq.sv`: two lanes alternating bands, error feedback, the output straight from lane 1's last band;
- `lib_svf_eq_regs_axil.sv`: ID `0x4551_5001`; an 8 KB window (1,536 coefficients); `coef_bank_ram` with `LANES` = 6 and `PORTS` = 2; reset all flat;
- `tb_lib_svf_eq.sv`.

Model side (`model/`): `eq_vectors.py` writes the TB's vectors from `FixedBand`. The library's regression runs it first (a new pre-step), and the mutation runner now also copies `blocks/` and `model/`.

**Checked:**
- **Bit-exact:** 14,336 samples over 448 frames. The phases:
  - flat (output = input);
  - random designs of every type;
  - extremes;
  - random designs again, two of the coefficient phases loaded in the middle of a frame's input beats, so the swap point is tested;
  - 384 frames of overload: a full-scale 2 kHz square into seven +15 dB boosts and a Q 10 low-pass, with every saturation in the path hit (the generator checks that the model saturates `v0 − ic2`: 44,537 times).
- **Timing:** the output stream contiguous and ascending, first beat exactly `lat_first`, last exactly `lat_last` (160 cycles after the last input; the pool budget is 221).
- **Reads:** each lane reads each of its sections exactly once per frame.
- **Mutants:** 18 / 18 killed. The first run left two alive, both TB gaps, both closed:
  - "no saturation on v3": the vectors never overloaded the chain; the stress phase was added;
  - "the bank swaps on the first input beat": coefficients only ever changed between frames; mid-frame loads were added.
- **A TB bug found on the way:** its `meta` array was sized for 4 phases, so the 5th was never loaded. Fixed: sized from the phase count.
- **Out-of-context synthesis** (`scripts/synth_ooc.tcl`, xczu3eg, routed): **28 DSP48E2, as planned**; 4 BRAM tiles, 1,605 LUTs (306 as memory), 2,245 registers. WNS 3.74 ns at 100 MHz (the block runs on mclk, 12.3 MHz).
- The library regression is 4 / 4 (coefram, smooth, template, svf_eq); the model's tests 15 / 15.

**Next: step C** (FPGAmixer). The second pool in the router; the 8 KB window at 0x8001_2000; the smoothers in the top; the server's `mixer_eq.py`, the EQ pool type and type changes through flat; the tests; a Vivado check; the image.

## 7. Step C plan: the EQ in FPGAmixer and the server (2026-11-17, for the user's review)

The block is done and generic; step C makes it the second insert type. Nothing in the core or the router's logic changes: the router was built for `NP` pools.

### 7.1 The FPGA side

- **Submodule:** `src/lib` moves to the library's `12f553c`. The Vivado project and both regression scripts pick up `src/lib/blocks/svf_eq/` (its TB stays out, like the template's).
- **Top** (`fpgamixer_top`):
  - `NPOOL` 2: pool 1 is `lib_svf_eq` (32 slots, 8 bands);
  - its binding `lib_svf_eq_regs_axil`, and a `coef_smooth` on each of its two read ports (W 26, 256 words, 6 lanes, the same `SMOOTH_K`);
  - without the PS: two flat readers over the all-flat bank;
  - the router's `POOL_LAT` becomes the larger of the two pools' (the EQ's 160). The router's rule is then 4 + 31 + 160 = 195 ≤ 256.
- **Router tables:** 60 + 2 × 32 = 124 entries (still one 4 KB window), with 5 read ports on its bank.
- **Block design:** `M_AXI_EQPOOL` on `ctrl_smc2` at **0x8001_2000, 8 KB**. The window loop learns a per-port range (today every window is 4 KB). The device tree gains its node.
- **Simulation:**
  - the BD stub gets master 12;
  - `tb_top_windows` checks the EQ window's ID and CONFIG;
  - a flat EQ inserted on a channel must be bit-exact;
  - a low shelf at 1 kHz, +6.02 dB, on a channel with the TB's DC input must give that channel ×2 at the output, to the coefficients' 0.004 dB. The coefficient codes come from the model, so the TB has no design maths of its own.
  - The regression stays green (`tb_insert_router` uses its own behavioural pools, so it doesn't change).
- **Vivado check:** about +28 DSPs (13 → 41 of 360) and about +4 BRAM tiles; timing must hold.

### 7.2 The server

- **`tools/mixer_eq.py`** (new; pure Python, no OSC, no hardware):
  - the design formulas and `EQ_FMT`'s quantization, a copy of the library's model;
  - a slot's 41 parameters → 8 × 6 coefficient words;
  - `eq_on` 0, or a band's `on` 0, → that band flat (m = 1, 0, 0);
  - the high-pass and low-pass ignore gain.
- **`tools/test_mixer_eq.py`** checks the copy against the library's model **through the submodule** (`src/lib/model`), word for word over a grid of settings, so the two can't drift. It runs on the PC.
- **`mixer_hw.py`:**
  - `EqPoolHW` (ID `0x4551_5001`; CONFIG checked: 32 slots, 8 bands, AF 24, MF 18);
  - windows get a size (this one 8 KB; every other still 4 KB);
  - `POOLS` becomes `(("gain", "gainpool"), ("eq", "eqpool"))`, the router's pool order.
- **The server:**
  - the pool type `eq` with the modules of §3. The enum `eq_bandN_type` carries `optionLabels` (Peak, Low shelf, High shelf, High-pass, Low-pass). The defaults are the identity, which the insert router's bit-exact front edits rely on.
  - An `EqPoolDriver` writes a slot's changed bands (6 words each, one COMMIT).
- **Type changes go through flat** (§5, finding 4): when a band's `type` changes, an EQ worker (like the insert worker: outside the ordering lock, values read from the store when each step runs):
  1. the old filter with the flat mix;
  2. wait ~0.1 s;
  3. the new filter with the flat mix;
  4. wait ~0.1 s;
  5. the band's stored values.

  The echo is immediate as always, and the sound follows about 0.2 s later. Other parameter changes are written at once, except to a band whose type change is under way (its last step writes them).
- **Groups, snapshots, persistence:** nothing new. The insert code is generic over pool types. A recall writes types directly (Q2).
- **The recipe:** `fpgamixer-osc` installs `mixer_eq.py` (the explicit file list; learned with `mixer_inserts.py`).
- **Tests:**
  - server tests over TCP: insert an EQ, set a band (echo, config, refusal on a free slot), groups link band parameters, a snapshot round trip;
  - the type-change sequence on fake hardware, in order;
  - `test_mixer_hw` for the window (on the Linux VM).
- **Docs:** the controller spec gains the `eq` type's module table. It's additive: a controller written to the spec already shows it with generic controls.

### 7.3 Then: bitstream, image, bench (yours)

- the gate (null tests);
- **bit-exact with an EQ inserted flat** on the channel-20 path;
- **by ear:** sweep a band fast, boost and cut, the shelves, high-pass and low-pass, a type change (no bump, about 0.2 s), no zipper noise or clicks;
- a response spot check on the meters (a known band setting, a sine).

### 7.4 Questions for the user

- **Q1, a type change waits about 0.2 s before the new type sounds** (the click-free path through flat). Recommended. The alternative is an instant switch, which can bump up to +13 dB on the way for unlike types.
- **Q2, snapshot recalls switch types directly**, with no wait: a recall changes the whole mix at once anyway. Recommended. The alternative is that recall also goes through flat for every band whose type changes (+0.2 s for those bands).
- **Q3, build the image and bench right after step C.** Recommended, as with the inserts.

**Decided (the user, 2026-11-17):** Q1 yes (type changes through flat, ~0.2 s), Q2 yes (recall switches types directly), Q3 yes (image and bench right after step C).

### 7.5 Step C built (2026-11-17; local, not pushed)

**Checked:**
- FPGAmixer regression **18 / 18**. `regs` failed once with "child exe not found" (Defender) and passed on rerun.
- `tb_top_windows`: the EQ window's ID, CONFIG and its last register (8 KB); an EQ inserted flat is **bit-exact**; a +6.02 dB low shelf at 1 kHz on input 13's DC gives **exactly 0x1C0000 = 2 × 0x0E0000**, the model's value, through the real smoothers.
- Python: 243 tests on Windows, 304 on Linux (the VM), with:
  - `test_mixer_eq` (the copy vs the library model, 875 settings word for word; the plans; the driver on a fake clock);
  - `EqInserts` (TCP end to end);
  - `test_mixer_hw` with the 8 KB window.
- **Two bugs found and fixed before commit:**
  - `band_steps` issued no-op writes;
  - the driver's re-plan after a wait would repeat its "new filter, flat mix" step forever.
- **Mutants:** `eq_server.json` **10 / 11**. The 11th, "filters keep the gain", is equivalent: `design()` ignores gain for high- and low-pass. The first run also let "the high shelf's m1 sign" survive: the Python mutation runner didn't copy the library's model, so the word-for-word test skipped itself. Fixed (`mutate_py.ps1` copies `src/lib/model`); killed.

**Vivado `eq1`:** WNS 4.145 ns, WHS 0.010 ns, 0 failing, 0 critical warnings, methodology PASS. Against `lf8`:

| | lf8 | eq1 | |
|---|---|---|---|
| LUTs | 26,067 | 30,317 | +4,250 |
| registers | 38,267 | 40,857 | +2,590 |
| BRAM tiles | 13.5 | 33 | **+19.5** |
| DSPs | 13 | 42 | +29 (the EQ 28, its window 1) |

**BRAM: more than §7.1's "about +4"**, which counted only the block. By module (the hierarchical report):

| Module | BRAM tiles |
|---|---|
| the EQ block | 4 |
| its window (the shadow and 2 × 6 lane RAMs) | 7.5 |
| its two smoothers | 6 |
| the router's history copies and the table bank's fifth port | +2 |

33 of 216 tiles is 15 %. If BRAM ever gets tight, the smoothers' current values could move to LUT-RAM.

**Blocked: the SDT.** `sdtgen.exe` is now refused by Windows Device Guard ("blocked by your organization's Device Guard policy"), twice. It ran for `lf8` on 2026-11-01. Not worked around: it is the user's security policy.

**The SDT, derived (the user, 2026-11-17: "Derive them from lf8"):** `build/sdt` = `sdt.lf8` with only what `sdtgen` would change for one more window:
- **The bitstream:** `fpgamixer_eq1.bit`, taken from the `eq1` XSA (MD5 `aac88b73…` = the XSA's).
- **`psu_init.*`:** taken from the `eq1` XSA, all six byte-identical to `lf8`'s (no PS change).
- **`pl.dtsi`:** `firmware-name` `fpgamixer_eq1.bit.bin`.
- **`pcw.dtsi`:** the `M_AXI_EQPOOL@80012000` node (reg `0x2000`), after `M_AXI_GPOOL`'s, in its form.
- **`system-top.dts`:** the window's line in each of the four `ranges` lists, in address order, size `0x2000`.

The method was checked first: a full `diff -r` of `sdt.lf2` → `sdt.lf8` shows exactly these three files and the bitstream changing for `lf8`'s two windows; `extracted/` and `include/` are identical. The XSA's `ps_sys.hwh` confirms the window at 0x8001_2000 … 0x8001_3FFF. If the tree were wrong, `gen-machine-conf` would fail, or the server would refuse the window (no device-tree node): it fails safe.

### 7.6 Bench session `eq1` (the user; the board at `ssh amd-edf@10.0.0.2`)

This image carries three untested layers: `lf2` (smoothing), `lf8` (inserts) and the EQ. So the gate comes first. A reflash wipes the mix and the on-board snapshots: save what's needed first.

1. **Flash, boot.** If the Ethernet LEDs go dark after a second, do a full power-off for ~10 s. Restore the mix and the channel-20 path.
2. **Board check:**
   - `sudo python3 /usr/lib/fpgamixer/mixer_hw.py inserts` prints the router (`K 8, 2 pool(s) x 32 slots, 9 frames per insert point`), `gain pool, 32 slots, Q2.16` and `EQ, 32 slots x 8 bands, a Q.24, m Q.18`;
   - `journalctl -b -u fpgamixer-osc | grep Inserts` shows `pools gain (32), eq (32)`.
3. **The gate:** T1 USB → USB, AVB → AVB, USB → AVB, 5 min each: all PASS, bit-exact.
4. **An EQ in the path, flat:** insert `eq` on the channel-20 path (input 20; OSC index 19); T1 USB → USB, 5 min: **PASS, bit-exact**.
5. **By ear**, an EQ on a channel you listen to:
   - a +12 dB peak swept fast across the range: smooth, no zipper noise;
   - boost and cut; a low and a high shelf; a high-pass at ~200 Hz; a low-pass;
   - **change a sounding band's type**: about 0.2 s later the new type, no bump;
   - `eq_on` off and on: a smooth fade;
   - `lf2`'s checks: fast fader moves, −∞ and back, a snapshot recall: no clicks.
6. **Persistence:** `sudo reboot`; the EQ and its settings are back.

**After a pass:** `eq1` replaces `p15e` as the image in use. A response spot check (a known sine through a known band, read on the meters) is optional, if a tone source is at hand.
