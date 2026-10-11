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

import json
import math
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from mixer_params import float32
from osc_codec import (Len32Framer, TCPLink, UDPLink, encode_bundle, encode_message,
                       osc_string)

HERE = os.path.dirname(os.path.abspath(__file__))
SIM_MAX_DB = 20.0 * math.log10(((1 << 17) - 1) / (1 << 16))   # the simulator's Q2.16 ceiling
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
    STATE = None        # a state tree to start from (written as the state file)

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="oscsrv-")
        if self.STATE is not None:
            with open(os.path.join(self.dir, "state.json"), "w") as f:
                json.dump(self.STATE, f)
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

    def test_config_reply_unframed(self):
        """The reply is one long OSC string (here ~600 bytes over 4 x 4; a
        20 x 20 board is larger); an unframed reader must wait for its NUL."""
        c = self.tcp()
        c.send_message("/mixer/get/system/config")
        text = c.read_message().args[0]
        self.assertGreater(len(text), 500)
        self.assertEqual(json.loads(text)["schemaVersion"], 1)


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


def silent(test, link, wait=0.4):
    """Assert nothing arrives on `link` for `wait` seconds."""
    try:
        msg = link.read_message(timeout=wait)
    except TimeoutError:
        return
    test.fail(f"expected silence, got {msg}")


class Names(ServerCase):
    """The /mixer/ alias and the name rules (F2, F9; standard: "Mixer name
    and the /mixer/ alias", "The system zone")."""

    SERVER_ARGS = ["--mixer-name", "FOH"]
    NAME = "/FOH/set/system/deviceName"

    def synced(self):
        """A connection the server certainly has (one round trip done)."""
        c = self.tcp()
        self.get(c, "system/deviceName")
        return c

    def test_alias_and_name_both_answer_replies_use_the_name(self):
        c = self.tcp()
        for root in ("mixer", "FOH"):
            c.send_message(f"/{root}/set/inputMatrix/0_1/level", [-6.0])
            self.assertEqual(c.read_message().address, "/FOH/set/inputMatrix/0_1/level", root)
            c.send_message(f"/{root}/get/system/deviceName")
            self.assertEqual(c.read_message().args, ["FOH"], root)

    def test_other_roots_are_ignored(self):
        c = self.tcp()
        for address in ("/other/set/inputMatrix/0_1/level", "/FO/set/inputMatrix/0_1/level",
                        "/mixerX/set/inputMatrix/0_1/level", "mixer/set/inputMatrix/0_1/level",
                        "/mixer"):
            c.send_message(address, [-6.0])
        silent(self, c)

    def test_alias_over_udp(self):
        c = self.synced()
        self.udp().send_message("/mixer/set/inputMatrix/1_2/level", [-4.0])
        m = c.read_message()
        self.assertEqual((m.address, m.args), ("/FOH/set/inputMatrix/1_2/level", [-4.0]))

    def test_rename_confirmed_under_old_name_then_new_name_and_alias(self):
        a, b = self.synced(), self.synced()
        a.send_message("/mixer/set/system/deviceName/", ["Stage.L-2_b"])
        for link in (a, b):
            m = link.read_message()
            self.assertEqual((m.address, m.args), (self.NAME, ["Stage.L-2_b"]))
        a.send_message("/FOH/get/system/deviceName")                 # old name: ignored
        silent(self, a)
        for root in ("Stage.L-2_b", "mixer"):
            a.send_message(f"/{root}/get/system/deviceName")
            m = a.read_message()
            self.assertEqual((m.address, m.args), ("/Stage.L-2_b/set/system/deviceName", ["Stage.L-2_b"]))

    def test_63_bytes_is_allowed(self):
        c = self.synced()
        c.send_message(self.NAME, ["n" * 63])
        self.assertEqual(c.read_message().args, ["n" * 63])

    def test_refused_rename_answers_the_sender_only(self):
        a, b = self.synced(), self.synced()
        for bad in ("mixer", "", "two words", "a/b", "n" * 64, "café", -1.0, 3):
            a.send_message(self.NAME, [bad])
            name = a.read_message()
            self.assertEqual((name.address, name.args), (self.NAME, ["FOH"]), repr(bad))
            err = a.read_message()
            self.assertEqual(err.address, "/FOH/error", repr(bad))
            self.assertEqual(err.args[0], "system/deviceName", repr(bad))
            self.assertIsInstance(err.args[1], str)
        silent(self, b)
        self.assertEqual(self.get(a, "system/deviceName"), "FOH")    # unchanged
        self.assertIn("reserved", self.log())
        self.assertIn("can't be empty", self.log())

    def test_refused_rename_over_udp_is_only_logged(self):
        c = self.synced()
        self.udp().send_message(self.NAME, ["two words"])
        silent(self, c)
        self.assertEqual(self.get(c, "system/deviceName"), "FOH")
        self.assertIn("refused system/deviceName", self.log())

    def test_rename_survives_a_restart(self):
        c = self.synced()
        c.send_message(self.NAME, ["Monitor"])
        c.read_message()
        time.sleep(0.6)                      # past the batched save
        with open(os.path.join(self.dir, "state.json")) as f:
            self.assertEqual(json.load(f)["system"]["deviceName"], "Monitor")


class ErrorsAndValues(ServerCase):
    """Error reply (F8, amendment G) and value rules (F9, D37) on a 4 x 4
    simulated matrix: inputMatrix with level only, plus system settings."""

    def expect_error(self, link, path):
        m = link.read_message()
        self.assertEqual(m.address, "/mixer/error", m)
        self.assertEqual(m.args[0], path)
        self.assertEqual(len(m.args), 2)
        self.assertIsInstance(m.args[1], str)
        return m.args[1]

    def test_unknown_paths_refused_for_set_and_get(self):
        a, b = self.tcp(), self.tcp()
        self.get(b, "system/deviceName")
        for tail, path in [("auxChannel/0/level", "auxChannel/0/level"),         # zone not advertised
                           ("inputChannel/4/level", "inputChannel/4/level"),     # channel out of range
                           ("inputMatrix/4_0/level", "inputMatrix/4_0/level"),   # out of range
                           ("busMatrix/0_4/level", "busMatrix/0_4/level"),
                           ("inputMatrix/0_0/delay/", "inputMatrix/0_0/delay"),  # module not there
                           ("inputMatrix/0_0", "inputMatrix/0_0"),
                           ("system/location", "system/location"),
                           ("test", "test")]:
            a.send_message(f"/mixer/set/{tail}", [-6.0])
            self.expect_error(a, path)
            a.send_message(f"/mixer/get/{tail}")              # no more 0.0 for a missing path
            self.expect_error(a, path)
        silent(self, b)                                        # nothing was broadcast

    def test_wrong_kind_and_missing_value(self):
        c = self.tcp()
        c.send_message(XP.format(0, 1), ["-6"])
        self.assertIn("string", self.expect_error(c, "inputMatrix/0_1/level"))
        c.send_message(XP.format(0, 1), [b"\x01\x02"])
        self.expect_error(c, "inputMatrix/0_1/level")
        c.send_message(XP.format(0, 1))
        self.assertIn("needs a value", self.expect_error(c, "inputMatrix/0_1/level"))
        self.assertEqual(self.get(c, "inputMatrix/0_1/level"), -90.0)   # untouched

    def test_read_only_and_enum(self):
        c = self.tcp()
        self.assertEqual(self.get(c, "system/sampleRate"), 48000.0)
        c.send_message("/mixer/set/system/sampleRate", [48000.0])
        self.assertIn("read-only", self.expect_error(c, "system/sampleRate"))

    def test_clamping_is_not_an_error_and_the_echo_carries_the_applied_value(self):
        c = self.tcp()
        for sent, applied in ((-120.0, -90.0), (50.0, float32(SIM_MAX_DB)), (float("nan"), -90.0),
                              (float("inf"), float32(SIM_MAX_DB)), (-3, -3.0), (True, 1.0)):
            self.assertEqual(self.roundtrip(c, XP.format(1, 2), sent), applied, sent)
        self.assertEqual(self.get(c, "inputMatrix/1_2/level"), 1.0)

    def test_canonical_path_in_echo_get_and_state(self):
        c = self.tcp()
        c.send_message("/mixer/set/inputMatrix/01_002/level/", [-7.0])
        m = c.read_message()
        self.assertEqual((m.address, m.args), (XP.format(1, 2), [-7.0]))
        c.send_message("/mixer/get/inputMatrix/1_2/level/")
        self.assertEqual(c.read_message().address, XP.format(1, 2))
        time.sleep(0.6)
        with open(os.path.join(self.dir, "state.json")) as f:
            matrix = json.load(f)["inputMatrix"]
        self.assertEqual(matrix["1_2"], {"level": -7.0})
        self.assertNotIn("01_002", matrix)

    def test_fresh_start_has_the_reset_routing(self):
        c = self.tcp()
        self.assertEqual([self.get(c, f"inputMatrix/{i}_{o}/level") for i, o in ((0, 0), (3, 3), (0, 1), (3, 2))],
                         [0.0, 0.0, -90.0, -90.0])
        # Phase 12 (L7): bus matrix identity, every channel level at unity
        self.assertEqual([self.get(c, f"busMatrix/{b}_{o}/level") for b, o in ((0, 0), (3, 3), (1, 0), (2, 3))],
                         [0.0, 0.0, -90.0, -90.0])
        for zone in ("inputChannel", "busChannel", "outputChannel"):
            self.assertEqual([self.get(c, f"{zone}/{n}/level") for n in range(4)], [0.0] * 4, zone)

    def test_udp_refusals_are_only_logged(self):
        c = self.tcp()
        self.get(c, "system/deviceName")
        u = self.udp()
        u.send_message("/mixer/set/inputChannel/9/level", [-6.0])
        u.send_message(XP.format(0, 1), ["x"])
        u.send_message("/mixer/set/system/sampleRate", [44100.0])
        silent(self, c)
        log = self.log()
        for path in ("inputChannel/9/level", "inputMatrix/0_1/level", "system/sampleRate"):
            self.assertIn(f"refused {path}", log)

    def test_float32_echo(self):
        c = self.tcp()
        self.assertEqual(self.roundtrip(c, XP.format(2, 2), 2.39), float32(2.39))


class OldStateFile(ServerCase):
    """An old state file keeps loading; the format doesn't change (§4.2)."""

    STATE = {"system": {"deviceName": "mixer"},
             "inputChannel": {"0": {"level": -12.0}},
             "auxChannel": {"0": {"level": -3.0}},
             "inputMatrix": {"0_0": {"level": -99.9, "delay": 2.39},
                             "0_1": {"level": 50.0},
                             "1_0": {"level": "loud"},
                             "1_1": {"level": -6.0}}}

    def state(self):
        time.sleep(0.6)                      # past the batched save
        with open(os.path.join(self.dir, "state.json")) as f:
            return json.load(f)

    def test_values_brought_inside_the_rules_and_unadvertised_ones_kept(self):
        c = self.tcp()
        self.assertEqual(self.get(c, "inputMatrix/0_0/level"), -90.0)            # was -99.9
        self.assertEqual(self.get(c, "inputMatrix/0_1/level"), float32(SIM_MAX_DB))  # was 50
        self.assertEqual(self.get(c, "inputMatrix/1_0/level"), -90.0)            # unusable: reset routing
        self.assertEqual(self.get(c, "inputMatrix/1_1/level"), -6.0)             # kept
        # Phase 12: inputChannel is served now, so a stored level is live
        # (and not reseeded); a zone the mixer doesn't have stays unreachable
        self.assertEqual(self.get(c, "inputChannel/0/level"), -12.0)
        self.assertEqual(self.get(c, "inputChannel/1/level"), 0.0)               # seeded: unity
        c.send_message("/mixer/get/auxChannel/0/level")
        self.assertEqual(c.read_message().address, "/mixer/error")               # unreachable...
        tree = self.state()
        self.assertEqual(tree["auxChannel"], {"0": {"level": -3.0}})             # ...but kept
        self.assertEqual(tree["inputChannel"]["0"], {"level": -12.0})
        self.assertEqual(tree["inputMatrix"]["0_0"]["delay"], 2.39)
        self.assertEqual(tree["inputMatrix"]["0_0"]["level"], -90.0)
        self.assertEqual(tree["inputMatrix"]["1_0"]["level"], -90.0)

    def test_new_values_land_in_the_same_tree(self):
        c = self.tcp()
        self.roundtrip(c, XP.format(3, 2), -20.0)
        self.assertEqual(self.state()["inputMatrix"]["3_2"], {"level": -20.0})


