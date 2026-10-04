#!/usr/bin/env python3
"""
Unit tests for osc_discovery.py: the .dnssd file systemd-resolved publishes,
when it is rewritten, and the reload. Standard library only; the reload is a
small script, so nothing touches the real systemd.

    python3 -m unittest -v test_osc_discovery        (from tools/)
"""

import os
import shutil
import sys
import tempfile
import unittest

from osc_discovery import DnssdAdvertiser, NoAdvertiser, make_advertiser


class Dnssd(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="dnssd-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "dnssd", "studiorunner.dnssd")   # dir created on demand
        self.marker = os.path.join(self.dir, "reloads")
        script = os.path.join(self.dir, "reload.py")
        with open(script, "w") as f:
            f.write(f"open({self.marker!r}, 'a').write('x')\n")
        self.logs = []
        self.adv = DnssdAdvertiser(8000, "len32", self.path, f"{sys.executable} {script}",
                                   log=self.logs.append)

    def wait(self):
        for t in self.adv.reloads:
            t.join(timeout=30)

    def reloads(self):
        self.wait()
        try:
            with open(self.marker) as f:
                return len(f.read())
        except OSError:
            return 0

    def test_file_contents(self):
        self.assertTrue(self.adv.advertise("FOH"))
        with open(self.path) as f:
            lines = [l for l in f.read().splitlines() if not l.startswith("#")]
        self.assertEqual(lines, ["[Service]", "Name=FOH", "Type=_studiorunner._tcp", "Port=8000",
                                 "TxtText=name=FOH v=1 framing=len32"])

    def test_framing_and_port_come_from_the_server(self):
        text = DnssdAdvertiser(9000, "none", self.path, "").render("x")
        self.assertIn("Port=9000\n", text)
        self.assertIn(" framing=none\n", text)

    def test_reload_only_when_the_contents_change(self):
        self.assertTrue(self.adv.advertise("FOH"))
        self.assertEqual(self.reloads(), 1)
        self.assertFalse(self.adv.advertise("FOH"))          # a server restart: nothing to do
        self.assertEqual(self.reloads(), 1)
        self.assertTrue(self.adv.advertise("Stage"))         # a rename
        self.assertEqual(self.reloads(), 2)
        with open(self.path) as f:
            self.assertIn("Name=Stage\n", f.read())

    def test_old_names_with_a_space_or_percent_stay_one_word(self):
        text = self.adv.render('FOH mixer 100%')
        self.assertIn("Name=FOH mixer 100%%\n", text)                  # systemd specifier escape
        self.assertIn('TxtText="name=FOH mixer 100%" v=1', text)       # one TXT word

    def test_quotes_and_backslashes_are_escaped(self):
        self.assertIn('TxtText="name=a\\"b\\\\c" v=1', self.adv.render('a"b\\c'))

    def test_a_failing_reload_is_logged_not_raised(self):
        adv = DnssdAdvertiser(8000, "len32", self.path, "no-such-command-xyz", log=self.logs.append)
        self.assertTrue(adv.advertise("FOH"))
        for t in adv.reloads:
            t.join(timeout=30)
        self.assertTrue(any("failed" in m for m in self.logs), self.logs)

    def test_a_reload_that_exits_non_zero_is_logged(self):
        script = os.path.join(self.dir, "fail.py")
        with open(script, "w") as f:
            f.write("import sys; sys.stderr.write('unit not found'); sys.exit(3)\n")
        adv = DnssdAdvertiser(8000, "len32", self.path, f"{sys.executable} {script}", log=self.logs.append)
        self.assertTrue(adv.advertise("FOH"))
        for t in adv.reloads:
            t.join(timeout=30)
        self.assertTrue(any("failed (3): unit not found" in m for m in self.logs), self.logs)

    def test_an_unwritable_path_is_logged_not_raised(self):
        blocker = os.path.join(self.dir, "file")
        open(blocker, "w").close()
        adv = DnssdAdvertiser(8000, "len32", os.path.join(blocker, "x.dnssd"), "", log=self.logs.append)
        self.assertFalse(adv.advertise("FOH"))
        self.assertTrue(any("could not write" in m for m in self.logs), self.logs)

    def test_no_reload_command(self):
        adv = DnssdAdvertiser(8000, "len32", self.path, "", log=self.logs.append)
        self.assertTrue(adv.advertise("FOH"))
        self.assertEqual(adv.reloads, [])
        self.assertFalse(os.path.exists(self.path + ".tmp"))

    def test_factory(self):
        self.assertIsInstance(make_advertiser("none", 8000, "len32"), NoAdvertiser)
        self.assertFalse(NoAdvertiser().advertise("FOH"))
        self.assertIsInstance(make_advertiser("dnssd", 8000, "len32", self.path, ""), DnssdAdvertiser)
        with self.assertRaises(ValueError):
            make_advertiser("avahi", 8000, "len32")


if __name__ == "__main__":
    unittest.main()
