# Phase 15 status: 2026-10-08 — channel sources (I/O patch, runtime channel counts)

**Branch:** `phase15-sources` (from `phase14-vgroups`, which holds snapshots, groups and the unshipped channel names; not yet merged to `main`).
**Plan:** `docs/plans/plan_channel_sources_2026-10-06.md` (written before Phase 11 and the rest of Phase 14; the corrections are in `docs/prompt_channel_sources_2026-10-08.md` and folded in below).
**State:** decided 2026-10-08 (§4: as recommended, except **CS5: no default patch**). Step 1 (the standard) done; the app's handoff is §7.

**Terms.** An **I/O port** is one channel of one of the mixer's interfaces, whatever the interface: the analog interface on the USB host port, **USB** (the computer, USB device mode) and the **network** (AVB). "Port" below always means that; it isn't limited to analog jacks (the user's clarification, 2026-10-08). A **channel** is the mixer's own, generic: input channel, bus, output channel.

---

## 1. The request

> "Having Analog, USB, and AVB is great, but I rarely need all at once, and finding the right channel is a pain. I'd like to be able to configure the mixer to N×Y×Z channels, with each channel being generic. I'd like to then be able to assign input channel sources and output channel destinations in the UI. For example, I could go in and assign inputs 1–5 to AVB 4–9, and then set output channels 1–3 to USB 1–3." (user, 2026-10-06)

## 2. Today

- **Core channel k is I/O port k**, both ways (`fpgamixer_top`: `core_in = {link2_rx, link_rx, link3_rx[0:3]}`):

  | I/O port | Front door | Label (CS4) |
  |---|---|---|
  | 0–3 | link #3, USB host (the MOTU M2 uses 0–1; 2–3 silent) | Analog 1–4 |
  | 4–11 | link #1, USB device (the Mac) | USB 1–8 |
  | 12–19 | link #2, AVB | AVB 1–8 |

- The core is fixed at **20 inputs → 20 buses → 20 outputs** (4 + 4 matrix lanes + 3 gain DSPs, **D = 249** of **D_MAX = 250**).
- The control SmartConnect is **full** (16 masters; M14 = formatter #3, M15 = link #3's status window at 0x8000_C000).
- Snapshots, virtual groups and channel names exist in the server (Phase 14); names ship with this feature's image.

## 3. Proposed shape

### 3.1 Signal flow

```
I/O in (20) ─► input patch ─► input channels (N) ─► levels ─► input matrix ─► buses (Y) ─► levels
               ch k ← source[k]                                                              │
I/O out (20) ◄─ output patch ◄─ output channels (Z) ◄─ levels ◄─ bus matrix ◄──────────────────┘
               port ← the channel whose destination it is
```

- **Input patch:** each input channel picks **one I/O input (analog, USB or AVB) or None** (silence). Any number of channels may pick the same input (the same mic on two channels with different processing).
- **Output patch:** each output channel picks **one I/O output (analog, USB or AVB) or None**. An I/O output belongs to at most one output channel; picking one that another channel holds **takes it** (the other channel becomes None and is echoed, CS2). One mix to several places is what the bus matrix is for (a bus to two output channels, each with its own destination), so the patch stays a plain one-to-one selector.
- **No default patch (CS5, the user):** *"A blank slate should be a blank slate."* Every `source` and `destination` starts as None, in the PL's reset tables and in the server; nothing is heard until something is patched. **Upgrading a board** whose state predates the patch gives the same: the state has no `source`/`destination`, so all are None and the mixer is silent until patched in the app (its levels and crosspoints are kept). Non-PS builds (no runtime control: `tb_top_*` and the non-PS projects) keep an identity reset patch, since nothing could ever patch them.

### 3.2 Gateware (CS1, CS10, CS11)

Two new generic **core-boundary blocks** replace the two converters inside `mixer_core` (the converters stay, for `matrix_packed_sim` and the matrix TBs):

- **`pcm_patch2stream`** (packed P_IN → stream N_IN): captures the I/O frame on the strobe like `pcm_pack2stream`, then per beat k reads `source[k]` through a coefficient read port and emits that port's sample (0 = None → silence). +1 cycle against `pcm_pack2stream` (the read port's latency; a read before the strobe would see the previous frame's table).
- **`pcm_stream2patch`** (stream N_OUT → packed P_OUT): per beat c reads `destination[c]` through a read port and writes the sample to that I/O output's slot; the slots are cleared at the strobe, so a port no channel picks is silent. All ports move to the packed output together, +1 cycle against `pcm_stream2pack`.
- **Tables:** register value = OSC value: 0 = None, p + 1 = I/O port p. Each a `coef_bank_ram` (ROW_LEN 1, W = 5 bits for 20 ports), so a repatch lands whole on one frame strobe like every other coefficient change (§3 of `architecture_modules.md`). Two drivers on one port (only reachable by bypassing the server) resolve deterministically: the later channel wins.
- **`mixer_core`** gains `P_IN` / `P_OUT` (I/O ports) and two read ports (`in_patch_*`, `out_patch_*`); its packed sides become the I/O ports. It still knows nothing about what the ports are; `fpgamixer_top` keeps the port map and the reset tables (all None in PS builds, identity without the PS; CS5).
- **Latency:** D = 249 + 2 = **251**. D_MAX is re-derived as **255**: since the Pmods went, the only consumers of the core's output are the three `pcm_link`s, which take it at the next strobe (cycle 256). To be confirmed against `pcm_link`'s capture in step 2 and checked at elaboration; the lane chooser keeps 4 + 4 (one lane fewer costs about two matrix passes, far over 255).
- **Windows:** a binding `patch_regs_axil` (ID `0x5054_5001`, "PT"; CONFIG = rows, ports, direction (0 in, 1 out), entry width) over `axil_coef_window` + `coef_bank_ram`, two instances: **input patch at 0x8000_D000, output patch at 0x8000_E000**.
- **SmartConnect (the main BD question):** a **second SmartConnect `ctrl_smc2` cascaded from the first's M15**; link #3's status window moves onto it (its address 0x8000_C000 and its port name stay, so no RTL or software changes), and the two patch windows join it. That leaves 13 free masters for Phase 7's DSP windows, which would hit the same wall. Nothing else moves; still no PS8 setting changes. To check in the build: sdtgen still emits a device-tree node per window behind the cascade (the server's `WindowAbsent` guard depends on it).

### 3.3 Runtime channel counts: N × Y × Z (CS6, CS7)

- The gateware stays built at **20 × 20 × 20** (the maximum). Three **`system` settings**: `inputCount`, `busCount`, `outputCount` (`int`, 1–20, default 20), stored like any setting.
- The config advertises only the first N / Y / Z: `inputChannel.count` = N, `inputMatrix` N × Y, `busChannel` Y, `busMatrix` Y × Z, `outputChannel` Z; meter blobs carry N / Y / Z peaks. A set or get beyond a count is refused (index out of range), as today past 20.
- **Hidden channels keep their stored values** (not deleted, not in the config, not in snapshots) and are **silenced in hardware**: a hidden input's patch is None, a hidden output's destination is None, a hidden bus's level is off. Nothing can reach a visible output through a hidden channel, and raising a count brings the channels back exactly as they were. (A hidden output's stored destination can still be taken by a visible channel; it then becomes None in storage.)
- No rebuild for a count change; it's a server operation (rebuild the model, push the hardware overrides, broadcast, §3.5).

