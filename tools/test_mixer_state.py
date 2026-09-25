#!/usr/bin/env python3
"""
Unit tests for mixer_state.py: the tree rules and every durability promise
in its docstring. Standard library only.

    python3 -m unittest -v test_mixer_state        (from tools/)

The last test starts the real OSC server as a subprocess and stops it with
SIGTERM, so it runs on Linux/macOS only (skipped on Windows).
"""

import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

import mixer_state
from mixer_state import MixerState

HERE = os.path.dirname(os.path.abspath(__file__))


def quiet(_msg):
    pass


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="mixstate-")
        self.path = os.path.join(self.dir, "mixer_state.json")
        self.logs = []

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def store(self, **kw):
        kw.setdefault("log", self.logs.append)
        kw.setdefault("save_delay", 0.05)
        return MixerState("mixer", self.path, **kw)

    def read(self, path=None):
        with open(path or self.path) as f:
            return json.load(f)

    def write(self, obj, path=None):
        with open(path or self.path, "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))


class TreeRules(Base):
    def test_roundtrip_and_shape(self):
        s = self.store()
        s.set("inputChannel/0/level", -6.0)
        s.set("inputMatrix/0_1/delay", 2.39)
        s.set("system/deviceName/", "FOH")
        self.assertTrue(s.close())
        self.assertEqual(self.read(), {
            "inputChannel": {"0": {"level": -6.0}},
            "inputMatrix": {"0_1": {"delay": 2.39}},
            "system": {"deviceName": "FOH"},
        })
        s2 = self.store()
        self.assertEqual(s2.get("inputChannel/0/level"), -6.0)
        self.assertEqual(s2.mixer_name, "FOH")
        s2.close()

    def test_conflicts_and_bad_paths_refused(self):
        s = self.store()
        s.set("inputChannel/0/level", -6.0)
        self.assertIsNotNone(s.set("inputChannel/0", 1.0))
        self.assertIsNotNone(s.set("inputChannel/0/level/x", 1.0))
        self.assertIsNotNone(s.set("a//b", 1.0))
        self.assertEqual(s.get("inputChannel/0"), 0.0)   # branch -> default
        s.close()

    def test_nonfinite_never_written(self):
        self.write('{"inputChannel": {"0": {"level": NaN}, "1": {"level": -Infinity}}}')
        s = self.store()
        self.assertEqual(s.get("inputChannel/0/level"), -99.9)
        s.set("x/0/level", 1.0)
        s.close()
        with open(self.path) as f:
            text = f.read()
        self.assertNotIn("NaN", text)
        self.assertNotIn("Infinity", text)

    def test_flat_format_converted(self):
        self.write({"mixer_name": "a", "values": {"inputChannel/0/level": -12.0, "test": 1.0}})
        s = self.store()
        s.close()
        self.assertEqual(self.read()["inputChannel"], {"0": {"level": -12.0}})
        self.assertEqual(s.mixer_name, "a")
        self.assertTrue(os.path.exists(self.path + ".flat.bak"))


class Durability(Base):
    def test_burst_is_batched(self):
        s = self.store(save_delay=0.2)
        base = s.saves
        for i in range(500):
            s.set("inputChannel/0/level", float(i))
        time.sleep(0.6)
        batched = s.saves - base
        s.close()
        self.assertLessEqual(batched, 3, f"{batched} writes for a 500-set burst")
        self.assertEqual(self.read()["inputChannel"]["0"]["level"], 499.0)

    def test_saves_without_close_after_delay(self):
        s = self.store(save_delay=0.05)
        s.set("inputChannel/0/level", -3.0)
        time.sleep(0.4)
        self.assertEqual(self.read()["inputChannel"]["0"]["level"], -3.0)
        s.close()

    def test_bak_is_previous_state(self):
        s = self.store()
        s.set("x/0/level", 1.0)
        s.flush()
        s.set("x/0/level", 2.0)
        s.flush()
        s.close()
        self.assertEqual(self.read()["x"]["0"]["level"], 2.0)
        self.assertEqual(self.read(self.path + ".bak")["x"]["0"]["level"], 1.0)
        self.assertFalse(os.path.exists(self.path + ".tmp"))

    def test_corrupt_main_falls_back_to_bak(self):
        self.write({"x": {"0": {"level": 1.0}}}, self.path + ".bak")
        self.write('{"x": {"0": {"lev')                      # truncated main
        s = self.store()
        self.assertEqual(s.get("x/0/level"), 1.0)
        s.close()
        aside = [f for f in os.listdir(self.dir) if ".corrupt-" in f]
        self.assertEqual(len(aside), 1, os.listdir(self.dir))
        with open(os.path.join(self.dir, aside[0])) as f:
            self.assertEqual(f.read(), '{"x": {"0": {"lev')  # kept byte for byte
        self.assertEqual(self.read()["x"]["0"]["level"], 1.0)  # main rewritten from bak

    def test_missing_main_uses_bak(self):
        # the crash window between the two renames
        self.write({"x": {"0": {"level": 7.0}}}, self.path + ".bak")
        s = self.store()
        self.assertEqual(s.get("x/0/level"), 7.0)
        s.close()
        self.assertTrue(os.path.exists(self.path))

    def test_both_unusable_starts_empty_keeps_evidence(self):
        self.write("garbage")
        self.write("[1, 2]", self.path + ".bak")              # valid JSON, wrong shape
        s = self.store()
        self.assertEqual(s.get("x/0/level", default=None), None)
        s.close()
        aside = [f for f in os.listdir(self.dir) if ".corrupt-" in f]
        self.assertEqual(len(aside), 2, os.listdir(self.dir))

    def test_leftover_tmp_is_ignored(self):
        self.write({"x": {"0": {"level": 1.0}}})
        self.write("half-written", self.path + ".tmp")
        s = self.store()
        self.assertEqual(s.get("x/0/level"), 1.0)
        s.set("x/0/level", 2.0)
        s.close()
        self.assertEqual(self.read()["x"]["0"]["level"], 2.0)

    def test_failed_save_is_retried(self):
        s = self.store(save_delay=10)                           # no background saves
        real = s._write
        calls = []

        def failing(text):
            calls.append(1)
            raise OSError(28, "No space left on device")
        s._write = failing
        s.set("x/0/level", 1.0)
        self.assertFalse(s.flush())
        self.assertTrue(any("NOT saved" in m for m in self.logs))
        s._write = real
        self.assertTrue(s.flush())                              # still dirty, so it writes
        self.assertEqual(self.read()["x"]["0"]["level"], 1.0)
        s.close()

    def test_memory_only(self):
        s = MixerState("mixer", None, log=quiet)
        s.set("x/0/level", 1.0)
        self.assertTrue(s.close())
        self.assertEqual(os.listdir(self.dir), [])


@unittest.skipIf(os.name == "nt", "needs POSIX signals")
class ServerShutdown(Base):
    def test_sigterm_flushes_pending_state(self):
        """A set arrives, then SIGTERM before the batch delay has passed: the
        value must still be on disk."""
        port = 18400 + os.getpid() % 500
        env = dict(os.environ, PYTHONUNBUFFERED="1")
        proc = subprocess.Popen(
            [sys.executable, os.path.join(HERE, "osc_mixer_server.py"),
             "--host", "127.0.0.1", "--tcp-port", str(port), "--udp-port", str(port + 1),
             "--state-file", self.path],
            cwd=HERE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            for _ in range(50):
                try:
                    c = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                self.fail("server did not start")

            def osc(s):
                b = s.encode() + b"\0"
                return b + b"\0" * (-len(b) % 4)
            c.sendall(osc("/mixer/set/inputChannel/5/level") + osc(",f") + struct.pack(">f", -7.5))
            c.settimeout(2)
            c.recv(256)                                  # the echo: it's in memory now
            proc.send_signal(signal.SIGTERM)             # well inside the batch delay
            out, _ = proc.communicate(timeout=10)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual(proc.returncode, 0, out.decode(errors="replace"))
        self.assertIn(b"state saved", out)
        self.assertEqual(self.read()["inputChannel"]["5"]["level"], -7.5)


if __name__ == "__main__":
    unittest.main()
