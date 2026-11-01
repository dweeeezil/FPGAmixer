# Proposal: DSP as inserts from processor pools (2026-10-31)

**Context:** the library foundation's step 4 was to put a parametric EQ on the input channels as a fixed core stage (`library_foundation_proposal_2026-10-10.md` §13). **The user (2026-10-31):** *"DSP modules should exist off to the side, and channels should be routed through them when the controller 'adds' them to a channel."* Every insert pre-fader; any channel, any zone (inputs, buses, outputs); any order the user chooses; several of the same kind on one channel ("if a user wants two EQs, that should be possible"); **32 channels' worth per module type**; and when a type has no free slot, the server answers the controller with an error. This also does LF8 ("describe the chain as sections"), which the user asked to do first.

**State:** Q1–Q4 decided (§10). Step plan §11 decided and **built in simulation, Vivado-checked (§11.6)**; not flashed. Next: the server (§7). The EQ prototype (4a) is unaffected: the EQ becomes the first pool.

---

## 1. The picture

```
            input patch        input matrix           bus matrix
 I/O ports ─────────────► [I] ── levels ── matrix ── [B] ── levels ── matrix ── [O] ── levels ── output patch ─► I/O ports
                           ▲│                          ▲│                         ▲│
                    return ││ send              return ││ send             return ││ send
                           │▼                          │▼                         │▼
                ┌──────────┴┴──────────────────────────┴┴─────────────────────────┴┴──────────┐
                │  insert router: each pool slot's SOURCE, each channel's RETURN (tables)     │
                ├──────────────────┬──────────────────┬──────────────────┬───────────────────┤
                │ EQ pool          │ dynamics pool    │ delay pool       │ ... (later types) │
                │ 32 slots         │ 32 slots         │ 32 slots         │                   │
                └──────────────────┴──────────────────┴──────────────────┴───────────────────┘
```

- **Insert points [I], [B], [O]**: one per zone, **pre-fader**: on the input channels after the input patch (before the input levels), on the buses after the input matrix (before the bus levels), on the outputs after the bus matrix (before the output levels).
- **Pools:** one per module type (EQ first; dynamics, delay, ... later). A pool is one library block, time-shared over its **32 slots**, each slot one channel's worth of that processor with its own coefficients. Pools belong to no zone.
- **The router** is tables, like the I/O patch (Phase 15). The hardware never changes when you insert something; only table entries do.

## 2. How a channel goes through its inserts

The controller gives a channel an **ordered list** of inserts, e.g. bus 3: *EQ → compressor → EQ*. The server turns it into router entries:

- it picks a free slot of each type (here EQ slot 5, dynamics slot 2, EQ slot 9);
- **each slot's SOURCE** says where its input comes from: a zone channel at an insert point, or **another slot's output**. EQ 5 ← bus 3, dynamics 2 ← EQ 5, EQ 9 ← dynamics 2;
- **the channel's RETURN** names the slot that ends its chain (EQ 9), or "dry" when it has no inserts.

A chain is a linked list through the pools, so **any order and any number of the same type** come for free: a second EQ is just another EQ slot.

**One frame per hop.** A pool works through its 32 slots once per frame, from inputs it took the frame before (each pool's outputs are double-buffered by frame; the insert points' sends are frame taps, the mechanism LF7 already planned for sidechains). So a slot can take its input from **any** other slot, in any order, without the pools having to run in a particular sequence. That is what makes arbitrary order possible: each hop costs exactly one frame (20.8 µs).

## 3. Latency: fixed, whatever is inserted

**If an inserted channel came back later than its dry neighbours, summing them (on a bus) would comb-filter.** So every channel passing an insert point is delayed by the **same** fixed amount, inserted or not:

