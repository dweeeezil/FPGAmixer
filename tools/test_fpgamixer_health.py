#!/usr/bin/env python3
"""
Tests for fpgamixer_health.sh (hardening T4, H-F5): the real script under sh,
with stub journalctl / systemctl / python3 first on PATH, so it runs on any
Linux host without a board.

    python3 -m unittest -v test_fpgamixer_health          (from tools/)

Checks: the bridge section (the latest status line per direction, a direction
at 0 frames/s flagged NOT MOVING with the explanation once, no flag for a
direction that moves (48000 frames/s holds "0 frames/s" too), a bridge with no
status line showing its last line); a finished one-time setup read as done;
ptp4l's worst max with clock steps (1 s or more) left out.
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
# show <unit> ...: $STUB/<unit>.state if there is one, else active running
if [ -f "$STUB/$2.state" ]; then cat "$STUB/$2.state"
else printf 'ActiveState=active\\nSubState=running\\nNRestarts=0\\n'; fi
"""
PYTHON3 = """#!/bin/sh
echo "pl stub"
"""


def line(name, fps, coarse=0, idle=0):
    return (f"{name}: {fps} frames/s, queue +0.0 frames from target, "
            f"xruns 0/0 (capture/playback), coarse fixes {coarse}, idle drops {idle}")


@unittest.skipIf(os.name == "nt" or not shutil.which("sh"), "needs a POSIX sh")
class HealthCase(unittest.TestCase):
    """The stubs and helpers; no tests of its own."""
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


class Bridges(HealthCase):
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

    def test_no_status_line_shows_the_last_line(self):
        self.journal("fpgamixer-usbhost-bridge", [
            "Started FPGAmixer USB host bridge.",
            "interface 'M2' not present; waiting for it"])
        out = self.run_health()
        got = self.bridge_lines(out, "fpgamixer-usbhost-bridge")
        self.assertEqual(got, ["    no status line; its last line: "
                               "interface 'M2' not present; waiting for it"])


class Services(HealthCase):
    def state(self, unit, active, sub, restarts=0):
        with open(os.path.join(self.dir, unit + ".state"), "w", newline="\n") as f:
            f.write(f"ActiveState={active}\nSubState={sub}\nNRestarts={restarts}\n")

    def service(self, out, unit):
        return [l for l in out if l.startswith(f"  {unit}: ")]

    def test_a_finished_setup_reads_as_done(self):
        self.state("fpgamixer-avb-net", "active", "exited")
        out = self.run_health()
        line, = self.service(out, "fpgamixer-avb-net")
        self.assertIn("active exited", line)
        self.assertIn("(a one-time setup: done)", line)
        osc, = self.service(out, "fpgamixer-osc")
        self.assertNotIn("one-time", osc)

    def test_a_failed_unit_is_not_called_done(self):
        self.state("fpgamixer-avb-net", "failed", "failed", 3)
        line, = self.service(self.run_health(), "fpgamixer-avb-net")
        self.assertIn("failed", line)
        self.assertIn("restarts 3", line)
        self.assertNotIn("done", line)


class Gptp(HealthCase):
    def summary(self, rms, mx):
        return f"[100.000] rms {rms} max {mx} freq -30 +/- 2 delay 1300 +/- 0"

    def gptp_line(self, out):
        i = out.index("== gPTP (ptp4l, ns)")
        return out[i + 1]

    def test_a_clock_step_is_left_out_of_the_worst_max(self):
        self.journal("fpgamixer-ptp4l", [
            self.summary(900000, 1747949603511445248),        # the boot step
            self.summary(12, 40), self.summary(7, 25)])
        line = self.gptp_line(self.run_health())
        self.assertIn("last rms 7, worst max 40 over the last 3 summaries", line)
        self.assertIn("(1 with a clock step left out)", line)

    def test_just_under_a_second_still_counts(self):
        self.journal("fpgamixer-ptp4l", [self.summary(5, 999999999), self.summary(7, 25)])
        line = self.gptp_line(self.run_health())
        self.assertIn("worst max 999999999", line)
        self.assertNotIn("left out", line)


if __name__ == "__main__":
    unittest.main()
