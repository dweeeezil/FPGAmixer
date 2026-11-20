# Proposal: the core's foundation for the DSP library (2026-10-10)

**Context:** hardening before the DSP library (`hardening_status_2026-10-10.md`, step 5). The user decided (HD2–HD7): **the core may span more than one frame (A)**; **the library is its own repo**; **click-free coefficient changes**; **a template block**; **multi-input blocks (sidechains) pick their extra inputs like channel sources**; **spatial processing / binaural is its own section, not a plugin**.
**State:** **decided 2026-10-26: LF1–LF8 all as recommended (§8).** Nothing built yet.
**The library repo (the user, 2026-10-26):** `C:\Users\dodec\Documents\HDL-DSP-Library`, remote `https://github.com/dweeeezil/HDL-DSP-Library.git`. **Empty**: no commits, no files, and no `main` on the remote yet; so LF5's "move the primitives there" starts from a blank repo, and nothing there constrains the decisions.

---

## 1. Today

- The chain (`mixer_core`): input patch → input levels → input matrix → bus levels → bus matrix → output levels → output patch; **D = 251 of D_MAX = 255**: the whole chain inside one 256-cycle frame. An EQ, a compressor or a delay added to the chain has no room.
- What actually depends on the frame strobe (checked in the RTL):
  1. **the coefficient banks** (`coef_bank_ram`): every block's bank swaps at the *global* strobe, and a block must do all of a frame's reads between two strobes;
  2. the two ends: `pcm_patch2stream` captures the I/O ports on the strobe; `pcm_stream2patch`'s output is taken by the links at the next strobe;
  3. the meters' windows (`pcm_peak`: a SNAP closes a window at a strobe);
  4. the stream contract's rule "all beats of frame k lie between strobe k and strobe k + 1", and `pcm_stream_monitor` checks it.
- What doesn't: the blocks themselves start **on order** (the first or last beat of their input), not on the strobe (`pcm_matrix` starts on beat N_IN − 1, `pcm_gain` on every beat).

## 2. A: a core that spans frames

**The rule changes from "every stream inside its frame" to "every block keeps up with the frame rate":**

