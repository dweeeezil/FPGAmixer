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

**Next, after Q5: step B** (the RTL block `lib_svf_eq` in the library), bit-exact against `FixedBand` with `EQ_FMT`.
