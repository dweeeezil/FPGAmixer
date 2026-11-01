# Inserts: the controller's spec (2026-10-31)

**Who this is for:** whoever builds inserts into a controller (StudioRunner). It describes everything a controller sends and receives about inserts, and what the mixer guarantees. The normative summary is the *Inserts* section of `FPGA Mixer OSC Standard.md`; this document is the full version, with examples and a checklist.

**Background, not needed to implement:** `insert_architecture_proposal_2026-10-31.md`. DSP processors live in **pools** off to the side of the mixer. A controller **inserts** them on any input channel, bus or output channel, pre-fader, in any order, several of the same kind if wanted. Each pool has a fixed number of **slots** (32 today); a slot is one instance of that processor.

**Reference implementation:** `tools/osc_mixer_server.py` + `tools/mixer_inserts.py` (the simulator behaves exactly like the board). Run it with:

```
python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001
```

Today the only processor type is **`gain`** (a trim in dB). EQ, dynamics etc. will arrive as further types, the same way. A controller written to this spec picks them up without changes, except for any processor-specific UI.

---

## 1. Discovery: what the config says

A mixer with inserts adds four things to the config reply (`/<name>/get/system/config`), all additive (`schemaVersion` stays 1):

```json
{
  "capabilities": ["snapshots", "inserts"],
  "inserts": { "maxPerChannel": 8, "types": ["gain"], "delayFrames": 9 },
  "zones": {
    "inputChannel":  { "count": 20, "modules": ["level", "source", "inserts", "vgroup", "name"] },
    "busChannel":    { "count": 20, "modules": ["level", "inserts", "vgroup", "name"] },
    "outputChannel": { "count": 20, "modules": ["level", "destination", "inserts", "vgroup", "name"] },
    "...":           "...",
    "gain":          { "count": 32, "modules": ["gain_level"], "kind": "pool" }
  },
  "modules": {
    "inserts":    { "type": "string", "default": "", "maxLength": 255, "group": "inserts", "linked": true },
    "gain_level": { "type": "float", "unit": "dB", "min": -90, "max": 6.02, "default": 0,
                    "group": "gain", "linked": true }
  },
  "values": { "busChannel/3/inserts": "gain:5", "gain/5/gain_level": -6.0, "...": "..." }
}
```

| Key | Meaning |
|---|---|
| `capabilities` contains `"inserts"` | the mixer has inserts. Without it, none of the below exists: show no insert UI. |
| `inserts.maxPerChannel` | K: the most inserts one channel may have (8). |
| `inserts.types` | the processor types, in the mixer's order; each one is also a zone. |
| `inserts.delayFrames` | informational: every channel at every insert point is this many samples late, inserted or not (§8). |
| a zone with `"kind": "pool"` | **a processor type's pool.** Its name is the type (`gain`), `count` its slots, `modules` the processor's parameters. Indexed like a channel zone: `<type>/<slot>/<module>`. A controller must accept zones it doesn't know by name when they say `"kind": "pool"` (today it warns "zone ignored"). |
| `inserts` on a channel zone | that zone can take inserts (all three channel zones do). |
| processor modules (`gain_level`, later `eq_*` ...) | ordinary module metadata. `group` names the processor for UI clustering. `default` is the processor's **identity** (it leaves the audio untouched; for `gain_level`, 0 dB). |

**Values in the config (sparse, as always):**
- a channel's `inserts` appears only if it isn't `""`;
- a slot's parameters appear only if the slot is in use and not at their default;
- a free slot's parameters never appear.

## 2. The `inserts` value

A string: the channel's chain **in signal order** (first = nearest the input), entries separated by spaces.

| Entry | Meaning |
|---|---|
| `<type>:<slot>` | that slot, e.g. `gain:5`. Slots are decimal, 0 … count − 1. |
| `<type>` | (only in a `set`) **a new insert** of that type: the mixer picks a free slot. |

- `""` = no inserts.
- The **canonical form**, which every echo, `get`, config value and snapshot carries, is every entry with its slot, one space apart, e.g. `"gain:5 gain:2"`.
- Input may use any run of spaces.
- A type is lower-case letters and digits, starting with a letter. A type name is also its pool zone's name.

## 3. Changing a chain

**A controller sets the whole list it wants.** Keep an insert by naming its slot, add one by naming only its type, remove one by leaving it out, reorder by reordering:

| Before | `set …/inserts` to | After (the echo) | What happened |
|---|---|---|---|
| `""` | `"gain"` | `"gain:0"` | added (slot 0 was free) |
| `"gain:0"` | `"gain gain:0"` | `"gain:1 gain:0"` | added at the front |
| `"gain:1 gain:0"` | `"gain:1 gain:0 gain"` | `"gain:1 gain:0 gain:2"` | added at the end |
| `"gain:1 gain:0 gain:2"` | `"gain:0 gain:1 gain:2"` | same | reordered |
| `"gain:0 gain:1 gain:2"` | `"gain:0 gain:2"` | same | gain:1 removed, its slot free |
| anything | `""` | `""` | all removed |