- **K = the most inserts one channel may have** (a build parameter).
- **Each insert point delays every channel of its zone by exactly K frames.** Each insert point keeps a **history buffer**: the last K frames of every channel of its zone. A dry channel returns its sample from K frames ago; a channel with *n* inserts feeds its chain from the sample K − n frames ago, and *n* hops later it returns exactly K frames late too. (The history buffer is also the send's frame tap.)
- So the timing of a channel **never depends on what is inserted**, and nothing is ever misaligned.
- **Every router table is a double bank with COMMIT** (the coefficient banks' mechanism), so a channel's whole chain changes in one frame, never half.

| K | per insert point | through all three (inputs → bus → output) |
|---|---|---|
| 4 | 83 µs | 0.25 ms |
| 8 | 167 µs | 0.50 ms |

For scale: today's USB round trip is 61 ms, AVB's 48 ms; the core itself is 251 cycles (20 µs). See Q1.

## 4. Adding and removing without clicks

Switching a channel's return from dry to a processor would jump, since the processed signal differs. The plan uses what steps 1–2 built instead of new hardware:

- **Every module type has an exact identity setting** (the EQ flat: output bit-identical to input; a compressor at ratio 1, threshold at the top; a delay at 0). Required of every pool block, and tested.
- **Insert:** the server sets the slot to identity, routes it in (seamless: identity is bit-exact and the timing is the same), then sets the user's parameters, which the smoother fades in.
- **Remove:** fade to identity, then route it out.
- A module whose parameters can't fade (LF4's crossfade case) crossfades inside its block instead; the routing step stays seamless either way.

**One case can't be bit-exact: a change that moves an existing processor in time.** The chain is read from the history buffer at K − n frames, so the processors *before* an added or removed insert see their input move by one frame: a one-sample skip or repeat. (The processor itself doesn't care which age it reads; what moves is the stream it is fed.)

| Edit | What the user hears |
|---|---|
| add or remove at the **front** of a chain (or on a dry channel) | nothing: bit-exact |
| add, remove or **reorder** anywhere else | a one-sample slip in that channel |

A one-sample slip is a small click on bright material. **The server covers it:** for those edits it dips that channel's level stage (always right after the insert point), switches, and brings it back. With the smoother at K = 8 that is a dip of roughly 30 ms on that one channel. See Q4.

## 5. What it costs

