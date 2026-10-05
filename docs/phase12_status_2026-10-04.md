# Phase 12 status: 2026-10-04 — channel levels and the bus layer: design proposal

*Opening prompt: `prompt_phase12_channels_buses.md`. Branch `phase12-levels-buses`, from `controller-support` at `6e70512`.*

**State: decided 2026-10-04 (L1–L10 all as recommended, §5); step 1 done in simulation (§6.1); step 2 (`mixer_core` with the chain) next.**

---

## 1. The goal

A **level** on every input, bus and output, and the **bus layer**: inputs → `inputMatrix` → buses → `busMatrix` → outputs. This brings the app's Inputs, Buses and Outputs tabs and both matrix tabs to life on the board, with no app change: the app builds everything from the config reply (controller D5, D64–D65, D74–D77).

## 2. Facts this rests on (checked 2026-10-04 in the tree, unless marked)

| Fact | Source | Consequence |
|---|---|---|
| The core is `pack2stream → pcm_matrix → stream2pack`. The header reserves the space between the converters for the bus layer and DSP. | `mixer_core.sv` | The chain goes inside `mixer_core`. `fpgamixer_top` gains coefficient ports and windows, and the front doors don't change. |
| **The matrix starts a frame on the beat for input N_IN−1**, and it depends only on beat order, not on its producer's timing. | `pcm_matrix.sv` (`start`) | Chained blocks compose directly: the bus matrix starts on the last bus beat. The matrices run in series, with no overlap. |
| `lat_last = passes·N_IN + 5 + l_last` after the last input beat, and core D = N_IN + lat_last + 1. **20 × 20 on 2 lanes: D = 227** (re-derived). | `pcm_matrix_pkg.sv` | The chain's D is a sum of per-block terms (§3.3). |
| `coef_bank_ram` is generic, with rows round-robin over lanes. With ROW_LEN = 1, N_ROWS = N and LANES = 1, word *c* is channel *c*'s gain. The bank swaps on the strobe edge, and a read in the strobe cycle still sees the old bank. | `coef_bank_ram.sv` header | A gain stage reuses it unchanged and reads `coef_addr = s_ch`. All reads in the chain fall inside one frame (D ≤ 250), so every block sees one bank per frame. |
| `matrix_regs_axil` defaults `LANES = matrix_lanes(N_IN, N_OUT)`, the single-matrix rule. | `matrix_regs_axil.sv` | In a chain, the lane counts must come from one place and be passed in explicitly (§3.3). |
| `MatrixBackend` is already generic over the zone name, sizes and window. It seeds the diagonal at 0 dB and normalises stored levels. | `osc_mixer_server.py` | `busMatrix` is a second instance on its own window. |
| **Module metadata is global per module name.** `Model.add_zone` refuses a module that two zones describe differently. `level` = float dB, −90 … ceiling, default −90. | `mixer_params.py`, controller status §4 | Channel levels must use **the same Q2.16 format** (ceiling +6.02 dB) as the matrices. Otherwise `level` would differ between zones and the model would refuse it. See L7. |
| Config values are sparse (absent = the module default, −90). The app's D77 expects channel levels to be listed explicitly. | standard "Config", D77 | Channel backends seed 0 dB at startup, so their 0 dB levels are non-default and appear in `values`. |
| The app labels matrix axes from the channel zones when they are present (D76). The standard's matrix is row = source, column = destination. | D76, standard | With `busChannel` advertised, the app labels `inputMatrix` columns as buses. |
| Device: 360 DSP48E2s, 432 RAMB18s. Today: 2 DSPs (matrix), a few RAMB18s. | phase 9 §5.1, P9.5 | Neither resource is close to a limit at any size below (§3.3). |

## 3. The shape

### 3.1 Inside `mixer_core` (stream contract §2.1 between every block)

```
in_flat ─pack2stream─► pcm_gain ─► pcm_matrix ─► pcm_gain ─► pcm_matrix ─► pcm_gain ─stream2pack─► out_flat
                       (input     (inputMatrix: (bus         (busMatrix:    (output
                        levels)    N_IN → N_BUS)  levels)     N_BUS → N_OUT)  levels)
                          ▲             ▲            ▲             ▲             ▲
                          └──── five coefficient read ports (§3 of the architecture doc) ────┘
```