class ConflictingStateFile(ServerCase):
    """A hand-edited file with a value where the tree needs a branch: the
    crosspoint can't be stored, so a set of it is refused, not lost."""

    STATE = {"inputMatrix": {"0_1": -3.0}}

    def test_set_refused_with_a_reason(self):
        c = self.tcp()
        c.send_message(XP.format(0, 1), [-6.0])
        m = c.read_message()
        self.assertEqual((m.address, m.args[0]), ("/mixer/error", "inputMatrix/0_1/level"))
        self.assertIn("can't store", m.args[1])
        self.assertEqual(self.roundtrip(c, XP.format(0, 2), -6.0), -6.0)   # the rest works


class FakeMatrixHW:
    """Records what a MatrixBackend writes; set_db clamps like mixer_hw."""

    def __init__(self):
        self.writes, self.banks = [], []

    def set_db(self, out, inp, db):
        self.writes.append((out, inp, db))
        return max(db, -90.0)

    def set_bank_db(self, levels):
        self.banks.append(dict(levels))
        return {k: max(db, -90.0) for k, db in levels.items()}

    def status(self):
        return "fake"


class FakeGainHW:
    """Records what a GainBackend writes; set_db clamps like mixer_hw."""

    def __init__(self):
        self.writes, self.banks = [], []

    def set_db(self, ch, db):
        self.writes.append((ch, db))
        return max(db, -90.0)

    def set_bank_db(self, levels):
        self.banks.append(dict(levels))
        return {k: max(db, -90.0) for k, db in levels.items()}

    def status(self):
        return "fake"


