# Phase 15 status: 2026-10-08 — channel sources (I/O patch, runtime channel counts)

**Branch:** `phase15-sources` (from `phase14-vgroups`, which holds snapshots, groups and the unshipped channel names; not yet merged to `main`).
**Plan:** `docs/plans/plan_channel_sources_2026-10-06.md` (written before Phase 11 and the rest of Phase 14; the corrections are in `docs/prompt_channel_sources_2026-10-08.md` and folded in below).
**State:** proposal; decisions CS1–CS13 to the user.

---

## 1. The request

> "Having Analog, USB, and AVB is great, but I rarely need all at once, and finding the right channel is a pain. I'd like to be able to configure the mixer to N×Y×Z channels, with each channel being generic. I'd like to then be able to assign input channel sources and output channel destinations in the UI. For example, I could go in and assign inputs 1–5 to AVB 4–9, and then set output channels 1–3 to USB 1–3." (user, 2026-10-06)

## 2. Today

- **Core channel k is physical port k**, both ways (`fpgamixer_top`: `core_in = {link2_rx, link_rx, link3_rx[0:3]}`):

  | Physical port | Front door | Label (proposed, CS4) |
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
physical in (20) ─► input patch ─► input channels (N) ─► levels ─► input matrix ─► buses (Y) ─► levels
                    ch k ← source[k]                                                              │
physical out (20) ◄─ output patch ◄─ output channels (Z) ◄─ levels ◄─ bus matrix ◄──────────────────┘
                    port ← the channel whose destination it is
