# Proposal: the core's foundation for the DSP library (2026-10-10)

**Context:** hardening before the DSP library (`hardening_status_2026-10-10.md`, step 5). The user decided (HD2–HD7): **the core may span more than one frame (A)**; **the library is its own repo**; **click-free coefficient changes**; **a template block**; **multi-input blocks (sidechains) pick their extra inputs like channel sources**; **spatial processing / binaural is its own section, not a plugin**.
**State:** proposal; decisions LF1–LF8 below to the user. Nothing built.

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