class InProcess(unittest.TestCase):
    """Backend and server functions called directly (no sockets)."""

    def setUp(self):
        import osc_mixer_server as srv
        from mixer_state import MixerState
        self.srv = srv
        self.state = MixerState("mixer", None, log=lambda m: None)
        srv.log = lambda m: None

    def test_matrix_backend_drives_hw_with_out_and_in_in_that_order(self):
        hw = FakeMatrixHW()
        b = self.srv.MatrixBackend("inputMatrix", hw, 3, 2, max_db=6.0)
        self.assertEqual(b.apply("2_1", "level", -6.0), -6.0)
        self.assertEqual(hw.writes, [(1, 2, -6.0)])                 # out 1, in 2

    def test_seed_pushes_the_whole_bank_with_the_reset_routing(self):
        hw = FakeMatrixHW()
        self.state.set("inputMatrix/1_0/level", -12.0)
        self.srv.MatrixBackend("inputMatrix", hw, 2, 2, max_db=6.0).seed_and_push(self.state)
        self.assertEqual(hw.banks, [{(0, 0): 0.0, (1, 1): 0.0, (1, 0): -90.0, (0, 1): -12.0}])

    def test_seed_identity_from_leaves_the_first_inputs_off_but_keeps_stored(self):
        """Phase 11 H5: the USB host's inputs (0-3 on the board) start off;
        a level the user stored there is still restored."""
        hw = FakeMatrixHW()
        self.state.set("inputMatrix/1_1/level", -6.0)
        self.srv.MatrixBackend("inputMatrix", hw, 3, 3, max_db=6.0,
                               identity_from=2).seed_and_push(self.state)
        bank = hw.banks[0]
        self.assertEqual((bank[(0, 0)], bank[(1, 1)], bank[(2, 2)]), (-90.0, -6.0, 0.0))
        self.assertEqual(self.state.get("inputMatrix/0_0/level"), -90.0)   # seeded into the store

    def test_apply_many_is_one_bank_per_window_with_the_applied_values(self):
        """Phase 14: a recall pushes each window once (one COMMIT), and the
        values it echoes are what the hardware applied."""
        mhw, ghw = FakeMatrixHW(), FakeGainHW()
        m = self.srv.MatrixBackend("inputMatrix", mhw, 3, 2, max_db=6.0)
        got = m.apply_many({("2_1", "level"): -6.0, ("0_0", "level"): -120.0})
        self.assertEqual(mhw.banks, [{(1, 2): -6.0, (0, 0): -120.0}])   # (out, in), one bank
        self.assertEqual(got, {("2_1", "level"): -6.0, ("0_0", "level"): -90.0})
        self.assertEqual(mhw.writes, [])                                 # no per-crosspoint commits
        g = self.srv.GainBackend("busChannel", ghw, 4, max_db=6.0)
        got = g.apply_many({("3", "level"): -2.0, ("1", "level"): -99.0})
        self.assertEqual(ghw.banks, [{3: -2.0, 1: -99.0}])
        self.assertEqual(got, {("3", "level"): -2.0, ("1", "level"): -90.0})
        self.assertEqual(self.srv.MatrixBackend("inputMatrix", None, 2, 2).apply_many(
            {("0_1", "level"): -3.0}), {("0_1", "level"): -3.0})        # simulator: as given

    def test_linked_set_is_one_bank_and_vgroup_never_reaches_the_hardware(self):
        """Phase 14: a set on a grouped channel writes every member in one
        bank (one COMMIT), and the stored/echoed values are the hardware's."""
        srv, hw = self.srv, FakeGainHW()
        sent = []

        class Registry:
            lock = threading.RLock()

            def broadcast(self, packet):
                sent.append(packet)

        b = srv.GainBackend("outputChannel", hw, 4, max_db=6.0)
        old = srv.BACKENDS.copy(), srv.MODEL
        srv.BACKENDS.clear()
        srv.BACKENDS["outputChannel"] = b
        srv.MODEL = srv.build_model(srv.BACKENDS, srv.SYSTEM_SETTINGS)
        try:
            for ch in (0, 2):
                srv.apply_set(f"outputChannel/{ch}/vgroup", 4, self.state, Registry(), None, "test")
            self.assertEqual((hw.writes, hw.banks), ([], []))            # vgroup: no hardware
            srv.apply_set("outputChannel/2/level", -120.0, self.state, Registry(), None, "test")
        finally:
            srv.BACKENDS.clear()
            srv.BACKENDS.update(old[0])
            srv.MODEL = old[1]
        self.assertEqual(hw.writes, [])                                   # no per-channel commits
        self.assertEqual(hw.banks, [{2: -90.0, 0: -90.0}])               # one bank, both members
        self.assertEqual((self.state.get("outputChannel/0/level"),
                          self.state.get("outputChannel/2/level")), (-90.0, -90.0))
        self.assertEqual(len(sent), 4)                                    # 2 vgroup echoes + 2 levels
        self.assertEqual(b.apply_many({("1", "level"): -1.0, ("1", "vgroup"): 3.0}),
                         {("1", "level"): -1.0, ("1", "vgroup"): 3.0})
        self.assertEqual(hw.banks[-1], {1: -1.0})                         # the level only

    def test_identity_from_reaches_the_input_matrix_only(self):
        backends = self.srv.build_backends(False, 6, identity_from=4)
        self.assertEqual(backends["inputMatrix"].identity_from, 4)
        self.assertEqual(backends["busMatrix"].identity_from, 0)
        self.assertEqual(self.srv.build_backends(False, 6, bus_layer=False,
                                                 identity_from=4)["inputMatrix"].identity_from, 4)

    def test_describe(self):
        spec, modules = self.srv.MatrixBackend("inputMatrix", None, 3, 2, max_db=6.0).describe()
        self.assertEqual((spec.kind, spec.rows, spec.cols, spec.modules), ("matrix", 3, 2, ("level",)))
        self.assertEqual((modules["level"].min, modules["level"].max, modules["level"].default),
                         (-90.0, 6.0, -90.0))

    def test_gain_backend_drives_hw_by_channel(self):
        hw = FakeGainHW()
        b = self.srv.GainBackend("busChannel", hw, 4, max_db=6.0)
        self.assertEqual(b.apply("3", "level", -6.0), -6.0)
        self.assertEqual(hw.writes, [(3, -6.0)])

    def test_gain_seed_is_unity_keeps_stored_and_normalises(self):
        hw = FakeGainHW()
        self.state.set("outputChannel/1/level", -12.0)
        self.state.set("outputChannel/2/level", -120.0)           # an older server's -inf
        self.srv.GainBackend("outputChannel", hw, 3, max_db=6.0).seed_and_push(self.state)
        self.assertEqual(hw.banks, [{0: 0.0, 1: -12.0, 2: -90.0}])  # one bank, one commit
        self.assertEqual(self.state.get("outputChannel/0/level"), 0.0)   # seeded into the store
        self.assertEqual(self.state.get("outputChannel/2/level"), -90.0)

    def test_gain_describe_shares_the_level_module(self):
        spec, modules = self.srv.GainBackend("inputChannel", None, 5, max_db=6.0).describe()
        self.assertEqual((spec.kind, spec.count, spec.modules), ("channels", 5, ("level", "vgroup", "name")))
        _mspec, mmodules = self.srv.MatrixBackend("inputMatrix", None, 5, 5, max_db=6.0).describe()
        self.assertEqual(modules["level"], mmodules["level"])     # one module (D77)

    def test_simulated_bus_layer_builds_one_model(self):
        backends = self.srv.build_backends(False, 6)
        self.assertEqual(list(backends), ["inputChannel", "inputMatrix", "busChannel",
                                          "busMatrix", "outputChannel"])
        model = self.srv.build_model(backends, self.srv.SYSTEM_SETTINGS)
        self.assertEqual(set(model.zones), set(backends))
        self.assertEqual(list(self.srv.build_backends(False, 6, bus_layer=False)), ["inputMatrix"])

    def test_hw_ceiling_comes_from_the_window_geometry(self):
        self.assertAlmostEqual(self.srv.q_ceiling_db(18, 16), 6.02053, places=5)   # Q2.16
        self.assertAlmostEqual(self.srv.q_ceiling_db(24, 16), 42.144, places=3)

    def test_apply_set_goes_through_the_backend_and_echoes_its_value(self):
        """The backend may adjust further (e.g. hardware quantisation): the
        stored value and the echo are the backend's."""
        srv = self.srv

        class Quantising(srv.MatrixBackend):
            def apply(self, index, module, value):
                self.seen = (index, module, value)
                return -6.5

        sent = []

        class Registry:
            lock = threading.RLock()

            def broadcast(self, packet):
                sent.append(packet)

        b = Quantising("inputMatrix", None, 2, 2, max_db=6.0)
        old = srv.BACKENDS.copy(), srv.MODEL
        srv.BACKENDS.clear()
        srv.BACKENDS["inputMatrix"] = b
        srv.MODEL = srv.build_model(srv.BACKENDS, srv.SYSTEM_SETTINGS)
        try:
            srv.apply_set("inputMatrix/1_0/level", -6.4, self.state, Registry(), None, "test")
        finally:
            srv.BACKENDS.clear()
            srv.BACKENDS.update(old[0])
            srv.MODEL = old[1]
        self.assertEqual(b.seen, ("1_0", "level", float32(-6.4)))
        self.assertEqual(self.state.get("inputMatrix/1_0/level"), -6.5)
        self.assertEqual(sent, [encode_message("/mixer/set/inputMatrix/1_0/level", [-6.5])])

    def with_model(self, backend):
        srv = self.srv
        old = srv.BACKENDS.copy(), srv.MODEL
        srv.BACKENDS.clear()
        srv.BACKENDS[backend.zone] = backend
        srv.MODEL = srv.build_model(srv.BACKENDS, srv.SYSTEM_SETTINGS)

        def restore():
            srv.BACKENDS.clear()
            srv.BACKENDS.update(old[0])
            srv.MODEL = old[1]
        self.addCleanup(restore)

    def test_snapshot_and_a_concurrent_set_are_never_interleaved(self):
        """F3, deterministic: the snapshot is slowed down after it has read
        the state; a set that arrives meanwhile must wait, so its echo comes
        after the snapshot (which doesn't contain it)."""
        srv = self.srv
        self.with_model(srv.MatrixBackend("inputMatrix", None, 2, 2, max_db=6.0))
        registry = srv.ClientRegistry("len32")
        server_side, client_side = socket.socketpair()
        self.addCleanup(server_side.close)
        self.addCleanup(client_side.close)
        registry.add(server_side)
        build = srv.MODEL.config

        def slow_config(*args, **kwargs):
            body = build(*args, **kwargs)
            time.sleep(0.4)                 # state already read; the reply not yet sent
            return body
        srv.MODEL.config = slow_config
        snap = threading.Thread(target=srv.reply_config, args=(self.state, registry, server_side, "t"))
        snap.start()
        time.sleep(0.1)
        srv.apply_set("inputMatrix/0_1/level", -6.0, self.state, registry, None, "t")
        snap.join()
        link = TCPLink("unused", 0, timeout=2.0)
        link.sock = client_side
        first, second = link.read_message(), link.read_message()
        self.assertEqual(first.address, "/mixer/set/system/config")
        self.assertNotIn("inputMatrix/0_1/level", json.loads(first.args[0])["values"])
        self.assertEqual((second.address, second.args), ("/mixer/set/inputMatrix/0_1/level", [-6.0]))

    def test_echoes_follow_the_store_order(self):
        """Two changes to one parameter from two threads: the last echo is the
        stored value (apply, store and echo are one step under the lock). The
        first change dawdles between its store and its echo, the window in
        which an unlocked second change would store and echo in between."""
        srv = self.srv
        from mixer_state import MixerState

        class SlowStore(MixerState):
            def set(self, tail, value):
                why = super().set(tail, value)
                if value == -1.0:
                    time.sleep(0.3)
                return why
        self.state = SlowStore("mixer", None, log=lambda m: None)
        self.with_model(srv.MatrixBackend("inputMatrix", None, 2, 2, max_db=6.0))
        registry = srv.ClientRegistry("len32")
        server_side, client_side = socket.socketpair()
        self.addCleanup(server_side.close)
        self.addCleanup(client_side.close)
        registry.add(server_side)
        first = threading.Thread(target=srv.apply_set,
                                 args=("inputMatrix/0_1/level", -1.0, self.state, registry, None, "a"))
        first.start()
        time.sleep(0.1)
        srv.apply_set("inputMatrix/0_1/level", -2.0, self.state, registry, None, "b")
        first.join()
        link = TCPLink("unused", 0, timeout=2.0)
        link.sock = client_side
        echoes = [link.read_message().args[0], link.read_message().args[0]]
        self.assertEqual(echoes[-1], self.state.get("inputMatrix/0_1/level"))

    def test_a_stalled_controller_is_dropped_and_closed(self):
        srv = self.srv
        registry = srv.ClientRegistry("len32")
        registry.SEND_TIMEOUT = 0.2
        stalled, peer = socket.socketpair()
        self.addCleanup(stalled.close)
        self.addCleanup(peer.close)
        registry.add(stalled)
        big = encode_message("/mixer/set/x", ["y" * 60000])
        t0 = time.monotonic()
        for _ in range(200):                 # the peer never reads: buffers fill, sendall times out
            registry.broadcast(big)
            if stalled not in registry.clients:
                break
        self.assertNotIn(stalled, registry.clients)
        self.assertLess(time.monotonic() - t0, 10)
        peer.settimeout(2)                   # and its connection is closed: EOF after the backlog
        while True:
            chunk = peer.recv(1 << 16)
            if not chunk:
                break

    def test_sends_from_two_threads_never_interleave(self):
        """A get reply (reader thread) and a broadcast (another thread) to one
        socket: whole packets, one after the other."""
        srv = self.srv
        registry = srv.ClientRegistry("len32")
        written = []

        class SlowSocket:
            def settimeout(self, t):
                pass

            def sendall(self, data):
                half = len(data) // 2
                written.append(data[:half])
                time.sleep(0.2)              # another thread could write here
                written.append(data[half:])
        sock = SlowSocket()
        registry.add(sock)
        a = encode_message("/mixer/set/a", [1.0])
        b = encode_message("/mixer/set/b", [2.0])
        for first, then in ((lambda: registry.send(sock, a), lambda: registry.broadcast(b)),
                            (lambda: registry.broadcast(b), lambda: registry.send(sock, a))):
            written.clear()
            t = threading.Thread(target=first)
            t.start()
            time.sleep(0.05)
            then()
            t.join()
            stream = b"".join(written)
            self.assertIn(stream, (Len32Framer.frame(a) + Len32Framer.frame(b),
                                   Len32Framer.frame(b) + Len32Framer.frame(a)))

    def test_reply_config_carries_the_firmware_and_goes_to_the_requester(self):
        srv = self.srv
        self.with_model(srv.MatrixBackend("inputMatrix", None, 2, 2, max_db=6.0))
        old = srv.FIRMWARE
        srv.FIRMWARE = "abc1234-dirty"
        self.addCleanup(setattr, srv, "FIRMWARE", old)
        registry = srv.ClientRegistry("len32")
        server_side, client_side = socket.socketpair()
        self.addCleanup(server_side.close)
        self.addCleanup(client_side.close)
        srv.reply_config(self.state, registry, server_side, "t")
        link = TCPLink("unused", 0, timeout=2.0)
        link.sock = client_side
        self.assertEqual(json.loads(link.read_message().args[0])["firmware"], "abc1234-dirty")

    def test_firmware_version_sources(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        self.assertEqual(self.srv.firmware_version(d), "dev")          # no VERSION, not a checkout
        with open(os.path.join(d, "VERSION"), "w") as f:
            f.write("071aadb-dirty\n")
        self.assertEqual(self.srv.firmware_version(d), "071aadb-dirty")
        in_checkout = subprocess.run(["git", "rev-parse", "--git-dir"], cwd=HERE,
                                     capture_output=True).returncode == 0
        if in_checkout:                       # a copy outside git (e.g. the board) has no git
            self.assertNotEqual(self.srv.firmware_version(HERE), "dev")

    def test_unset_parameter_reads_as_its_default(self):
        from mixer_params import ModuleSpec, Param
        p = Param("inputChannel", "0", "level", ModuleSpec("float", default=-12.0))
        self.assertEqual(self.srv.current_value(p, self.state), -12.0)
        self.state.set("inputChannel/0/level", -3.0)
        self.assertEqual(self.srv.current_value(p, self.state), -3.0)


APP_ZONES = {"inputChannel": "channel", "busChannel": "channel", "outputChannel": "channel",
             "inputMatrix": "matrix", "busMatrix": "matrix", "system": "system"}
APP_TYPES = ("float", "int", "bool", "enum", "string")


def app_config_problems(d):
    """Everything the app's DeviceConfig (StudioRunnerProtocol/DeviceConfig.swift,
    controller repo, 2026-10-04) would throw on or warn about, ported rule by
    rule, so the reply can be checked without a Mac. Empty = decodes cleanly."""
    problems = []

    def is_int(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool) and float(v).is_integer()

    def is_num(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool)

    def module(ctx, m):
        if not isinstance(m, dict):
            return problems.append(f"{ctx} is not an object")
        t = m.get("type")
        if t is None:
            problems.append(f"{ctx} has no type")
        elif t not in APP_TYPES:
            problems.append(f"{ctx} has unknown type {t!r}")
        for key in ("min", "max"):
            if key in m and not is_num(m[key]):
                problems.append(f"{ctx}.{key} not numeric")
        if is_num(m.get("min")) and is_num(m.get("max")) and m["min"] > m["max"]:
            problems.append(f"{ctx} min > max")
        if "default" in m:
            numeric_type = t != "string"
            v = m["default"]
            numeric_value = is_num(v) or isinstance(v, bool)
            if isinstance(v, (dict, list)) or v is None or numeric_type != numeric_value:
                problems.append(f"{ctx}.default doesn't match its type")
        if t == "enum" and not m.get("options"):
            problems.append(f"{ctx} is an enum without options")

    def parses(key):
        parts = key.split("/")
        while parts and parts[-1] == "":
            parts.pop()
        if len(parts) < 2 or "" in parts or parts[0] not in APP_ZONES:
            return False
        kind = APP_ZONES[parts[0]]
        if kind == "system":
            return len(parts) <= 3
        if len(parts) != 3:
            return False
        idx = parts[1].split("_") if kind == "matrix" else [parts[1]]
        return len(idx) == (2 if kind == "matrix" else 1) and all(
            i and len(i) <= 9 and i.isascii() and i.isdigit() for i in idx)

    v = d.get("schemaVersion")
    if not is_int(v) or v < 1 or v > 1:
        problems.append(f"schemaVersion {v!r} (the app supports 1)")
    for key in ("deviceName", "firmware"):
        if key in d and not isinstance(d[key], str):
            problems.append(f"{key} not a string")
    if "sampleRate" in d and not is_int(d["sampleRate"]):
        problems.append("sampleRate not an integer")
    modules = d.get("modules")
    if not isinstance(modules, dict):
        problems.append("modules missing or not an object")
        modules = {}
    for name, m in modules.items():
        module(f"modules.{name}", m)
    zones = d.get("zones")
    if not isinstance(zones, dict):
        problems.append("zones missing or not an object")
        zones = {}
    for name, z in zones.items():
        kind = APP_ZONES.get(name)
        if kind in (None, "system"):
            problems.append(f"zone {name!r} ignored")
            continue
        dims = ("count",) if kind == "channel" else ("rows", "cols")
        limit = 1024 if kind == "channel" else 256
        for dim in dims:
            if not (is_int(z.get(dim)) and 0 <= z[dim] <= limit):
                problems.append(f"zones.{name}.{dim} invalid")
        mods = z.get("modules")
        if mods is None:
            problems.append(f"zones.{name} has no modules")
        elif not isinstance(mods, list):
            problems.append(f"zones.{name}.modules not an array")
        else:
            for m in mods:
                if not (isinstance(m, str) and m and "/" not in m):
                    problems.append(f"zones.{name} module name {m!r}")
                elif m not in modules:
                    problems.append(f"zones.{name} lists {m!r} without metadata")
    system = d.get("system", {})
    if not isinstance(system, dict):
        problems.append("system not an object")
        system = {}
    for name, m in system.items():
        module(f"system.{name}", m)
    if isinstance(system.get("deviceName"), dict) and system["deviceName"].get("type") != "string":
        problems.append("system.deviceName must be a string")
    values = d.get("values", {})
    if not isinstance(values, dict):
        problems.append("values not an object")
        values = {}
    for key, value in values.items():
        if not parses(key):
            problems.append(f"values key {key!r} doesn't parse")
        elif isinstance(value, (dict, list)) or value is None:
            problems.append(f"values[{key!r}] not a number, bool or string")
    return problems


# MockProfile.hardwareToday (MockDevice/MockProfile.swift, controller repo),
# as its configJSON writes it: the shape the app was built against.
HARDWARE_TODAY_LEVEL = {"type": "float", "unit": "dB", "min": -90, "max": 6.02, "default": -90,
                        "group": "level", "linked": True}
VGROUP = {"type": "int", "min": 0, "max": 64, "default": 0, "group": "link"}   # Phase 14
NAME = {"type": "string", "default": "", "maxLength": 32}                       # Phase 14
PORT_LABELS = ([f"Analog {i}" for i in range(1, 5)] + [f"USB {i}" for i in range(1, 9)]
               + [f"AVB {i}" for i in range(1, 9)])                            # Phase 15, CS4
PATCH = {"type": "enum", "default": 0.0, "group": "patch",
         "options": [float(v) for v in range(21)], "optionLabels": ["None"] + PORT_LABELS}


class Config(ServerCase):
    """F1: get/system/config -> set/system/config "<json>", to the requester only."""

    SERVER_ARGS = ["--mixer-name", "FOH"]

    def config(self, link, address="/mixer/get/system/config"):
        link.send_message(address)
        m = link.read_message()
        self.assertEqual(m.address, "/FOH/set/system/config")
        self.assertIsInstance(m.args[0], str)
        return json.loads(m.args[0])

    def test_reply_decodes_in_the_app_without_warnings(self):
        d = self.config(self.tcp())
        self.assertEqual(app_config_problems(d), [])

    def test_shape_matches_the_mocks_standard_profile(self):
        """Phase 12: the five zones of MockProfile.standard (8 there, 4 here),
        level only, the shared level module as the large profiles have it
        (default off, D77), and the reset state listed explicitly: both
        diagonals and every channel level at 0 dB."""
        d = self.config(self.tcp())
        self.assertEqual(set(d), {"schemaVersion", "deviceName", "firmware", "sampleRate", "zones",
                                  "modules", "system", "values", "capabilities"})
        self.assertEqual(d["capabilities"], ["snapshots"])                 # Phase 14
        ch = {"count": 4, "modules": ["level", "vgroup", "name"]}          # vgroup, name: Phase 14
        mx = {"rows": 4, "cols": 4, "modules": ["level"]}
        self.assertEqual(d["zones"], {"inputChannel": dict(ch, modules=["level", "source", "vgroup", "name"]),
                                      "inputMatrix": mx, "busChannel": ch, "busMatrix": mx,
                                      "outputChannel": dict(ch, modules=["level", "destination",
                                                                         "vgroup", "name"])})  # Phase 15
        self.assertEqual(list(d["zones"]), ["inputChannel", "inputMatrix", "busChannel",
                                            "busMatrix", "outputChannel"])   # signal-flow order
        self.assertEqual(set(d["modules"]), {"level", "vgroup", "name", "source", "destination"})
        self.assertEqual(d["modules"]["name"], NAME)
        self.assertEqual(d["modules"]["vgroup"], VGROUP)                   # not linked itself
        self.assertEqual(d["modules"]["source"], PATCH)                    # Phase 15
        self.assertEqual(d["modules"]["destination"], PATCH)
        self.assertEqual({k: d["system"][k] for k in ("inputCount", "busCount", "outputCount")},
                         {k: {"type": "int", "min": 1, "max": 4, "default": 4}
                          for k in ("inputCount", "busCount", "outputCount")})
        level = d["modules"]["level"]
        self.assertEqual(set(level), set(HARDWARE_TODAY_LEVEL))
        for key in ("type", "unit", "min", "default", "group", "linked"):
            self.assertEqual(level[key], HARDWARE_TODAY_LEVEL[key], key)
        self.assertAlmostEqual(level["max"], 6.02, places=2)     # the real ceiling, 6.0205
        self.assertEqual(d["values"], {**{f"inputMatrix/{i}_{i}/level": 0.0 for i in range(4)},
                                       **{f"busMatrix/{i}_{i}/level": 0.0 for i in range(4)},
                                       **{f"{z}/{n}/level": 0.0 for z in ("inputChannel", "busChannel",
                                                                          "outputChannel")
                                          for n in range(4)},
                                       "system/deviceName": "FOH"})
        logged = re.search(r"Firmware (\S+);", self.log())      # sources: test_firmware_version_sources
        self.assertEqual(d["firmware"], logged.group(1))

    def test_requester_only_and_every_address_form(self):
        a, b = self.tcp(), self.tcp()
        self.get(b, "system/deviceName")
        for address in ("/mixer/get/system/config", "/FOH/get/system/config", "/FOH/get/system/config/"):
            self.config(a, address)
        silent(self, b)

    def test_values_follow_changes_and_rename(self):
        c = self.tcp()
        foh = XP.replace("/mixer/", "/FOH/")
        self.roundtrip(c, foh.format(0, 0), -90.0)        # back to the default: leaves values
        self.roundtrip(c, foh.format(1, 2), -6.0)
        c.send_message("/mixer/set/system/deviceName", ["Stage"])
        c.read_message()
        c.send_message("/mixer/get/system/config")
        d = json.loads(c.read_message().args[0])
        self.assertEqual(d["deviceName"], "Stage")
        self.assertEqual(d["values"]["system/deviceName"], "Stage")
        self.assertEqual(d["values"]["inputMatrix/1_2/level"], -6.0)
        self.assertNotIn("inputMatrix/0_0/level", d["values"])

    def test_config_is_not_a_setting_and_udp_gets_nothing(self):
        c = self.tcp()
        c.send_message("/mixer/set/system/config", ["{}"])
        m = c.read_message()
        self.assertEqual((m.address, m.args[0]), ("/FOH/error", "system/config"))
        self.udp().send_message("/mixer/get/system/config")
        silent(self, c)



class ConfigWithoutBusLayer(Config):
    """A bitstream from before Phase 12 (simulated: --no-bus-layer): the
    config is exactly what the app's MockProfile.hardwareToday was built
    against, one matrix, input -> output."""

    SERVER_ARGS = ["--mixer-name", "FOH", "--no-bus-layer"]

    def test_shape_matches_the_mocks_standard_profile(self):
        self.skipTest("the five-zone shape is Config's")

    def test_shape_matches_the_mocks_hardware_today_profile(self):
        d = self.config(self.tcp())
        self.assertEqual(d["zones"], {"inputMatrix": {"rows": 4, "cols": 4, "modules": ["level"]}})
        self.assertEqual(d["values"], {**{f"inputMatrix/{i}_{i}/level": 0.0 for i in range(4)},
                                       "system/deviceName": "FOH"})   # unity diagonal, as the profile


class BusLayer(ServerCase):
    """Phase 12: the channel zones and busMatrix take sets like inputMatrix:
    applied with the same rules, echoed, stored under their own zones."""

    def state(self):
        time.sleep(0.6)
        with open(os.path.join(self.dir, "state.json")) as f:
            return json.load(f)

    def test_sets_echo_and_store_in_every_zone(self):
        a, b = self.tcp(), self.tcp()
        self.get(b, "system/deviceName")                        # b is registered before a sets
        cases = [("inputChannel/2/level", -6.0, -6.0), ("busChannel/3/level", 50.0, float32(SIM_MAX_DB)),
                 ("outputChannel/0/level", -200.0, -90.0), ("busMatrix/1_3/level", -12.5, -12.5)]
        for tail, sent, applied in cases:
            self.assertEqual(self.roundtrip(a, f"/mixer/set/{tail}", sent), applied, tail)
            m = b.read_message()                                    # broadcast to everyone
            self.assertEqual((m.address, m.args), (f"/mixer/set/{tail}", [applied]))
        tree = self.state()
        self.assertEqual(tree["inputChannel"]["2"], {"level": -6.0})
        self.assertEqual(tree["busChannel"]["3"], {"level": float32(SIM_MAX_DB)})
        self.assertEqual(tree["outputChannel"]["0"], {"level": -90.0})
        self.assertEqual(tree["busMatrix"]["1_3"], {"level": -12.5})

    def test_channel_index_is_canonical(self):
        c = self.tcp()
        c.send_message("/mixer/set/busChannel/02/level", [-3.0])
        m = c.read_message()
        self.assertEqual((m.address, m.args), ("/mixer/set/busChannel/2/level", [-3.0]))


class StateFromBeforeBuses(ServerCase):
    """Decision L3: a state file from before Phase 12 (inputMatrix only, then
    input -> output) loads unchanged onto the bus layer. Its crosspoints keep
    their values; the bus matrix is seeded at identity and every level at
    0 dB, so input -> bus k -> output k sounds as input -> output k did."""

    STATE = {"system": {"deviceName": "mixer"},
             "inputMatrix": {f"{i}_{o}": {"level": (0.0 if i == o else -90.0)}
                             for i in range(4) for o in range(4)}}

    def setUp(self):
        self.STATE = json.loads(json.dumps(self.STATE))
        self.STATE["inputMatrix"]["1_0"] = {"level": -6.0}        # in 1 -> out 0, as on the bench
        self.STATE["inputMatrix"]["0_0"] = {"level": -90.0}
        super().setUp()

    def test_old_crosspoints_kept_and_the_rest_seeded_transparent(self):
        c = self.tcp()
        self.assertEqual(self.get(c, "inputMatrix/1_0/level"), -6.0)
        self.assertEqual(self.get(c, "inputMatrix/0_0/level"), -90.0)
        self.assertEqual(self.get(c, "inputMatrix/2_2/level"), 0.0)
        for b in range(4):
            for o in range(4):
                self.assertEqual(self.get(c, f"busMatrix/{b}_{o}/level"), 0.0 if b == o else -90.0)
        for zone in ("inputChannel", "busChannel", "outputChannel"):
            self.assertEqual(self.get(c, f"{zone}/3/level"), 0.0)
        time.sleep(0.6)
        with open(os.path.join(self.dir, "state.json")) as f:
            tree = json.load(f)
        self.assertEqual(tree["inputMatrix"]["1_0"], {"level": -6.0})   # the format didn't change
        self.assertEqual(set(tree), {"system", "inputMatrix", "inputChannel", "busChannel",
                                     "busMatrix", "outputChannel"})


class Metering(ServerCase):
    """Phase 13 (F4) end to end with the synthetic source: subscribe over TCP,
    datagrams on a UDP socket, decoded as the app's UDPMeterListener does.
    The synthetic peak of channel c is -12 - 3*(c % 6) dBFS + the level."""

    SERVER_ARGS = ["--meter-source", "synthetic"]
    MASK_IN_OUT = 0b101

    def listener(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        s.settimeout(0.2)
        self.addCleanup(s.close)
        return s

    def collect(self, sock, seconds):
        """{zone: [(seq, [centibels...]), ...]} received for `seconds`."""
        from osc_codec import decode_packet
        out, end = {}, time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                data = sock.recv(65535)
            except socket.timeout:
                continue
            for m in decode_packet(data):
                self.assertEqual(m.address.rsplit("/", 1)[0], "/mixer/meter")
                blob = m.args[0]
                self.assertIsInstance(blob, (bytes, bytearray))
                seq = struct.unpack(">I", blob[:4])[0]
                vals = list(struct.unpack(f">{(len(blob) - 4) // 2}h", blob[4:]))
                out.setdefault(m.address.rsplit("/", 1)[1], []).append((seq, vals))
        return out

    def subscribe(self, link, port, rate=30, mask=MASK_IN_OUT):
        link.send_message("/mixer/meter/subscribe", [port, rate, mask])

    def test_stream_zones_blob_sequence_and_values(self):
        c, u = self.tcp(), self.listener()
        self.subscribe(c, u.getsockname()[1])
        got = self.collect(u, 1.0)
        self.assertEqual(set(got), {"inputChannel", "outputChannel"})   # bit 1 (bus) not asked for
        ins = got["inputChannel"]
        self.assertTrue(20 <= len(ins) <= 35, len(ins))                  # ~30 Hz
        self.assertEqual([s for s, _v in ins], list(range(len(ins))))    # 0, 1, 2, ... per zone
        self.assertEqual(ins[0][1], [-1200, -1500, -1800, -2100])        # N = 4, levels at 0 dB
        self.assertEqual([s for s, _v in got["outputChannel"]][:3], [0, 1, 2])

    def test_blobs_follow_the_channel_count(self):
        """Phase 15 (standard "Channel counts"): at once, before any refetch."""
        c, u = self.tcp(), self.listener()
        self.subscribe(c, u.getsockname()[1], mask=0b001)
        self.assertEqual(len(self.collect(u, 0.3)["inputChannel"][-1][1]), 4)
        c.send_message("/mixer/set/system/inputCount", [2])
        self.assertEqual(c.read_message().address, "/mixer/set/system/inputCount")
        self.collect(u, 0.1)                                            # in flight
        self.assertEqual({len(v) for _s, v in self.collect(u, 0.3)["inputChannel"]}, {2})

    def test_meters_follow_the_level(self):
        c, u = self.tcp(), self.listener()
        self.roundtrip(c, "/mixer/set/outputChannel/2/level", -90.0)
        self.roundtrip(c, "/mixer/set/outputChannel/1/level", -6.0)
        self.subscribe(c, u.getsockname()[1], mask=0b100)
        vals = self.collect(u, 0.3)["outputChannel"][-1][1]
        self.assertEqual(vals[2], -32768)                                # off: silence
        self.assertEqual(vals[1], -1500 - 600)

    def test_floats_with_integral_values_are_accepted(self):
        c, u = self.tcp(), self.listener()
        c.send_message("/mixer/meter/subscribe", [float(u.getsockname()[1]), 30.0, 1.0])
        self.assertIn("inputChannel", self.collect(u, 0.3))
        silent(self, c)                                                  # no error reply

    def test_malformed_subscribes_get_an_error_reply(self):
        c = self.tcp()
        for args in ([9000, 30], ["9000", 30, 1], [0, 30, 1], [70000, 30, 1], [9000.5, 30, 1],
                     [9000, 30, 1, 1], [9000, 30, float("nan")]):
            c.send_message("/mixer/meter/subscribe", args)
            m = c.read_message()
            self.assertEqual((m.address, m.args[0]), ("/mixer/error", "meter/subscribe"), args)

    def test_rate_is_clamped(self):
        c, u = self.tcp(), self.listener()
        self.subscribe(c, u.getsockname()[1], rate=10000, mask=1)
        n = len(self.collect(u, 1.0).get("inputChannel", []))
        self.assertTrue(90 <= n <= 125, n)                               # 120 Hz, not 10 kHz

    def test_mask_0_unsubscribes_and_closing_tcp_ends_it(self):
        c, u = self.tcp(), self.listener()
        self.subscribe(c, u.getsockname()[1])
        self.assertTrue(self.collect(u, 0.3))
        self.subscribe(c, u.getsockname()[1], mask=0)
        self.collect(u, 0.2)                                             # drain what's in flight
        self.assertEqual(self.collect(u, 0.4), {})
        d, v = self.tcp(), self.listener()
        self.subscribe(d, v.getsockname()[1])
        self.assertTrue(self.collect(v, 0.3))
        d.close()
        self.collect(v, 0.2)
        self.assertEqual(self.collect(v, 0.4), {})

    def test_two_subscribers_each_get_their_own_sequences(self):
        a, ua = self.tcp(), self.listener()
        b, ub = self.tcp(), self.listener()
        self.subscribe(a, ua.getsockname()[1], rate=30, mask=1)
        first_a = self.collect(ua, 0.3)["inputChannel"]                  # a's stream so far
        self.subscribe(b, ub.getsockname()[1], rate=10, mask=1)
        gb = self.collect(ub, 0.5)["inputChannel"]
        later_a = self.collect(ua, 0.01)["inputChannel"]                 # what a got meanwhile
        self.assertEqual(first_a[0][0], 0)
        self.assertEqual(gb[0][0], 0)                                    # b starts at 0 ...
        self.assertEqual(later_a[0][0], first_a[-1][0] + 1)              # ... a just continues
        self.assertGreater(len(later_a), len(gb))                        # 30 Hz vs 10 Hz


class NoMeters(ServerCase):
    """No meter source (the simulator's default; an older bitstream): a
    subscribe is answered with an error reply."""

    def test_subscribe_refused(self):
        c = self.tcp()
        c.send_message("/mixer/meter/subscribe", [9000, 30, 7])
        m = c.read_message()
        self.assertEqual(m.args[:1], ["meter/subscribe"])
        self.assertIn("no meters", m.args[1])


class MeterSourceFlag(unittest.TestCase):
    def test_synthetic_refused_with_hw(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, "osc_mixer_server.py"),
                            "--tcp-port", "1", "--udp-port", "2", "--hw",
                            "--meter-source", "synthetic"],
                           cwd=HERE, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2)
        self.assertIn("decision M8", r.stderr)