- **Per pool:** the block (the EQ for 32 slots × 4 bands: roughly 10–16 DSPs, to be measured by the 4a prototype), its coefficient bank (+ smoother) for 32 slots, a double-buffered output (32 samples × 2: LUT-RAM).
- **Router:** the source table (32 entries per pool: a slot's output, or a zone channel at an age), the return table (one per channel per zone: 60).
- **History buffers:** 60 channels × (K + 1) frames × 24 bits (K = 8: ~13 kbit; one BRAM, or LUT-RAM).
- **One register window per pool** (block-design change: the second SmartConnect has 13 masters free) and **one for the router**.
- The ZU3EG has 360 DSPs and 216 BRAM tiles; the design uses 11 and 7.5 today. Several pools fit comfortably.

## 6. The core as sections (LF8, done with this)

`mixer_core` stops hard-coding seven stages. It is described as **sections**, each a list of stages with their streams, swap pulses and read strobes:

| Section | Stages |
|---|---|
| inputs | input patch → **insert point [I]** → input levels |
| buses | input matrix → **insert point [B]** → bus levels |
| outputs | bus matrix → **insert point [O]** → output levels → output patch |

The package computes the chain's latency and `chain_fits` from the sections (each insert point adds K frames plus its own cycles), and the platform wires each stage's coefficient port by the same description. A later section (the spatial processor, HD7) is added the same way.

## 7. The server

- **Slot allocation per type:** a free list of 32 slots. When a type has none free, **the insert is refused with an error to the controller** (the standard's error reply), and nothing changes.
- **Per-channel insert lists**, ordered, stored with the mix and with snapshots (a recall rebuilds the router tables and the slots' coefficients).
- **The OSC side** (how a controller adds, removes and reorders inserts, and addresses an inserted module's parameters) is a protocol design of its own, to be written with the server step. The app follows, as the user said.

## 8. Order of work

1. **This proposal**, decided (Q1–Q4 below).
2. **4a, the EQ prototype** (Python): structure, number formats, identity, smoothing. Unchanged by this; can run in parallel.
3. **LF8 + the insert machinery in simulation, with a trivial pool first:** a "gain" pool (the template block) proves the router, the hops, the alignment and the identity-switch without the EQ's complexity. Every existing TB stays green (with no inserts the mix is bit-identical, only K frames later per insert point).
4. **The EQ block** (4b) as the first real pool.
5. **The server** (allocation, lists, the error, persistence) and the OSC design.
6. Bitstream, image, bench.

## 9. Questions for the user

- **Q1, K (most inserts on one channel):** **8** (0.5 ms through all three insert points; the app's strip shows up to 8 slots) or **4** (0.25 ms). Recommended: **8**. It's a build parameter, so it can change later, but changing it changes the latency.
- **Q2, the insert latency everywhere:** with K fixed, every channel carries the K frames even when nothing is inserted anywhere. The alternative is per-zone K (e.g. fewer on outputs) at the cost of a less uniform rule. Recommended: **the same K at all three insert points**, simple and predictable.
- **Q3, the first pool to build the machinery with:** a trivial **gain pool** (the template block) first, then the EQ. Recommended. The alternative is building the routing directly around the EQ, which is fewer steps but debugs two new things at once.
- **Q4, edits that move a processor in time (§4):** the server dips that channel for about 30 ms while it switches. Recommended. The alternative is to accept the one-sample click. A seamless version (running the old and new chains side by side and crossfading) would need twice the slots during an edit, so it isn't proposed.

## 10. Decisions (the user, 2026-10-31)

| | Decision |
|---|---|
| Q1 | **K = 8** inserts per channel at most |
| Q2 | **The same K at all three insert points** |
| Q3 | **A gain pool first** to prove the machinery, then the EQ |
| Q4 | **Mid-chain edits dip the channel** (~30 ms) while the server switches |

## 11. Step plan: the core as sections, the router, a gain pool (2026-10-31, for the user's review)

Simulation first, like steps 1–3. No server change: with every return "dry" (the reset state) the mix is bit-identical to today's, only later.

### 11.1 The pieces

| Piece | Where | What it is |
|---|---|---|
| **insert ports on the core** | `mixer_core.sv` | Each zone's stream leaves the core at its insert point (**send**) and comes back (**return**) a stated INS_LAT cycles later (about 3). The core doesn't know what's out there. A plain loop-back (`pcm_insert_loop`) closes the ports in builds and TBs without a router. |
| **sections (LF8)** | `mixer_core_pkg.sv` | The chain arithmetic grouped as the three sections of §6, each section's stages and latency listed once; the insert stages are part of it. `chain_latency` and `chain_fits` are built from the sections. |
| **the router** | `insert_router.sv` + `insert_router_pkg.sv` (FPGAmixer: mixer architecture, not a DSP block) | The three history buffers, each pool's input stream (slot 0..31, one per cycle, from each slot's SOURCE), each pool's output buffer (double, by frame), and the three returns. Parameters: K, the slots per pool (32), the number of pools. |
| **router registers** | `insert_router_regs_axil.sv` | One window for **every** table (all SOURCE entries, all RETURN entries), shadow + active, **one COMMIT**, swapping at the strobe: a whole edit lands in one frame. Read-only words state K, the slots, the pools and each pool's type ID, so the server learns the hardware instead of hard-coding it. |
| **the gain pool** | `fpgamixer_top.sv` | The library's template block at N = 32, as it is: its bank (+ smoother) and its register window. Its identity (gain 1.0) is bit-exact. No new block RTL. |

A pool is an ordinary library block: it gets a stream of 32 channels (its slots) once per frame and returns one. So any block written to the stream contract can become a pool. **The one new rule for a pool block:** it must finish its 32 slots within one frame (the router checks this at elaboration from the block's `occupancy`).

### 11.2 Timing, exactly

The pools run once per frame, right after the strobe. Each run reads the zones' **previous** frame and the pools' **previous** run, so the order of the pools and zones never matters. Two hand-offs, zone → pool and pool → zone, make the round trip one frame longer than the hops alone. So **each insert point delays its zone by K + 1 = 9 frames** (dry: the history at age 9; a chain of n: its head reads age K − n). Through all three insert points that is **0.56 ms**, not the 0.5 ms §3 estimated. See Q1.

Inside the frame, the core's stream timing grows only by 3 × INS_LAT cycles (the K + 1 frames are in the content, not in the stream). At 20/20/20 that takes D from 251 to about 260, past one frame, so the latency-first lane chooser will likely spend **one more DSP** (4 + 5) to keep D within a frame. The package will state the exact number.

The router refuses to elaborate if a zone's stream could still be running when the pools read it (true for chains that span frames, LF1). Today's 20/20/20 core fits. Spanning chains with inserts come later, if ever needed.

### 11.3 Tests

- **`tb_insert_router`** (new): two gain pools, random chains of up to K slots per channel on all three zones, in any order, repeating types, pool-to-pool hops both ways, all 32 slots of a pool used. A model computes every channel's expected sample, frame by frame, with saturation at every hop. Edits checked:
  - front adds and removes: **bit-exact**;
  - mid-chain edits: exactly the predicted one-sample slip, nothing else;
  - a whole multi-entry edit changes in one frame (the COMMIT).
- **`tb_mixer_core`**: the same 9 configurations with the loop-back; expectations unchanged except D.
- **`tb_mixer_core_pkg`**: the new D's and lane picks, and the sections' arithmetic.
- **`tb_top_windows`**: the router's and the gain pool's windows; settle times grow by 3 × 9 frames.
- **Mutants** for the router (wrong age, a hop from the current run instead of the previous, a skipped COMMIT, a missed slot, a return off by one channel), as in steps 1–3.
- The whole regression (FPGAmixer 17 + new, the library's 3).

### 11.4 After this step

The block design gets two windows (router, gain pool) on the second SmartConnect. Then the server step (§7) can drive real inserts. The EQ (4a prototype, 4b block) becomes the second pool.

### 11.5 Questions for the user

- **Q1, 9 frames per insert point (0.56 ms total), not 8:** keep **K = 8** and accept the extra frame, or take **K = 7** to keep 0.5 ms. Recommended: **K = 8 at 0.56 ms**; the difference is 62 µs against USB's 61 ms.
- **Q2, the router outside the core:** the core only exports a send/return port per zone, and the router and pools sit in the platform layer. Recommended (the core stays generic, `modularity-first`). The alternative, the router inside `mixer_core`, saves the ports but makes the core know about pools.
- **Q3, one router window, one COMMIT:** recommended, so a multi-step edit never shows half-done. The alternative is a window per table, which is smaller but needs ordering rules in the server.
- **Q4, at the end of this step:** a Vivado synthesis + timing check (as for step 3; no image, nothing to flash) — recommended — or go straight on to the EQ and check both together.

**Decided (the user, 2026-10-31):** Q1 K = 8 (9 frames per insert point, 0.56 ms); Q2 the router outside the core; Q3 one router window, one COMMIT; Q4 a Vivado synthesis + timing check at the end of the step.

### 11.6 Built (2026-10-31, simulation + Vivado check; not flashed, no image)

**What was built, as planned, plus one library change:**
- `mixer_core`: three insert port pairs, its check of the return timing (`err_o`); `mixer_core_pkg`: `INS_LAT` = 3 and the sections (`ins_*_send_last`, `sec_*_last`); `pcm_insert_loop`.
- `insert_router` + `insert_router_pkg` + `insert_router_regs_axil`; in `fpgamixer_top` the router, the gain pool (`lib_template` at 32 slots, its window, a `coef_smooth`), and in the block design `M_AXI_INSERT` 0x8000_F000 and `M_AXI_GPOOL` 0x8001_0000 on `ctrl_smc2` (M02, M03; link #3's status moves to M04, same address). Builds without the PS: tables all 0 (no inserts), the pool at identity.
- **Library (`HDL-DSP-Library` 1ea7926, local):** `coef_bank_ram` gets `PORTS` read ports on one handshake. Found while planning the router: separate banks with one COMMIT could swap a frame apart (each synchronizer resolves on its own), which would break "an edit lands whole". Default 1, so every other user is unchanged.

**Numbers:** 20/20/20 now 4 + 5 lanes, D = 241 (+1 DSP, as predicted). Every channel 9 frames late at every insert point (0.56 ms in total).

**Checked:**
- FPGAmixer regression **18 / 18** (the 17, plus `router`); the library's **3 / 3** (`coefram` with a 3-port case: every port must see the same bank in every frame).
- `tb_insert_router`, both sizes (5/4/3, K 3, 6 slots; 20/20/20, K 8, 32 slots; two pools each), against an exact model: front add and front remove **bit-exact on every channel**; mid-chain add **only that channel changes, in 2 frames**, then bit-exact again.
- `tb_top_windows`: the two new windows (ID, CONFIG), and real inserts through them: input 9 at 0.5, bus 10 at 0.25, a chain of two on input 11, output 12, all exact.
- **Mutants:**
  - router 13 / 13. The first run left two alive, age K and kind 3 read as a zone: a TB gap (random unused slots rarely drew them). Fixed probe sources on the reserved slots now cover both.
  - core/top 4 / 4 (`lf8_core_top.json`).
  - library bank ports 4 / 4 (`coef_bank_ports.json`).
  - Two kills are weak: the loop-back timing mutant by a TB timeout (not proven to be the core's `err_o` check), the bank's wrong-lane mutant at elaboration.
- **Vivado (`lf8chk`):** WNS 4.403 ns, 0 critical warnings, methodology PASS. Against `lf3chk`:

| | lf3chk | lf8chk | |
|---|---|---|---|
| logic LUTs | 21,643 | 22,377 | +734 |
| LUT-RAM | 3,424 | 3,690 | +266 |
| registers | 37,284 | 38,267 | +983 |
| BRAM tiles | 7.5 | 13.5 | +6 (the history copies, the 4-port table bank, the pool's bank) |
| DSPs | 11 | 13 | +2 (one matrix lane, the gain pool) |

**Not done:**
- the server (allocation, the no-free-slot error, persistence) and the OSC design (§7);
- an image and the bench;
- pushing (the library first: FPGAmixer's submodule points at the library's local commit).

## 12. Step plan: the server (2026-10-31, for the user's review)

What the server must do (§7, the user's answers): give each insert a free slot of its type, refuse with an error when there is none, keep every channel's ordered list, change the hardware without clicks (§4), and keep it all across a power cycle and in snapshots. The FPGA side is done (§11.6); this step is Python only, in `tools/`, plus an amendment to the OSC standard.

### 12.1 The OSC side (proposal)

The standard already has everything a processor's *parameters* need: zones with indices, modules with metadata (`type`, `min`, `max`, `default`, `group`), set/get/echo, config, snapshots, error replies. What's new is only **which processors a channel has, in which order**. The proposal adds two things and no new command kinds:

**1. A zone per processor type, indexed by slot.** Each pool is a zone with `count` = its slots, its modules being the processor's parameters:

```
"zones": { ..., "gain": { "count": 32, "modules": ["level"] } }        // later: "eq": { "count": 32, "modules": ["eq_band1_freq", ...] }
/<name>/set/gain/5/level -6.0        // slot 5 of the gain pool
```

Every existing rule then applies unchanged: clamping, echo to every controller, config values (sparse: the default is the processor's identity), snapshots, persistence.

**2. A channel module `inserts`, a string: the chain in signal order.** Each entry is `<type>:<slot>`, space-separated:

```
/<name>/get/busChannel/3/inserts          -> "eq:5 gain:2 eq:9"
```

A controller **changes the chain by setting the whole list**. An entry with a slot keeps that insert, and one with only a type is a new insert:

| set `busChannel/3/inserts` to | means |
|---|---|
| `"eq:5 gain:2 eq:9 eq"` | add an EQ at the end (the server picks a free slot) |
| `"eq gain:2"` from `"gain:2"` | add an EQ at the front |
| `"eq:9 eq:5 gain:2"` | reorder |
| `"eq:5 eq:9"` | remove gain:2 (its slot goes free, back to identity) |
| `""` | remove all |

The echo, to every controller, is the canonical list with every slot filled in (`"eq:5 gain:2 eq:9 eq:14"`), so every controller learns the new slot the same way. **Refused with an error reply, nothing changed:**
- no free slot of a type: `/<name>/error busChannel/3/inserts "no free eq slot"` (the user's requirement);
- more than K = 8 entries;
- an unknown type;
- a slot that isn't this channel's (another channel's, or free);
- the same slot twice.

A set of a slot's parameters while it is free is refused too (Q3).

Why a whole-list set rather than new `insert` / `remove` / `move` commands:
- it rides on the existing set path (TCP and UDP, echo, groups, the state file, snapshots, recall) with no new message kind;
- any edit is one message, so it is atomic.

The price: the value is a small string grammar, defined in the standard.

### 12.2 The server's pieces

| Piece | Where | What |
|---|---|---|
| hardware | `tools/mixer_hw.py` | `InsertRouterHW` (0x8000_F000: CONFIG → K, S, NP; entries; COMMIT) and `GainPoolHW` (0x8001_0000: one gain per slot), in `WINDOWS`, checked by ID and found through the device tree like every window; a CLI `inserts` that prints the tables |
| the insert logic | `tools/mixer_inserts.py` (new; no OSC, no hardware, like `mixer_params`) | the pools' free lists; parsing and formatting `inserts`; the chain → table entries (RETURN, SOURCE, heads at age K − n, the format of `insert_router_pkg`); and the **edit plan**: the ordered steps of a change (below), as data, so it is tested without hardware |
| the server | `tools/osc_mixer_server.py` | a backend per pool (its zone, its modules; the gain pool's `level`); the `inserts` module on the three channel zones; the executor that runs an edit plan; at startup, rebuilding the tables and slot parameters from the state file; recall |
| the simulator | the same code, `hw` None | as for every backend: the same rules, no window |

**An edit, step by step:**
1. **Front add or remove, or a dry channel's first insert:**
   - set the new slot to identity and route it in (bit-exact, §4); for a remove, fade the slot to identity first;
   - then set the slot's parameters, which the smoother fades in.
2. **Mid-chain add or remove, and reorders:**
   - dip the channel's level stage (the one after its insert point; the hardware only, the stored level unchanged);
   - switch in one COMMIT;
   - restore the level from the state, so a level set during the dip still lands.
3. **Freed slots** go back to identity and to silence.

The waits (about 30 ms) run without holding the registry lock, so other controllers are not held up. Each channel's edits run in order.

**Recall and startup:**
- the slots are part of the stored values (`inserts`, `gain/5/level`), so a recall restores exactly those slots;
- all routing goes in one COMMIT. A recall changes the mix anyway, so it is not made seamless.

### 12.3 Tests

- `test_mixer_inserts.py`:
  - parse and format;
  - every refusal;
  - allocation, including all 32 slots used and the 33rd refused;
  - the tables against hand-worked chains, with the same entries as `tb_insert_router`'s model;
  - each edit kind's plan: front edits without a dip, mid-chain edits with one.
- `test_osc_mixer_server.py`:
  - over TCP: add, remove and reorder, with the echo to every controller and the config;
  - the no-free-slot error to the requester only;
  - pool parameter sets refused on a free slot;
  - the state file across a restart;
  - snapshot save and recall;
  - UDP (applied, never answered).
- `test_mixer_hw.py`: the two windows on a fake `/dev/mem`, as the others.
- The standard: an amendment (*Inserts*), additive, `schemaVersion` stays 1.

### 12.4 Then: the bench (Q4)

An image with `lf8` and this server. It inherits `lf2`'s untested steps (§11.2 of the library proposal: the core spans frames, smoothing). It is lean, per the bench rule:

1. **Null test (USB, as T3) with nothing inserted:** exact. The latency should be **27 samples more** than on p15e (3 × 9 frames), the one number that proves the router is in the path.
2. **The same with a gain insert at 0 dB on that channel:** still exact (identity is bit-exact).
3. **By ear:** that insert at −12 dB, then removed: a drop and back, no click on the front edit.

### 12.5 Questions for the user

- **Q1, the OSC design:** the whole-list `inserts` string with a zone per pool (12.1; recommended). The alternative is new command kinds (`insert`, `remove`, `move`), each one edit, with replies of their own.
- **Q2, the gain pool:** expose it as a real insert type, `gain`, a trim with a `level` in dB. Recommended: it proves the whole path on the bench before the EQ exists, and it is a useful processor anyway. The alternative is to keep it hidden as a test fixture.
- **Q3, a free slot's parameters:** refuse a set on a slot that is not inserted (recommended; nothing is stored for a processor nobody uses), or accept and store it.
- **Q4, after this step:** build the image and bench it (12.4; recommended, since the router and lf2's changes would then be checked on the board before the EQ adds more), or go straight on to the EQ.
- **Not asked, deferred:** whether inserts follow virtual groups (a stereo pair sharing one EQ setting). Today `inserts` won't be linked; it can be added later without breaking anything.

**Decided (the user, 2026-10-31):**
- Q1: the whole list (*"easier to implement given the json config structuring"*);
- Q2: yes, `gain` is a real insert type;
- Q3: yes, a free slot's parameters are refused;
- Q4: bench first.

Not deferred after all. **Inserts follow virtual groups** (*"That's actually the driving reason behind virtual groups"*). Defined as follows (12.6), and the user asked for a full write-up of the protocol for the controller (`docs/inserts_controller_spec_2026-10-31.md`).

### 12.6 Inserts and virtual groups

Grouped channels are separate audio, so each member has **its own slots**. What links is the chain's *structure* and the processors' *parameters*:

1. **A set of `inserts` on a grouped channel applies to every member** (same zone, same `vgroup`).
   - The requester's chain is as given.
   - Each other member gets the same types in the same order. Member position j keeps its own slot if the requester's entry j kept the slot at position p, and the member has the same type at position p. Otherwise it gets a new slot.
   - A member's slots that aren't kept go free.
2. **Afterwards every member's processors equal the requester's**, position by position. A member's new slots take the requester's parameters at that position, and its kept slots are brought to them too ("the next set of a linked module brings the members together").
3. **A set of a processor's parameter** (pool modules are `linked`) on a slot owned by a grouped channel at position p applies to the slot at position p of every member that has the same type there.
4. **All or nothing.** If the group needs more free slots of a type than there are, the set is refused (`no free <type> slot`) and nothing changes. A slot freed by an edit is never reused within that same edit, since it isn't at identity yet.
5. **Echo order:**
   - the requested channel's `inserts` first, then the other members' in index order;
   - then every parameter of each newly assigned slot, so a controller never has to diff lists;
   - then the changed parameters of kept slots.
6. **Unchanged rules:** joining or leaving a group changes nothing; recall doesn't link; matrices never link.

### 12.7 Built (2026-10-31, server; not on the board)

**What was built:**
- `tools/mixer_inserts.py` (new): parse/format; allocation (lowest free slot first, never a slot freed by the same edit); groups (12.6); the router's tables; edit plans.
- `tools/mixer_hw.py`: `InsertRouterHW`, `GainPoolHW`, `WINDOWS` `insert` / `gainpool`, `POOLS` (the router's pool order), CLI `inserts`.
- `tools/mixer_params.py`: the zone kind `pool` (`"kind": "pool"` in the config).
- `tools/osc_mixer_server.py`: `PoolBackend`, the `inserts` module, `set_inserts`, linked pool parameters, refusals of free slots, `InsertWorker` (outside the lock), startup (`seed_inserts`, the tables pushed), snapshots (chains checked before a recall, free slots never in a snapshot), the config's `inserts` object and capability, `--no-inserts`.
- **Module name:** the gain pool's parameter is `gain_level`, not `level`: module metadata is global, and `level` defaults to off where a processor's default must be its identity.

**Edit timing:** `FADE_S` = 80 ms before a dip's switch, or before a front remove (the smoother is exact after about 70 ms at K = 8). A level set on a dipped channel waits in the store, and the restore applies it. A parameter set on a slot not yet switched in reaches the hardware only after the switch.

**Checked:**
- Python 283 tests on Linux (the build VM): `test_mixer_inserts` 19, `test_osc_mixer_server` with 15 insert tests (TCP end to end, groups, refusals, UDP, snapshots, state across a restart, the worker's step order on fake hardware), `test_mixer_hw` `InsertWindows` 3.
- On Windows the same minus the mmap tests; the old `MediaClock*` tests error there on `os.O_SYNC` (pre-existing, Linux-only).
- **Mutants `lf8_server.json` 15 / 15.** The first run left one alive: a group member's new slot copying the requester's values. A real test gap, closed by `test_a_member_out_of_step_takes_the_requesters_parameters`.

**Docs:**
- the standard's *Inserts* section and change log;
- **`docs/inserts_controller_spec_2026-10-31.md`**: the full spec for the controller, with discovery, the value, edits, parameters, groups, every error string, snapshots, audio behaviour, a checklist and a message session.

**Next: the bench (12.4)**, an image with `lf8` and this server.
