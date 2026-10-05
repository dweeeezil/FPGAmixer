# Prompt: channel levels and the bus layer (inputs, buses, outputs)

*Written 2026-10-04 at the end of the controller-support session (`controller_support_status_2026-10-04.md`), as the opening prompt for a fresh session in the **FPGAmixer** repo. The StudioRunner controller app is checked out next to it at `../StudioRunner-controller`.*

---

You're working on the FPGAmixer project: a digital matrix mixer on a Genesys ZU-3EG (Zynq UltraScale+), controlled over OSC by the StudioRunner macOS app. Today the core is one 20 × 20 crosspoint matrix (input → output) and nothing else: no per-channel processing and no buses. **Your job:**

1. a **level** (gain) on every **input**, every **bus** and every **output** (level only for now; mute, EQ and the rest come later);
2. the **bus layer**: inputs → **input matrix** → buses → **bus matrix** → outputs.

so that the app's Inputs, Buses and Outputs tabs and both matrix tabs come alive on the real board. The app already has all five tabs (strips, Stage 8; matrices, Stage 9) and fills them from the board's config reply; nothing in the app should need to change.

## Read first, in this order

1. `docs/architecture_modules.md`: §1 (the rule, block kinds, where each block lives), §2 and **§2.1** (the PCM contract and the in-core stream contract), §3 (coefficient contract), §4.1 (register windows, the address map: next free window **0x8000_5000**), **§4.2** (OSC zone → backend → window; the stored state mirrors the OSC tree, and **that format is a contract**), §6 (how the bus layer was meant to plug in).
2. `docs/phase9_status_2026-09-26.md` §5 (the time-shared matrix: schedule, lanes, the latency budget, `coef_bank_ram`). Then the headers of `src/rtl/mixer_core.sv`, `pcm_matrix.sv`, `pcm_matrix_pkg.sv`, `coef_bank_ram.sv`, `matrix_regs_axil.sv`.
3. `docs/FPGA Mixer OSC Standard.md`: the protocol, merged 2026-10-04. Zones: `inputChannel`, `inputMatrix` (input → **bus**), `busChannel`, `busMatrix` (bus → output), `outputChannel`.
4. `docs/controller_support_status_2026-10-04.md`: what the server became (the parameter model, `Backend.describe()`, error replies, the config reply, ordering, discovery) and its open items (metering, board checks).
5. The server: docstrings of `tools/osc_mixer_server.py`, `tools/mixer_params.py`, `tools/mixer_state.py`.
6. The app's expectations, in `../StudioRunner-controller` (`git log origin/main`; the user builds on the Mac, so the local checkout may lag: read with `git show origin/main:<path>` after a `git fetch`, never pull or edit there): `docs/DECISIONS.md` **D5, D64–D65, D74–D77** (strips and matrices are built from metadata; D77: one shared `level` module, default −90 = off, channel levels listed explicitly in `values`), `Packages/StudioRunnerCore/Sources/MockDevice/MockProfile.swift` (`standard`, `proposedStrip()`, `large64`: config shapes the app was built against).
7. Your memory directory (`MEMORY.md`), especially the bench notes: **the Pi is gone**.

## What exists (verified 2026-10-04)

- **Core:** `mixer_core` (packed PCM in/out) = `pcm_pack2stream` → time-shared `pcm_matrix` → `pcm_stream2pack`. Its header says the bus layer and DSP blocks go *inside it, between the converters*, so the platform layer and front doors never change. 20 × 20 (4 Pmod + 8 USB link + 8 AVB link channels, `fpgamixer_top`), 2 lanes (DSP48E2s), latency D = 227 of the 250-cycle budget (one frame is 256 `mclk` cycles; `pcm_matrix_pkg`: D ≤ 250 leaves 3 cycles before `i2s_port` samples).
- **Coefficients:** `coef_bank_ram` (shadow + two banks, COMMIT = copy, swap at a frame strobe) behind `axil_coef_window`, bound by `matrix_regs_axil` (ID `0x4D58_5001`, CONFIG = N_OUT/N_IN/GAIN_WIDTH/GAIN_FRAC). Gains Q2.16, ceiling +6.02 dB, ≤ −90 dB = hard 0.
- **Server:** one parameter model (`mixer_params.Model`) built from each backend's `describe()` (zone shape, modules, module metadata). It validates every set/get, refuses what it doesn't name, and builds the config reply. **Module metadata is global per module name**: `Model.add_zone` refuses a module described differently by two zones. `MatrixBackend` describes `inputMatrix` 20 × 20, module `level` (float dB, −90 … ceiling, **default −90**), and seeds the reset routing (diagonal 0 dB) at startup. Adding a block = a window in `mixer_hw.WINDOWS`, a `Backend` with `describe()`, one entry in `build_backends()`; the config, validation and app follow.
- **App:** shows a zone's tab only when the config lists the zone; strips per channel zone, grids per matrix zone; matrix axes are labelled from the channel zones when present (D76). It meters channel zones only (F4; not implemented on the board yet).
- **Image:** `ctl1` (`build/sd/ctl1-controller-20261004.wic.xz`, commit `12c8f9f`) runs the current server; the app connects to it.

