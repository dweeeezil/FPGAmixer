# Proposal: DSP as inserts from processor pools (2026-10-31)

**Context:** the library foundation's step 4 was to put a parametric EQ on the input channels as a fixed core stage (`library_foundation_proposal_2026-10-10.md` §13). **The user (2026-10-31):** *"DSP modules should exist off to the side, and channels should be routed through them when the controller 'adds' them to a channel."* Every insert pre-fader; any channel, any zone (inputs, buses, outputs); any order the user chooses; several of the same kind on one channel ("if a user wants two EQs, that should be possible"); **32 channels' worth per module type**; and when a type has no free slot, the server answers the controller with an error. This also does LF8 ("describe the chain as sections"), which the user asked to do first.

**State:** proposal, for the user's review. Nothing built. The EQ prototype (4a) is unaffected: the EQ becomes the first pool.

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