class Ping(ServerCase):
    """F7, amendment H: /<name>/ping <int> -> /<name>/pong <int>, to the sender."""

    SERVER_ARGS = ["--mixer-name", "FOH"]

    def test_pong_carries_the_token_to_the_sender_only(self):
        a, b = self.tcp(), self.tcp()
        self.get(b, "system/deviceName")
        for root, token in (("mixer", 7), ("FOH", -2147483648), ("FOH", 2147483647), ("mixer", 0)):
            a.send_message(f"/{root}/ping", [token])
            m = a.read_message()
            self.assertEqual((m.address, m.args), ("/FOH/pong", [token]), root)
        silent(self, b)

    def test_pong_is_an_osc_int(self):
        c = self.tcp()
        c.send_message("/mixer/ping", [42])
        c.sock.settimeout(2)
        self.assertEqual(c.sock.recv(100), Len32Framer.frame(encode_message("/FOH/pong", [42])))

    def test_anything_else_is_ignored(self):
        c = self.tcp()
        for args in ([], [1.0], ["7"], [1, 2]):
            c.send_message("/mixer/ping", args)
        c.send_packet(osc_string("/mixer/ping") + osc_string(",T"))   # an OSC true, not an int
        c.send_message("/mixer/ping/x", [1])
        self.udp().send_message("/mixer/ping", [5])
        silent(self, c)
        c.send_message("/mixer/ping", [9])                     # still answering
        self.assertEqual(c.read_message().args, [9])