To add, a controller usually takes the current value, edits it, and sends it, e.g. appends `" gain"`.

**The echo** (to every TCP controller, as for any set) is the canonical list, so every controller learns the slot the mixer picked. **Right after it**, the mixer echoes **every parameter of every newly assigned slot** with its starting value (the processor's identity, or a group's values, §5). So:

```
-> /FOH/set/busChannel/3/inserts "gain:1 gain"
<- /FOH/set/busChannel/3/inserts "gain:1 gain:4"          (every controller)
<- /FOH/set/gain/4/gain_level 0.0                          (every controller)
```

A controller never has to diff lists or guess a new slot's values. Applying echoes as they arrive is enough.

**Atomic:** one set is one edit. It is applied whole, or refused whole with nothing changed (§6).

**A removed slot is free.** Its parameters are gone, and the next time it's assigned it starts at identity. A controller should drop what it holds for a slot once no channel's chain contains it.

Sets of `inserts` work over **UDP** too: applied and echoed to the TCP controllers, never answered, refusals only logged (as every UDP set).

## 4. Processor parameters

Ordinary parameters of the pool zone, `/<name>/set/<type>/<slot>/<module> <value>`:

```
-> /FOH/set/gain/4/gain_level -6.0
<- /FOH/set/gain/4/gain_level -6.0                         (every controller)
```

- Value rules, echo, `get`, snapshots and persistence are as for every module (clamping is not an error, and the echo carries the applied value).
- **A slot no channel holds is refused**, set and get: `/<name>/error gain/9/gain_level "gain:9 isn't inserted on any channel"`.
- Today's type is **`gain`**, with one module **`gain_level`**: a float in dB, −90 (off) to +6.02 (the hardware's ceiling), default 0 (unity, bit-exact identity), linked.

## 5. Virtual groups

Inserts follow virtual groups (the reason groups exist: a stereo pair or a surround set sharing its processing). Grouped channels are still separate audio, so **each member has its own slots**. What links is the chain's **structure** and the processors' **parameters**.

1. **A set of `inserts` on a grouped channel applies to every member** of its group (same zone, same `vgroup` ≠ 0, visible channels only).
   - The requested channel gets the list as given.
   - Every other member gets **the same types in the same order**. Position j keeps the member's own slot when the request kept a slot that was at position p, and the member has the same type at p. Otherwise the member gets a new slot.
   - A member's slots that aren't kept go free.
2. **Afterwards every member's processors equal the requester's**, position by position (new slots and kept ones). This is "the next set of a linked module brings the members together".
3. **A set of a processor parameter** on a slot that a grouped channel holds at position p also goes to the slot at position p of **every other member with the same type there**.
4. **All members or none.** If the group needs more free slots than the pool has, the whole set is refused: `no free gain slot (the group needs 2, 1 free)`.
5. **Echo order:**
   - the requested channel's `inserts` first, then the other members' (index order, only those that changed);
   - then every parameter of every newly assigned slot (requester's slots first, then members');
   - then the kept slots' parameters that changed.
   - For a linked parameter set, the requested one first, then the members' slots in member index order.
6. **Unchanged rules:** joining or leaving a group changes nothing (the next `inserts` set brings the members together); a recall doesn't link; matrices never link.

Example: inputs 0 and 2 in group 1.

```
-> /FOH/set/inputChannel/2/inserts "gain gain"
<- /FOH/set/inputChannel/2/inserts "gain:0 gain:1"
<- /FOH/set/inputChannel/0/inserts "gain:2 gain:3"
<- /FOH/set/gain/0/gain_level 0.0      (then gain/1, gain/2, gain/3: 0.0)
-> /FOH/set/gain/1/gain_level -4.0
<- /FOH/set/gain/1/gain_level -4.0
<- /FOH/set/gain/3/gain_level -4.0     (input 0's slot at the same position)
```

## 6. Errors

