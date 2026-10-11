#!/usr/bin/env python3
"""
Tests for osc_stress.py: the protected-set rules on a hand-made config, and a
short stress run against the real server (simulated backends, 4 x 4 x 4,
the hardware's 20 I/O ports): nothing protected changes, nothing is refused,
the mix is as it was afterwards, and the check really sees a protected change.

    python3 -m unittest -v test_osc_stress        (from tools/)
"""

import json
import random
import unittest

import osc_stress as st
from test_osc_mixer_server import ServerCase


def config(n=4, values=None):
    labels = ["None"] + [f"Analog {i}" for i in range(1, 5)] + [f"USB {i}" for i in range(1, 9)]
    ch = {"count": n, "modules": ["level", "vgroup", "name"]}
    return {"zones": {"inputChannel": dict(ch, modules=["level", "source", "vgroup", "name"]),
                      "inputMatrix": {"rows": n, "cols": n, "modules": ["level"]},
                      "busChannel": ch, "busMatrix": {"rows": n, "cols": n, "modules": ["level"]},
                      "outputChannel": dict(ch, modules=["level", "destination", "vgroup", "name"])},
            "modules": {"level": {"type": "float", "default": -90.0},
                        "vgroup": {"type": "int", "default": 0.0},
                        "name": {"type": "string", "default": ""},
                        "source": {"type": "enum", "default": 0.0, "optionLabels": labels},
                        "destination": {"type": "enum", "default": 0.0, "optionLabels": labels}},
            "system": {}, "values": dict(values or {})}


class ProtectedSets(unittest.TestCase):

    def test_closure_over_feeds_groups_and_analog_outputs(self):
        v = {"outputChannel/2/destination": 1.0,          # Analog 1: a speaker
             "busMatrix/1_2/level": 0.0,                   # bus 1 feeds it
             "inputMatrix/3_1/level": -6.0,                # input 3 feeds bus 1
             "inputChannel/0/vgroup": 5.0, "inputChannel/3/vgroup": 5.0,   # 0 grouped with 3
             "outputChannel/1/destination": 6.0}           # USB 2: not protected
        m = st.Mixer(config(values=v))
        prot = st.protected_sets(m, None, allow_analog=False)
        self.assertEqual(prot, {"inputChannel": {0, 3}, "busChannel": {1}, "outputChannel": {2}})
        self.assertEqual(st.protected_sets(m, None, allow_analog=True),
                         {"inputChannel": set(), "busChannel": set(), "outputChannel": set()})
        prot = st.protected_sets(m, (2, 3, 0), allow_analog=True)                  # a null path
        self.assertEqual(prot, {"inputChannel": {2}, "busChannel": {3}, "outputChannel": {0}})
        paths = st.protected_paths(m, prot)
        self.assertIn("inputMatrix/0_3/level", paths)       # anything into the protected bus
        self.assertIn("busMatrix/1_0/level", paths)         # anything into the protected output
        self.assertIn("outputChannel/0/destination", paths)
        self.assertNotIn("outputChannel/0/name", paths)     # names never reach the audio


class StressRun(ServerCase):
    """A null path in -> bus -> out 1, a 'speaker' on output 3 (Analog 1),
    input 4 grouped with the speaker's input 3."""

    def setUp(self):
        super().setUp()
        c = self.tcp()
        for addr, v in (("/mixer/set/inputChannel/0/source", 13.0),        # AVB 1
                        ("/mixer/set/outputChannel/0/destination", 13.0),
                        ("/mixer/set/outputChannel/2/destination", 1.0),   # Analog 1
                        ("/mixer/set/inputChannel/2/vgroup", 7.0),
                        ("/mixer/set/inputChannel/3/vgroup", 7.0)):
            self.roundtrip(c, addr, v)
        self.c = c

    def config(self, link):
        link.send_message("/mixer/get/system/config")
        while True:
            m = link.read_message()
            if m.address.endswith("/set/system/config"):
                return json.loads(m.args[0])

    def test_a_short_run_changes_nothing_protected_and_restores_the_mix(self):
        before = self.config(self.c)
        self.c.close()          # an idle controller that doesn't read is dropped (5 s), by design
        link = self.tcp()
        logged = []
        s = st.Stress(link, random.Random(3), (0, 0, 0), log=logged.append)
        self.assertEqual(s.prot, {"inputChannel": {0, 2, 3}, "busChannel": {0, 2},
                                  "outputChannel": {0, 2}})
        ok, bad = s.run(6.0, rate=2000, batch=25, report=1.5, every=(1.0, 1.7, 2.3))
        self.assertTrue(ok, "\n".join(logged))
        self.assertEqual(bad, [])
        self.assertEqual(s.refusals, [])
        self.assertGreater(s.stats["sets"], 500)
        self.assertGreaterEqual(s.stats["recalls"], 2)
        self.assertGreaterEqual(s.stats["count changes"], 1)
        self.assertGreaterEqual(s.stats["saves"], 1)
        after = self.config(self.tcp())
        self.assertEqual(after["zones"], before["zones"])        # counts back
        self.assertEqual(after["values"], before["values"])      # the mix as it was

    def test_never_an_analog_destination_unless_allowed(self):
        """Speaker safety: no draw ever patches an output to an Analog port,
        or to a port a protected output holds."""
        link = self.tcp()
        for allow, expect_analog in ((False, False), (True, True)):
            s = st.Stress(link, random.Random(5), (0, 0, 0), allow_analog=allow, log=lambda m: None)
            dests = [v for p, v in (s.random_change() for _ in range(4000)) if p.endswith("/destination")]
            labels = {s.m.ports[int(v)] for v in dests}
            self.assertEqual(any(l.startswith("Analog") for l in labels), expect_analog, labels)
            self.assertNotIn("AVB 1", labels)                       # held by the protected output 1
            if not allow:                                           # protected outputs: only names change
                touched = {p for p, _v in (s.random_change() for _ in range(2000))
                           if p.startswith(("outputChannel/0/", "outputChannel/2/"))}
                self.assertTrue(all(p.endswith("/name") for p in touched), touched)

    def test_count_changes_never_hide_a_protected_channel(self):
        s = st.Stress(self.tcp(), random.Random(11), (0, 0, 0), log=lambda m: None)
        s.begin()
        for _ in range(20):
            s.change_count()
        self.assertEqual(s.stats["count changes"], 20)
        self.assertEqual(s.check(), [])                    # includes any count that hid one
        s.finish()

    def test_the_check_sees_a_protected_change(self):
        s = st.Stress(self.tcp(), random.Random(1), (0, 0, 0), log=lambda m: None)
        self.assertEqual(s.check(), [])
        self.roundtrip(self.c, "/mixer/set/busMatrix/3_0/level", -6.0)  # into the protected output
        self.assertEqual(s.check(), [("busMatrix/3_0/level", -90.0, -6.0)])


if __name__ == "__main__":
    unittest.main()