- A stream's beats of frame k may lie anywhere, crossing strobes, as long as **consecutive frames' beats arrive exactly 256 cycles apart** (a fixed schedule, as today) and **each block's occupancy per frame is ≤ 256 cycles** (it is done with frame k before frame k + 1 reaches it). Latency is then any stated number of cycles; D stays a number (e.g. 600 = 2 frames + 88 cycles), and the links take the output at the strobe after it: still a fixed latency.
- **Each block's coefficient bank swaps at the block's own frame start, not the global strobe**: the strobe travels down the chain with the stream (`frame_o` = the input stream's frame marker delayed by the block's latency), and each block's `coef_bank_ram` / smoother takes its block's marker as `frame_i`. A frame then sees one whole bank in *every* block, however late it runs. This is the one real change; the bank RAM itself doesn't change (its `frame_i` is just a different wire).
- **The stream contract gains a frame marker**: `s_first` (the beat of channel 0 of a frame) already is one; the contract's "between strobes" rule becomes "N beats, ascending, between consecutive `s_first`, which are 256 cycles apart". `pcm_stream_monitor` checks that instead.
- **Meters**: a SNAP closes the window at the meter's own frame start (its tap's marker), so every frame still belongs to exactly one window.
- **`mixer_core_pkg`**: latency in cycles without the D_MAX bound; the bound becomes per block (occupancy ≤ 256) plus a sanity cap (e.g. 8 frames); the lane chooser keeps choosing the fewest DSPs for an occupancy that fits (the matrices' occupancy today is ~100 cycles).
- **Cost**: a few registers per block for the marker; no new clock domain; the links and front doors don't change. Latency grows by whole frames only where the chain needs it (20.8 µs each; the user: negligible).

Rejected: a faster processing clock (B: every block re-timed, the MMCM's fine phase shift on two outputs, the Phase 9 decision to stay on `mclk`); more lanes (C: buys ~20 cycles).

## 3. Click-free coefficient changes

- **A generic smoother between the bank and the block**: `coef_smooth`, the same read-port interface on both sides, so a block doesn't know it's there (like `coef_bank_ram` vs `coef_flat_reader` today). It keeps the *current* value of every coefficient in a RAM; every frame, as the block reads a coefficient (each is read exactly once per frame), it moves the current value toward the bank's target and returns the moved value: `cur += (target − cur) >>> K`, a one-pole per coefficient (K = 6 → τ ≈ 64 frames ≈ 1.3 ms; a parameter). Read-modify-write on a dual-port RAM, +1 cycle on the read port.
- **Gains** (levels, crosspoints, sends, makeup) smooth in the linear domain this way. **Filter coefficients** (EQ biquads) smooth too for normal parameter moves; a block whose coefficients can't be interpolated safely declares it, and the template offers a **crossfade** form instead (run old and new for a few ms and fade): decided per block in the library.
- **Retrofit to today's blocks** (`pcm_gain`, both `pcm_matrix`es): this removes today's clicks on fader moves and snapshot recalls (Phase 5 decision: clicks deferred; Phase 14: "a recall may click"). It costs one BRAM per smoothed bank and nothing in the OSC protocol (the standard's click note is then removed).
- **Mute** (Phase 7's first item) is a level of −90 dB through the smoother: a fade, not a click.

## 4. The template block

Every library block starts from one skeleton (in the library repo):

| Part | What it is |
|---|---|
| RTL | stream in → stream out (the contract above, frame marker included), one coefficient read port per bank, `frame_o`, a stated latency and occupancy (package functions, checked at elaboration) |
| Binding | `<block>_regs_axil`: ID, CONFIG, bank geometry over `axil_coef_window` + `coef_bank_ram` (+ `coef_smooth`) — today's pattern |
| TB harness | a model in SystemVerilog (64-bit, bit-exact), random coefficients and audio per frame, `pcm_stream_monitor`, `coef_flat_reader` banks; a run at several sizes |
| Mutation harness | the scripts used here (`mutate.ps1` / `xsim_regress.ps1` targets) |
| Server side | a `Backend` with `describe()` (modules, metadata, `linked` where it makes sense) — documented as the contract the FPGAmixer server follows |

## 5. Multi-input blocks (sidechains)

- **UX (HD6)**: a block with a second input has a module like `sidechain` on its channel: an `enum` with `optionLabels`, picked exactly like `source` (None, then the choices).
- **Choices**: the input channels (post input patch), the buses, and the I/O ports? Recommended: **the input channels and the buses** (what a console offers: key a compressor from another channel or a bus); I/O ports are reachable by patching a channel. To decide (LF6).
- **In the core**: a generic **`pcm_frame_tap`**: captures a stream (e.g. the input levels' output, the buses) into a double-buffered RAM, one entry per channel, swapping at its frame marker; a block reads entry `sidechain[c]` (a table like the patch's, through a read port) while processing channel c. The sidechain is then one frame behind the main signal (20.8 µs): irrelevant for detection, and it removes any ordering problem (channel 3 keyed by channel 17).

## 6. Sections

The spatial processor / binauralizer is a **section** (HD7): its own zone(s), its own place in the chain (e.g. buses → spatial → outputs, or a parallel path), not a per-channel plugin. The core should therefore describe its chain as a list of **sections**, each a list of stages, so a section is added like a block is today (the platform layer composes; `mixer_core` stops hard-coding seven stages). Proposed now only as the shape; built when the section is.

## 7. The two repos

- **The library repo** holds the blocks, their bindings, their TBs, the template, and — so that a block can be built and tested on its own — **the shared primitives**: the stream contract and `pcm_stream_monitor`, `coef_bank_ram`, `coef_flat_reader`, `coef_smooth`, `axil_coef_window`, `pcm_frame_tap`.
- **FPGAmixer** keeps the core's composition (`mixer_core`, the converters, the packages), the platform, the server, and **consumes the library as a git submodule** (`src/lib/`), pinned to a commit, so a library change reaches the mixer only when updated here (and the regression runs here on every bump).

## 8. Decisions (recommended first)

**Decided 2026-10-26 (the user): all eight as recommended** (the "Recommended" column). The user also asked to be more hands-on from here: each step's plan is shown before it's built, with check-ins at milestones.

| # | Question | Recommended | Alternative |
|---|---|---|---|
| LF1 | Multi-frame timing | per-block bank swap at the block's own frame start (`frame_o` travels with the stream); "keeps up with the frame rate" replaces "inside one frame"; latency in cycles, capped at ~8 frames | a frame retimer block after the chain's 255th cycle (simpler to state, but every block after it waits a whole frame) |
| LF2 | Smoothing | `coef_smooth` between bank and block (one-pole per coefficient, K a parameter, default ~1.3 ms) | ramps inside each block |
| LF3 | Retrofit | smooth today's levels and matrices first (removes today's clicks), before any new block | only new blocks |
| LF4 | Filter coefficients | smoothed by default; a block may declare crossfade instead | always crossfade |
| LF5 | Primitives' home | the library repo (blocks test on their own); FPGAmixer pins it as a submodule | primitives stay here, the library depends on FPGAmixer |
| LF6 | Sidechain choices | input channels and buses | also I/O ports and output channels |
| LF7 | Sidechain timing | one frame behind (`pcm_frame_tap`) | same frame (only for sources earlier in the chain) |
| LF8 | Sections | describe the chain as sections now (no new section yet) | when the spatial section is built |

## 9. Steps (once decided)

1. LF1 in the core: the frame marker through every block, per-block bank swap, the monitor and the package; every existing TB re-run, plus a TB with a chain deliberately longer than a frame. Mutation-tested.
2. LF2/LF3: `coef_smooth` + its TB; on the level stages and matrices; bench by ear (fader moves, recalls).
3. The library repo: the primitives moved (LF5), the template block, its harness; FPGAmixer takes it as a submodule; regression green on both.
4. The first library block (mute is free with LF2; then EQ or dynamics, the user's pick), end to end with its zone in the server and the standard.

## 10. Step 1 plan: LF1, the core spans frames (2026-10-26, for the user's go-ahead)

**Found in the RTL** (`mixer_core.sv`, `coef_bank_ram.sv`, `pcm_matrix.sv`, `pcm_gain.sv`, `pcm_stream2patch.sv`, `pcm_peak.sv`, `pcm_stream_monitor.sv`, `fpgamixer_top.sv`): the blocks already start on their input's beats, not on the strobe. Four things still lean on the global strobe: every coefficient bank swaps on it (7 banks, `fpgamixer_top`); the meters close their windows on it; `pcm_stream2patch` flags "strobe while a frame is incomplete"; the TB monitor checks "every beat between two strobes". The input converter (`pcm_patch2stream`) captures on the strobe and stays so: it *is* the chain's start.

**The rule, made concrete:** a block's bank swaps on **its input's last beat of a frame** (`valid && ch == N-1`). The read issued in that cycle still sees the old bank, every later one the new (`coef_bank_ram`'s existing semantics). That works for both kinds of block: `pcm_gain` reads per input beat, so the next read is the next frame's channel 0; `pcm_matrix` starts a frame's reads on that same edge (its input's last beat), so all of the frame's reads see the new bank, provided the previous frame's reads are done by then (**occupancy ≤ 256 cycles**, the new per-block rule). The pulse is computed from the stream, so no block changes: the core exports one swap pulse per coefficient port.

**Changes:**
1. `mixer_core`: 7 outputs `*_swap` (the input patch = the strobe; the others = the last beat of the stream into that block). Its `D ≤ D_MAX` check becomes "each matrix's occupancy ≤ 256" plus a sanity cap (D ≤ 8 frames).
2. `mixer_core_pkg` / `pcm_matrix_pkg`: occupancy functions; the lane chooser (see the question below).
3. `fpgamixer_top`: each bank's (`coef_bank_ram` or `coef_flat_reader`) `frame_i` from its swap pulse; the meters' from their tap's last beat (`pcm_peak` itself unchanged: a beat sampled on its pulse edge already belongs to the closing window).
4. `pcm_stream2patch`: the strobe-based "incomplete frame" check goes (the channel-order check already catches a broken frame); its `frame_i` port goes.
5. `pcm_stream_monitor` (sim): frames are marked by channel 0, consecutive frames exactly 256 cycles apart, all N beats ascending before the next channel 0; FIRST_BEAT/LAST_BEAT may exceed 256 (measured from the frame's own strobe).
6. **A new TB case: a chain longer than a frame.** 12 / 12 / 12 forced to 1 + 1 lanes (each matrix 144 cycles, D ≈ 350 > 256), audio and **random commits to every bank while it runs**; each output frame must equal the model with *one whole bank per block* (old or new, never a mix: a "torn" frame fails). Plus every existing TB re-run (17), and mutants (e.g. one bank left on the global strobe; the monitor's spacing check; the occupancy bound).

**What changes on the board:** nothing audible. 20 / 20 / 20 keeps D = 251 (if the chooser stays as it is), the banks swap a few cycles later than the strobe, the meters close on their tap's frame. Effort: RTL small, the TB work larger; a few hours.

**Questions for the user:**
- **Q1, the lane chooser.** With frames no longer a limit, each matrix only needs occupancy ≤ 256: 20 / 20 / 20 could run on 2 + 2 DSPs instead of 4 + 4, at D ≈ 450 (one frame more: +20.8 µs). Recommended: **keep latency first** (fewest DSPs that still fit one frame, as today; fall back to the occupancy rule only when nothing fits). DSPs aren't scarce (the ZU3EG has 360; the core uses ~11).
- **Q2, the bitstream.** Step 1 changes nothing audible. Recommended: **no bitstream for step 1 alone**; build one after step 2 (the smoothing, which you will hear), so one Vivado build and one bench session cover both.

### 10.1 Step 1 built (2026-10-26; the user's go-ahead with Q1 latency first, Q2 no bitstream until step 2)

**A correction to the plan, found while reading the RTL:** "occupancy ≤ 256" isn't the whole rule for `pcm_matrix`. It keeps one frame's input samples in a single buffer, which the next frame's beats overwrite, so it must also have read each sample for the last time before the next frame's beat for it arrives. With the input stream's span (last minus first beat): `SPAN_IN + (passes − 1)·N_IN + 1 ≤ 256`, besides `DEPTH = passes·N_IN ≤ 256` (`mixer_core_pkg::matrix_fits`). The planned test chain 12/12/12 on 1 + 1 breaks it (D 325 but the bus matrix's samples would be overwritten); 16/16/16 on 2 + 2 (D 299) and on 1 + 16 (D 328) are valid and longer than a frame.

**Changes:**
- `mixer_core_pkg`: `FRAME`, `D_CAP` (8 frames), `matrix_fits`, `matrix_span_out`, `chain_fits`; the chooser in two passes: the fewest lanes with D ≤ 255 (as before), and only if none, the fewest for which `chain_fits` holds. Every size the project uses keeps its lanes and D; 48/48/48 now gets 12 + 16 lanes at D 435 (was "nothing fits"), 64/64/64 22 + 32 at 459, 96/96/96 48 + 48 at 599.
- `mixer_core`: seven `*_swap` outputs (the input patch: the strobe; every other block: its input stream's last beat); the elaboration check is `chain_fits` instead of `D ≤ D_MAX`.
- `fpgamixer_top`: every bank (`coef_bank_ram` in the PS build, `coef_flat_reader` without it) on its swap pulse; the three meters on their tap's last beat. The links, their counters and the media clock stay on the global strobe.
- `pcm_stream2patch`: no `frame_i`, no strobe check (an incomplete frame is flagged at the next frame's channel 0).
- `coef_flat_reader`: `LATCH` (default 0 = unchanged): copy the vector on `frame_i` and once at the first edge, like the bank's swap.
- `pcm_peak`, `pcm_gain`, `pcm_matrix`: header text only (the meter needed no change: a beat on its closing pulse already belongs to the closing window).
- `pcm_stream_monitor`: `SPANS` mode (frames may cross strobes; channel 0 marks a frame, consecutive starts exactly `FRAME` apart, complete before the next channel 0, first/last beats at their stated cycle after the frame's own strobe, beyond 256 if need be). Default unchanged.
- `tb_mixer_core` (rewritten stimulus and check): coefficient sets held 3 frames; each frame of each tap stream and each output frame must be explained by one set per block (old or new) for **all** its beats, else "torn"; exact where only one set is possible; the two long chains added (9 configurations, 90 frames each). `tb_mixer_core_pkg`: the new chooser results and `matrix_fits` / `chain_fits` at their edges (values from an independent Python model). `tb_pcm_patch`: the "missing last beat" case now expects the flag at the next frame's channel 0.
- `docs/architecture_modules.md` §2.1 and §3: the contracts as changed.

**Checked (XSim 2026.1, Windows):** all 17 TBs PASS (one `regs` "child exe not found", Defender, rerun: PASS). `tb_mixer_core`: 20/20/20 4 + 4 D 251, 12/12/12 1 + 2 D 254, 28/28/28 10 + 10 D 235, 20/8/20 2 + 2 D 207, 3/5/2 D 53, 7/5/3 3 + 2 D 57, 1/1/1 D 28, **16/16/16 2 + 2 D 299, 16/16/16 1 + 16 D 328**: 90 frames each, 0 errors, bus clips seen in 8 of 9.

**Mutants (`scripts/mutants/lf1_*.json`, `scripts\mutate_sv.ps1`), baseline passing first: 16 of 17 killed, the 17th the predicted equivalent.**
- `corepkg`, **5 / 5**: `matrix_fits`' depth bound `<` instead of `<=`; its sample bound without the `+ 1`; the chooser without the multi-frame pass; the chooser ignoring `chain_fits`; `chain_fits` ignoring the bus matrix.
- `patch`, **1 / 1**: `pcm_stream2patch` without its channel-order check.
- `core`, **10 / 11**: each of in_mx, bus_lvl, bus_mx, out_lvl, out_patch swapping on the global strobe (27 … 393 errors: the frames that cross a strobe tear); in_lvl, in_mx and out_patch swapping on their input's first beat instead of the last; the input patch's swap late; `coef_flat_reader`'s `LATCH` following the vector live. **Survived, as predicted: in_lvl on the global strobe.** The input levels' stream (cycles 6 … N_IN + 5) never crosses a strobe, so that swap point can't tear a frame; it is still wired to the stream's last beat, the rule every block follows.
- **A TB fix found on the way:** the first core run's kills mostly ended in an XSim kernel FATAL in `tap_beat`'s error message (a nested conditional over the three tables), not a FAIL line; the error path was reached (the unmutated design never reaches it), but a kill must be a verdict. Rewritten in plain steps; the rerun: every kill a clean FAIL with its error count.

## 11. Step 2 plan: LF2 + LF3, click-free levels and matrices (2026-10-26, for the user's review)

**What it does for you:** fader moves, crosspoint changes and snapshot recalls fade instead of jumping, so they stop clicking. At rest nothing changes: the smoother arrives at the exact target value, so the null tests stay bit-exact.

**The block: `coef_smooth`** (new, generic, `src/rtl/`; moves to the library repo in step 3). It sits on a coefficient read port, between the bank (`coef_bank_ram` / `coef_flat_reader`) and the block, with the same port on both sides, so neither the bank nor the block knows it's there.
- It keeps the **current** value of every coefficient (per lane) in a small RAM. When the block really reads coefficient *a*, it gets the bank's **target** and the current value in the same cycle and returns `cur + (target − cur) >>> K`, writing that back as the new current value. Each coefficient is read once per frame, so this is a one-pole lowpass per coefficient running at 48 kHz.
- **Exactly the target in the end:** the current value carries K extra fractional bits (so small steps don't stall short of the target), and once it is within one output LSB it snaps to the target. Unity stays unity, bit for bit.
- **Timing unchanged:** the arithmetic sits between the two RAM outputs and the block (combinational), so the read port's one-cycle latency stays. At `mclk` (12.288 MHz) the extra add is nothing for timing.
- **Cost:** one small RAM per smoothed port (the bus matrix: 100 words × 4 lanes × 26 bits; a level stage: 20 × 26 bits) and an adder, a shifter and a compare per lane: 11 lanes in all.

**One contract addition (needed, small): a read strobe.** Both blocks drive their coefficient address continuously, also when idle (`pcm_gain`: `coef_addr = in_ch` every cycle; `pcm_matrix`: its step counter, stale between frames). A smoother that updated on every cycle would smooth idle addresses many times per frame. So the read port gains **`coef_rd`**, high in the cycle a block issues a real read (`pcm_gain`: the beat's `in_valid`; `pcm_matrix`: `run`), with the rule *each coefficient is read exactly once per frame*. The banks ignore it; the smoother updates only on it; `mixer_core` passes it out per port. The library's template block gets it too (step 3).

**Where it goes:** in `fpgamixer_top`, on the five gain and matrix ports (input levels, input matrix, bus levels, bus matrix, output levels), between each register window's bank and the core. **Not on the patches**: a routing change still switches at once (a crossfade there is a later option). `mixer_core` doesn't change beyond `coef_rd`, so `tb_mixer_core` keeps testing the core bit-exact against the banks directly.

**Tests:**
- `tb_coef_smooth` (new). **(A) unit:** a bit-exact model of the smoother. Random targets and bank swaps, random read sequences with idle cycles (no update without `coef_rd`), several lane counts; the output equals the model on every read; it approaches without overshoot; it reaches the exact target within the computed bound; lanes are independent. **(B) with real blocks:** `pcm_gain` and `pcm_matrix` through a smoother, with frames checked bit-exact against a model that smooths once per frame. That proves the `coef_rd` wiring and the once-per-frame rule.
- Every existing TB re-run; `tb_top_windows` (the PS build's wiring) with the smoothers in. Mutants: no snap, K off by one, update without `coef_rd`, the current value without its extra bits, the matrix's `coef_rd` on the wrong signal, and others.

**Then the bitstream (Q2 of step 1: one build for steps 1 + 2), an image, and a bench session:**
- **By ear:** fader moves and a snapshot recall no longer click.
- **The gate:** the AVB null tests.
- **Exactness:** the USB → USB null test after the levels settle, which must stay bit-exact.
- **T3 again**, 30 min: the protected path is still bit-exact under control changes elsewhere.
- The OSC standard's note "a recall may click" is removed once that passes.

**Questions for the user:**
- **Q1, how fast a change fades.** K sets the time constant: **K = 6**: τ ≈ 1.3 ms, exact within ~17 ms (quick, but a full-scale step still has some low thump); **K = 7**: τ ≈ 2.7 ms, ~35 ms; **K = 8**: τ ≈ 5.3 ms, ~70 ms. Recommended **K = 8**: well inside what consoles and DAWs use against zipper noise, inaudible as a delay on a fader, and still settles in well under a tenth of a second. It is one parameter, easy to change later.
- **Q2, power-on.** The smoother's state starts at 0, so at boot every level fades in from silence over a few τ (~70 ms with K = 8) when the server restores the mix. Recommended: **keep that** (a soft start, no logic). The alternative, starting from the banks' reset values, needs an init pass and only matters if a fade-in at boot is unwanted.

### 11.1 Step 2 built in simulation (2026-10-26; the user's go-ahead: K = 8, the fade-in at power-on)

**Changes:** `coef_smooth.sv` (new); `coef_rd` on `pcm_gain` (= `in_valid`) and `pcm_matrix` (= `run`), passed out of `mixer_core` per gain/matrix port (`*_rd`); `fpgamixer_top`: a `coef_smooth` on each of the five gain/matrix ports between bank and core (the banks on internal `*_bk_*` wires), `SMOOTH_K` a module parameter, default 8 (only so that a TB of the whole top can settle quickly); `sim.mk` / `xsim_regress.ps1`: `coef_smooth.sv` in the top's file list, a new target `smooth`; `docs/architecture_modules.md` §3 and the module table.

**Checked (XSim 2026.1):**
- **`tb_coef_smooth` (new) PASS.** A, the smoother alone at 20 × 1 × K 3, 5 × 3 × K 2, 1 × 1 × K 1 and 2 × 2 × K 8: 49,747 reads, every one bit-exact against the model, never past the target, exact after the bound on 1,377 reads checked there. B: `pcm_gain` (6 ch) and `pcm_matrix` (4 → 3, 2 lanes) through smoothers, 760 frames each, every output beat bit-exact against models that smooth each coefficient once per frame.
- **`tb_top_windows` updated:** run with `SMOOTH_K = 2`. It waits until a change has arrived exactly (76 frames + 3) where it used to wait 3 frames: the identity check, which depends on the power-on fade-in, and the per-window changes. **New: 3 frames after the per-window changes, outputs 4, 5, 6 are mid-fade** (neither the old nor the new value): smoothing is on those paths in the real top. Its first run failed (98 checks), exactly by the fade-in: the outputs read 0 three frames after reset. **Limit:** mid-fade proves smoothing on the paths together, not port by port (bypassing only the output-level smoother would leave out B+1 mid-fade through the others); the smoother is proven in its own TB, and the final exact values prove every port's bank → smoother → core path.
- **All 18 TBs PASS** (8 Defender "child exe not found" in the full run, rerun: PASS).
- **Mutants (`scripts/mutants/lf2_smooth.json`, target `smooth`): 9 / 10 killed:** no snap, the step `>>> (K − 1)`, the current value without its fraction bits, updating without `rd_en`, the write-back to the new address, the snap boundary including −2^K (3 errors: the edge case does occur), `pcm_gain`'s and `pcm_matrix`'s `coef_rd` stuck high, `pcm_matrix`'s `coef_rd` on the input beat. **Survived: "the target read unsigned": an equivalent mutant.** Shifting a W-bit value left by K into W + K bits puts its top bit exactly at the result's sign bit, so `$signed` makes no difference: there is no extension.

**Next:** the bitstream for steps 1 + 2 (the user's Q2), an image, the bench session (§11: by ear, the gate, the null tests, T3).

### 11.2 Bitstream and image `lf2-smooth-20261031` (steps 1 + 2; 2026-10-31)

- **Vivado 2026.1** (`create_project.tcl`, `build.tcl lf2`): **WNS 4.315 ns** (p15a: 4.710), WHS 0.010 ns, 0 failing paths, 0 critical warnings, the methodology gate passed. Utilization vs `p15a`: LUTs 25,034 (35.5 %; was 23,433), of which LUT as memory 3,424 (was 2,864: the smoothers' current values), registers 37,284 (was 36,946), **BRAM 7.5 and DSPs 11, unchanged**. XSA `build/fpgamixer_lf2.xsa`.
- **SDT** (`build/sdt`; `p15a`'s kept as `build/sdt.p15a`, on the VM `~/edf/sdt.p15a`): `psu_init.*`, `zynqmp*.dtsi`, `pcw.dtsi`, `system-top.dts` **identical**; `pl.dtsi` only `firmware-name` (`fpgamixer_lf2.bit.bin`). No PS setting and no window changed.
- **Image** (`gen-machine-conf` from the new SDT, then bitbake; layer `7efa33a`, which carries everything of `p15e`): 15,107 tasks, all succeeded, 7 min 9 s, no warning beyond `p15a`'s. **Checked:** the deployed bitstream's MD5 `3b8426ad…` = the XSA's; rootfs `VERSION` `7efa33a`; the gadget's `REQ_NUMBER=8`, PAUSE off in `avb_net.py`, the journal mount (p15e's fixes). **`build/sd/lf2-smooth-20261031.wic.xz`** (`xz -t` OK, MD5 `30d0fe3b…`, same on both ends). **Not flashed.**

**Bench session (the user; the board at `ssh amd-edf@10.0.0.2`; a reflash wipes the mix and the on-board snapshots, so save what's needed first):**
1. Flash, boot. If the Ethernet LEDs go dark after a second: a full power-off for ~10 s (the PHY's first-boot flake). Restore the mix and the channel-20 path.
2. **The gate:** T1 AVB → AVB and USB → AVB, 5 min each. Both PASS, or reflash `p15e`.
3. **By ear (the point of step 2):** while listening, move a fader quickly, pull a level to −∞ and back, and recall a snapshot that changes many levels. **No clicks**; changes glide over a few ms.
4. **Exact at rest:** T1 USB → USB, 5 min, with the channel-20 path at unity: **bit-exact** (the smoother arrives exactly).
5. Optional: T3, 30 min (control changes under load; the protected path stays bit-exact).
6. Expected and harmless: at power-on the mix fades in over ~70 ms (the user's Q2).
After a pass: `lf2` replaces `p15e`, and the OSC standard's "a recall may click" note goes.

## 12. Step 3 plan: the library repo, the template block, the submodule (2026-10-31, for the user's review)

**Goal:** a library block can be written, simulated and mutation-tested in `HDL-DSP-Library` on its own, and FPGAmixer uses the library at a pinned commit (decisions HD3, HD5, LF5). Nothing audible changes; FPGAmixer's 18 TBs still pass, and its bitstream would be the same logic.

**What moves to the library (with their TBs), out of FPGAmixer's `src/`:**
- the coefficient primitives `coef_bank_ram.sv` (+ `constraints/coef_bank_ram.xdc`, scoped), `coef_flat_reader.sv`, `coef_smooth.sv`, `axil_coef_window.sv`;
- the stream checker `pcm_stream_monitor.sv` (sim);
- `tb_coef_bank_ram.sv`, and part A of `tb_coef_smooth.sv` (the smoother alone). Part B (through `pcm_gain` / `pcm_matrix`) stays in FPGAmixer, since those blocks stay (see Q4);
- the two contracts as the library's own documents: the stream contract (`architecture_modules.md` §2.1, LF1 form) and the coefficient contract (§3: read port, swap on the block's frame boundary, `coef_rd`, smoothing).

**The library repo's layout:** `rtl/` (primitives, later blocks), `sim/` (TBs, the monitor), `constraints/`, `template/` (the template block), `scripts/` (an XSim regression and a mutation runner, the same pattern as FPGAmixer's), `docs/` (the contracts, "how to write a block"), `README.md`.

**The template block (`template/`, also built and tested):** a working example block to copy: a per-channel gain-like block, `lib_template`:
- **RTL:** stream in → stream out (the LF1 contract: channel 0 marks a frame), one coefficient read port with `coef_addr`, **`coef_rd`** and **`coef_swap`** (see Q2), a package with its latency and occupancy and the `fits` check at elaboration;
- **binding:** `lib_template_regs_axil` (ID, CONFIG, the bank over `axil_coef_window` + `coef_bank_ram`), the same pattern as `gain_regs_axil`;
- **TB harness:** a bit-exact model, random coefficients and audio per frame, `pcm_stream_monitor` in `SPANS` mode, banks with `LATCH`, a run at several sizes, and a mutant list;
- **server side:** a short contract document: what a block's backend must provide in FPGAmixer's OSC server (`describe()`: zone, modules, metadata, as `mixer_hw.py`'s backends do). Implemented with the first real block (step 4), not here.

**FPGAmixer's side:**
- the library as a git submodule at `src/lib/`, pinned to a commit;
- the moved files deleted from `src/`;
- `create_project.tcl` also globs `src/lib/rtl/*.sv` and takes the scoped XDC from `src/lib/constraints/`;
- `xsim_regress.ps1` and `sim.mk` point at the moved files;
- a Vivado elaboration check that the design is unchanged (same utilization ± 0); no new bitstream;
- the two regressions green: the library's alone, FPGAmixer's with the submodule.

**Questions for the user:**
- **Q1, the first real block (step 4), which shapes the template a little:**
  - **EQ** (parametric, biquads per channel): the most-used processor, no sidechain, and it exercises LF4 (filter coefficients smoothed, or a crossfade where that isn't safe).
  - **Dynamics** (compressor / gate): needs the sidechain machinery (`pcm_frame_tap`, LF6 / LF7) as well.
  - Recommended: **EQ first**, dynamics second.
- **Q2, who knows when a block's bank swaps:**
  - Today the core derives it from the stream (the input's last beat), which is right for blocks that read per beat or start on the last beat.
  - Recommended: **each block exports its own `coef_swap`** (the template's default = its input's last beat), so a block with a different read schedule (an EQ reading its coefficients mid-frame, a delay line) states it instead of the core assuming it.
  - `pcm_gain` / `pcm_matrix` would get it too; the core then wires the blocks' pulses instead of computing them.
- **Q3, pushing the library repo to GitHub** (`dweeeezil/HDL-DSP-Library`, empty today): I'll make the first commits locally and ask before pushing; the submodule's URL then points at that repo. **Is the repo private?** It doesn't change the work, only what is published when pushed.
- **Q4, `pcm_gain` and `pcm_matrix`:**
  - Recommended: **they stay in FPGAmixer for now** (they are the core's own blocks and step 1/2 just changed them); they can move to the library later, once the template has proved itself.
  - The alternative: move them now as the first library blocks.

**Answered (the user, 2026-10-31): Q1 EQ first (dynamics second); Q2 each block exports its own `coef_swap` (`pcm_gain` / `pcm_matrix` too, the core wires their pulses); Q3 the GitHub repo is private (still: ask before pushing); Q4 `pcm_gain` / `pcm_matrix` stay in FPGAmixer for now.**

### 12.1 Step 3 built (2026-10-31)

**A, every block states its swap point** (commit `0029377`): `pcm_gain`, `pcm_matrix`, `pcm_patch2stream`, `pcm_stream2patch` export `coef_swap`; `mixer_core` wires them out instead of computing them. All 18 TBs passed; the swap mutants moved to the blocks: **7 / 7 killed** (each block's swap on the wrong beat, a gain that never swaps, the input patch late, the flat reader live).

**B, the library repo** (`HDL-DSP-Library`, local commit `01a6c01`, **not pushed**): the primitives moved (`coef_bank_ram` + XDC, `axil_coef_window`, `coef_flat_reader`, `coef_smooth`, `pcm_stream_monitor`, `tb_coef_bank_ram`, the unit part of `tb_coef_smooth`); the template block `lib_template` (package, block, `lib_template_regs_axil` with ID 0x5450_5001, `tb_lib_template`); `docs/` (the stream contract, the coefficient contract with `coef_swap` and crossfade-vs-smooth, "writing a block" with the server side); `scripts/` (its XSim regression, the mutation runner). Its regression: **3 / 3 PASS** (`tb_lib_template`: the block at N 1, 5 with gaps, 20, 40 frames each, bit-exact; the binding over AXI4-Lite across two clocks). Mutants: **template 8 / 8, `coef_smooth` 6 / 6**. A TB flaw found on the way: the template's model first updated its bank on the block's own `coef_swap`, so it followed a block that swapped in the wrong place (that mutant was caught only by the read count, 2 errors); the model now swaps where the contract says (the frame's last beat): 799 errors.

**C, FPGAmixer takes the library as a submodule at `src/lib`** (URL `https://github.com/dweeeezil/HDL-DSP-Library.git`, pinned to `01a6c01`; the checkout was cloned from the local repo). The eight moved files are deleted from FPGAmixer (each checked identical to its library copy first, apart from line endings; `tb_coef_smooth` split into the library's unit TB and FPGAmixer's **`tb_smooth_blocks`**). `xsim_regress.ps1` / `sim.mk` read the primitives from `src/lib` (targets `coefram` and `smooth` gone: they run in the library; `smooth_blocks` new); `create_project.tcl` globs `src/lib/rtl` and `src/lib/sim`, takes the scoped XDC from `src/lib/constraints/`, and tells a clone without the submodule to `git submodule update --init`; the mutant lists point at `src/lib`; `architecture_modules.md`'s table at the library paths.

**D, checked:** FPGAmixer's regression **17 / 17 PASS** against the submodule (18 before, less the two that moved, plus `smooth_blocks`); the read-strobe mutants against `tb_smooth_blocks`: **3 / 3**. **Vivado** (`lf3chk`, from the submodule): WNS 4.160 ns, 0 critical warnings, the bank's XDC applied from `src/lib/constraints`. **Utilization against `lf2`: registers 37,284, LUT-RAM 3,424, BRAM 7.5, DSPs 11, muxes and carry chains identical; logic LUTs 21,643 (lf2: 21,610), 33 more (0.05 % of the device).** Not the "± 0" the plan said: the RTL is structurally different since A (the swap comparisons inside the blocks) and the sources reach synthesis in another order, and Vivado's optimizer varies with both. The same registers and memories, and simulations showing every pulse unchanged, say the logic is the same; recorded as such, not as identical. `lf2`'s image stays the one to bench; nothing in steps 3's RTL is audible.

## 13. Step 4 plan: the first library block, a parametric EQ (2026-10-31, for the user's review)

> **Superseded on placement (2026-10-31).** The user: DSP modules live off to the side in pools, and the controller inserts them on any channel (inputs, buses, outputs), pre-fader, any number and any order, 32 slots per type. The EQ is no longer a fixed core stage; it becomes the first pool. See `insert_architecture_proposal_2026-10-31.md`. The EQ prototype (4a) and the block itself below still stand.

**What you get:** a per-channel parametric EQ on the input channels, controlled from the app like any other module. The app already renders advertised modules by `group` (knobs for numbers with ranges, menus for enums, buttons for bools: StudioRunner D65), and its mock device already uses `eq_band1..4_freq/gain/q`, so no app work is needed to use it. The pop-out EQ editor (D73) stays an app item for later. With the EQ flat or bypassed, the path stays **bit-exact**, so the null tests keep working.

**The parts, in order:**

**4a, a numerical prototype first (Python, on the PC; no RTL yet).** It decides the filter structure and the number formats from measured numbers, not guesses, and it becomes the TB's reference model.
- **The question it answers:** low frequencies are the hard case for a fixed-point EQ. At 20 Hz and 48 kHz the filter's poles sit very close to 1, so coefficient precision and internal noise decide whether a low shelf works at all.
- **Two candidates:**
  - **(i) a state-variable filter**, the "TPT" form. It is known to stay well-conditioned at low frequencies, and to tolerate its coefficients changing while it runs.
  - **(ii) the classic biquad** (Direct Form I) with error feedback.
- **For each, it measures:**
  - the response error against a floating-point reference, 20 Hz–20 kHz, for every band type at the extremes of frequency, gain and Q;
  - the noise floor;
  - **whether the coefficients may be smoothed directly** (LF4). Every intermediate coefficient set of a fast sweep must stay stable; otherwise the block declares a crossfade.
- **Expected outcome:** 24-bit audio, wider internal state, coefficients wider than the DSP's 18-bit port, so a multiply uses 2 DSPs. The prototype fixes the exact widths.

**4b, the block `lib_eq` in the library, from the template.**
- **Structure:**
  - per channel, 4 bands in series plus a bypass;
  - time-shared over the channels like the matrix, a few DSP lanes, roughly 6–10 DSPs for 20 channels × 4 bands;
  - a fixed latency of about one more frame (20.8 µs: fine since LF1).
- **Coefficients:** per band, the handful the structure needs, computed by the server, in a bank of 20 × 4 × that many words.
- **Smoothing or crossfade:** whatever 4a says.
- **Flat or off is exactly identity:** unity pass-through coefficients, so the output is bit-identical to the input.
- **Its TB:** bit-exact against the prototype's fixed-point model, plus mutants.

**4c, FPGAmixer:**
- a new core stage on the input channels, between the input patch and the input levels (pre-fader, where a console's channel EQ sits);
- its register window (a new AXI window on the second SmartConnect, which has 13 masters free; a block-design change, so the device tree gains a node);
- its bank (+ smoother) in `fpgamixer_top`;
- the server:
  - a `mixer_hw` class (ID "EQ");
  - the modules in `inputChannel`'s config;
  - the coefficient maths (the standard design formulas for the chosen structure);
  - stored with the mix and snapshots;
  - Python tests of the maths against the prototype;
- `tb_mixer_core` with the EQ stage, then a bitstream and an image.

**4d, the bench session (yours):**
- **The gate:** the AVB null tests.
- **Bit-exact with the EQ flat:** USB → USB null.
- **By ear:** sweep a band, boost and cut, shelves, the high-pass; no zipper noise or clicks while moving.
- **A response check:** a sine at a few frequencies through a known setting, compared on the meters.

**Proposed modules (per input channel, group `eq`):**
- `eq_on` (bool, bypass);
- for each band 1–4:
  - `eq_bandN_on` (bool);
  - `eq_bandN_type` (enum with `optionLabels`: Peak, Low shelf, High shelf, High-pass, Low-pass);
  - `eq_bandN_freq` (Hz, 20–20,000);
  - `eq_bandN_gain` (dB, ±15);
  - `eq_bandN_q` (0.1–10).

These follow the app's mock naming, plus `type` and `on`.

**Questions for the user:**
- **Q1, bands:** 4 bands, each any type (Peak, shelves, high/low-pass), with the modules above. Recommended. The alternative is a fixed layout: high-pass, low shelf, two peaks, high shelf.
- **Q2, where:** input channels only, pre-fader. Recommended for now; the block is per-channel and generic, so buses or outputs later are another instance.
- **Q3, filter structure:** let the prototype decide between the state-variable filter and the biquad, and report the numbers before RTL. Recommended. The alternative is choosing the biquad now, the familiar form.
- **Q4, LF8 (the chain as sections):** decided "now" but not yet done.
  - Recommended: insert the EQ stage directly in `mixer_core` (one change at a time), then do LF8 as its own refactor right after, when there are two optional stages to describe.
  - The alternative: do LF8 first, so the EQ goes in as a section entry.