Every refusal is the standard error reply to the requester only, `/<name>/error <path> <reason>`, and changes nothing. The reasons (the reference server's wording; a controller should show them, not parse them):

| Case | path | reason |
|---|---|---|
| not a string | `…/inserts` | `expected a string` |
| too long / control characters | `…/inserts` | `at most 255 bytes` / `control characters aren't allowed` |
| malformed entry | `…/inserts` | `'gain:' is not <type> or <type>:<slot>` |
| unknown type | `…/inserts` | `no insert type 'eq' (this mixer has: gain)` |
| slot out of range | `…/inserts` | `gain has slots 0..31, not 32` |
| same slot twice | `…/inserts` | `gain:1 twice` |
| more than K | `…/inserts` | `at most 8 inserts per channel` |
| a slot that isn't this channel's | `…/inserts` | `gain:5 is free, not on this channel` / `gain:5 is on inputChannel/1, not on this channel` |
| **no free slot** | `…/inserts` | `no free gain slot` (grouped: `no free gain slot (the group needs 2, 1 free)`) |
| a free slot's parameter | `gain/9/gain_level` | `gain:9 isn't inserted on any channel` |
| hidden channel / unknown index | as today | as today |

A slot freed by a set can't be reused within that same set. So with every slot in use, replacing one insert by a new one of the same type takes two sets: remove, then add.

## 7. Snapshots and persistence

- The mixer keeps every chain and every in-use slot's parameters across a power cycle.
- **A snapshot holds** every channel's `inserts` (including `""`) and the parameters of the slots in use, never a free slot's. Slot numbers are part of the snapshot, so a recall restores exactly those slots.
- **A recall** (`snapshot/load` or `snapshot/apply`):
  - sets every channel's chain and every slot's parameters, and echoes what changed;
  - doesn't link (as for every recall);
  - parameters for a slot that ends up free are ignored.
- **A recall is refused whole** (`/<name>/error snapshot/apply …`) when the chains can't all hold:
  - an entry without a slot: `inputChannel/0/inserts: a snapshot's inserts must name their slots`;
  - a slot on two channels: `gain:3 is on both inputChannel/0 and busChannel/2`;
  - an unknown type, too many, a malformed value.
- A controller writing its own snapshot files must give every entry its slot, and use each slot once.

## 8. What the audio does (informational)

- **Fixed latency:** every channel passing an insert point is `delayFrames` (9) samples late, whether it has inserts or not. Inserting never changes timing, so grouped or summed channels never comb-filter. Input to output that is 3 × 9 = 27 samples (0.56 ms at 48 kHz) more than a mixer without inserts.
- **Clicks:**
  - adding or removing at the **front** of a chain (or on a channel with none) is bit-exact: no click, and the new processor fades in from identity;
  - any other edit (a reorder, an add or remove in the middle or at the end) briefly **dips that channel**, about 80 ms, while the routing switches;
  - parameter changes are smoothed (about 5 ms).
- None of this changes the protocol. The echo comes at once; the hardware follows within about 0.1 s.

## 9. Channel counts

A channel hidden by `system/inputCount` (etc.) keeps its chain and its slots (as it keeps every value), is silent, and isn't in the config. Its slots stay in use, so they aren't free for others. Groups don't reach hidden channels.

## 10. Controller checklist

1. Read `capabilities`; if it has no `"inserts"`, hide all insert UI.
2. Accept zones with `"kind": "pool"` (as channel-like, indexed by slot), and their values keys (`gain/5/gain_level`).
3. Per channel: show `inserts` (parse §2) as a chain of processors in order. For each entry, its type's pool zone and slot give its parameters: `<type>/<slot>/<module>`, with metadata from `modules`.
4. Add / remove / reorder by sending the whole new list (§3); add with a bare type. Update the UI from the **echo**, not from what was sent (the echo carries the chosen slots).
5. Apply the parameter echoes that follow (§3, §5): a new slot's values, the members' slots.
6. Show error replies (§6), especially `no free <type> slot`.
7. Limit a chain to `inserts.maxPerChannel` entries in the UI; the mixer refuses more anyway.
8. Groups need no special code: the mixer echoes every member's change. Show grouped channels' chains as linked if wanted.
9. Snapshot files: keep the slot numbers as they are (§7).
10. Forget a slot's parameters when no channel's chain lists it.

## 11. Compatibility

- **Older mixers** have no `"inserts"` capability, no pool zones and no `inserts` module. A controller must work without them.
- **Older controllers** on this mixer see a zone they don't know (they warn and ignore it), and an `inserts` string module they show as text. Nothing breaks, but they can't build chains.
- **New processor types** are additive: a new pool zone, its modules, its name in `inserts.types`. A controller shows unknown processor types with generic controls from their metadata.

## 12. A whole session, as messages

```
-> /FOH/get/system/config
<- /FOH/set/system/config "{… "capabilities":["snapshots","inserts"], "inserts":{"maxPerChannel":8,…} …}"

-> /FOH/set/busChannel/0/inserts "gain"                    add a trim to bus 0
<- /FOH/set/busChannel/0/inserts "gain:0"
<- /FOH/set/gain/0/gain_level 0.0

-> /FOH/set/gain/0/gain_level -3.0                         turn it down
<- /FOH/set/gain/0/gain_level -3.0

-> /FOH/set/busChannel/0/inserts "gain gain:0"             a second one in front
<- /FOH/set/busChannel/0/inserts "gain:1 gain:0"
<- /FOH/set/gain/1/gain_level 0.0

-> /FOH/set/busChannel/0/inserts "gain:0 gain:1"           swap them (a ~80 ms dip)
<- /FOH/set/busChannel/0/inserts "gain:0 gain:1"

-> /FOH/set/busChannel/0/inserts "gain:1"                  remove gain:0
<- /FOH/set/busChannel/0/inserts "gain:1"

-> /FOH/set/gain/0/gain_level 1.0                          gain:0 is free now
<- /FOH/error gain/0/gain_level "gain:0 isn't inserted on any channel"
```
