#!/usr/bin/env python3
"""
Tests for mixer_inserts.py: the `inserts` value, allocation, virtual groups,
the router's tables (the same entries tb_insert_router's model expects) and
the edit plans. Standard library only.

    python3 -m unittest -v test_mixer_inserts        (from tools/)
"""

import unittest

import mixer_inserts as mi
from mixer_params import ModuleSpec

LEVEL = ModuleSpec("float", unit="dB", min=-90.0, max=6.0, default=0.0, linked=True)


def pools(slots=4, eq=False):
    p = {"gain": mi.PoolType("gain", slots, {"gain_level": LEVEL}, {"gain_level": 0.0}, 0)}
    if eq:
        p["eq"] = mi.PoolType("eq", slots, {"eq_gain": LEVEL}, {"eq_gain": 0.0}, 1)
    return p


def ins(k=3, slots=4, eq=False, n=4):
    return mi.Inserts(k, pools(slots, eq), {z: n for z in mi.ZONES})


def setc(x, zone, ch, text, members=None):
    res = x.resolve(zone, ch, text, members or [ch])
    x.commit(res)
    return res


class Parse(unittest.TestCase):
    def test_forms_and_canonical(self):
        p = pools(eq=True)
        self.assertEqual(mi.parse("  gain   eq:2 gain:0 ", p, 3), [("gain", None), ("eq", 2), ("gain", 0)])
        self.assertEqual(mi.parse("", p, 3), [])
        self.assertEqual(mi.fmt([("gain", 1), ("eq", 0)]), "gain:1 eq:0")
        self.assertEqual(mi.fmt([]), "")

    def test_refusals(self):
        p = pools()
        for text, reason in (("dyn", "no insert type 'dyn'"), ("gain:", "is not"), ("Gain", "is not"),
                             ("gain:x", "is not"), ("gain:4", "slots 0..3"), ("gain:1 gain:1", "twice"),
                             ("gain gain gain gain", "at most 3"), ("gain;1", "is not")):
            with self.assertRaises(mi.InsertRefused) as cm:
                mi.parse(text, p, 3)
            self.assertIn(reason, str(cm.exception), text)
        with self.assertRaises(mi.InsertRefused):
            mi.parse(5.0, p, 3)


class Allocate(unittest.TestCase):
    def test_new_slots_lowest_first_and_kept_ones_stay(self):
        x = ins()
        self.assertEqual(setc(x, "busChannel", 2, "gain gain").chains[("busChannel", 2)],
                         [("gain", 0), ("gain", 1)])
        res = setc(x, "busChannel", 2, "gain gain:1 gain:0")
        self.assertEqual(res.chains[("busChannel", 2)], [("gain", 2), ("gain", 1), ("gain", 0)])
        self.assertEqual(res.added, [("gain", 2)])
        self.assertEqual(x.owner[("gain", 0)], ("busChannel", 2, 2))

    def test_removed_slots_go_free(self):
        x = ins()
        setc(x, "inputChannel", 0, "gain gain")
        res = setc(x, "inputChannel", 0, "gain:1")
        self.assertEqual(res.freed, [("gain", 0)])
        self.assertFalse(x.is_used("gain", 0))
        self.assertEqual(x.free_slots("gain"), [0, 2, 3])

    def test_a_slot_that_isnt_this_channels(self):
        x = ins()
        setc(x, "inputChannel", 0, "gain")
        for text, reason in (("gain:0", "on inputChannel/0"), ("gain:3", "free")):
            with self.assertRaises(mi.InsertRefused) as cm:
                x.resolve("inputChannel", 1, text, [1])
            self.assertIn(reason, str(cm.exception))

    def test_every_slot_then_no_free_slot_and_nothing_changed(self):
        x = ins(k=3, slots=4)
        setc(x, "inputChannel", 0, "gain gain gain")
        setc(x, "busChannel", 0, "gain")
        before = dict(x.chains)
        with self.assertRaises(mi.InsertRefused) as cm:
            x.resolve("outputChannel", 1, "gain", [1])
        self.assertEqual(str(cm.exception), "no free gain slot")
        self.assertEqual(x.chains, before)

    def test_a_freed_slot_isnt_reused_in_the_same_edit(self):
        x = ins(k=3, slots=2)
        setc(x, "inputChannel", 0, "gain gain")
        with self.assertRaises(mi.InsertRefused):        # gain:0 leaving can't be the new one
            x.resolve("inputChannel", 0, "gain gain:1", [0])
        res = setc(x, "inputChannel", 0, "gain:1")
        self.assertEqual(res.freed, [("gain", 0)])


