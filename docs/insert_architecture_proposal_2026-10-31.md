# Proposal: DSP as inserts from processor pools (2026-10-31)

**Context:** the library foundation's step 4 was to put a parametric EQ on the input channels as a fixed core stage (`library_foundation_proposal_2026-10-10.md` §13). **The user (2026-10-31):** *"DSP modules should exist off to the side, and channels should be routed through them when the controller 'adds' them to a channel."* Every insert pre-fader; any channel, any zone (inputs, buses, outputs); any order the user chooses; several of the same kind on one channel ("if a user wants two EQs, that should be possible"); **32 channels' worth per module type**; and when a type has no free slot, the server answers the controller with an error. This also does LF8 ("describe the chain as sections"), which the user asked to do first.

**State:** Q1–Q4 decided (§10). Step plan (§11) for the user's review. Nothing built. The EQ prototype (4a) is unaffected: the EQ becomes the first pool.

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