## Decisions to get from the user before building

Write a short proposal first (`docs/phase12_status_<date>.md`), with these questions and your recommendations, and let the user decide. Recommendations below are a starting point; check them against the RTL.

1. **Where the levels live.**
   - (a) **PL gain stages:** a generic stream block (`pcm_gain`, one multiplier time-shared over its channels, coefficients through the same `coef_bank_ram` machinery: a row of length 1 per channel), one instance per tap: after the inputs, after the buses, before the outputs. Costs a few DSPs and a few cycles each. Gives real tap points for meters (F4a) and a place for later per-channel DSP and gain smoothing.
   - (b) **Folded into the matrices in software:** effective crosspoint = input level + crosspoint + bus level (and bus level + crosspoint + output level). No new gateware for levels, but every level move rewrites a whole row or column of a bank; the hardware can't meter per stage; and it doesn't model where sums saturate.
   Recommendation: (a), because the hardware should look like what the app shows, and Phase 7 DSP needs the same stages.
2. **Bus count B.** Recommendation: **B = N_OUT (20)**, with the bus matrix defaulting to identity (bus *k* → output *k*). Then (point 3) existing routing keeps working unchanged. Alternatives: 8 or 16 buses (fewer DSPs, a different migration).
3. **`inputMatrix` changes meaning** (today input → output, controller D5; with buses, input → bus). The state format must not change (§4.2), and old state files must keep loading. With B = N_OUT and an identity bus matrix, every saved `inputMatrix` crosspoint keeps its audible effect, so no migration is needed. With B ≠ N_OUT, decide what happens to saved crosspoints (e.g. keep those that fit, retire the rest) and say so in the status doc.
4. **Latency.** Two matrices in series inside one frame. First-cut numbers from `pcm_matrix_pkg`'s formulas (20 in, 20 out, the second matrix starting at the first one's last output beat; **estimates, not synthesis results**): B = 8: 4 DSPs, D ≈ 248 (tight); B = 16: 7 DSPs, D ≈ 234; **B = 20: 8 DSPs (4 + 4), D ≈ 237**; three streamed gain stages add a few cycles each and fit with one more lane. The device has 360 DSP48E2s. Recommendation: stay within one frame (no added latency) by choosing lanes per matrix; generalise `pcm_matrix_pkg` so the chain's D is computed in one place and the core refuses to elaborate past D_MAX, as the single matrix does now.
5. **Saturation points.** In a two-matrix chain each bus sum saturates to 24 bits at the bus, as on a real console. Confirm that's wanted (it is the natural result of (a)).
6. **Register windows.** One per block, each with the common header: the bus matrix (a second `matrix_regs_axil`), and one per gain stage (a new small binding, its own ID). Addresses from 0x8000_5000 up; update the §4.1 table, `mixer_hw.WINDOWS`, the SDT/device tree check (windows must exist before `mixer_hw` opens them: presence guards).
7. **Defaults.** After reset (PL) and on a fresh state (server): channel levels **0 dB** (unity), input matrix diagonal 0 dB, bus matrix identity. Following D77, `level` stays one shared module (default −90), so the channel backends must *seed* 0 dB at startup, exactly as the matrix seeds its diagonal; otherwise a fresh channel would read as off.
8. **Metering in this phase?** Channel zones finally give metering (F4, controller-support step 6) a purpose, and the gain stages are the natural tap points for the F4a peak detector (`../StudioRunner-controller/docs/handoff/hdl-dsp-library-peak-detector.md`). Ask whether to include the server's meter protocol (with a synthetic source until F4a), F4a itself, or neither.
9. **Growth.** Phase 11 (USB host, `phase11_status_2026-09-30.md`) may grow the core to 28 × 28. Keep every size a parameter derived from the platform's channel map; new channels are appended, never interleaved (§2).
10. **The phase's name and number** in the roadmap (`FPGAmixer_Architecture_Roadmap.md`): this is the first piece of Phase 7's "per-channel/bus processing" plus the bus layer from §6. Ask how the user wants it recorded.