class Groups(unittest.TestCase):
    def test_members_get_the_structure_with_their_own_slots(self):
        x = ins(k=3, slots=8, eq=True)
        res = setc(x, "inputChannel", 0, "gain eq", members=[0, 1])
        self.assertEqual(res.chains[("inputChannel", 0)], [("gain", 0), ("eq", 0)])
        self.assertEqual(res.chains[("inputChannel", 1)], [("gain", 1), ("eq", 1)])
        self.assertEqual(res.added, [("gain", 0), ("eq", 0), ("gain", 1), ("eq", 1)])
        self.assertEqual(res.copies, {("gain", 1): ("gain", 0), ("eq", 1): ("eq", 0)})

    def test_kept_positions_keep_the_members_slots(self):
        x = ins(k=3, slots=8, eq=True)
        setc(x, "inputChannel", 0, "gain eq", members=[0, 1])
        res = setc(x, "inputChannel", 1, "eq:1 gain gain:1", members=[0, 1])   # reorder + add, from member 1
        self.assertEqual(res.chains[("inputChannel", 1)], [("eq", 1), ("gain", 2), ("gain", 1)])
        self.assertEqual(res.chains[("inputChannel", 0)], [("eq", 0), ("gain", 3), ("gain", 0)])
        self.assertEqual(res.copies, {("eq", 0): ("eq", 1), ("gain", 3): ("gain", 2), ("gain", 0): ("gain", 1)})

    def test_a_member_out_of_step_gets_new_slots_where_types_differ(self):
        x = ins(k=3, slots=8, eq=True)
        setc(x, "inputChannel", 0, "gain")
        setc(x, "inputChannel", 1, "eq")                  # not grouped yet: different chains
        res = setc(x, "inputChannel", 0, "gain:0 gain", members=[0, 1])
        self.assertEqual(res.chains[("inputChannel", 1)], [("gain", 2), ("gain", 3)])
        self.assertIn(("eq", 0), res.freed)

    def test_all_members_or_none(self):
        x = ins(k=3, slots=3)
        setc(x, "busChannel", 3, "gain gain")
        before = dict(x.chains)
        with self.assertRaises(mi.InsertRefused) as cm:
            x.resolve("inputChannel", 0, "gain", [0, 1])
        self.assertEqual(str(cm.exception), "no free gain slot (the group needs 2, 1 free)")
        self.assertEqual(x.chains, before)


class Tables(unittest.TestCase):
    """The words tb_insert_router's model reads: heads at age K - n, each next
    slot the previous, RETURN the last; pool p slot s at 3N + p*S + s."""

    def test_chains_to_words(self):
        x = ins(k=3, slots=4, eq=True, n=4)
        setc(x, "busChannel", 2, "gain eq gain")          # gain:0 -> eq:0 -> gain:1
        setc(x, "outputChannel", 0, "eq")                 # eq:1
        w = x.tables()
        self.assertEqual(len(w), 3 * 4 + 2 * 4)
        src = 12
        self.assertEqual(w[src + 0], mi.entry_zone("busChannel", 2, 0))       # head: age K - 3
        self.assertEqual(w[src + 4 + 0], mi.entry_slot(0, 0))                  # eq:0 <- gain:0
        self.assertEqual(w[src + 1], mi.entry_slot(1, 0))                      # gain:1 <- eq:0
        self.assertEqual(w[4 + 2], mi.entry_slot(0, 1))                        # bus 2 returns gain:1
        self.assertEqual(w[src + 4 + 1], mi.entry_zone("outputChannel", 0, 2)) # age K - 1
        self.assertEqual(w[8 + 0], mi.entry_slot(1, 1))
        self.assertEqual(sum(1 for v in w.values() if v), 6)                   # the rest: dry / silent

    def test_entry_format(self):
        self.assertEqual(mi.entry_zone("busChannel", 10, 7), 0x1_1_7_0A)       # kind 1, zone 1, age 7, ch 10
        self.assertEqual(mi.entry_slot(0, 3), 0x2_0_0_03)


