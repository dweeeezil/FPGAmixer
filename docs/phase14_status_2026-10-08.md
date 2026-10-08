# Phase 14 status: 2026-10-08 — quality of life: snapshots first

**Branch:** `phase14-snapshots` (from `main` at `68b541b`, the Phase 11 merge, PR #9).
**Plans:** `docs/plans/plan_snapshots_2026-10-06.md` (this phase), then `plan_virtual_groups_…`, `plan_channel_sources_…`; bundled in `docs/prompt_phase14_qol.md`.
**Status: snapshots DONE 2026-10-08 (S1–S8, §2–§4; bench PASS with the app). Virtual groups: proposed (§6), decisions V1–V8 open.** The user updates the controller (StudioRunner) side from the standard (`docs/FPGA Mixer OSC Standard.md`, *Snapshots*, amended 2026-10-08).

---

## 1. The request

> "This is intended to be a studio tool, and I might begin work on one track before finishing another. I'd like to have a system to save a system snapshot to the board (or to my computer) that I can then load again later." (user, 2026-10-06)

> "Let me know what API conventions you're thinking for the snapshots and I'll update the controller side of things too." (user, 2026-10-08)

## 2. Proposed API

### 2.1 A new command kind, `snapshot` (TCP only)

The same pattern as `meter`: the segment after the mixer name is the kind (standard, *Command kinds*). Snapshot requests aren't parameter sets: they don't echo themselves, and they change many parameters at once, so they don't fit `set`/`get` on the `system` zone. UDP stays `set`-only; a `snapshot` message over UDP is ignored, like any other non-`set`.

**Controller → mixer**

| Request | Does |
|---|---|
| `/<name>/snapshot/list` | asks for the list of snapshots stored on the board |
| `/<name>/snapshot/save <name:s>` | stores the **live state** on the board under that name (replaces one of the same name) |
| `/<name>/snapshot/load <name:s>` | recalls a snapshot stored on the board |
| `/<name>/snapshot/delete <name:s>` | deletes a stored snapshot |
| `/<name>/snapshot/fetch` | asks for the **live state** as snapshot JSON ("save to my computer") |
| `/<name>/snapshot/fetch <name:s>` | asks for a stored snapshot's JSON ("download") |
| `/<name>/snapshot/apply <json:s>` | recalls a snapshot the controller sends ("load from my computer") |
| `/<name>/snapshot/store <name:s> <json:s>` | stores a snapshot the controller sends, **without** recalling it ("upload") |

**Mixer → controller**

| Message | When, to whom |
|---|---|
| `/<name>/snapshot/list <json:s>` | the reply to `list` (requester only); **and broadcast to every TCP controller after a `save`, `store` or `delete`**: that broadcast is the confirmation, as a `set`'s echo is |
| `/<name>/snapshot/data <name:s> <json:s>` | the reply to `fetch` (requester only); `name` is `""` for the live state |
| `/<name>/snapshot/loaded <name:s> <applied:i> <skipped:i>` | broadcast to every TCP controller after a `load` or `apply`, **after** the `set`s it caused (§2.3) |
| `/<name>/error snapshot/<request> <reason:s>` | a refused request (standard, *Error reply*), requester only, e.g. `snapshot/load` "no snapshot named 'Song B'" |

`list` JSON: an array, sorted by name:

```json
[
  {"name": "Song A rough", "savedAt": "2026-10-08T17:02:11Z"},
  {"name": "Before load",  "savedAt": "2026-10-08T17:05:40Z", "auto": true}
]
```

Integers (`applied`, `skipped`) travel as OSC `i`, like `pong`'s token; a controller should also accept `f`.

**Config:** an optional top-level `"capabilities": ["snapshots"]` (additive; no `schemaVersion` bump). An older mixer ignores an unknown command kind without a reply, so the app shows snapshot UI only when the mixer advertises it.

### 2.2 The snapshot JSON (one format on the board and on the computer)

```json
{
  "snapshotVersion": 1,
  "name": "Song A rough",
  "savedAt": "2026-10-08T17:02:11Z",
  "source": {"deviceName": "FOHmixer", "firmware": "4f5b29b"},
  "zones": {
    "inputChannel": {"count": 20, "modules": ["level"]},
    "inputMatrix":  {"rows": 20, "cols": 20, "modules": ["level"]}
  },
  "values": {
    "inputChannel/0/level": 0.0,
    "inputMatrix/4_0/level": -6.0
  }
}
```

- **`values`**: the same keys as the config's `values` (the address tail of a `set`), so the app reuses the parser it has. **Complete**, not sparse: every parameter of every zone (today 860: 60 channel levels + 2 × 400 crosspoints), because the reset state isn't the modules' defaults. **No `system/*`**: the name and settings stay with the device.
- **`zones`**: the topology it was saved from, informational (the app can say "saved on a 20 × 20 mixer"; recall doesn't need it).
- **`snapshotVersion`**: a breaking-change number like `schemaVersion`; a mixer refuses a newer one. Unknown keys are ignored.
- On the board: `/var/lib/fpgamixer/snapshots/`, one file per snapshot, written crash-safely like the state file (temp + fsync + rename). The name inside the file is the truth; the file name is a safe encoding of it.
- This differs from the plan, which proposed the state file's nested tree: the flat `values` map is what the app already parses from the config, and the envelope carries the metadata. The state file itself is unchanged.

### 2.3 Recall (`load` and `apply`)

1. **Validate first, apply nothing on failure:** not JSON, no or a newer `snapshotVersion`, `values` missing or not an object, a value of the wrong kind (a string for a number) → the whole request is refused with an error reply.
2. **Fit it to this mixer:** a path the mixer doesn't have (a zone, index or module it lacks, e.g. a snapshot from a bigger configuration) is **skipped and counted**; numbers are clamped and snapped by the module's rules (not errors, as for any `set`). `system/*` entries are ignored.
3. **Parameters the snapshot doesn't mention keep their current value.**
4. **Push:** every window that changed gets one bank push and **one COMMIT**. The windows commit independently and there's no gain smoothing yet, so a recall can click. Acceptable for a studio; stated in the standard.
5. **Tell controllers:** under the ordering lock, one broadcast `set` for **every value that changed** (only those), then `snapshot/loaded <name> <applied> <skipped>`. A controller that knows nothing about snapshots still ends up in sync, through the same path as any other device-originated set (app D44). A full recall of today's mixer is at most ~860 sets over TCP.
6. The live state is saved (the state file) like any other change, so a recall survives a power cycle.

`applied` = values in the snapshot that this mixer has (whether or not they changed); `skipped` = values it doesn't have.

### 2.4 Names and limits

- **Snapshot names:** 1–63 bytes of UTF-8; spaces allowed; no `/`, `\` or control characters; no leading `.` and no leading or trailing spaces; case-sensitive. (These are labels, not addresses, so the device-name rules don't need to apply.)
- At most **128** stored snapshots; a snapshot JSON at most **1 MiB** (today's is ~30 KB). Past either limit, `save`/`store` is refused with a reason.
- `save` and `store` over an existing name replace it; the app asks the user before overwriting (it has the list).

## 3. Decisions (recommended first)

| # | Question | Recommended | Alternative |
|---|---|---|---|
| S1 | Where the requests live | a new command kind `snapshot` (§2.1) | requests under `system/snapshot/...` with `set`/`get` (awkward: no echo semantics fit) |
| S2 | How controllers learn about a recall | broadcast `set`s for every changed value, then `snapshot/loaded` (§2.3) | a single "config changed, fetch it again" message (needs app work to stay in sync; deferred to channel sources, where topology changes need it) |
| S3 | Format of `values` | flat keys, as in the config (§2.2) | the state file's nested tree (the plan's first idea) |
| S4 | Parameters a snapshot doesn't mention | keep their current value | reset to the reset state |
| S5 | Snapshot names | labels with spaces (§2.4) | the device-name rules (no spaces) |
| S6 | Undo for a recall | the mixer saves the live state as **"Before load"** (`"auto": true` in the list) just before every `load`/`apply`, replacing the previous one, so a mis-click can be undone by loading it | none |
| S7 | `store` (upload a computer file to the board without recalling it) | include | leave out (the app can `apply` then `save`, at the cost of recalling it) |
| S8 | Recall scope | everything (there's only one kind of parameter until channel sources add the I/O patch; "recall safe" for the patch is decided then) | — |

**Decided by the user 2026-10-08: "as recommended"** (S1–S8, the left column).

## 4. Steps

1. Amend the standard (*Snapshots* section, *Command kinds* row, `capabilities` in *Config*, change log); user review.
2. `tools/mixer_snapshots.py` (the store: list, read, write crash-safely, delete, name rules, limits; the format's validation) + `test_mixer_snapshots.py`.
3. The server: the `snapshot` kind, recall through the model and the backends (one push per window), the broadcasts, `capabilities` in the config; tests (round trip, a bigger and a smaller snapshot, corrupt files refused, names, two controllers both told, crash safety). Mutation-tested. **Add `mixer_snapshots.py` to the `fpgamixer-osc` recipe's file list.**
4. Image, bench by ear with the app (save, change, load, power cycle, download, upload).
5. The app (user): list / save / load / delete UI, export / import a file, the `loaded` notice.

### 4.1 Steps 1–3 done (2026-10-08)

- **Standard** amended: *Snapshots* section, the `snapshot` row in *Command kinds*, "TCP only" in *Transports*, `capabilities` in *Config*, the error list, the change log (8 Oct 2026; additive, `schemaVersion` stays 1).
- **`tools/mixer_snapshots.py`**: `name_problem`, `parse` (envelope: JSON object, `snapshotVersion` 1, `values` an object of numbers/strings, ≤ 1 MiB), `make_snapshot`, `SnapshotStore` (one file per snapshot, the name percent-encoded into the file name with a local encoder because `urllib.parse` isn't in the board's `python3-core`; temp + fsync + rename + directory fsync; a leftover `.tmp` removed on open; an unparsable or misnamed file skipped and logged, never deleted; 128 snapshots, replacing at the limit allowed; in memory when there's no state file).
- **Server**: `handle_snapshot` (all seven requests), `fit_snapshot`, `recall_snapshot`, `live_values`/`snapshot_of`; `Backend.apply_many` (default per value; `MatrixBackend`/`GainBackend`: one `set_bank_db`, one COMMIT, returning the applied values, so `mixer_hw.MatrixHW/GainHW.set_bank_db` now return `{key: applied dB}`); `capabilities: ["snapshots"]` in the config; `--snapshot-dir` (default `snapshots/` next to the state file, so `/var/lib/fpgamixer/snapshots` on the board with no service change). UDP ignores `snapshot` (it already ignored every non-`set`).
- **Recipe**: `mixer_snapshots.py` added to `fpgamixer-osc_1.0.bb`'s `SRC_URI` and `do_install` (no new Python packages: json, os, threading, time).
- **Tests**: `test_mixer_snapshots.py` (13: names, the envelope, the store, limits, a failed write leaves the old file, bad files skipped, reopen) and `test_osc_mixer_server.py` `Snapshots` (9, over TCP: save + list broadcast to two controllers + complete fetch; load round trip broadcasting only the changes then `loaded`; "Before load" as undo; a bigger snapshot fitted with skips, clamping, unmentioned values kept, `system/*` ignored; a refused entry / bad JSON / newer version refuse the whole recall with nothing changed and nobody told; store without recall, name and `auto` replaced; refusals; delete broadcast; UDP ignored) plus `InProcess` (one bank per window, applied values echoed) and the config test (`capabilities`). Windows: 142 OK (server, snapshots, state, params). **Mutants 23/23 killed** (baseline clean first): changes-only broadcast, the undo point, whole-recall refusal, `system/*` ignored, `applied` count, the three list broadcasts, store's name/`auto`/no-recall, the bank mapping and single COMMIT, applied values echoed, `capabilities`, no `system/*` in snapshots; names, version, the limit, the temp write, `.tmp` cleanup, sorting, misnamed files.

- **Linux** (the build VM, Python as on the board): 197 tests OK (server, snapshots, `mixer_hw`, state, params, meters).
- **Image `p14s-snapshots-20261008`** (layer `54e3dd8`, bitstream `p11h3` unchanged, no `gen-machine-conf`): all tasks succeeded, 4 min 5 s, the same 22 warnings. Checked: bitstream MD5 `58d7e3f6…`; rootfs `VERSION` `54e3dd8`, `/usr/lib/fpgamixer/mixer_snapshots.py` present, the server has `handle_snapshot`. **`build/sd/p14s-snapshots-20261008.wic.xz`** (MD5 `7a7bd10a…`, same on both ends).

### 4.2 For the app (controller repo)

The standard's *Snapshots* section is the spec. What the app needs:

- Offer snapshots only when the config's `capabilities` contains `"snapshots"`.
- **List**: send `snapshot/list` after sync; keep the list from any `snapshot/list` message (they also arrive unasked after any controller's save/store/delete). Entries with `"auto": true` ("Before load") can be shown as an undo.
- **Save to board**: `snapshot/save <name>`; confirm overwrite in the UI when the name is listed. **Load**: `snapshot/load <name>`. **Delete**: `snapshot/delete <name>`.
- **Save to computer**: `snapshot/fetch` (no argument) → `snapshot/data "" <json>` → write the JSON to a file (`.json`; the app chooses the file name). **Download a board snapshot**: `snapshot/fetch <name>`.
- **Load from computer**: `snapshot/apply <json>`. **Upload to board**: `snapshot/store <name> <json>`.
- **After a recall** the values arrive as ordinary `set`s (D44's device-originated path), then `snapshot/loaded <name> <applied> <skipped>`: show it (e.g. "Loaded 'Song A' (3 skipped)"). Up to ~860 sets arrive in a burst today.
- Refusals arrive as `/<name>/error snapshot/<request> <reason>`: show the reason.
- Name rules for the UI's validation: 1–63 UTF-8 bytes, spaces OK, no `/` `\` or control characters, no leading `.`, no leading/trailing space.

## 5. Log

- **2026-10-08:** Phase 11 merged (PR #9); branch `phase14-snapshots`. Snapshot API proposed (§2), decisions S1–S8 to the user.
- **2026-10-08:** decisions S1–S8 as recommended. Next: the standard, then the store and the server.
- **2026-10-08:** steps 1–3 done (§4.1): standard amended; store + server + recipe; 142 tests OK on Windows, mutants 23/23. Next: Linux test run, image, bench once the app speaks it.
- **2026-10-08:** **snapshots bench PASS** with the app: the user built snapshots into StudioRunner; *"everything works great."* Snapshots done.
- **2026-10-08:** virtual groups started (§6), branch `phase14-vgroups` (from `phase14-snapshots`). Proposal V1–V8 to the user.

## 6. Virtual groups (vGroups): proposal (2026-10-08)

> "I like having mono channels because it makes it very clear where everything is going, but I don't want to have to individually change every parameter when working in stereo or surround. In the UI, a user should be able to assign any channel to a group, and then when any parameter is changed on any channel in a given group, that change is reflected across all channels in that group. This could technically be done only in the UI, but then changes wouldn't persist across sessions." (user, 2026-10-06)

Plan: `docs/plans/plan_virtual_groups_2026-10-06.md`. Control plane only: no gateware, no image change beyond the server.

### 6.1 Proposed shape

- **A module `vgroup`** on each channel zone (`inputChannel`, `busChannel`, `outputChannel`): `int`, 0 = not grouped, 1..N = group number (N = the zone's channel count), default 0. **Not `group`**: `group` is already a metadata key in the standard (UI clustering, `"group": "level"`), so a module of that name would be ambiguous in the config. Groups are **per zone**: input group 1 and bus group 1 are unrelated.
- **An ordinary parameter**: set/get/echo like any other, stored in the state file, carried by snapshots (a recall sets every member's values as stored; it doesn't apply linking).
- **Which modules link**: a module opts in by metadata, a new optional `"linked": true` in its config description (additive, no `schemaVersion` bump), so future modules (mute, EQ, dynamics) link by declaring it. Today: `level`. Never linked: `vgroup` itself, and later `name`, `source`/`destination`.
- **A set on a grouped channel** (TCP or UDP) applies the same value to every member, with one bank write / one COMMIT per window (`Backend.apply_many`, from snapshots), under the ordering lock; then every member's applied value is broadcast as a `set`, **the edited parameter first** (so the sender's pending edit, app D44, resolves at once) and the other members after it, in index order.

### 6.2 Matrix crosspoints

The rows of `inputMatrix` are input channels and its columns buses; `busMatrix` rows are buses and its columns outputs. A crosspoint set links through the groups of its row and its column:

| Row's channel | Column's channel | Linked crosspoints | Example |
|---|---|---|---|
| ungrouped | ungrouped | just this one | — |
| in a group R | ungrouped | every member of R → the same column | stereo input → a mono bus: L and R both at −6 |
| ungrouped | in a group C | the same row → every member of C | a mono mic → a stereo bus: both sides at −6 |
| group R | group C, **same size** | pairs by position, keeping the offset: setting (R[a], C[b]) sets (R[i], C[(i + b − a) mod n]) for every i | stereo (1, 2) → stereo bus (3, 4): 1→3 sets 2→4; 1→4 sets 2→3 |
| group R | group C, different sizes | just this one (no linking) | stereo → a 5.1 bus group: set each send yourself |

### 6.3 Decisions (recommended first)

| # | Question | Recommended | Alternative |
|---|---|---|---|
| V1 | Where linking lives | in the server (persistent, the same for every controller, in snapshots) | in the app only |
| V2 | Module name and type | `vgroup`, int 0..N, per channel zone | `group` (collides with the metadata key); an enum |
| V3 | Absolute or relative level linking | **absolute**: every member gets the same value (a console stereo link; lossless, no edge cases at −90 / +6.02) | relative (DAW fader groups: offsets kept; lossy at the ends); a per-group mode later if wanted |
| V4 | Joining a group | **the channel keeps its own values**; joining never changes the audio, and the next edit of a linked parameter aligns all members | the new member copies the group's values at once (channel levels and its matrix sends) |
| V5 | Matrix rule | as §6.2 (pair by position with the offset for equal sizes; fan out across one grouped side; no link for unequal sizes) | unequal sizes: pair the first min(R, C) by position |
| V6 | Which modules link | opt-in by `"linked": true` metadata; today `level` (channels and matrices) | a fixed list in the server |
| V7 | Echo order | the edited parameter first, then the other members in index order | index order only |
| V8 | Group names / colours | later (the app can colour by number); they'd be `system`-level metadata, not per channel | now |

### 6.4 Steps (after the decisions)

1. The standard: `vgroup` and the linking rules (a *Virtual groups* section), `linked` in the module metadata, the change log. User review; the user updates the app from it.
2. The server: `vgroup` on the three channel backends; `ModuleSpec.linked`; the linking step in `apply_set` (channels and matrices, §6.2) through `apply_many`; tests (each table row, absolute values at the clamps, the echo order, two controllers, UDP, snapshots carry `vgroup` and don't link on recall, `vgroup` itself never links). Mutation-tested.
3. Image; bench with the app (stereo pairs by ear: a stereo input to a stereo bus).