## Steps (after the decisions)

Each step: build, test, commit, status doc updated.

1. **RTL blocks, each with its own testbench** (Icarus via `scripts/sim.mk`, XSim via `scripts/xsim_regress.ps1`; keep them in step): the gain stage on the stream contract; the generalised latency package. Bit-exact against a reference model, as `tb_pcm_matrix_rect` does. Mutation-test the testbenches (plant a wrong stride, a wrong saturation).
2. **`mixer_core` with the chain** (gain → matrix → gain → matrix → gain), its coefficient ports, a core-level TB with random samples and gains against a model of the whole chain, including bus saturation.
3. **Control plane RTL:** the bus matrix's `matrix_regs_axil`, the gain stages' register bindings, `fpgamixer_top` wiring, the block design's SmartConnect ports and address map (`scripts/create_project.tcl`).
4. **Vivado:** timing, CDC and the methodology gate (as every phase since 9), DSP and BRAM counts recorded. Export, `sdtgen`, compare `psu_init` (should be identical) and the device tree (new windows).
5. **Software:** `mixer_hw` classes for the new windows (checked by ID); backends `GainBackend` (channel zones, module `level`) and a second `MatrixBackend` (`busMatrix`), each with `describe()`; `build_backends()`. Server tests (the subprocess harness in `tools/test_osc_mixer_server.py`, in-process tests against fake windows) and the config reply checked against the app's rules (`app_config_problems` in that file). The state format doesn't change.
6. **Image** (VM, below) and the **bench**.

## The bench, as of 2026-10-04

- **The Pi is gone.** The Mac is the board's only neighbour, on a direct cable (OWC TB4 10G adapter). The board has IPv4 link-local + mDNS on `end0` (image `ctl1` and later): **`ssh amd-edf@amd-edf.local`** from the Mac, no IP settings; the app finds the board through Bonjour. The PC can't reach the board; it reaches the **build VM** (`ssh edfvm`).
- **Images:** commit, `scripts/sync_buildhost.sh` (a clean tree, so the image's `VERSION` is the commit), then on the VM `source edf-init-build-env` and `bitbake edf-linux-disk-image xilinx-bootbin` (plus `gen-machine-conf` and the SDT when the hardware changes; see the Phase 9 image entries for the exact sequence). Run long builds detached (`setsid nohup …`) and poll briefly; don't hold one long blocking SSH call. Copy the `.wic.xz` to `build/sd/<name>.wic.xz` and record its MD5. Flashing erases the saved state.
- **Tests that need Linux** (`test_mixer_state`'s SIGTERM test, `test_mixer_hw`) run on the VM, whose Python 3.12 matches the board's.
- **Listening:** the Pmod I2S2s on JB/JC have mono cables, so only the left channels can be heard (core out 0 = JB_L, out 2 = JC_L; never route test audio to JC_R). The Mac is a multichannel source and sink over USB (8 × 8, core channels 4–11) and AVB (core 12–19). Prefer one by-ear check per claim over recording and analysis.
- A full power-cycle restore check with real audio is the user's standing request whenever routing changes (Phase 6/8 history).

## How this user works

- **Modularity first.** Front doors, the PCM core and the control plane stay generic and decoupled; a new block plugs into an existing seam and says which. Update `architecture_modules.md` in the same change.
- **Proposal → decisions → small verified steps.** Report what was *measured*, and say what wasn't.
- **The user runs every board and Mac command.** Short numbered steps, one command per code block, say which machine and terminal, and what healthy output looks like. Read the Terminal panel yourself (list the tabs first; titles aren't ids).
- **Lean bench checks:** the smallest check that proves the point; no extra tooling when the ear or a byte count will do. Board-side Python is minimal (`python3-core`, `-io`, `-json`, `-mmap`): check before shipping a dependency.
- Use the Edit/Write tools, not heredoc scripts, for repo files; verify every edit; mutation-test new tests. **The mutation runner must first run the unmutated baseline in its temp folder and stop if it fails** (two false-kill episodes in the last session: arguments passed as one string; tests that needed a git checkout).
- Work on a branch with the attribution trailer; the user opens PRs. Start from `controller-support` (or wherever it has been merged): the server work there is what this builds on.
- Don't edit `../StudioRunner-controller`; if the app needs anything, write it up for the user.

## Not in this task

- Mute, EQ, dynamics, delay (later Phase 7 work; the strips already show them when advertised, D64–D65).
- Gain smoothing (deferred since Phase 5; note where it would go).
- USB host mode (Phase 11) and the AVB checks still open from Phase 10.
