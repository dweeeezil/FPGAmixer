#!/usr/bin/env python3
"""
Tests for fpgamixer_health.sh (hardening T4, H-F5): the real script under sh,
with stub journalctl / systemctl / python3 first on PATH, so it runs on any
Linux host without a board.

    python3 -m unittest -v test_fpgamixer_health          (from tools/)

Checks the bridge section: the latest status line per direction, a direction
at 0 frames/s flagged NOT MOVING with the explanation once, and no flag for a
direction that moves (48000 frames/s holds "0 frames/s" too).
"""

import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "fpgamixer_health.sh")

JOURNALCTL = """#!/bin/sh
# prints $STUB/<unit>.log for -u <unit>
while [ $# -gt 0 ]; do
    [ "$1" = "-u" ] && { shift; cat "$STUB/$1.log" 2>/dev/null; exit 0; }
    shift
done
"""
SYSTEMCTL = """#!/bin/sh
printf 'ActiveState=active\\nSubState=running\\nNRestarts=0\\n'
"""
PYTHON3 = """#!/bin/sh
echo "pl stub"
"""


def line(name, fps, coarse=0, idle=0):
    return (f"{name}: {fps} frames/s, queue +0.0 frames from target, "
            f"xruns 0/0 (capture/playback), coarse fixes {coarse}, idle drops {idle}")


@unittest.skipIf(os.name == "nt" or not shutil.which("sh"), "needs a POSIX sh")
class Bridges(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="health-")
        self.bin = os.path.join(self.dir, "bin")
        os.mkdir(self.bin)
        for name, body in (("journalctl", JOURNALCTL), ("systemctl", SYSTEMCTL),
                           ("python3", PYTHON3)):
            p = os.path.join(self.bin, name)
            with open(p, "w", newline="\n") as f:
                f.write(body)
            os.chmod(p, 0o755)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def journal(self, unit, lines):
        with open(os.path.join(self.dir, unit + ".log"), "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")

    def run_health(self):
        env = dict(os.environ, STUB=self.dir,
                   PATH=self.bin + os.pathsep + os.environ.get("PATH", ""))
        r = subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True,
                           timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.splitlines()

    def bridge_lines(self, out, unit):
        i = out.index(f"  {unit}:")
        rest = []
        for l in out[i + 1:]:
            if not l.startswith("    "):
                break
            rest.append(l)
        return rest

    def test_moving_directions_are_not_flagged(self):
        self.journal("fpgamixer-avb-bridge", [
            line("A net->core", 48000), line("B core->net", 48000),
            "A net->core: the system clock was stepped; restarting the capture",
            line("A net->core", 48000), line("B core->net", 48000)])
        out = self.run_health()
        got = self.bridge_lines(out, "fpgamixer-avb-bridge")
        self.assertEqual(len(got), 2, got)               # the latest per direction
        self.assertFalse(any("NOT MOVING" in l for l in out), out)

    def test_a_stopped_direction_is_flagged_once_explained(self):
        self.journal("fpgamixer-avb-bridge", [
            line("A net->core", 48000), line("B core->net", 48000),
            line("A net->core", 48000), line("B core->net", 0, coarse=1, idle=4999)])
        self.journal("fpgamixer-usb-bridge", [
            line("A mac->pl", 48000), line("B pl->mac", 0, coarse=1, idle=5000)])
        out = self.run_health()
        avb = self.bridge_lines(out, "fpgamixer-avb-bridge")
        self.assertEqual(["NOT MOVING" in l for l in avb], [False, True], avb)
        self.assertIn("idle drops 4999", avb[1])
        usb = self.bridge_lines(out, "fpgamixer-usb-bridge")
        self.assertEqual(["NOT MOVING" in l for l in usb], [False, True], usb)
        notes = [l for l in out if l.startswith("  NOT MOVING =")]
        self.assertEqual(len(notes), 1, out)

    def test_only_the_latest_line_counts(self):
        self.journal("fpgamixer-avb-bridge", [
            line("B core->net", 0, idle=100), line("B core->net", 48000, idle=100)])
        out = self.run_health()
        self.assertFalse(any("NOT MOVING" in l for l in out), out)

    def test_no_status_line(self):
        out = self.run_health()
        self.assertIn("    no status line", out)
        self.assertFalse(any("NOT MOVING" in l for l in out), out)


if __name__ == "__main__":
    unittest.main()