class Plans(unittest.TestCase):
    def kinds(self, plan):
        return [s[0] for s in plan]

    def test_classify(self):
        A, B, C = ("gain", 0), ("gain", 1), ("gain", 2)
        for old, new, want in (([], [A], "exact"), ([A], [B, A], "exact"), ([B, A], [A], "exact"),
                               ([A], [], "exact"), ([A, B], [C, B], "exact"), ([A], [A], "none"),
                               ([A, B], [B, A], "dip"), ([A, B], [A], "dip"), ([A], [A, B], "dip"),
                               ([A, B], [A, C, B], "dip")):
            self.assertEqual(mi.classify(old, new), want, (old, new))

    def test_front_add_has_no_dip(self):
        x = ins()
        setc(x, "inputChannel", 0, "gain")
        plan = x.plan(setc(x, "inputChannel", 0, "gain gain:0"))
        self.assertEqual(self.kinds(plan), ["wait_fade", "tables", "settle", "params"])
        self.assertEqual(plan[3][1], [("gain", 1)])

    def test_front_remove_fades_the_slot_first(self):
        x = ins()
        setc(x, "inputChannel", 0, "gain gain")
        plan = x.plan(setc(x, "inputChannel", 0, "gain:1"))
        self.assertEqual(self.kinds(plan), ["identity", "wait_fade", "tables", "settle", "freed"])
        self.assertEqual(plan[0][1], [("gain", 0)])

    def test_reorder_dips_and_restores(self):
        x = ins()
        setc(x, "busChannel", 1, "gain gain")
        plan = x.plan(setc(x, "busChannel", 1, "gain:1 gain:0"))
        self.assertEqual(self.kinds(plan), ["dip", "wait_fade", "tables", "settle", "restore"])
        self.assertEqual(plan[0][1], [("busChannel", 1)])

    def test_the_tables_are_the_new_ones(self):
        x = ins()
        res = setc(x, "inputChannel", 3, "gain")
        tables = next(s[1] for s in x.plan(res) if s[0] == "tables")
        self.assertEqual(tables, x.tables())
        self.assertEqual(tables[3], mi.entry_slot(0, 0))


class Load(unittest.TestCase):
    def test_bad_entries_dropped_with_notes(self):
        x = ins(k=2)
        notes, canon = x.load({("inputChannel", 0): "gain:1  gain:0", ("busChannel", 0): "gain:1",
                               ("outputChannel", 0): "dyn:0", ("outputChannel", 1): "gain"})
        self.assertEqual(x.chain("inputChannel", 0), [("gain", 1), ("gain", 0)])
        self.assertEqual(x.chain("busChannel", 0), [])                 # gain:1 is input 0's
        self.assertEqual(canon[("inputChannel", 0)], "gain:1 gain:0")  # canonical spacing
        self.assertEqual(canon[("busChannel", 0)], "")
        self.assertEqual(canon[("outputChannel", 0)], "")
        self.assertEqual(canon[("outputChannel", 1)], "")              # no slot named
        self.assertEqual(len(notes), 3)


if __name__ == "__main__":
    unittest.main()
