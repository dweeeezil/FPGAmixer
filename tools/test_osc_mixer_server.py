#!/usr/bin/env python3
"""
Tests for osc_mixer_server.py through its sockets: the real server runs as a
subprocess (simulated backends, a temporary state file) and the tests talk
OSC to it, as a controller would. Standard library only; runs on Windows too.

    python3 -m unittest -v test_osc_mixer_server        (from tools/)

The fuller protocol suite against a running server or the board is
osc_mixer_test.py; these tests pin down server behaviour precisely and are
the ones mutation-tested.
"""

import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

from osc_codec import (Len32Framer, TCPLink, UDPLink, encode_bundle, encode_message,
                       osc_string)

HERE = os.path.dirname(os.path.abspath(__file__))
XP = "/mixer/set/inputMatrix/{}_{}/level"


def free_port(kind):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class ServerCase(unittest.TestCase):
    """Starts one server per test. Subclasses set SERVER_ARGS."""

    SERVER_ARGS = []
    FRAMING = "len32"

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="oscsrv-")
        self.tcp_port = free_port(socket.SOCK_STREAM)
        self.udp_port = free_port(socket.SOCK_DGRAM)
        self.log_path = os.path.join(self.dir, "server.log")
        self.log_file = open(self.log_path, "wb")
        self.proc = subprocess.Popen(
            [sys.executable, os.path.join(HERE, "osc_mixer_server.py"),
             "--host", "127.0.0.1", "--tcp-port", str(self.tcp_port),
             "--udp-port", str(self.udp_port), "--matrix-size", "4",
             "--state-file", os.path.join(self.dir, "state.json")] + self.SERVER_ARGS,
            cwd=HERE, env=dict(os.environ, PYTHONUNBUFFERED="1"),
            stdout=self.log_file, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", self.tcp_port), timeout=0.2).close()
                break
            except OSError:
                if self.proc.poll() is not None or time.monotonic() > deadline:
                    self.fail(f"server did not start:\n{self.log()}")
                time.sleep(0.05)
        self.links = []

    def tearDown(self):
        for link in self.links:
            link.close()
        self.proc.kill()
        self.proc.wait(timeout=10)
        self.log_file.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def log(self):
        with open(self.log_path, "rb") as f:
            return f.read().decode(errors="replace")

    def tcp(self, framing=None):
        link = TCPLink("127.0.0.1", self.tcp_port, timeout=2.0,
                       framing=framing or self.FRAMING).connect()
        self.links.append(link)
        return link

    def udp(self):
        link = UDPLink("127.0.0.1", self.udp_port)
        self.links.append(link)
        return link

    def roundtrip(self, link, address, value):
        """Set, and return the echo's value (the echo must be for `address`)."""
        link.send_message(address, [value])
        reply = link.read_message()
        self.assertEqual(reply.address, address)
        return reply.args[0]

    def get(self, link, tail):
        link.send_message(f"/mixer/get/{tail}")
        return link.read_message().args[0]


class Len32Framing(ServerCase):
    def test_echo_is_framed(self):
        c = self.tcp()
        c.send_message(XP.format(0, 1), [-6.0])
        c.sock.settimeout(2)
        data = c.sock.recv(4096)
        expected = encode_message(XP.format(0, 1), [-6.0])
        self.assertEqual(data, Len32Framer.frame(expected))

    def test_bundle_runs_in_order(self):
        c = self.tcp()
        c.send_packet(encode_bundle([encode_message(XP.format(0, 1), [-3.0]),
                                     encode_message(XP.format(0, 1), [-4.0]),
                                     encode_message(XP.format(1, 0), [-5.0])]))
        got = [(m.address, m.args[0]) for m in (c.read_message() for _ in range(3))]
        self.assertEqual(got, [(XP.format(0, 1), -3.0), (XP.format(0, 1), -4.0),
                               (XP.format(1, 0), -5.0)])

    def test_truncated_packet_is_dropped_and_the_stream_stays_in_step(self):
        c = self.tcp()
        c.send_packet(osc_string(XP.format(0, 1)) + osc_string(",f") + b"\0\0")
        self.assertEqual(self.roundtrip(c, XP.format(0, 1), -8.25), -8.25)
        self.assertIn("truncated", self.log())

    def test_bad_type_tag_drops_only_that_packet(self):
        c = self.tcp()
        bad = osc_string(XP.format(0, 1)) + osc_string(",z") + b"\0\0\0\0"
        c.send_raw(Len32Framer.frame(bad) + Len32Framer.frame(encode_message(XP.format(1, 1), [-2.0])))
        reply = c.read_message()
        self.assertEqual((reply.address, reply.args), (XP.format(1, 1), [-2.0]))

    def test_bad_message_in_a_bundle_drops_the_whole_bundle(self):
        c = self.tcp()
        bad = osc_string(XP.format(0, 1)) + osc_string(",z") + b"\0\0\0\0"
        c.send_packet(encode_bundle([encode_message(XP.format(2, 3), [-1.0]), bad]))
        self.assertEqual(self.roundtrip(c, XP.format(3, 3), -2.0), -2.0)   # first reply: no -1.0 echo
        self.assertEqual(self.get(c, "inputMatrix/2_3/level"), -90.0)     # still the seeded "off"

    def test_impossible_size_closes_the_connection_only(self):
        c = self.tcp()
        c.send_raw(struct.pack(">I", 0x7FFFFFFF) + b"abcd")
        c.sock.settimeout(2)
        self.assertEqual(c.sock.recv(100), b"")             # the server closed it
        self.assertIn("stream position lost", self.log())
        self.assertEqual(self.roundtrip(self.tcp(), XP.format(0, 1), -7.0), -7.0)

    def test_unframed_bytes_are_not_a_valid_stream(self):
        """An old unframed controller on a len32 port: its first 4 bytes ('/mix')
        read as a ~800 MB size, so the connection is closed, not misparsed."""
        c = self.tcp(framing="none")
        c.send_message(XP.format(0, 1), [-6.0])
        c.sock.settimeout(2)
        self.assertEqual(c.sock.recv(100), b"")


class UnframedFraming(ServerCase):
    SERVER_ARGS = ["--tcp-framing", "none"]
    FRAMING = "none"

    def test_messages_back_to_back(self):
        c = self.tcp()
        c.send_raw(encode_message(XP.format(0, 1), [-1.0]) + encode_message(XP.format(0, 1), [-2.0]))
        self.assertEqual([c.read_message().args[0] for _ in range(2)], [-1.0, -2.0])

    def test_echo_is_not_framed(self):
        c = self.tcp()
        c.send_message(XP.format(0, 1), [-6.0])
        c.sock.settimeout(2)
        self.assertEqual(c.sock.recv(4096), encode_message(XP.format(0, 1), [-6.0]))

    def test_messages_before_a_malformed_one_still_run(self):
        c = self.tcp()
        bad = osc_string(XP.format(0, 1)) + osc_string(",z") + b"\0\0\0\0"
        c.send_raw(encode_message(XP.format(1, 2), [-9.0]) + bad)
        reply = c.read_message()
        self.assertEqual((reply.address, reply.args), (XP.format(1, 2), [-9.0]))
        self.assertEqual(self.roundtrip(c, XP.format(0, 1), -3.0), -3.0)   # recovered

    def test_framing_is_logged(self):
        self.assertIn("TCP framing: none", self.log())


class Udp(ServerCase):
    def test_bundle_in_one_datagram(self):
        watcher = self.tcp()
        self.get(watcher, "inputMatrix/0_0/level")          # the server has this client now
        self.udp().send_raw(encode_bundle([encode_message(XP.format(1, 2), [-11.0]),
                                           encode_message(XP.format(2, 1), [-12.0])]))
        got = [(m.address, m.args[0]) for m in (watcher.read_message() for _ in range(2))]
        self.assertEqual(got, [(XP.format(1, 2), -11.0), (XP.format(2, 1), -12.0)])

    def test_two_messages_in_one_datagram_are_dropped(self):
        watcher = self.tcp()
        self.get(watcher, "inputMatrix/0_0/level")
        self.udp().send_raw(encode_message(XP.format(1, 2), [-11.0]) + encode_message(XP.format(2, 1), [-12.0]))
        with self.assertRaises(TimeoutError):
            watcher.read_message(timeout=0.5)
        self.assertIn("after the message", self.log())


if __name__ == "__main__":
    unittest.main()