- **`pcm_gain`**: a new generic PCM core block. Stream in, stream out, N channels, `y[c] = sat(x[c] · g[c] >>> GF)`, with the same arithmetic as one matrix crosspoint (Q2.16, truncate, saturate to SW). It reads its coefficient at `coef_addr = s_ch`, so one DSP48E2 is time-shared over all channels (at most one beat per cycle). It states its timing (latency G after each beat). It is bit-exact against a reference model.
- **It is the natural home for later per-channel work.** Mute = gain 0 (a server-side combination of `level` and `mute`, no new gateware). Gain smoothing = a ramp on the coefficient inside this block (§3 of the architecture doc: the contract doesn't change). Meter taps = its output stream (L8).
- `mixer_core` keeps the packed contract on both sides. Its coefficient side becomes five read ports. The single-matrix core stays reachable as a parameter (`N_BUS = 0`: no bus layer, no gain stages) only if you want it (L10). Otherwise the core is always the chain.

### 3.2 Control plane

| Window | Block | Binding | ID |
|---|---|---|---|
| 0x8000_0000 | `inputMatrix` (unchanged address; **meaning input → bus**) | `matrix_regs_axil` | `0x4D58_5001` |
| **0x8000_5000** | `busMatrix` | `matrix_regs_axil` (second instance) | `0x4D58_5001` |
| **0x8000_6000** | input levels | **`gain_regs_axil`** (new, small) | `0x474E_5001` ("GN") |
| **0x8000_7000** | bus levels | `gain_regs_axil` | `0x474E_5001` |
| **0x8000_8000** | output levels | `gain_regs_axil` | `0x474E_5001` |

`gain_regs_axil` = `axil_coef_window` + `coef_bank_ram` (ROW_LEN 1, LANES 1). Its CONFIG word is `[31:24] N`, **`[23:16]` the tap (0 input, 1 bus, 2 output)**, `[15:8]` GW, `[7:0]` GF. Its registers are `GAIN[c]` at 0x100 + 4c, and it resets to unity (0x10000). The three gain windows share an ID. The tap field lets `mixer_hw` verify that it opened the window it meant to, not only the right *kind* of window (linkstat/linkstat2 could only check the kind). Each window gets a presence guard (a DT node `…@8000x000`) as before.

### 3.3 Latency: two matrices and three gain stages inside one frame

D = N_IN + 3G + lat_last(N_IN, N_BUS, L1) + lat_last(N_BUS, N_OUT, L2) + 1, with D ≤ D_MAX = 250. These numbers come from the package formulas, re-computed today. **They are estimates, not synthesis results.** G is the gain stage's latency per beat. My design is G = 4 (coefficient read, A/B, M, saturate); the table budgets G = 5.

| N_BUS | Lanes L1 + L2 (matrix DSPs) | + gain DSPs | D | Note |
|---|---|---|---|---|
| 20 (= N_OUT) | **4 + 5** (or 5 + 4) | 3 | **233** | recommended; 12 DSPs in all |
| 20, no gain stages | 4 + 4 | 0 | 237 | (the prompt's figure; checks out) |
| 16 | 4 + 3 | 3 | 242 | tight |
| 8 | 2 + 2 | 3 | 208 | (the prompt's "D ≈ 248" was the 1 + 3 split; 2 + 2 is better) |
| 28 × 28 core, 28 buses (Phase 11 growth) | 10 + 10 | 3 | 236 | 23 DSPs of 360 |

**Proposal:** generalise `pcm_matrix_pkg` into a chain package (`mixer_core_pkg`, or the same package extended). It holds `gain_lat()`, `chain_latency(n_in, n_bus, n_out, l1, l2)` and a chooser: the fewest total matrix lanes with D ≤ D_MAX, ties broken by the smaller D. `mixer_core`, `fpgamixer_top` (which sizes both banks) and both `matrix_regs_axil` instances take L1/L2 from it. The core `$error`s at elaboration past D_MAX, as the single matrix does now. **The added latency is zero frames:** link and I2S-L stay at +1 frame, and I2S-R is unchanged because D > 126 already.

BRAM: one `coef_bank_ram` per lane and per gain stage, so about 1–2 RAMB18s each, roughly 15–25 of 432 in all. This gets measured in step 4.

### 3.4 Software

- `mixer_hw`: `GainHW(RegWindow)` (ID `0x474E_5001`, checks N and the tap, takes dB in and returns the applied dB). Three `WINDOWS` entries (`inlevel`, `buslevel`, `outlevel`) and `busmatrix` (a `MatrixHW`). CLI: `info` covers them, plus `dump`/`set` for the new windows.
- `GainBackend(zone, hw, n)`: zones `inputChannel` / `busChannel` / `outputChannel`, module `level`, **described exactly like the matrix's** (same `ModuleSpec`: the model refuses anything else). `seed_and_push`: a missing level is seeded at **0 dB**, stored levels are normalised, and the whole bank goes out in one commit.
- `build_backends()`: five backends. The simulator (`--matrix-size`) builds the same five with B = N.
- **The state format doesn't change.** New zones are new top-level keys. An old state file loads as it is: `inputMatrix` keys are untouched, and the new zones get seeded.
- Tests: the in-process tests against fake windows, the subprocess harness, `app_config_problems` on the new config, and the restore test extended to channel levels and `busMatrix`.

## 4. What changes for saved state and the bench

With **N_BUS = N_OUT and the bus matrix at identity**, input → bus *k* → output *k* reproduces today's input → output *k* exactly (0 dB through the bus and output stages, unity gain stages), so **every saved `inputMatrix` crosspoint keeps its audible effect, and no migration is needed.** Two caveats, both inherent:

- A bus sum now saturates at the bus (24 bits), then passes the bus level and the bus matrix. With an identity bus matrix and 0 dB levels this is bit-identical to today: the same saturation, in the same place.
- Flashing the image erases saved state anyway (bench notes). The compatibility matters for units that keep their state across a server-only update.

## 5. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| **L1** | Where the levels live: **(a)** PL gain stages (`pcm_gain`, one per tap, own windows), or (b) folded into the matrices in software? | **(a).** The hardware matches what the app shows; there are real meter tap points; a home for mute, smoothing and Phase 7 DSP; and a level move is one register write plus a commit, not a row/column rewrite. Cost: 3 DSPs, about 15 cycles, one more matrix lane. |
| **L2** | Bus count | **N_BUS = N_OUT (20)**, as a parameter derived from the platform's channel map, so it follows the core when it grows (28 with USB host). |
| **L3** | `inputMatrix` becomes input → bus. What happens to old crosspoints? | With L2 and an identity bus matrix: **nothing; they keep their effect** (§4). Recorded in the architecture doc and in the server docstring (which today says "bus = output for now"). |
| **L4** | Latency | **Stay inside one frame** (D = 233 estimated at 20/20/20). A chain package computes D in one place, chooses the lanes, and refuses to elaborate past D_MAX. |
| **L5** | Saturation | **Saturate at every block's output** (gain stages and both matrices), to 24 bits, as a console does. The bus sum clips at the bus. Bit-exact models check every stage. Widening the internal format (C6) stays a Phase 7 question. |
| **L6** | Register windows | §3.2: bus matrix at **0x8000_5000**, gain stages at **0x5000 + 0x1000 · (1…3)**, i.e. 0x8000_6000 input, 0x8000_7000 bus and 0x8000_8000 output. One new binding, `gain_regs_axil`, ID `0x474E_5001` with the tap in CONFIG. The architecture doc §4.1 table, `mixer_hw.WINDOWS`, the BD address map and the DT presence checks are all updated. |
| **L7** | Defaults and ceiling | PL reset: unity gains, both matrices at identity. Server fresh state: channel levels seeded at **0 dB**, input matrix diagonal 0 dB, bus matrix identity. **Channel levels use the matrices' Q2.16 format (ceiling +6.02 dB)**, so `level` stays one shared module (D77). More headroom on inputs (e.g. +12 or +18 dB trim) would need either a different module (D64's `trim`, later) or per-zone metadata, which is an app and model change. Not now. |
| **L8** | Metering in this phase? | **Neither in this phase; it goes immediately after**, as its own small piece: F4a (a peak detector on the gain stages' output streams, which already are the "post-DSP" taps the standard names) plus server step 6. This phase only makes sure the taps exist and are documented. A synthetic meter source on the board would show meters that aren't real. |
| **L9** | Growth | Every size is a parameter derived from `fpgamixer_top`'s channel map (N_IN, N_OUT, N_BUS = N_OUT). Channels are appended, never interleaved. The TBs run 20/20/20 and at least one uneven size (e.g. 7 → 5 → 3). The 28 × 28 case is checked at elaboration (lanes and D) but not built. |
| **L10** | Name, and the old single-matrix core | Record it in the roadmap as **Phase 12, "channel levels and buses"**: the first slice of Phase 7's per-channel and per-bus processing plus §6's bus layer (Phase 7 keeps EQ, dynamics, delay and mute). **Drop the single-matrix configuration** of `mixer_core`: every build gets the chain, which keeps one tested path. |

**Decided by the user, 2026-10-04: all as recommended.** L1 PL gain stages (`pcm_gain`); L2 N_BUS = N_OUT; L3 no migration; L4 inside one frame, one chain package; L5 saturate at every block; L6 windows 0x8000_5000 (bus matrix), 0x6000 / 0x7000 / 0x8000 (input / bus / output levels), `gain_regs_axil` ID `0x474E_5001` with the tap in CONFIG; L7 unity / identity at reset, 0 dB seeded, Q2.16 shared `level`; L8 metering right after this phase; L9 sizes as parameters; L10 roadmap "Phase 12", single-matrix core dropped.

## 6. Steps after the decisions

Each step is built, tested, committed, and recorded here.

1. **RTL blocks:** `pcm_gain` + `tb_pcm_gain` (bit-exact, timing to the cycle, stream monitor); the chain package and its own small check (D and lanes for the sizes above). Icarus and XSim kept in step. Mutation: a wrong coefficient address, a missing saturation, G off by one.
2. **`mixer_core` with the chain** + a core-level TB: random samples and gains at all five stages, against a model of the whole chain, including bus saturation; D checked to the cycle. Mutation: a wrong bus stride, a skipped bus saturation.
3. **Control plane RTL:** `gain_regs_axil` + its TB (the `tb_matrix_regs` pattern), the second `matrix_regs_axil`, `fpgamixer_top` wiring (non-PS builds through `coef_flat_reader`s), SmartConnect ports and the address map in `create_project.tcl`.
4. **Vivado:** timing, CDC, the methodology gate; DSP and BRAM counts recorded. Export, `sdtgen`, compare `psu_init` (expected identical), DT (four new nodes).
5. **Software:** §3.4, all tests on the PC and on the VM.
6. **Image + bench:** USB in (Mac) → input level → bus → bus level → bus matrix → output level → JB_L, by ear, one check per stage. Then the power-cycle restore check with audio.

### 6.1 Step 1: `pcm_gain` and the chain package (simulation): PASS

| File | What |
|---|---|
| `src/rtl/pcm_gain.sv` (new) | the gain stage: stream in/out, read port `coef_addr = s_ch` (ROW_LEN 1, LANES 1), one multiplier; **G = 4** (register, A/B, M, saturate), so every beat leaves exactly 4 cycles after it arrived and the input's order, gaps and timing carry through. Same arithmetic as one matrix crosspoint |
| `src/rtl/mixer_core_pkg.sv` (new) | `GAIN_LAT`, `chain_bus_last`, `chain_out_last`, `chain_latency`, `chain_l1` / `chain_l2` (fewest total lanes with D ≤ D_MAX, ties to the smaller D, then the smaller L1). Uses `pcm_matrix_pkg`'s per-matrix formulas, unchanged |
| `src/sim/tb_pcm_gain.sv` (new) | N = 1, 4, 20, 28 contiguous, and 20 with random gaps; 60 frames each, random samples and gains with extremes; every beat bit-exact vs a 64-bit reference, on its channel, exactly G cycles after its input; no unexpected beats; `pcm_stream_monitor` (first/last beat and no gaps where contiguous) |
| `src/sim/tb_mixer_core_pkg.sv` (new) | lanes and D for 20/20/20, 12/12/12, 28/28/28, 40/40/40 (= D_MAX), 48 and 64 (nothing fits), 20/8/20, 20/16/20, 7/5/3, 1/1/1, against values from an independent Python model of the formulas |
| `scripts/sim.mk`, `scripts/xsim_regress.ps1` | targets `corepkg`, `gain` (in step) |
| `scripts/xsim_regress.ps1` | **fix:** `.\scripts\xsim_regress.ps1 a b` bound only `a` and silently skipped the rest (a plain `[string[]]` parameter); now `ValueFromRemainingArguments`. Found because `gain` printed no line |

**The estimate moved, in your favour on DSPs:** with G = 4 instead of the budgeted 5, the rule picks **4 + 4 lanes at 20/20/20, D = 249** (one cycle under D_MAX; 4 + 5 would be 230). That is the same rule `matrix_lanes` applies (spend lanes only when the frame needs them). So the chain needs 8 matrix DSPs + 3 gain DSPs = **11**. D_MAX already carries the 3-cycle margin to `i2s_port`; a later Phase 7 block that lengthens the chain makes the chooser add a lane by itself.

**Results (XSim 2026.1):** `corepkg` PASS; `gain` PASS (5 × 60 frames, 0 errors). Icarus not run (not installed on this PC); the `sim.mk` targets are written like the others.

**Mutation test** (scratchpad runner: copies `src/` and `scripts/` to a temp folder, runs the unmutated baseline there first, stops if it fails; one replacement per mutant): **11 of 12 killed.** Killed: wrong coefficient address (3700 errors), no positive / negative saturation (522 / 610), valid one cycle early (5573), rounding instead of truncation (877), sample and gain misaligned (3031), channel tag from the wrong stage (4843); package: GAIN_LAT missing at the buses, the +1 missing, ties to the later candidate, D_MAX + 1 accepted, all failing `corepkg`. **Survived, equivalent:** capping L1 by N_IN only (not also N_BUS). Lanes beyond a matrix's outputs can't shorten it (one pass either way), so the chooser always settles the tie at the smaller total before the cap could matter; `pcm_matrix` still refuses such a LANES at elaboration.

## 7. Not in this phase

Mute, EQ, dynamics, delay; gain smoothing (its place: inside `pcm_gain`); metering (L8); USB host mode; the open AVB checks.
