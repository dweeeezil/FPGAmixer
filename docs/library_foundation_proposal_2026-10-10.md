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