### 3.4 Protocol (amend the standard first)

- **`source`** on `inputChannel`, **`destination`** on `outputChannel`: `enum`, `options` [0, 1, …, 20], **`optionLabels`** ["None", "Analog 1", …, "Analog 4", "USB 1", …, "USB 8", "AVB 1", …, "AVB 8"], metadata `group` `"patch"`, never `linked`. The module `default` is 0 (None), and nothing is seeded (CS5), so the config's sparse `values` list only the channels that are patched.
- **`optionLabels`** (new, optional, any `enum`): a list of strings the same length as `options`, the label for each option. Additive, `schemaVersion` stays 1; a controller without it shows the numbers.
- **A taken destination** is echoed: the requested `set` first, then `outputChannel/<other>/destination 0` (the vGroups echo order). One `apply_many`, one COMMIT, so the two changes land on the same frame.
- **Counts:** `system/inputCount`, `system/busCount`, `system/outputCount` (`int`, `min` 1, `max` 20, `default` 20), in the config's `system` block.

### 3.5 "Config changed" (deferred here by S2)

A count change alters the topology, which `set`s can't express. After the count's echo the mixer sends, to every TCP controller:

```
/<name>/config/changed
```

(a new command kind `config`, mixer → controller, no arguments). The controller then runs *Connect ordering* steps 2–5 again: send `get/system/config`, discard every `set` until the reply, apply it. Since the reply is serialized into the same stream as the broadcasts, nothing is lost. A controller that doesn't know the kind ignores it (the existing rule) and keeps a stale topology until it reconnects; the app adds it together with the count UI. Any future topology change (a different bitstream's sizes, DSP blocks appearing) uses the same message.

