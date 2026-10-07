# Prompt: channel sources, virtual groups, snapshots

*Written 2026-10-06 at the end of the Phase 12–13 session (`phase12_status_2026-10-04.md`, `phase13_status_2026-10-06.md`), as the opening prompt for a fresh session in the **FPGAmixer** repo. The StudioRunner app is next to it at `../StudioRunner-controller` (read it with `git show origin/main:<path>` after a `git fetch`; never edit it).*

---

You're working on FPGAmixer: a digital matrix mixer on a Genesys ZU-3EG, controlled over OSC by the StudioRunner macOS app. Today: 20 inputs (4 Pmod analog, 8 USB, 8 AVB) → levels → input matrix → 20 buses → levels → bus matrix → 20 outputs → levels, peak meters on every channel, all persistent. Core channel k **is** physical port k (`fpgamixer_top`'s channel map).

The user asked for three quality-of-life features (2026-10-06, their words, lightly trimmed):

1. **Channel sources.** "Having Analog, USB, and AVB is great, but I rarely need all at once, and finding the right channel is a pain. I'd like to be able to configure the mixer to N×Y×Z channels, with each channel being generic. I'd like to then be able to assign input channel sources and output channel destinations in the UI. For example, I could assign inputs 1–5 to AVB 4–9, and then set output channels 1–3 to USB 1–3."
2. **Virtual groups.** "I like having mono channels because it makes it very clear where everything is going, but I don't want to have to individually change every parameter when working in stereo or surround. In the UI, a user should be able to assign any channel to a group, and then when any parameter is changed on any channel in a group, that change is reflected across all channels in that group. This could technically be done only in the UI, but then changes wouldn't persist across sessions."
3. **Snapshots.** "This is intended to be a studio tool, and I might begin work on one track before finishing another. I'd like a system to save a system snapshot to the board (or to my computer) that I can then load again later."

The previous session agreed with the user that all three make sense, and recommended the order and shapes below. **Start by writing a proposal** (`docs/phase14_status_<date>.md`, or one per feature): check the recommendations against the code, list the decisions, and let the user decide. Then small verified steps, as in Phases 12–13.

## Read first

1. `docs/architecture_modules.md`: §1–§2.1 (the contracts, the channel map, "appended, never interleaved"), §3, §4.1 (windows: the next free one is **0x8000_C000**), **§4.2** (OSC zone → backend → window; **the state file mirrors the OSC tree, and that format is a contract**).
2. `docs/FPGA Mixer OSC Standard.md`: zones, values (enum options are **numbers only**, no labels), config reply (module metadata is **global per module name**), sets/echoes, errors, metering.
3. `docs/phase12_status_2026-10-04.md` (the chain, `mixer_core_pkg`: **D = 249 of D_MAX = 250**; the lane chooser) and `docs/phase13_status_2026-10-06.md` (tap ports, meters).
4. The server: `tools/osc_mixer_server.py` (backends, `build_backends`, `apply_set`, the ordering lock), `tools/mixer_params.py` (the model, `ModuleSpec`), `tools/mixer_state.py` (the store), `tools/mixer_meters.py`.
5. The app's decisions: `../StudioRunner-controller/docs/DECISIONS.md`, especially D44 (matching echoes to edits), D64 (proposed modules: `name`, **`source`**, …), D65, D74–D77. The app builds every tab from the config reply.
6. Memory (`MEMORY.md`): bench (Mac only, `amd-edf.local`), Defender/Device Guard blocking XSim and `sdtgen` (retry; never touch security settings), lean bench checks.

## Recommended order, and why

**Snapshots → groups → channel sources.**

