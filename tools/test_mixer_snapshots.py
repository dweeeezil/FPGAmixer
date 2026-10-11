#!/usr/bin/env python3
"""
Tests for mixer_snapshots.py: the name rules, the format's envelope check and
the store (files, limits, crash safety). Standard library only.

    python3 -m unittest -v test_mixer_snapshots        (from tools/)
"""

import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

import mixer_snapshots as ms


def doc(name, values=None, **extra):
    return ms.make_snapshot(name, values or {"inputChannel/0/level": -6.0}, {}, "mixer", "test",
                            saved_at="2026-10-08T12:00:00Z", **extra)


class Names(unittest.TestCase):
    def test_accepted(self):
        for name in ("Song A", "Mix #2 é", "a", "x" * 63, "v1.2 (rough)"):
            self.assertIsNone(ms.name_problem(name), name)

    def test_refused(self):
        for name in ("", " a", "a ", ".hidden", "a/b", "a\\b", "a\nb", "a\x7fb", "x" * 64,
                     "é" * 32, None, 5):
            self.assertIsNotNone(ms.name_problem(name), repr(name))


class Parse(unittest.TestCase):
    def test_well_formed(self):
        d, why = ms.parse(ms.encode(doc("A")))
        self.assertIsNone(why)
        self.assertEqual(d["values"], {"inputChannel/0/level": -6.0})

    def test_unknown_keys_and_string_values_are_fine(self):
        d, why = ms.parse(json.dumps({"snapshotVersion": 1, "future": [1],
                                      "values": {"inputChannel/0/name": "Kick"}}))
        self.assertIsNone(why)

    def test_refused(self):
        bad = ["not json", "[1, 2]", json.dumps({"values": {}}),
               json.dumps({"snapshotVersion": True, "values": {}}),
               json.dumps({"snapshotVersion": "1", "values": {}}),
               json.dumps({"snapshotVersion": 2, "values": {}}),
               json.dumps({"snapshotVersion": 0, "values": {}}),
               json.dumps({"snapshotVersion": 1}),
               json.dumps({"snapshotVersion": 1, "values": []}),
               json.dumps({"snapshotVersion": 1, "values": {"a/0/level": [1]}}),
               json.dumps({"snapshotVersion": 1, "values": {"a/0/level": None}}),
               '{"snapshotVersion": 1, "values": {"a/0/level": NaN}}',
               json.dumps({"snapshotVersion": 1, "values": {}, "pad": "x" * ms.MAX_BYTES}),
               None]
        for text in bad:
            d, why = ms.parse(text)
            self.assertIsNone(d, text if text is None else text[:60])
            self.assertTrue(why)

    def test_make_snapshot_marks_auto_only_when_asked(self):
        self.assertNotIn("auto", doc("A"))
        self.assertIs(doc("A", auto=True)["auto"], True)


class Store(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="snaps-")
        self.logs = []
        self.addCleanup(shutil.rmtree, self.dir, True)

    def store(self, **kw):
        return ms.SnapshotStore(self.dir, log=self.logs.append, **kw)

    def test_write_read_list_delete(self):
        s = self.store()
        s.write(doc("B"))
        s.write(doc("A", auto=True))
        self.assertEqual(s.list(), [{"name": "A", "savedAt": "2026-10-08T12:00:00Z", "auto": True},
                                    {"name": "B", "savedAt": "2026-10-08T12:00:00Z"}])
        self.assertEqual(json.loads(s.read("B"))["name"], "B")
        s.delete("A")
        self.assertEqual([e["name"] for e in s.list()], ["B"])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "A.json")))
        with self.assertRaises(KeyError):
            s.read("A")
        with self.assertRaises(KeyError):
            s.delete("A")

    def test_survives_reopen_and_names_with_odd_characters(self):
        s = self.store()
        for name in ("Song A", "Mix #2 é", "50% wet"):
            s.write(doc(name))
        s2 = self.store()
        self.assertEqual([e["name"] for e in s2.list()], ["50% wet", "Mix #2 é", "Song A"])
        self.assertEqual(json.loads(s2.read("Mix #2 é"))["name"], "Mix #2 é")

    def test_replace_keeps_one_entry(self):
        s = self.store()
        s.write(doc("A", {"inputChannel/0/level": -1.0}))
        s.write(doc("A", {"inputChannel/0/level": -2.0}))
        self.assertEqual(len(s.list()), 1)
        self.assertEqual(json.loads(s.read("A"))["values"]["inputChannel/0/level"], -2.0)
        self.assertEqual(len(os.listdir(self.dir)), 1)

    def test_limits(self):
        s = self.store(max_snapshots=2)
        s.write(doc("A"))
        s.write(doc("B"))
        with self.assertRaises(ms.SnapshotRefused):
            s.write(doc("C"))
        s.write(doc("B"))                    # replacing at the limit is fine
        with self.assertRaises(ms.SnapshotRefused):
            s.write(doc("D", {"x": "y" * ms.MAX_BYTES}))
        with self.assertRaises(ms.SnapshotRefused):
            s.write(doc("bad/name"))
        self.assertEqual([e["name"] for e in s.list()], ["A", "B"])

    def test_a_failed_write_leaves_the_old_file(self):
        s = self.store()
        s.write(doc("A", {"inputChannel/0/level": -1.0}))
        with mock.patch("mixer_snapshots.os.replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                s.write(doc("A", {"inputChannel/0/level": -2.0}))
        self.assertEqual(json.loads(s.read("A"))["values"]["inputChannel/0/level"], -1.0)
        s2 = self.store()                    # the leftover .tmp is cleaned up, A is intact
        self.assertEqual(json.loads(s2.read("A"))["values"]["inputChannel/0/level"], -1.0)
        self.assertEqual(sorted(os.listdir(self.dir)), ["A.json"])

    def test_bad_files_are_skipped_not_deleted(self):
        with open(os.path.join(self.dir, "junk.json"), "w") as f:
            f.write("{not json")
        with open(os.path.join(self.dir, "wrong.json"), "w") as f:
            f.write(ms.encode(doc("right")))          # name doesn't match the file
        with open(os.path.join(self.dir, "notes.txt"), "w") as f:
            f.write("ignored")
        s = self.store()
        self.assertEqual(s.list(), [])
        self.assertEqual(len(self.logs), 2)
        self.assertEqual(sorted(os.listdir(self.dir)), ["junk.json", "notes.txt", "wrong.json"])

    def test_in_memory(self):
        s = ms.SnapshotStore(None)
        s.write(doc("A"))
        self.assertEqual(json.loads(s.read("A"))["name"], "A")
        s.delete("A")
        self.assertEqual(s.list(), [])


if __name__ == "__main__":
    unittest.main()