### 3.6 Snapshots and recall safe (CS9)

- `source` / `destination` are ordinary parameters, so snapshots carry the patch. **Recommended: no "recall safe" yet**: a recall sets the patch like everything else (S8 stays "everything"). Snapshots saved within one session share their patch, so recalling between songs changes nothing; a snapshot from another setup brings its patch with it, which is what a "show file" wants. "Before load" undoes a wrong recall. A recall-safe switch can come later if a real case needs it (a `system` bool that makes a recall skip `source`/`destination`).
- A recall that would put two output channels on one destination resolves in index order like a run of `set`s (the later channel takes it; the earlier is echoed as None). A snapshot the mixer saved never does this.
- **Counts are `system` settings, so snapshots don't carry them** (the existing rule: snapshots never hold `system/*`). A snapshot from a wider setup recalls the visible channels and counts the rest as skipped.

### 3.7 Server

- `mixer_hw`: `PatchHW` (window, ID and CONFIG checked, the table as OSC values), the windows `inpatch` / `outpatch`, and **`IO_PORTS`**: the platform's port list with labels, an explicit copy of `fpgamixer_top`'s map like `WINDOWS` (checked against the windows' CONFIG port count at startup).
- The channel zones gain modules served by a second window (`source` → input patch, `level` → input levels), so the channel backends delegate per module instead of assuming one window per zone; `vgroup` and `name` stay stored-only.
- The counts: the model is rebuilt from them; a topology step pushes the hidden-channel overrides (§3.3) through `apply_many`; `MeterHub` slices to the counts.
- An older bitstream without the patch windows: no `source` / `destination`, no count settings; everything else as today.

## 4. Decisions (recommended first)

| # | Question | Recommended | Alternative |
|---|---|---|---|
| CS1 | Where the patch lives | in the PL at the core boundary: `pcm_patch2stream` / `pcm_stream2patch`, tables in `coef_bank_ram`, repatch on a frame strobe (§3.2) | in the Linux bridges (can't move a channel between links; no AVB → MOTU without another copy and latency) |
| CS2 | Output semantics | each **output channel** picks one destination or None; picking a taken one **takes it** (the other becomes None, echoed); one-to-many through the bus matrix | refuse a taken destination (clear it first); or per-I/O-output pickers (a new zone the standard doesn't have) |
| CS3 | Input semantics | each input channel picks one source or None; sources may be shared | exclusive sources |
| CS4 | Port labels | **Analog 1–4, USB 1–8, AVB 1–8** (enum 0 = None, 1–20 in port order); "Analog" because the host port's interface can change | "MOTU 1–2" with link #3's unused ports 2–3 not offered |
| CS5 | Default patch | ~~identity (input k ← port k, output k → port k), seeded on first start~~ | **all None — chosen by the user** |
| CS6 | N × Y × Z | runtime `system` settings `inputCount` / `busCount` / `outputCount`, 1–20; gateware stays 20 × 20 × 20 | sizes at build time (a rebuild per change); or a bigger maximum now (28 × 28 × 28 fits the frame on 10 + 10 lanes) |
| CS7 | Hidden channels | values kept, out of the config, silenced in hardware; they come back unchanged | reset to defaults when hidden |
| CS8 | Topology change | broadcast `/<name>/config/changed`; controllers refetch with the connect ordering (§3.5) | drop every TCP connection so controllers reconnect |
| CS9 | Recall safe | none yet: a recall sets the patch like everything else; counts aren't in snapshots (§3.6) | a `system` "patch recall safe" switch now; or counts inside snapshots (a recall could change the topology) |
| CS10 | Register windows | a second SmartConnect cascaded from M15, link #3's status window moved onto it (same address), patch windows at 0x8000_D000 / 0x8000_E000 (§3.2) | fold the tables into an existing window (breaks one window per block); or an RTL AXI-Lite splitter (a new block to verify, for what SmartConnect does) |
| CS11 | Latency | +2 cycles (D = 251), D_MAX re-derived to 255 | look-ahead reads to keep D = 249 (cleverer, more to verify) |
| CS12 | Enum labels | optional `optionLabels` beside `options` (additive) | labels in the app only |
| CS13 | Names | ship with this image (no separate one), as planned | — |

**Decided by the user 2026-10-08: "as recommended"**, except **CS5: no default patch** (*"Don't do default patching. A blank slate should be a blank slate."*). Clarified at the same time: sources and destinations are every interface's channels, network (AVB) and USB included, not only analog (the *Terms* note at the top).

## 5. Steps (once decided)

1. **Standard:** `source` / `destination`, `optionLabels`, the counts, `config/changed` (+ the *Command kinds* row), the taken-destination echo, the change log. User review; the app is built from it.
2. **RTL:** `pcm_patch2stream`, `pcm_stream2patch` (TBs bit-exact against a model at random tables and random audio, None = silence, identity = the old converters, timing to the cycle with `pcm_stream_monitor`); `mixer_core` with P_IN / P_OUT and the two read ports (`tb_mixer_core` at random patches; D = 251 checked); D_MAX re-derived; `patch_regs_axil` (+ its TB); `fpgamixer_top` (reset tables, windows, `tb_top_windows` reaching both); `xsim_regress.ps1` and `sim.mk` in step. **Mutation-tested**, baseline first.
3. **BD:** `ctrl_smc2`, link #3's window moved, the two patch ports; `architecture_modules.md` address map and block table in the same change.
4. **Server:** `PatchHW`, `IO_PORTS`, per-module delegation on the channel backends, `optionLabels`, the take rule, counts + hidden-channel overrides + `config/changed`, meters sliced; tests (assignments, the take echo, counts in and out with values kept, hidden channels silent in `InProcess`, snapshots carrying the patch, recall resolving duplicates, the older-bitstream fallback). Mutation-tested. Any new Python module into the `fpgamixer-osc` recipe's file list.
5. **Build:** bitstream, sdtgen, `gen-machine-conf`, image (names included). Checks: windows in the device tree, D in the build log.
6. **Bench (user, by ear in the app):** the user's example — inputs 1–5 ← AVB, outputs 1–3 → USB 1–3 — then counts down and back up.
7. **App (user):** pickers with the labels, the count settings, the refetch on `config/changed`.

### 5.1 Step 1 done (2026-10-08)

**Standard** (`docs/FPGA Mixer OSC Standard.md`): new sections *I/O patch* (with the reference server's port table and a config example), *Channel counts*, *Config changed* (under *Config*); `optionLabels` in the module metadata; the `config` row in *Command kinds*; "current counts" in `zones`; meter blobs sized by their length; hidden channels in the error list; the change log. Additive, `schemaVersion` 1.

### 5.2 Step 2 done: RTL (2026-10-08)

- **`pcm_patch2stream`** (input patch: P ports → N channels, `source` per channel through a read port; beats in cycles 2 … N+1) and **`pcm_stream2patch`** (output patch: N channels → P ports, `destination` per channel; channel 0 clears the frame's slots, so an unnamed port is silent; two channels on one port: the later wins; output 2 cycles after the last beat; the same `err_o` rules as `pcm_stream2pack`). Entries are the OSC value: 0 = None, port + 1; anything past P = None.
- **`mixer_core`**: `P_IN` / `P_OUT`, the packed sides are the I/O ports, two more read ports (`in_patch_*`, `out_patch_*`). **`mixer_core_pkg`**: `IN_PATCH_LAT` 1, `OUT_PATCH_LAT` 2, `chain_in_last`; **D = 251** at 20 → 20 → 20, still 4 + 4 lanes. **`pcm_matrix_pkg::D_MAX` = 255** (re-derived: `pcm_link` captures `tx_flat` on the strobe edge, 256). The looser bound lets the chooser save a DSP at 12/12/12 (1 + 2, D 254), a TB size only.
- **`patch_regs_axil`** (ID `0x5054_5001`, CONFIG = N, P, DIR, entry width; entries at 0x100 + 4c) over `axil_coef_window` + `coef_bank_ram`. `axil_coef_window` gained **`COEF_SIGNED`** (default 1: every existing window unchanged): with 0 entries read back zero-extended (port 19 + 1 = 0b10100 would otherwise read negative).
- **`fpgamixer_top`**: `P` = 20 I/O ports, `N` = 20 channels (no longer the same constant); `io_in` / `io_out` (were `core_in` / `core_out`); `u_inpatch_regs` / `u_outpatch_regs` on `M_AXI_INPATCH` / `M_AXI_OUTPATCH` in **every PS build**, reset **all None** (CS5); without the PS, identity `coef_flat_reader`s. `ps_sys_wrapper_stub`: masters 8 and 9.
- **TBs** (XSim, all 17 PASS): new `tb_pcm_patch` (both converters chained, 6 port/channel sizes incl. fewer and more channels than ports, 60 frames each in four table modes: raw fields, console one-to-one, identity, every destination on one port; stream contract and timing; then `pcm_stream2patch` alone: gaps, swapped beats, a missing last beat, recovery) and `tb_patch_regs` (both windows across unrelated clocks: ID/CONFIG, reset tables, shadow vs COMMIT, zero-extended readback, WSTRB, atomicity over 20 table changes, end to end). Updated: `tb_mixer_core` (random patch tables every frame through the chain model, port counts ≠ channel counts), `tb_mixer_core_pkg` (new D and lanes, D_MAX, two sizes exactly at 255), `tb_top_windows` (patch windows' ID/CONFIG; **blank slate at reset: every port silent**; identity patched through the windows; the port map; a crossing repatch). `sim.mk` in step (`patch`, `patchregs`).
- **Mutants** (baseline clean first): converters **13/13** killed; integration **13/13** (the latencies, D_MAX, signed readback in the window and the binding, DIR, the reset tables, either patch window wired to the other's block, the port order, the converter sized by channels, a plain converter at the output).

### 5.3 Step 3: the block design (2026-10-08)

- `create_project.tcl`: **`ctrl_smc2`**, a second SmartConnect on `ctrl_smc`'s last master (phase9: M15), same clock and reset. It carries `M_AXI_INPATCH` (0x8000_D000), `M_AXI_OUTPATCH` (0x8000_E000) and, in phase9, **`M_AXI_LINK3STAT` (moved from M15; address and port unchanged)**. `ctrl_smc` keeps 16 masters in phase9 (base + 7 bus-layer/meter windows + formatter #3 + the cascade); the script now fails if the masters used and `NUM_MI` disagree. Patch windows in every PS build. The create log confirms `ctrl_smc2 on ctrl_smc M15` and both windows at their addresses.

### 5.4 Step 4: the server (2026-10-08)

- **`mixer_params`**: `ModuleSpec.option_labels` → `optionLabels` (same length as `options`, checked).
- **`mixer_hw`**: `PatchHW` (`InputPatchHW` / `OutputPatchHW` check DIR; entries unsigned; `set_entries` = one COMMIT, values past the ports → None), windows `inpatch` / `outpatch` (`PATCH`), **`IO_PORTS`** (Analog 1–4, USB 1–8, AVB 1–8), CLI `mixer_hw.py patch` (both tables with labels, read only).
- **`mixer_meters`**: `MeterHub.set_visible(counts)`: blobs carry each zone's first `count` channels.
- **`osc_mixer_server`**:
  - `PatchPart` + `patch_module` (enum 0–20 with labels, default None, group `patch`); `GainBackend` routes `source` / `destination` to the patch window and `level` to the gain window; nothing seeded (CS5).
  - **Move rule**: `destination_holders` (hidden holders included); one `apply_many`, echoed requested first, hidden ones not echoed. A recall resolves destinations in index order (`recall_destinations`).
  - **Counts**: `system/inputCount`, `busCount`, `outputCount` only with the patch (`system_settings`); `apply_topology` (channel zones' `count`, matrices' `set_shape`, model rebuilt, meters trimmed); **hidden channels** keep their values, their hardware gets `HIDE` (source / destination None, bus level off). `set_count`: store, topology, echo, then `/<name>/config/changed` (only if changed). Stored counts apply before the first hardware push, so hidden channels never sound at boot.
  - `apply_set` now resolves under the ordering lock (the model can change); `--no-patch` simulates a pre-Phase-15 bitstream; with `--hw` the patch windows are both-or-neither and must match the level stages and `IO_PORTS`.
- **Tests** (Windows: 188 OK with params, meters, snapshots, state, server): `IOPatch` (blank slate, shared sources, refusals, the move and its echo order to two controllers, never linked, snapshots carry the patch and a recall keeps outputs unique), `ChannelCounts` (echo then `config/changed` to both controllers, the config's shapes, hidden paths refused, unchanged / clamped counts, hidden values kept, a hidden destination taken quietly, groups and snapshots see only shown channels), `ChannelCountsFromState`, `NoPatch`, `PatchInProcess` (the hardware writes: blank push, stored entries, hidden overrides, bus off), `Metering.test_blobs_follow_the_channel_count`; `test_mixer_params` (labels), `test_mixer_meters` (`set_visible`), `test_mixer_hw.Patch` (Linux: header/DIR, unsigned entries, nothing seeded, partial or mismatched windows refused). Config and snapshot shape tests updated (76 parameters on the 4 × 4 × 4 simulator).

## 6. Log

- **2026-10-08:** branch `phase15-sources` from `phase14-vgroups`. Read the plan, `architecture_modules.md`, the standard, `fpgamixer_top`'s map, the BD. Proposal (§3) and decisions CS1–CS13 to the user. Fixed in passing: `architecture_modules.md`'s address map still showed 0x8000_C000 as reserved (it's link #3's status window since Phase 11 H.3) and lacked formatter #3.
- **2026-10-08:** decisions as recommended except CS5 (no default patch: all None); "I/O port" covers analog, USB and AVB. Step 1 done: the standard amended (§5.1); the app's handoff in §7. Next: step 2 (RTL).
- **2026-10-08:** step 2 done (§5.2): the patch converters, the core at D = 251, `patch_regs_axil`, the top (blank slate); 17/17 TBs, mutants 13/13 + 13/13. Next: step 3 (the BD), then the server.

## 7. For the app (controller repo)

The standard's *I/O patch*, *Channel counts* and *Config changed* sections are the spec; this is the checklist. Everything is additive (`schemaVersion` stays 1), and every new item is optional: show it only when the config has it.

**New in the config**

| Where | What | Meaning |
|---|---|---|
| `modules.<any enum>.optionLabels` | list of strings, same length and order as `options` | the label for each option; send and store the **number**, show the label |
| `zones.inputChannel.modules` | `"source"` | `enum`, options 0–20, 0 = None, `group` `"patch"`, not `linked` |
| `zones.outputChannel.modules` | `"destination"` | the same, for outputs |
| `system.inputCount` / `busCount` / `outputCount` | `int`, `min` 1, `max` 20, `default` 20 | the channel counts |
| `zones.*.count`, `rows`, `cols` | — | now the **current** counts (they change at runtime) |

**New messages**

| Message | Direction | What to do |
|---|---|---|
| `/<name>/set/inputChannel/<k>/source <f>` | both | an input channel's source; 0 = None |
| `/<name>/set/outputChannel/<k>/destination <f>` | both | an output channel's destination; 0 = None |
| `/<name>/set/system/inputCount <f>` (and `busCount`, `outputCount`) | both | the counts; set from a setup screen |
| `/<name>/config/changed` (no arguments) | mixer → controller | re-fetch: send `get/system/config`, drop every `set` until the reply arrives, then rebuild the UI from it (the connect ordering again) |

**Behaviour to handle**

1. **Pickers:** a source picker on each input strip, a destination picker on each output strip, filled from `options` + `optionLabels` (None, Analog 1–4, USB 1–8, AVB 1–8 on this mixer; don't hard-code them). Ports are interfaces' channels of every kind: analog, USB and AVB alike.
2. **Moved destinations:** setting a destination that another output channel has makes the mixer send two `set`s: yours first, then `outputChannel/<other>/destination 0`. Treat the second as an ordinary device-originated set (D44's path). The UI may warn before taking one ("USB 3 is used by Output 5"), since it has the values.
3. **Blank slate:** every `source` and `destination` defaults to 0 and is absent from the sparse `values` until patched. A new or upgraded mixer is silent until patched; a "nothing patched" hint on an empty mixer would help.
4. **Counts:** after a count `set` the echo arrives, then `config/changed`; zones, matrices and meters shrink or grow after the refetch. Channels beyond a count are hidden by the mixer (gets and sets of them are refused) and come back with their old values.
5. **Meters:** size each blob by its length, (length − 4) / 2, not by the config's count: right after a count change they can disagree briefly.
6. **Snapshots:** carry `source` / `destination` like any value (a recall repatches); they don't carry the counts.
7. **Older firmware:** no `source` / `destination` / counts in the config → no pickers or count settings; it never sends `config/changed`.