class Discovery(ServerCase):
    """F5 through the server: the advertisement follows the name (the file
    only; resolved itself is the board's, checked on the bench)."""

    def setUp(self):
        self.dnssd = os.path.join(tempfile.mkdtemp(prefix="dnssd-"), "studiorunner.dnssd")
        self.addCleanup(shutil.rmtree, os.path.dirname(self.dnssd), True)
        self.SERVER_ARGS = ["--mixer-name", "FOH", "--tcp-framing", "len32", "--advertise", "dnssd",
                            "--dnssd-file", self.dnssd, "--dnssd-reload", ""]
        super().setUp()

    def advertised(self):
        with open(self.dnssd) as f:
            return [l for l in f.read().splitlines() if l.startswith(("Name=", "Port=", "TxtText="))]

    def test_advertised_at_startup_and_after_a_rename_not_after_a_refused_one(self):
        self.assertEqual(self.advertised(), ["Name=FOH", f"Port={self.tcp_port}",
                                             "TxtText=name=FOH v=1 framing=len32"])
        c = self.tcp()
        c.send_message("/mixer/set/system/deviceName", ["two words"])
        c.read_message()
        c.read_message()                                    # name + error: refused
        self.assertEqual(self.advertised()[0], "Name=FOH")
        c.send_message("/mixer/set/system/deviceName", ["Stage"])
        c.read_message()
        self.get(c, "system/deviceName")                    # the rename is done by now
        self.assertEqual(self.advertised()[0], "Name=Stage")
        self.assertIn("TxtText=name=Stage v=1 framing=len32", self.advertised())



class DiscoveryOffByDefault(ServerCase):
    def test_nothing_advertised_without_the_option(self):
        c = self.tcp()
        self.get(c, "system/deviceName")                    # started and serving
        self.assertNotIn("Discovery:", self.log())


class SnapshotOrdering(ServerCase):
    """F3, end to end: one controller sets values in a tight loop while others
    connect and sync. Every set a syncing controller receives after its
    snapshot must be newer than the snapshot, and snapshot + later sets must
    end on the mixer's value."""

    SERVER_ARGS = ["--matrix-size", "4"]
    PATH = "inputMatrix/0_1/level"

    def test_snapshot_never_older_than_what_follows(self):
        stop = threading.Event()
        sent = []

        w = self.tcp()

        def discard_echoes():             # the writer must read, or the server drops it
            while not stop.is_set():
                try:
                    w.read_message(timeout=0.2)
                except (TimeoutError, OSError):
                    pass

        def writer():
            i = 0
            while not stop.is_set() and i < 9000:
                w.send_message(f"/mixer/set/{self.PATH}", [-89.0 + i * 0.01])   # strictly increasing
                sent.append(i)
                i += 1

        threading.Thread(target=discard_echoes, daemon=True).start()
        t = threading.Thread(target=writer, daemon=True)
        t.start()
        try:
            for _ in range(15):
                c = self.tcp()
                c.send_message("/mixer/get/system/config")
                while True:                                   # sets before the snapshot: dropped
                    m = c.read_message(timeout=5)
                    if m.address.endswith("/set/system/config"):
                        break
                snap = json.loads(m.args[0])["values"].get(self.PATH, -90.0)
                later = []
                deadline = time.monotonic() + 0.05
                while time.monotonic() < deadline:
                    try:
                        later.append(c.read_message(timeout=0.05).args[0])
                    except TimeoutError:
                        break
                for v in later:
                    self.assertGreaterEqual(v, snap, f"a set older than the snapshot ({v} < {snap})")
                c.close()
        finally:
            stop.set()
            t.join(timeout=10)
        self.assertGreater(len(sent), 100, "the writer barely ran")
        final = self.tcp()
        expected = self.get(final, self.PATH)
        c = self.tcp()
        c.send_message("/mixer/get/system/config")
        self.assertEqual(json.loads(c.read_message().args[0])["values"][self.PATH], expected)


class FactoryName(ServerCase):
    """No name given anywhere: the mixer is 'mixer' (C6) and can be renamed."""

    def test_factory_name_is_mixer_and_renaming_away_works(self):
        c = self.tcp()
        self.assertEqual(self.get(c, "system/deviceName"), "mixer")
        c.send_message("/mixer/set/system/deviceName", ["FOH"])
        self.assertEqual(c.read_message().address, "/mixer/set/system/deviceName")
        c.send_message("/mixer/get/system/deviceName")               # alias still works
        self.assertEqual(c.read_message().address, "/FOH/set/system/deviceName")


class StoredInvalidName(ServerCase):
    """A name stored before the rules existed loads as it is (C6)."""

    STATE = {"system": {"deviceName": "FOH mixer"}}

    def test_loads_and_answers(self):
        c = self.tcp()
        c.send_message("/mixer/get/system/deviceName")
        m = c.read_message()
        self.assertEqual((m.address, m.args), ("/FOH mixer/set/system/deviceName", ["FOH mixer"]))


