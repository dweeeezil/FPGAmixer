#!/usr/bin/env python3
"""
Inserts (docs/insert_architecture_proposal_2026-10-31.md sec. 12; the
controller's view: docs/inserts_controller_spec_2026-10-31.md): which
processors each channel runs through, in which order, on which pool slots,
and what the insert router's tables must hold for that. Like mixer_params,
it knows nothing about OSC, sockets or hardware: the server asks it to
resolve a set, and it answers with the new chains, the slots to copy, and an
edit PLAN (a list of steps, as data) that the server's worker runs against
the hardware.

TERMS
  pool type   a processor kind, served by one pool of `slots` slots (today
              "gain"); its zone in the OSC model has the same name
  slot        one instance: (type, slot number)
  chain       a channel's inserts in signal order: [(type, slot), ...]
  K           the most inserts on one channel (the router's CONFIG)

THE `inserts` VALUE (a string module on the three channel zones)
  entries separated by spaces; an entry is <type>:<slot> (keep that insert)
  or <type> (a new insert: the mixer picks a free slot). The canonical form,
  which every echo carries, is every entry with its slot, one space apart;
  "" = no inserts. Input may use any run of spaces. Refused (InsertRefused,
  nothing changes): an unknown type, a malformed entry, more than K entries,
  a slot outside the pool, the same slot twice, a slot that isn't this
  channel's, no free slot of a type.

VIRTUAL GROUPS (proposal 12.6): a set on a grouped channel gives every
member the same structure (types in order), each member its own slots;
member position j keeps its slot if the requester's entry j kept its slot
from position p and the member has the same type at p; else a new slot.
Afterwards every member's slot at j takes the requester's parameters at j
(`copies`). All members or none.

TABLES (insert_router_pkg.sv): one 18-bit entry per word,
  [17:16] kind (0 none/dry, 1 zone channel, 2 pool slot), [15:12] sel (zone
  or pool), [11:8] age, [7:0] idx (channel or slot)
  RETURN, one per channel: inputs 0..N_I-1, buses, outputs; then SOURCE,
  pool p slot s at N_I + N_B + N_O + p*S + s. A chain of n: its head reads
  its own channel at age K - n, each next slot the previous one, RETURN =
  the last slot. Free slots: 0 (silence).

EDITS (proposal 4): per channel, old chain -> new chain is
  'none'  : unchanged;
  'exact' : the kept slots are a common SUFFIX of both (only the front
            changed: add, remove or replace there). Bit-exact if the slots
            leaving are faded to identity first and the new ones start at
            identity: no dip;
  'dip'   : anything else (a reorder, a mid-chain add or remove): the
            channel's level stage dips while the tables switch.
"""

import re
from dataclasses import dataclass, field

ZONES = ("inputChannel", "busChannel", "outputChannel")
ZONE_CODE = {"inputChannel": 0, "busChannel": 1, "outputChannel": 2}   # insert_router_pkg ZONE_*
KIND_ZONE, KIND_SLOT = 1, 2
INSERTS_MODULE = "inserts"
INSERTS_MAX_BYTES = 255
_TYPE_NAME = re.compile(r"[a-z][a-z0-9]*\Z")
_ENTRY = re.compile(r"([a-z][a-z0-9]*)(?::([0-9]{1,9}))?\Z")


class InsertRefused(Exception):
    """A set of `inserts` the mixer refuses; the message is the error reply's reason."""


@dataclass(frozen=True)
class PoolType:
    """One processor kind. modules: {name: ModuleSpec} (the zone's modules,
    in order); identity: {module: value} that makes the processor exact
    identity (bit-exact pass-through); index: the router's pool number."""
    name: str
    slots: int
    modules: dict
    identity: dict
    index: int

    def __post_init__(self):
        if not _TYPE_NAME.match(self.name):
            raise ValueError(f"pool type name {self.name!r}")
        if set(self.identity) != set(self.modules):
            raise ValueError(f"{self.name}: identity must name every module")


def entry_zone(zone, ch, age):
    return (KIND_ZONE << 16) | (ZONE_CODE[zone] << 12) | (age << 8) | ch


def entry_slot(pool, slot):
    return (KIND_SLOT << 16) | (pool << 12) | slot