```

- **Input patch:** each input channel picks **one physical input or None** (silence). Any number of channels may pick the same input (the same mic on two channels with different processing).
- **Output patch:** each output channel picks **one physical output or None**. A physical output belongs to at most one output channel; picking one that another channel holds **takes it** (the other channel becomes None and is echoed, CS2). One mix to several places is what the bus matrix is for (a bus to two output channels, each with its own destination), so the patch stays a plain one-to-one selector.
- **The default patch is identity** (input k ← port k, output k → port k), so every saved state, snapshot and crosspoint keeps its meaning and the mixer sounds exactly as today until someone repatches.

### 3.2 Gateware (CS1, CS10, CS11)

Two new generic **core-boundary blocks** replace the two converters inside `mixer_core` (the converters stay, for `matrix_packed_sim` and the matrix TBs):

- **`pcm_patch2stream`** (packed P_IN → stream N_IN): captures the physical frame on the strobe like `pcm_pack2stream`, then per beat k reads `source[k]` through a coefficient read port and emits that port's sample (0 = None → silence). +1 cycle against `pcm_pack2stream` (the read port's latency; a read before the strobe would see the previous frame's table).
- **`pcm_stream2patch`** (stream N_OUT → packed P_OUT): per beat c reads `destination[c]` through a read port and writes the sample to that physical output's slot; the slots are cleared at the strobe, so a port no channel picks is silent. All ports move to the packed output together, +1 cycle against `pcm_stream2pack`.
- **Tables:** register value = OSC value: 0 = None, p + 1 = physical port p. Each a `coef_bank_ram` (ROW_LEN 1, W = 5 bits for 20 ports), so a repatch lands whole on one frame strobe like every other coefficient change (§3 of `architecture_modules.md`). Two drivers on one port (only reachable by bypassing the server) resolve deterministically: the later channel wins.
- **`mixer_core`** gains `P_IN` / `P_OUT` (physical ports) and two read ports (`in_patch_*`, `out_patch_*`); its packed sides become physical. It still knows nothing about what the ports are; `fpgamixer_top` keeps the port map and the reset tables (identity).
- **Latency:** D = 249 + 2 = **251**. D_MAX is re-derived as **255**: since the Pmods went, the only consumers of the core's output are the three `pcm_link`s, which take it at the next strobe (cycle 256). To be confirmed against `pcm_link`'s capture in step 2 and checked at elaboration; the lane chooser keeps 4 + 4 (one lane fewer costs about two matrix passes, far over 255).
- **Windows:** a binding `patch_regs_axil` (ID `0x5054_5001`, "PT"; CONFIG = rows, ports, direction (0 in, 1 out), entry width) over `axil_coef_window` + `coef_bank_ram`, two instances: **input patch at 0x8000_D000, output patch at 0x8000_E000**.
- **SmartConnect (the main BD question):** a **second SmartConnect `ctrl_smc2` cascaded from the first's M15**; link #3's status window moves onto it (its address 0x8000_C000 and its port name stay, so no RTL or software changes), and the two patch windows join it. That leaves 13 free masters for Phase 7's DSP windows, which would hit the same wall. Nothing else moves; still no PS8 setting changes. To check in the build: sdtgen still emits a device-tree node per window behind the cascade (the server's `WindowAbsent` guard depends on it).

### 3.3 Runtime channel counts: N × Y × Z (CS6, CS7)

- The gateware stays built at **20 × 20 × 20** (the maximum). Three **`system` settings**: `inputCount`, `busCount`, `outputCount` (`int`, 1–20, default 20), stored like any setting.
- The config advertises only the first N / Y / Z: `inputChannel.count` = N, `inputMatrix` N × Y, `busChannel` Y, `busMatrix` Y × Z, `outputChannel` Z; meter blobs carry N / Y / Z peaks. A set or get beyond a count is refused (index out of range), as today past 20.
- **Hidden channels keep their stored values** (not deleted, not in the config, not in snapshots) and are **silenced in hardware**: a hidden input's patch is None, a hidden output's destination is None, a hidden bus's level is off. Nothing can reach a visible output through a hidden channel, and raising a count brings the channels back exactly as they were. (A hidden output's stored destination can still be taken by a visible channel; it then becomes None in storage.)
- No rebuild for a count change; it's a server operation (rebuild the model, push the hardware overrides, broadcast, §3.5).

### 3.4 Protocol (amend the standard first)

- **`source`** on `inputChannel`, **`destination`** on `outputChannel`: `enum`, `options` [0, 1, …, 20], **`optionLabels`** ["None", "Analog 1", …, "Analog 4", "USB 1", …, "USB 8", "AVB 1", …, "AVB 8"], metadata `group` `"patch"`, never `linked`. The module `default` is 0 (None); the identity patch is seeded into the state on first start (like the identity crosspoints today), so `values` lists every channel's source and destination.
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

- `mixer_hw`: `PatchHW` (window, ID and CONFIG checked, the table as OSC values), the windows `inpatch` / `outpatch`, and **`PHYSICAL_PORTS`**: the platform's port list with labels, an explicit copy of `fpgamixer_top`'s map like `WINDOWS` (checked against the windows' CONFIG port count at startup).
- The channel zones gain modules served by a second window (`source` → input patch, `level` → input levels), so the channel backends delegate per module instead of assuming one window per zone; `vgroup` and `name` stay stored-only.
- The counts: the model is rebuilt from them; a topology step pushes the hidden-channel overrides (§3.3) through `apply_many`; `MeterHub` slices to the counts.
- An older bitstream without the patch windows: no `source` / `destination`, no count settings; everything else as today.

## 4. Decisions (recommended first)

| # | Question | Recommended | Alternative |
|---|---|---|---|
| CS1 | Where the patch lives | in the PL at the core boundary: `pcm_patch2stream` / `pcm_stream2patch`, tables in `coef_bank_ram`, repatch on a frame strobe (§3.2) | in the Linux bridges (can't move a channel between links; no AVB → MOTU without another copy and latency) |
| CS2 | Output semantics | each **output channel** picks one destination or None; picking a taken one **takes it** (the other becomes None, echoed); one-to-many through the bus matrix | refuse a taken destination (clear it first); or per-physical-output pickers (a new zone the standard doesn't have) |
| CS3 | Input semantics | each input channel picks one source or None; sources may be shared | exclusive sources |
| CS4 | Port labels | **Analog 1–4, USB 1–8, AVB 1–8** (enum 0 = None, 1–20 in port order); "Analog" because the host port's interface can change | "MOTU 1–2" with link #3's unused ports 2–3 not offered |
| CS5 | Default patch | identity (input k ← port k, output k → port k), seeded on first start | all None |
| CS6 | N × Y × Z | runtime `system` settings `inputCount` / `busCount` / `outputCount`, 1–20; gateware stays 20 × 20 × 20 | sizes at build time (a rebuild per change); or a bigger maximum now (28 × 28 × 28 fits the frame on 10 + 10 lanes) |
| CS7 | Hidden channels | values kept, out of the config, silenced in hardware; they come back unchanged | reset to defaults when hidden |
| CS8 | Topology change | broadcast `/<name>/config/changed`; controllers refetch with the connect ordering (§3.5) | drop every TCP connection so controllers reconnect |
| CS9 | Recall safe | none yet: a recall sets the patch like everything else; counts aren't in snapshots (§3.6) | a `system` "patch recall safe" switch now; or counts inside snapshots (a recall could change the topology) |
| CS10 | Register windows | a second SmartConnect cascaded from M15, link #3's status window moved onto it (same address), patch windows at 0x8000_D000 / 0x8000_E000 (§3.2) | fold the tables into an existing window (breaks one window per block); or an RTL AXI-Lite splitter (a new block to verify, for what SmartConnect does) |
| CS11 | Latency | +2 cycles (D = 251), D_MAX re-derived to 255 | look-ahead reads to keep D = 249 (cleverer, more to verify) |
| CS12 | Enum labels | optional `optionLabels` beside `options` (additive) | labels in the app only |
| CS13 | Names | ship with this image (no separate one), as planned | — |

## 5. Steps (once decided)

1. **Standard:** `source` / `destination`, `optionLabels`, the counts, `config/changed` (+ the *Command kinds* row), the taken-destination echo, the change log. User review; the app is built from it.
2. **RTL:** `pcm_patch2stream`, `pcm_stream2patch` (TBs bit-exact against a model at random tables and random audio, None = silence, identity = the old converters, timing to the cycle with `pcm_stream_monitor`); `mixer_core` with P_IN / P_OUT and the two read ports (`tb_mixer_core` at random patches; D = 251 checked); D_MAX re-derived; `patch_regs_axil` (+ its TB); `fpgamixer_top` (reset tables, windows, `tb_top_windows` reaching both); `xsim_regress.ps1` and `sim.mk` in step. **Mutation-tested**, baseline first.
3. **BD:** `ctrl_smc2`, link #3's window moved, the two patch ports; `architecture_modules.md` address map and block table in the same change.
4. **Server:** `PatchHW`, `PHYSICAL_PORTS`, per-module delegation on the channel backends, `optionLabels`, the take rule, counts + hidden-channel overrides + `config/changed`, meters sliced; tests (assignments, the take echo, counts in and out with values kept, hidden channels silent in `InProcess`, snapshots carrying the patch, recall resolving duplicates, the older-bitstream fallback). Mutation-tested. Any new Python module into the `fpgamixer-osc` recipe's file list.
5. **Build:** bitstream, sdtgen, `gen-machine-conf`, image (names included). Checks: windows in the device tree, D in the build log.
6. **Bench (user, by ear in the app):** the user's example — inputs 1–5 ← AVB, outputs 1–3 → USB 1–3 — then counts down and back up.
7. **App (user):** pickers with the labels, the count settings, the refetch on `config/changed`.

## 6. Log

- **2026-10-08:** branch `phase15-sources` from `phase14-vgroups`. Read the plan, `architecture_modules.md`, the standard, `fpgamixer_top`'s map, the BD. Proposal (§3) and decisions CS1–CS13 to the user. Fixed in passing: `architecture_modules.md`'s address map still showed 0x8000_C000 as reserved (it's link #3's status window since Phase 11 H.3) and lacked formatter #3.