- **Snapshots first:** the smallest (server + protocol, no gateware), useful at once, and a safety net (save before experimenting) for the other two. It also builds the one piece the other features need: a way to tell controllers that **many parameters, or the topology, just changed** (after a recall; after a channel-count change).
- **Groups second:** server-only (plus the app's UI); it settles the linking rules before channel sources add `source`/`destination` modules that must *not* be linked.
- **Channel sources last:** the biggest (gateware, BD, server, protocol, app). If the user would rather start here (it is the stated pain point), nothing blocks it: the "topology changed" message is then built here instead.

Every feature needs app work. As in controller support: **amend the standard first** (user review), build the firmware side, and write the app side up as a handoff for the controller repo.

## 1. Snapshots: recommended shape

- **Format = the state file's** (§4.2: the OSC tree as nested JSON), minus `system` (the name and read-only settings stay with the device). One format on the board and on the computer; a snapshot taken on the board can be downloaded and loaded back.
- **Complete, not sparse:** the config's `values` are sparse against module defaults, but the reset state isn't the defaults (diagonals and channel levels at 0 dB), so a snapshot stores every parameter.
- **Board storage:** `/var/lib/fpgamixer/snapshots/<name>.json`, written crash-safely like the state file (`mixer_state.py`'s method), names under the device-name rules.
- **Protocol (to design):** save / load / delete / list, e.g. requests under `system/snapshot/…`, and the list in the config's `system` block or its own reply. Loading from the computer: the app sends a snapshot JSON string (the config reply already travels as a JSON string), so "load from file" and "load from board" are one path.
- **Recall:** every value through the model's rules (clamped, refused when the zone/index/module doesn't exist on this mixer: a snapshot from a bigger configuration loads what fits, and says what it skipped), then one push and one COMMIT per window. Windows commit independently and there is no gain smoothing yet, so a recall may click; fine for a studio, state it.
- **Telling controllers:** either a `set` broadcast for every changed parameter (up to ~900 messages: fine over TCP) or a new "config changed, fetch it again" broadcast (one message; app work). Recommend the broadcast message: channel sources' count changes need it anyway.
- **Recall scope** (decide): everything, or everything but the I/O patch (once channel sources exist), as consoles offer.

## 2. Virtual groups: recommended shape

- **In the server, not the UI**: persistent, the same for every controller, and in snapshots for free. A module **`group`** (int, 0 = none, 1..G) on each channel zone; groups are per zone (an input group and a bus group are different things).
- **On a set of a linked module on a grouped channel**, the server applies the change to every member, under the ordering lock, and echoes each member's applied value (the app's D44 already takes device-originated sets).
- **Decisions:**
  - Which modules link: `level`, `mute`, later EQ/dynamics; never `group`, `name`, `source`/`destination`.
  - **Absolute or relative** level linking: relative (offsets kept, like DAW fader groups) suits trims; absolute suits matched stereo pairs. Clamping and "off" (−90) make relative links lossy at the ends; decide the rule.
  - **Matrix crosspoints:** with a stereo input group (1, 2) sent to a stereo bus group (3, 4), changing 1→3 should change 2→4, not 2→3: pair members by order when both sides are groups of the same size; apply across one side when only that side is grouped; decide what happens when sizes differ.
  - Joining a group: does the new member take the group's values, or keep its own?
- Names/colours of groups: later, unless the user wants them now.

## 3. Channel sources: recommended shape

- **A patch on each side of the core, in the PL**, as selectors (one source per destination; no mixing): before the core, input channel k ← physical input `src[k]` (or none); after it, physical output p ← output channel `sel[p]` (or none). Each table is a small coefficient bank (`coef_bank_ram`, row length 1) in its own window. Physical port indices keep the "appended, never interleaved" rule; core channel numbers become the user's.
  - **Cost and latency:** do the input selection inside `pcm_pack2stream` (it already emits one channel per cycle: read `in_flat[src[k]]` through a read port, one N:1 mux) and the output selection after `pcm_stream2pack` (a registered mux, or per-beat writes into every output that selects that channel). Each adds about one cycle: **D = 249 of 250**, so check whether D_MAX can loosen (it comes from the Pmods' `i2s_port`; the user may remove the Pmods) or whether the chooser just spends lanes.
  - The default patch is identity, so every saved state keeps its meaning.
- **N×Y×Z:** the gateware is built at fixed maximum sizes (DSP and latency budget, `mixer_core_pkg`). Recommend a **runtime** count per zone as system settings (the server advertises only the first N / Y / Z channels; the rest are unpatched and silent), so changing the count needs no rebuild, only the "config changed" broadcast from snapshots. Note the window size limit: a 4 KB window holds at most **960** coefficients (0x100 + 4k ≤ 0x1000), so a matrix above 30 × 32 needs bigger windows (an 8 KB BD range and ADDR_WIDTH 13).
- **Protocol:** per input channel a `source`, per output channel a `destination` (D64 already proposes `source`). Both are pickers from a fixed list of physical ports ("Analog 1–4", "USB 1–8", "AVB 1–8", later the MOTU's). The standard's enums are numbers only, so add **option labels** (e.g. an optional `optionLabels` list beside `options`: additive, no `schemaVersion` bump) and get the app to show them.
- **Decide:** outputs as "each output channel picks one destination" (the user's phrasing) vs "each physical output picks one output channel" (what the hardware does; lets one output feed two places). The server can present the first on top of the second; then assigning a destination that another channel has either steals it (the other becomes none, echoed) or is refused.

## How this user works

- **Proposal → decisions → small verified steps.** Report what was measured, and say what wasn't.
- **Modularity first:** each feature plugs into an existing seam and says which; `architecture_modules.md` is updated in the same change; status docs as you go.
- **The user runs every board and Mac command**; short numbered steps, one command per block, what healthy output looks like. Bench checks are lean: by ear or by eye in the app.
- Edit/Write tools for repo files; verify edits; **mutation-test** new tests (the runner runs the unmutated baseline in its temp folder first; a tool launch failure is no verdict).
- Work on a new branch from `phase13-metering` (or wherever it was merged); the attribution trailer; the user opens PRs. Don't edit `../StudioRunner-controller`; write app work up for the user.
- **Board recipes list their files explicitly** (`fpgamixer-osc_1.0.bb`): a new Python module must be added there (Phase 13 nearly shipped a server that couldn't import `mixer_meters`).
