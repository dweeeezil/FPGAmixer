# Plan: snapshots

**Written:** 2026-10-06 17:40 PDT (2026-10-07 00:40 UTC), at the end of Phase 13, on branch `phase13-metering` (commit `d3c1587`).
**Status:** plan only, nothing built. Order agreed in principle: **snapshots → virtual groups → channel sources**, after Phase 11 (USB host mode), which the user put first on 2026-10-06.
**Companions:** `plan_virtual_groups_2026-10-06.md`, `plan_channel_sources_2026-10-06.md`; the session prompt that bundles all three: `docs/prompt_phase14_qol.md`.

---

## The request (user, 2026-10-06)

> "This is intended to be a studio tool, and I might begin work on one track before finishing another. I'd like to have a system to save a system snapshot to the board (or to my computer) that I can then load again later. This should be relatively simple, as the UI already loads the Json on connection."

## Why first

The smallest of the three (server + protocol + app, no gateware), useful at once, and a safety net before the other two. It also builds the one piece the others need: a way to tell controllers that **many parameters, or the topology, just changed** (after a recall here; after a channel-count change in channel sources).

## Shape (recommended; to be decided in a proposal)

- **Format = the state file's** (`architecture_modules.md` §4.2: the OSC tree as nested JSON, a contract), minus `system` (the name and read-only settings stay with the device). One format on the board and on the computer: a board snapshot can be downloaded and loaded back.
- **Complete, not sparse.** The config's `values` are sparse against module *defaults*, but the reset state isn't the defaults (both matrix diagonals and every channel level at 0 dB; `level`'s default is −90), so a snapshot stores every parameter.
- **Board storage:** `/var/lib/fpgamixer/snapshots/<name>.json`, written crash-safely as `mixer_state.py` writes the state file (temp + fsync + rename); names under the device-name rules (`name_problem`).
- **Protocol (to design and add to `docs/FPGA Mixer OSC Standard.md` first, user review):** save / load / delete / list, e.g. requests under `system/snapshot/…`; the list in the config's `system` block or its own reply. Load from the computer: the app sends the snapshot JSON as a string (the config reply already travels as a JSON string), so "load from a file" and "load from the board" are one path.
- **Recall:** every value through the model's rules (`mixer_params.Model.resolve` + `ModuleSpec.apply`), refused where the zone / index / module doesn't exist on this mixer (a snapshot from a bigger configuration loads what fits and reports what it skipped); then **one push and one COMMIT per window**. Windows commit independently and there is no gain smoothing yet, so a recall may click; acceptable for a studio, to be stated.
- **Telling controllers:** a `set` broadcast for every changed parameter (≈ 900 messages: fine over TCP), or a new **"config changed, fetch it again"** broadcast (one message; app work). Recommend the broadcast message, which channel sources' runtime counts need anyway.
- **Recall scope (decide):** everything, or everything but the I/O patch once channel sources exist (as consoles offer "recall safe").
- **Meters, groups and patch:** groups and the patch are ordinary parameters, so snapshots carry them with no special code.

## Seams

Control plane only: a snapshot store next to `mixer_state.py`, request handlers in `osc_mixer_server.py`, the model for validation, the backends' existing `apply` / `seed_and_push` paths for the push. No gateware, no image change beyond the server files (remember: the `fpgamixer-osc` recipe lists its files explicitly).

## Tests to plan

Round trip (save → change → load → every value back, every window pushed once); a snapshot from a bigger and a smaller configuration; a corrupt or hand-edited file refused with a reason, nothing applied; names refused under the rules; two controllers both told; crash safety of the write (as `test_mixer_state`); the app-side decoding of whatever new message is chosen. Mutation-tested.

## App work (controller repo, handoff)

Save / load / delete / list UI; export / import to a file on the Mac; handling the "config changed" message (refetch the config, as on connect).