class VGroups(ServerCase):
    """Phase 14 (standard "Virtual groups"), over TCP on the simulated 4 x 4 x 4
    mixer (reset: identity matrices, 0 dB levels, no groups)."""

    def pair(self):
        a, b = self.tcp(), self.tcp()
        for link in (a, b):
            self.get(link, "inputChannel/0/level")
        return a, b

    def group(self, link, zone, channels, g):
        for ch in channels:
            self.roundtrip(link, f"/mixer/set/{zone}/{ch}/vgroup", g)

    def echoes(self, link, address, value):
        """Set, then every echo up to a get's answer: [(tail, value), ...] in order."""
        link.send_message(address, [value])
        link.send_message("/mixer/get/system/deviceName")
        out = []
        while True:
            m = link.read_message()
            if m.address == "/mixer/set/system/deviceName":
                return out
            out.append((m.address[len("/mixer/set/"):], m.args[0]))

    def test_channels_link_absolutely_and_the_requested_one_is_echoed_first(self):
        a, b = self.pair()
        self.group(a, "inputChannel", (1, 3), 2)
        for _ in range(2):
            b.read_message()
        got = self.echoes(a, "/mixer/set/inputChannel/3/level", -6.0)
        self.assertEqual(got, [("inputChannel/3/level", -6.0), ("inputChannel/1/level", -6.0)])
        self.assertEqual([b.read_message().address for _ in range(2)],
                         ["/mixer/set/inputChannel/3/level", "/mixer/set/inputChannel/1/level"])
        self.assertEqual(self.get(a, "inputChannel/0/level"), 0.0)        # not in the group
        self.assertEqual(self.get(a, "inputChannel/2/level"), 0.0)
        got = self.echoes(a, "/mixer/set/inputChannel/1/level", 50.0)     # clamped, all the same
        self.assertEqual(got, [("inputChannel/1/level", float32(SIM_MAX_DB)),
                               ("inputChannel/3/level", float32(SIM_MAX_DB))])

    def test_joining_and_vgroup_itself_change_nothing_else(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/busChannel/0/level", -10.0)
        self.roundtrip(a, "/mixer/set/busChannel/2/level", -3.0)
        self.assertEqual(self.echoes(a, "/mixer/set/busChannel/0/vgroup", 5),
                         [("busChannel/0/vgroup", 5.0)])
        self.assertEqual(self.echoes(a, "/mixer/set/busChannel/2/vgroup", 5),
                         [("busChannel/2/vgroup", 5.0)])                  # joining: no other change
        self.assertEqual((self.get(a, "busChannel/0/level"), self.get(a, "busChannel/2/level")),
                         (-10.0, -3.0))
        self.assertEqual(self.echoes(a, "/mixer/set/busChannel/2/level", -4.0),
                         [("busChannel/2/level", -4.0), ("busChannel/0/level", -4.0)])
        self.assertEqual(self.echoes(a, "/mixer/set/busChannel/0/vgroup", 0),   # leaving: itself only
                         [("busChannel/0/vgroup", 0.0)])
        self.assertEqual(self.get(a, "busChannel/2/vgroup"), 5.0)

    def test_groups_are_per_zone(self):
        a = self.tcp()
        self.group(a, "inputChannel", (0, 1), 1)
        self.group(a, "outputChannel", (2, 3), 1)                         # the same number
        self.assertEqual(self.echoes(a, "/mixer/set/inputChannel/0/level", -2.0),
                         [("inputChannel/0/level", -2.0), ("inputChannel/1/level", -2.0)])
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/3/level", -1.0),
                         [("outputChannel/3/level", -1.0), ("outputChannel/2/level", -1.0)])

    def test_crosspoints_never_link(self):
        """User, 2026-10-08: grouped channels stay independently routable, so
        a stereo pair can go to different buses (not be summed). Every
        grouping of rows and columns: only the crosspoint itself changes."""
        a = self.tcp()
        self.group(a, "inputChannel", (0, 1), 1)
        self.assertEqual(self.echoes(a, XP.format(0, 2), -6.0), [("inputMatrix/0_2/level", -6.0)])
        self.group(a, "busChannel", (2, 3), 1)
        self.assertEqual(self.echoes(a, XP.format(0, 2), -12.0), [("inputMatrix/0_2/level", -12.0)])
        self.assertEqual(self.echoes(a, XP.format(3, 3), -3.0), [("inputMatrix/3_3/level", -3.0)])
        self.group(a, "outputChannel", (0, 1), 2)
        self.assertEqual(self.echoes(a, "/mixer/set/busMatrix/2_0/level", -6.0),
                         [("busMatrix/2_0/level", -6.0)])
        self.assertEqual((self.get(a, "inputMatrix/1_2/level"), self.get(a, "inputMatrix/1_3/level"),
                          self.get(a, "busMatrix/3_1/level")), (-90.0, -90.0, -90.0))

    def test_udp_sets_link_too(self):
        a, u = self.tcp(), self.udp()
        self.group(a, "outputChannel", (0, 1), 3)
        u.send_message("/mixer/set/outputChannel/0/level", [-7.0])
        self.assertEqual([a.read_message().address for _ in range(2)],
                         ["/mixer/set/outputChannel/0/level", "/mixer/set/outputChannel/1/level"])

    def test_refused_set_changes_no_member(self):
        a = self.tcp()
        self.group(a, "inputChannel", (0, 1), 1)
        a.send_message("/mixer/set/inputChannel/0/level", ["loud"])
        self.assertEqual(a.read_message().address, "/mixer/error")
        self.assertEqual(self.get(a, "inputChannel/1/level"), 0.0)

    def test_snapshots_carry_groups_and_recall_doesnt_link(self):
        a = self.tcp()
        self.group(a, "inputChannel", (0, 1), 1)
        snap = {"snapshotVersion": 1, "values": {"inputChannel/0/level": -5.0,
                                                 "inputChannel/1/level": -20.0}}
        a.send_message("/mixer/snapshot/apply", [json.dumps(snap)])
        while a.read_message().address != "/mixer/snapshot/loaded":
            pass
        self.assertEqual((self.get(a, "inputChannel/0/level"), self.get(a, "inputChannel/1/level")),
                         (-5.0, -20.0))
        a.send_message("/mixer/snapshot/fetch")
        values = json.loads(a.read_message().args[1])["values"]
        self.assertEqual((values["inputChannel/0/vgroup"], values["inputChannel/2/vgroup"]), (1.0, 0.0))