def parse(text, pools, k):
    """The entries of an `inserts` value: [(type, slot or None)], or raise
    InsertRefused. Checks the syntax, the types, the slot range, K and
    duplicates; not ownership (resolve does)."""
    if not isinstance(text, str):
        raise InsertRefused("expected a string")
    entries, seen = [], set()
    for word in text.split():
        m = _ENTRY.match(word)
        if m is None:
            raise InsertRefused(f"{word!r} is not <type> or <type>:<slot>")
        typ, num = m.group(1), m.group(2)
        if typ not in pools:
            raise InsertRefused(f"no insert type {typ!r} (this mixer has: {', '.join(pools)})")
        slot = None
        if num is not None:
            slot = int(num)
            if slot >= pools[typ].slots:
                raise InsertRefused(f"{typ} has slots 0..{pools[typ].slots - 1}, not {slot}")
            if (typ, slot) in seen:
                raise InsertRefused(f"{typ}:{slot} twice")
            seen.add((typ, slot))
        entries.append((typ, slot))
    if len(entries) > k:
        raise InsertRefused(f"at most {k} inserts per channel")
    return entries


def fmt(chain):
    """The canonical `inserts` value of a chain."""
    return " ".join(f"{t}:{s}" for t, s in chain)


def classify(old, new):
    """'none', 'exact' or 'dip' (module docstring, EDITS)."""
    if old == new:
        return "none"
    kept = [x for x in new if x in old]
    n = len(kept)
    suffix_ok = (n == 0 or (old[len(old) - n:] == kept and new[len(new) - n:] == kept))
    return "exact" if suffix_ok else "dip"


@dataclass
class Resolution:
    """What a set of `inserts` becomes, before it is committed.
    chains:  {(zone, ch): new chain} for every member (requester first)
    old:     {(zone, ch): old chain}
    added:   [(type, slot)] newly assigned, in echo order
    freed:   [(type, slot)] going free
    copies:  {(type, slot) target: (type, slot) source}: the target takes the
             source's parameters (a group's members; source = requester's)"""
    chains: dict
    old: dict
    added: list
    freed: list
    copies: dict = field(default_factory=dict)