class ChannelNames(ServerCase):
    """Phase 14: a nickname per channel ('name', string, at most 32 UTF-8
    bytes, "" = none), synced and stored like any parameter, never linked."""

    def test_set_echo_get_and_utf8(self):
        a, b = self.tcp(), self.tcp()
        self.get(b, "inputChannel/0/name")                          # b registered
        self.assertEqual(self.get(a, "busChannel/2/name"), "")      # none yet
        self.assertEqual(self.roundtrip(a, "/mixer/set/busChannel/2/name", "Drums bus é"), "Drums bus é")
        self.assertEqual(b.read_message().args, ["Drums bus é"])    # everyone hears it
        self.assertEqual(self.get(a, "busChannel/2/name"), "Drums bus é")
        self.assertEqual(self.roundtrip(a, "/mixer/set/busChannel/2/name", ""), "")   # cleared

    def test_refused_names_change_nothing(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/outputChannel/1/name", "Mon L")
        for bad in ("x" * 33, "é" * 17, "tab\there", "new\nline", 5.0):
            a.send_message("/mixer/set/outputChannel/1/name", [bad])
            m = a.read_message()
            self.assertEqual((m.address, m.args[0]), ("/mixer/error", "outputChannel/1/name"), repr(bad))
        self.assertEqual(self.get(a, "outputChannel/1/name"), "Mon L")
        self.assertEqual(self.roundtrip(a, "/mixer/set/outputChannel/1/name", "x" * 32), "x" * 32)

    def test_names_dont_link_and_snapshots_carry_them(self):
        a = self.tcp()
        for ch in (0, 1):
            self.roundtrip(a, f"/mixer/set/inputChannel/{ch}/vgroup", 1)
        self.roundtrip(a, "/mixer/set/inputChannel/0/name", "Kick")
        self.assertEqual(self.get(a, "inputChannel/1/name"), "")    # not linked
        a.send_message("/mixer/snapshot/fetch")
        values = json.loads(a.read_message().args[1])["values"]
        self.assertEqual((values["inputChannel/0/name"], values["inputChannel/1/name"]), ("Kick", ""))


class Snapshots(ServerCase):
    """Phase 14 (standard "Snapshots"), end to end over TCP. The simulated
    mixer is 4 x 4 x 4: 76 parameters (3 x 4 channels x level, vgroup, name;
    4 sources, 4 destinations (Phase 15); 2 x 16 crosspoints), reset state =
    identity matrices, 0 dB levels, no groups, no names, nothing patched."""

    N_PARAMS = 76

    def pair(self):
        """Two controllers, both registered: a get is answered only once the
        server has the connection, so neither can miss a broadcast."""
        a, b = self.tcp(), self.tcp()
        for link in (a, b):
            self.get(link, "inputChannel/0/level")
        return a, b

    def snap(self, link, request, *args):
        link.send_message(f"/mixer/snapshot/{request}", list(args))

    def listed(self, link):
        m = link.read_message()
        self.assertEqual(m.address, "/mixer/snapshot/list")
        return json.loads(m.args[0])

    def error(self, link, path):
        m = link.read_message()
        self.assertEqual((m.address, m.args[0]), ("/mixer/error", path), m)
        return m.args[1]

    def until_loaded(self, link):
        """The sets a recall broadcasts, then its snapshot/loaded args."""
        sets = {}
        while True:
            m = link.read_message()
            if m.address == "/mixer/snapshot/loaded":
                return sets, m.args
            self.assertTrue(m.address.startswith("/mixer/set/"), m)
            sets[m.address[len("/mixer/set/"):]] = m.args[0]

    def fetch_live(self, link):
        self.snap(link, "fetch")
        m = link.read_message()
        self.assertEqual((m.address, m.args[0]), ("/mixer/snapshot/data", ""))
        return json.loads(m.args[1])

    def quiet(self, link):
        """Nothing more arrives (a get is answered in order after anything queued)."""
        link.send_message("/mixer/get/inputChannel/0/level")
        self.assertEqual(link.read_message().address, "/mixer/set/inputChannel/0/level")

    def test_save_broadcasts_the_list_and_fetch_returns_the_complete_live_state(self):
        a, b = self.pair()
        self.snap(a, "list")
        self.assertEqual(self.listed(a), [])
        self.roundtrip(a, XP.format(1, 2), -12.0)
        b.read_message()                                          # b hears the set too
        self.snap(a, "save", "Song A")
        for link in (a, b):                                       # the list broadcast is the confirmation
            entries = self.listed(link)
            self.assertEqual([e["name"] for e in entries], ["Song A"])
            self.assertRegex(entries[0]["savedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        live = self.fetch_live(a)
        self.assertEqual(live["snapshotVersion"], 1)
        self.assertEqual(len(live["values"]), self.N_PARAMS)      # complete, not sparse
        self.assertFalse(any(k.startswith("system/") for k in live["values"]))
        self.assertEqual(live["values"]["inputMatrix/1_2/level"], -12.0)
        self.assertEqual(live["values"]["inputMatrix/1_1/level"], 0.0)
        self.snap(a, "fetch", "Song A")
        m = a.read_message()
        self.assertEqual((m.address, m.args[0]), ("/mixer/snapshot/data", "Song A"))
        self.assertEqual(json.loads(m.args[1])["values"], live["values"])
        self.assertTrue(os.path.exists(os.path.join(self.dir, "snapshots", "Song A.json")))

    def test_load_round_trip_broadcasts_only_the_changes_then_loaded(self):
        a, b = self.pair()
        self.roundtrip(a, XP.format(0, 1), -6.0)
        b.read_message()
        self.snap(a, "save", "A")
        self.listed(a), self.listed(b)
        self.roundtrip(a, XP.format(0, 1), -20.0)
        self.roundtrip(a, "/mixer/set/outputChannel/3/level", -3.0)
        for _ in range(2):
            b.read_message()
        self.snap(a, "load", "A")
        for link in (a, b):
            sets, loaded = self.until_loaded(link)
            self.assertEqual(sets, {"inputMatrix/0_1/level": -6.0, "outputChannel/3/level": 0.0})
            self.assertEqual(loaded, ["A", self.N_PARAMS, 0])
        self.assertEqual(self.get(a, "inputMatrix/0_1/level"), -6.0)
        self.assertEqual(self.get(a, "outputChannel/3/level"), 0.0)

    def test_before_load_is_an_undo(self):
        a = self.tcp()
        self.snap(a, "save", "A")                                 # the reset state
        self.listed(a)
        self.roundtrip(a, XP.format(2, 3), -9.0)
        self.snap(a, "load", "A")
        self.until_loaded(a)
        self.assertEqual(self.get(a, "inputMatrix/2_3/level"), -90.0)
        self.snap(a, "list")
        self.assertEqual([(e["name"], e.get("auto", False)) for e in self.listed(a)],
                         [("A", False), ("Before load", True)])
        self.snap(a, "load", "Before load")                       # undo
        sets, loaded = self.until_loaded(a)
        self.assertEqual(sets, {"inputMatrix/2_3/level": -9.0})
        self.assertEqual(loaded[0], "Before load")

    def test_apply_fits_a_bigger_snapshot_and_keeps_what_it_doesnt_mention(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/busChannel/1/level", -4.0)
        snap = {"snapshotVersion": 1, "name": "From a 20 x 20",
                "values": {"inputChannel/0/level": -5.0,
                           "inputChannel/7/level": -5.0,          # no channel 7 here
                           "inputMatrix/9_9/level": 0.0,          # no crosspoint 9_9
                           "eqZone/0/gain": 1.0,                  # no such zone
                           "inputChannel/0/mute": 1.0,            # no such module
                           "system/deviceName": "Elsewhere",      # ignored, not counted
                           "inputMatrix/1_0/level": 50.0}}        # clamped, not refused
        self.snap(a, "apply", json.dumps(snap))
        sets, loaded = self.until_loaded(a)
        self.assertEqual(loaded, ["From a 20 x 20", 2, 4])
        self.assertEqual(set(sets), {"inputChannel/0/level", "inputMatrix/1_0/level"})
        self.assertEqual(sets["inputMatrix/1_0/level"], float32(SIM_MAX_DB))
        self.assertEqual(self.get(a, "busChannel/1/level"), -4.0)  # not mentioned: kept
        self.assertEqual(self.get(a, "system/deviceName"), "mixer")

    def test_a_refused_entry_refuses_the_whole_recall(self):
        a, b = self.pair()
        bad = {"snapshotVersion": 1, "values": {"inputChannel/0/level": -5.0,
                                                "inputChannel/1/level": "loud"}}
        for text, reason in ((json.dumps(bad), "inputChannel/1/level"), ("{oops", "JSON"),
                             (json.dumps({"snapshotVersion": 2, "values": {}}), "not supported")):
            self.snap(a, "apply", text)
            self.assertIn(reason, self.error(a, "snapshot/apply"))
        self.assertEqual(self.get(a, "inputChannel/0/level"), 0.0)   # nothing applied
        self.snap(a, "list")
        self.assertEqual(self.listed(a), [])                         # no "Before load" either
        self.quiet(b)                                                # and nobody else heard anything

    def test_store_uploads_without_recalling(self):
        a, b = self.pair()
        upload = {"snapshotVersion": 1, "name": "laptop name", "savedAt": "2026-01-02T03:04:05Z",
                  "auto": True, "values": {"inputChannel/2/level": -30.0}}
        self.snap(a, "store", "Uploaded", json.dumps(upload))
        for link in (a, b):
            self.assertEqual(self.listed(link),
                             [{"name": "Uploaded", "savedAt": "2026-01-02T03:04:05Z"}])
        self.assertEqual(self.get(a, "inputChannel/2/level"), 0.0)   # not recalled
        self.snap(a, "fetch", "Uploaded")
        stored = json.loads(a.read_message().args[1])
        self.assertEqual((stored["name"], "auto" in stored), ("Uploaded", False))
        self.snap(a, "store", "Bad", json.dumps({"snapshotVersion": 1,
                                                 "values": {"inputChannel/0/level": "x"}}))
        self.error(a, "snapshot/store")

    def test_refusals(self):
        a = self.tcp()
        cases = [("load", ["nope"]), ("delete", ["nope"]), ("fetch", ["nope"]),
                 ("save", ["bad/name"]), ("save", [" padded"]), ("save", []),
                 ("save", [5]), ("store", ["x"]), ("apply", []), ("list", ["extra"]),
                 ("rename", ["a", "b"])]
        for request, args in cases:
            self.snap(a, request, *args)
            self.error(a, f"snapshot/{request}")
        self.snap(a, "delete", "nope")
        self.assertIn("no snapshot named", self.error(a, "snapshot/delete"))

    def test_delete_broadcasts_the_list(self):
        a, b = self.pair()
        self.snap(a, "save", "A")
        self.listed(a), self.listed(b)
        self.snap(b, "delete", "A")
        for link in (a, b):
            self.assertEqual(self.listed(link), [])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "snapshots", "A.json")))

    def test_udp_snapshot_requests_are_ignored(self):
        a, u = self.tcp(), self.udp()
        u.send_message("/mixer/snapshot/save", ["Over UDP"])
        time.sleep(0.2)
        self.snap(a, "list")
        self.assertEqual(self.listed(a), [])


class Phase15Case(ServerCase):
    """Helpers for the I/O patch and channel counts tests (Phase 15), on the
    simulated 4 x 4 x 4 mixer with the hardware's 20 I/O ports."""

    def pair(self):
        a, b = self.tcp(), self.tcp()
        for link in (a, b):
            self.get(link, "inputChannel/0/level")
        return a, b

    def echoes(self, link, address, value):
        """Set, then everything up to a get's answer: [(address tail, args), ...]."""
        link.send_message(address, [value])
        return self.drain(link)

    def drain(self, link):
        link.send_message("/mixer/get/system/deviceName")
        out = []
        while True:
            m = link.read_message()
            if m.address == "/mixer/set/system/deviceName":
                return out
            out.append((m.address[len("/mixer/"):], m.args[0] if len(m.args) == 1 else m.args))

    def error(self, link, path):
        m = link.read_message()
        self.assertEqual((m.address, m.args[0]), ("/mixer/error", path))
        return m.args[1]

    def config(self, link):
        link.send_message("/mixer/get/system/config")
        return json.loads(link.read_message().args[0])


class IOPatch(Phase15Case):
    """Standard "I/O patch": source per input channel, destination per output
    channel, 0 = None, ports 1-20 = Analog 1-4, USB 1-8, AVB 1-8."""

    def test_a_blank_slate_then_sources_may_be_shared(self):
        a = self.tcp()
        for ch in range(4):
            self.assertEqual(self.get(a, f"inputChannel/{ch}/source"), 0.0)
            self.assertEqual(self.get(a, f"outputChannel/{ch}/destination"), 0.0)
        self.assertNotIn("inputChannel/0/source", self.config(a)["values"])    # sparse: the default
        self.assertEqual(self.echoes(a, "/mixer/set/inputChannel/0/source", 13),
                         [("set/inputChannel/0/source", 13.0)])                # AVB 1
        self.assertEqual(self.echoes(a, "/mixer/set/inputChannel/2/source", 13),
                         [("set/inputChannel/2/source", 13.0)])                # shared: nothing moves
        self.assertEqual(self.get(a, "inputChannel/0/source"), 13.0)
        self.assertEqual(self.config(a)["values"]["inputChannel/2/source"], 13.0)

    def test_values_outside_the_options_are_refused(self):
        a = self.tcp()
        for bad in (21, 2.5, -1, "AVB 1"):
            a.send_message("/mixer/set/inputChannel/1/source", [bad])
            self.error(a, "inputChannel/1/source")
        self.assertEqual(self.get(a, "inputChannel/1/source"), 0.0)
        a.send_message("/mixer/get/busChannel/0/source")                       # buses aren't patched
        self.error(a, "busChannel/0/source")
        a.send_message("/mixer/get/inputChannel/0/destination")
        self.error(a, "inputChannel/0/destination")

    def test_a_taken_destination_moves_and_both_changes_are_echoed(self):
        a, b = self.pair()
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/0/destination", 7),
                         [("set/outputChannel/0/destination", 7.0)])
        b.read_message()
        got = self.echoes(a, "/mixer/set/outputChannel/2/destination", 7)     # USB 3, held by 0
        self.assertEqual(got, [("set/outputChannel/2/destination", 7.0),
                               ("set/outputChannel/0/destination", 0.0)])     # requested first
        self.assertEqual([(m.address, m.args[0]) for m in (b.read_message(), b.read_message())],
                         [("/mixer/set/outputChannel/2/destination", 7.0),
                          ("/mixer/set/outputChannel/0/destination", 0.0)])
        self.assertEqual(self.get(a, "outputChannel/0/destination"), 0.0)
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/2/destination", 7),
                         [("set/outputChannel/2/destination", 7.0)])          # its own: nothing moves
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/1/destination", 0),
                         [("set/outputChannel/1/destination", 0.0)])          # None is never taken
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/3/destination", 0),
                         [("set/outputChannel/3/destination", 0.0)])

    def test_the_patch_never_links(self):
        a = self.tcp()
        for ch in (0, 1):
            self.roundtrip(a, f"/mixer/set/outputChannel/{ch}/vgroup", 3)
            self.roundtrip(a, f"/mixer/set/inputChannel/{ch}/vgroup", 3)
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/0/destination", 5),
                         [("set/outputChannel/0/destination", 5.0)])
        self.assertEqual(self.echoes(a, "/mixer/set/inputChannel/1/source", 6),
                         [("set/inputChannel/1/source", 6.0)])

    def test_snapshots_carry_the_patch_and_a_recall_keeps_outputs_unique(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/inputChannel/1/source", 14.0)
        self.roundtrip(a, "/mixer/set/outputChannel/3/destination", 9.0)
        a.send_message("/mixer/snapshot/save", ["Gig"])
        a.read_message()
        self.roundtrip(a, "/mixer/set/inputChannel/1/source", 0.0)
        self.roundtrip(a, "/mixer/set/outputChannel/3/destination", 2.0)
        a.send_message("/mixer/snapshot/load", ["Gig"])
        got = dict(self.drain(a))
        self.assertEqual((got["set/inputChannel/1/source"], got["set/outputChannel/3/destination"]),
                         (14.0, 9.0))
        # a hand-made snapshot that puts outputs 0 and 1 on USB 5, which output 3 holds
        self.roundtrip(a, "/mixer/set/outputChannel/3/destination", 9.0)
        doc = {"snapshotVersion": 1, "values": {"outputChannel/0/destination": 9.0,
                                                "outputChannel/1/destination": 9.0}}
        a.send_message("/mixer/snapshot/apply", [json.dumps(doc)])
        got = dict(self.drain(a))
        self.assertEqual({k: v for k, v in got.items() if "destination" in k},
                         {"set/outputChannel/1/destination": 9.0,
                          "set/outputChannel/3/destination": 0.0})   # 0 was set, then taken by 1
        self.assertEqual([self.get(a, f"outputChannel/{ch}/destination") for ch in range(4)],
                         [0.0, 9.0, 0.0, 0.0])


class ChannelCounts(Phase15Case):
    """Standard "Channel counts" and "Config changed"."""

    def test_a_count_is_echoed_then_config_changed_and_the_config_follows(self):
        a, b = self.pair()
        for link in (a, b):
            if link is a:
                link.send_message("/mixer/set/system/inputCount", [2])
            m1, m2 = link.read_message(), link.read_message()
            self.assertEqual((m1.address, m1.args), ("/mixer/set/system/inputCount", [2.0]))
            self.assertEqual((m2.address, m2.args), ("/mixer/config/changed", []))
        d = self.config(a)
        self.assertEqual(d["zones"]["inputChannel"]["count"], 2)
        self.assertEqual((d["zones"]["inputMatrix"]["rows"], d["zones"]["inputMatrix"]["cols"]), (2, 4))
        self.assertEqual(d["zones"]["busMatrix"], {"rows": 4, "cols": 4, "modules": ["level"]})
        self.assertNotIn("inputMatrix/3_3/level", d["values"])
        self.assertEqual(d["values"]["system/inputCount"], 2.0)
        for tail in ("inputChannel/2/level", "inputChannel/3/source", "inputMatrix/3_0/level"):
            a.send_message(f"/mixer/get/{tail}")
            self.error(a, tail)
        self.assertEqual(self.echoes(a, "/mixer/set/system/busCount", 3),
                         [("set/system/busCount", 3.0), ("config/changed", [])])
        d = self.config(a)
        self.assertEqual((d["zones"]["busChannel"]["count"], d["zones"]["inputMatrix"]["cols"],
                          d["zones"]["busMatrix"]["rows"], d["zones"]["busMatrix"]["cols"]), (3, 3, 3, 4))
        self.assertEqual(self.echoes(a, "/mixer/set/system/outputCount", 1),
                         [("set/system/outputCount", 1.0), ("config/changed", [])])
        self.assertEqual(self.config(a)["zones"]["busMatrix"]["cols"], 1)

    def test_an_unchanged_or_clamped_count_and_wrong_kinds(self):
        a = self.tcp()
        self.assertEqual(self.echoes(a, "/mixer/set/system/busCount", 4),
                         [("set/system/busCount", 4.0)])                       # no change: no config/changed
        self.assertEqual(self.echoes(a, "/mixer/set/system/busCount", 99),
                         [("set/system/busCount", 4.0)])                       # clamped to the hardware's
        self.assertEqual(self.echoes(a, "/mixer/set/system/busCount", 0),
                         [("set/system/busCount", 1.0), ("config/changed", [])])
        a.send_message("/mixer/set/system/busCount", ["two"])
        self.error(a, "system/busCount")

    def test_hidden_channels_keep_their_values(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/outputChannel/3/level", -6.0)
        self.roundtrip(a, "/mixer/set/outputChannel/3/name", "Wedge")
        self.roundtrip(a, "/mixer/set/busMatrix/2_3/level", -3.0)
        self.echoes(a, "/mixer/set/system/outputCount", 2)
        self.echoes(a, "/mixer/set/system/outputCount", 4)
        self.assertEqual((self.get(a, "outputChannel/3/level"), self.get(a, "outputChannel/3/name"),
                          self.get(a, "busMatrix/2_3/level")), (-6.0, "Wedge", -3.0))

    def test_a_hidden_channel_loses_its_destination_quietly(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/outputChannel/3/destination", 9.0)
        self.echoes(a, "/mixer/set/system/outputCount", 3)
        self.assertEqual(self.echoes(a, "/mixer/set/outputChannel/0/destination", 9),
                         [("set/outputChannel/0/destination", 9.0)])          # no echo for the hidden one
        self.echoes(a, "/mixer/set/system/outputCount", 4)
        self.assertEqual(self.get(a, "outputChannel/3/destination"), 0.0)

    def test_a_recall_takes_a_hidden_destination_quietly_too(self):
        a = self.tcp()
        self.roundtrip(a, "/mixer/set/outputChannel/3/destination", 9.0)
        self.echoes(a, "/mixer/set/system/outputCount", 3)
        doc = {"snapshotVersion": 1, "values": {"outputChannel/0/destination": 9.0}}
        a.send_message("/mixer/snapshot/apply", [json.dumps(doc)])
        self.assertEqual(self.drain(a), [("set/outputChannel/0/destination", 9.0),
                                         ("snapshot/loaded", ["", 1, 0])])   # nothing for output 3
        self.echoes(a, "/mixer/set/system/outputCount", 4)
        self.assertEqual(self.get(a, "outputChannel/3/destination"), 0.0)

    def test_groups_and_snapshots_see_only_the_shown_channels(self):
        a = self.tcp()
        for ch in (0, 3):
            self.roundtrip(a, f"/mixer/set/inputChannel/{ch}/vgroup", 1)
        a.send_message("/mixer/snapshot/save", ["Four"])
        a.read_message()
        self.echoes(a, "/mixer/set/system/inputCount", 2)
        self.assertEqual(self.echoes(a, "/mixer/set/inputChannel/0/level", -5.0),
                         [("set/inputChannel/0/level", -5.0)])                # 3 is hidden: not linked
        a.send_message("/mixer/snapshot/fetch")
        live = json.loads(a.read_message().args[1])["values"]
        self.assertNotIn("inputChannel/3/level", live)
        self.assertNotIn("inputMatrix/2_0/level", live)
        self.assertNotIn("system/inputCount", live)                          # counts aren't in snapshots
        a.send_message("/mixer/snapshot/load", ["Four"])
        sets = self.drain(a)
        self.assertEqual(sets[-1][0], "snapshot/loaded")
        self.assertEqual(sets[-1][1][2], 2 * 4 + 2 * 4)    # skipped: 2 hidden inputs x 4 modules, 2 x 4 crosspoints
        self.assertNotIn("set/inputChannel/3/level", dict(sets[:-1]))
        self.echoes(a, "/mixer/set/system/inputCount", 4)
        self.assertEqual(self.get(a, "inputChannel/3/level"), 0.0)           # untouched while hidden


class ChannelCountsFromState(Phase15Case):
    """Counts are kept across a power cycle like any setting."""

    STATE = {"system": {"deviceName": "mixer", "outputCount": 2.0}}

    def test_stored_counts_shape_the_config(self):
        d = self.config(self.tcp())
        self.assertEqual(d["zones"]["outputChannel"]["count"], 2)
        self.assertEqual(d["zones"]["busMatrix"]["cols"], 2)


class NoPatch(Phase15Case):
    """A bitstream from before Phase 15 (simulated: --no-patch): no patch
    modules, no counts, channel k is I/O port k."""

    SERVER_ARGS = ["--no-patch"]

    def test_no_patch_and_no_counts(self):
        a = self.tcp()
        d = self.config(a)
        self.assertEqual(d["zones"]["inputChannel"]["modules"], ["level", "vgroup", "name"])
        self.assertNotIn("source", d["modules"])
        self.assertNotIn("inputCount", d["system"])
        a.send_message("/mixer/set/system/inputCount", [2])
        self.error(a, "system/inputCount")
        a.send_message("/mixer/get/outputChannel/0/destination")
        self.error(a, "outputChannel/0/destination")


class FakePatchHW:
    """Records what a PatchPart writes (mixer_hw.PatchHW.set_entries)."""

    def __init__(self, ports=20):
        self.ports, self.banks = ports, []

    def set_entries(self, entries):
        self.banks.append(dict(entries))
        return {c: (v if 0 <= v <= self.ports else 0) for c, v in entries.items()}

    def status(self):
        return "fake"


class PatchInProcess(unittest.TestCase):
    """Phase 15: the patch and the hidden-channel rule at the hardware."""

    LABELS = tuple(f"P{i}" for i in range(1, 21))

    def setUp(self):
        import osc_mixer_server as srv
        from mixer_state import MixerState
        self.srv = srv
        self.state = MixerState("mixer", None, log=lambda m: None)
        srv.log = lambda m: None

    def channel(self, zone, n=4):
        g, p = FakeGainHW(), FakePatchHW()
        module = self.srv.PATCH_MODULES.get(zone)
        b = self.srv.GainBackend(zone, g, n, max_db=6.0,
                                 patch=self.srv.PatchPart(module, p, self.LABELS) if module else None,
                                 hide=self.srv.HIDE[zone])
        return b, g, p

    def test_blank_slate_push_and_stored_entries(self):
        b, g, p = self.channel("inputChannel")
        self.state.set("inputChannel/2/source", 13.0)
        self.state.set("inputChannel/3/source", 99.0)                 # a port this mixer lacks
        b.seed_and_push(self.state)
        self.assertEqual(p.banks, [{0: 0, 1: 0, 2: 13, 3: 0}])      # one table, one COMMIT
        self.assertEqual(g.banks, [{0: 0.0, 1: 0.0, 2: 0.0, 3: 0.0}])

    def test_hidden_channels_get_the_silent_value_but_keep_their_own(self):
        b, g, p = self.channel("outputChannel")
        for ch in range(4):
            self.state.set(f"outputChannel/{ch}/destination", float(ch + 5))
        b.set_count(2, self.state)
        self.assertEqual(p.banks[-1], {0: 5, 1: 6, 2: 0, 3: 0})
        self.assertEqual(g.banks, [])                                # outputs hide by destination
        got = b.apply_many({("3", "destination"): 11.0, ("1", "destination"): 12.0})
        self.assertEqual(p.banks[-1], {3: 0, 1: 12})                 # hidden: None at the hardware
        self.assertEqual(got, {("3", "destination"): 11.0, ("1", "destination"): 12.0})
        self.assertEqual(b.describe()[0].count, 2)
        b.set_count(4, self.state)
        self.assertEqual(p.banks[-1], {0: 5, 1: 6, 2: 7, 3: 8})      # back as stored

    def test_hidden_buses_are_off_at_the_hardware(self):
        b, g, _p = self.channel("busChannel")
        self.state.set("busChannel/3/level", -6.0)
        b.set_count(3, self.state)
        self.assertEqual(g.banks[-1], {0: 0.0, 1: 0.0, 2: 0.0, 3: -90.0})
        self.assertEqual(b.apply("3", "level", -2.0), -2.0)           # stored as asked ...
        self.assertEqual(g.writes[-1], (3, -90.0))                   # ... silent at the hardware
        self.assertEqual(b.describe()[0].modules, ("level", "vgroup", "name"))

    def test_simulated_backends_have_the_patch_unless_told(self):
        backends = self.srv.build_backends(False, 4)
        self.assertEqual(backends["inputChannel"].describe()[0].modules,
                         ("level", "source", "vgroup", "name"))
        self.assertEqual(backends["outputChannel"].patch.module, "destination")
        self.assertIn("inputCount", self.srv.system_settings(backends))
        plain = self.srv.build_backends(False, 4, patch=False)
        self.assertIsNone(plain["inputChannel"].patch)
        self.assertNotIn("inputCount", self.srv.system_settings(plain))

    def test_patch_module_labels(self):
        spec = self.srv.patch_module(("A", "B"))
        self.assertEqual(spec.describe(), {"type": "enum", "default": 0.0, "group": "patch",
                                           "options": [0.0, 1.0, 2.0],
                                           "optionLabels": ["None", "A", "B"]})


if __name__ == "__main__":
    unittest.main()