class Inserts:
    """Every channel's chain and every slot's owner. n: {zone: channels (the
    hardware's)}; pools: {type: PoolType} in router pool order."""

    def __init__(self, k, pools, n):
        self.k = k
        self.pools = dict(pools)
        self.n = dict(n)
        self.chains = {}           # (zone, ch) -> [(type, slot)]
        self.owner = {}            # (type, slot) -> (zone, ch, position)

    # ----- state -----
    def chain(self, zone, ch):
        return list(self.chains.get((zone, int(ch)), []))

    def is_used(self, typ, slot):
        return (typ, int(slot)) in self.owner

    def free_slots(self, typ):
        return [s for s in range(self.pools[typ].slots) if (typ, s) not in self.owner]

    def set_chain(self, zone, ch, chain):
        ch = int(ch)
        for t, s in self.chains.get((zone, ch), []):
            self.owner.pop((t, s), None)
        if chain:
            self.chains[(zone, ch)] = list(chain)
        else:
            self.chains.pop((zone, ch), None)
        for pos, (t, s) in enumerate(chain):
            self.owner[(t, s)] = (zone, ch, pos)

    def load(self, stored):
        """stored: {(zone, ch): `inserts` text} from the state file. Entries
        that can't be honoured (a slot twice across channels, a type this
        mixer lacks, a type without a slot, more than K) are dropped with a
        note; returns (the notes, {(zone, ch): canonical text}) so the store can
        be brought into line."""
        notes, canon = [], {}
        for (zone, ch), text in sorted(stored.items(), key=lambda kv: (ZONES.index(kv[0][0]), kv[0][1])):
            try:
                entries = parse(text, self.pools, self.k)
            except InsertRefused as e:
                notes.append(f"{zone}/{ch}/inserts {text!r} dropped ({e})")
                canon[(zone, ch)] = ""
                continue
            chain = []
            for t, s in entries:
                if s is None or (t, s) in self.owner or (t, s) in chain:
                    notes.append(f"{zone}/{ch}/inserts: {t}:{s} dropped (no slot, or another channel's)")
                    continue
                chain.append((t, s))
            self.set_chain(zone, ch, chain)
            if fmt(chain) != text:
                canon[(zone, ch)] = fmt(chain)
        return notes, canon

    # ----- a set -----
    def resolve(self, zone, ch, text, members):
        """A set of `zone`/`ch`/inserts to `text`, for the group `members`
        (channel numbers, the requester included; [ch] when not grouped).
        Returns a Resolution, or raises InsertRefused. Changes nothing."""
        ch = int(ch)
        members = [int(m) for m in members]
        entries = parse(text, self.pools, self.k)
        old_r = self.chain(zone, ch)
        for t, s in entries:
            if s is not None and (t, s) not in old_r:
                who = self.owner.get((t, s))
                raise InsertRefused(f"{t}:{s} is " + ("free" if who is None else
                                    f"on {who[0]}/{who[1]}") + ", not on this channel")
        free = {t: self.free_slots(t) for t in self.pools}
        chains, old, added, copies = {}, {}, [], {}

        def take(t):
            if not free[t]:
                raise InsertRefused(f"no free {t} slot")
            return (t, free[t].pop(0))

        need = {}
        for m in [ch] + [x for x in members if x != ch]:
            old_m = self.chain(zone, m)
            new_m = []
            for j, (t, s) in enumerate(entries):
                if m == ch:
                    new_m.append((t, s) if s is not None else None)
                    continue
                p = old_r.index((t, s)) if s is not None else -1
                if p >= 0 and p < len(old_m) and old_m[p][0] == t:
                    new_m.append(old_m[p])
                else:
                    new_m.append(None)
            for j, x in enumerate(new_m):
                if x is None:
                    need[entries[j][0]] = need.get(entries[j][0], 0) + 1
            chains[(zone, m)] = new_m
            old[(zone, m)] = old_m
        for t, n in need.items():
            if n > len(free[t]):
                raise InsertRefused(f"no free {t} slot" + (f" (the group needs {n}, {len(free[t])} free)"
                                                            if n > 1 else ""))
        for key in chains:                   # requester first, then members in index order
            chains[key] = [x if x is not None else take(entries[j][0])
                           for j, x in enumerate(chains[key])]
            added += [x for x in chains[key] if x not in old[key]]
        req = chains[(zone, ch)]
        for key, new_m in chains.items():
            if key == (zone, ch):
                continue
            for j, x in enumerate(new_m):
                copies[x] = req[j]
        freed = [x for key in chains for x in old[key] if x not in chains[key]]
        return Resolution(chains, old, added, freed, copies)

    def commit(self, res):
        for (zone, m), chain in res.chains.items():
            self.set_chain(zone, m, chain)

    # ----- the router's tables -----
    def tables(self):
        """{word: entry} for every word of the router's table (insert_router_pkg layout)."""
        base = {}
        off = 0
        for zone in ZONES:
            base[zone] = off
            off += self.n[zone]
        src_base = off
        words = {k: 0 for k in range(src_base + sum(p.slots for p in self.pools.values()))}
        pool_base = {}
        for t, p in self.pools.items():
            pool_base[t] = src_base + p.index * p.slots
        for (zone, ch), chain in self.chains.items():
            if not chain:
                continue
            n = len(chain)
            for j, (t, s) in enumerate(chain):
                if j == 0:
                    words[pool_base[t] + s] = entry_zone(zone, ch, self.k - n)
                else:
                    pt, ps = chain[j - 1]
                    words[pool_base[t] + s] = entry_slot(self.pools[pt].index, ps)
            lt, ls = chain[-1]
            words[base[zone] + ch] = entry_slot(self.pools[lt].index, ls)
        return words

    # ----- the edit plan -----
    def plan(self, res):
        """The steps that take the hardware from res.old to res.chains
        (after commit(res); the tables are the new ones). Steps, in order:
          ("identity", [slots])  the slots go to identity (smoothed)
          ("dip", [(zone, ch)])  those channels' level stages go off
          ("wait_fade",)         until those fades have arrived (and any new
                                 slot freed recently has reached identity)
          ("tables", {word: entry})  one COMMIT
          ("settle",)            until the router has swapped
          ("params", [slots])    the slots get their stored parameters
          ("restore", [(zone, ch)])  the dipped channels get their stored level
          ("freed", [slots])     the freed slots: identity, and the time noted
        """
        dips, fade = [], []
        for key, new in res.chains.items():
            kind = classify(res.old[key], new)
            if kind == "dip":
                dips.append(key)
            elif kind == "exact":
                fade += [x for x in res.old[key] if x not in new]
        steps = []
        if fade:
            steps.append(("identity", fade))
        if dips:
            steps.append(("dip", dips))
        if fade or dips or res.added:
            steps.append(("wait_fade",))
        steps.append(("tables", self.tables()))
        steps.append(("settle",))
        if res.added or res.copies:
            steps.append(("params", list(dict.fromkeys(res.added + list(res.copies)))))
        if dips:
            steps.append(("restore", dips))
        if res.freed:
            steps.append(("freed", list(res.freed)))
        return steps
