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
        for tail, path in [("inputChannel/0/level", "inputChannel/0/level"),     # zone not advertised
                           ("inputMatrix/4_0/level", "inputMatrix/4_0/level"),   # out of range
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

    def test_udp_refusals_are_only_logged(self):
        c = self.tcp()
        self.get(c, "system/deviceName")
        u = self.udp()
        u.send_message("/mixer/set/inputChannel/0/level", [-6.0])
        u.send_message(XP.format(0, 1), ["x"])
        u.send_message("/mixer/set/system/sampleRate", [44100.0])
        silent(self, c)
        log = self.log()
        for path in ("inputChannel/0/level", "inputMatrix/0_1/level", "system/sampleRate"):
            self.assertIn(f"refused {path}", log)

    def test_float32_echo(self):
        c = self.tcp()
        self.assertEqual(self.roundtrip(c, XP.format(2, 2), 2.39), float32(2.39))


class OldStateFile(ServerCase):
    """An old state file keeps loading; the format doesn't change (§4.2)."""

    STATE = {"system": {"deviceName": "mixer"},
             "inputChannel": {"0": {"level": -12.0}},
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
        c.send_message("/mixer/get/inputChannel/0/level")
        self.assertEqual(c.read_message().address, "/mixer/error")               # unreachable...
        tree = self.state()
        self.assertEqual(tree["inputChannel"], {"0": {"level": -12.0}})          # ...but kept
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

    def test_describe(self):
        spec, modules = self.srv.MatrixBackend("inputMatrix", None, 3, 2, max_db=6.0).describe()
        self.assertEqual((spec.kind, spec.rows, spec.cols, spec.modules), ("matrix", 3, 2, ("level",)))
        self.assertEqual((modules["level"].min, modules["level"].max, modules["level"].default),
                         (-90.0, 6.0, -90.0))

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
                        "group": "level"}


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

    def test_shape_matches_the_mocks_hardware_today_profile(self):
        d = self.config(self.tcp())
        self.assertEqual(set(d), {"schemaVersion", "deviceName", "firmware", "sampleRate", "zones",
                                  "modules", "system", "values"})
        self.assertEqual(d["zones"], {"inputMatrix": {"rows": 4, "cols": 4, "modules": ["level"]}})
        level = d["modules"]["level"]
        self.assertEqual(set(level), set(HARDWARE_TODAY_LEVEL))
        for key in ("type", "unit", "min", "default", "group"):
            self.assertEqual(level[key], HARDWARE_TODAY_LEVEL[key], key)
        self.assertAlmostEqual(level["max"], 6.02, places=2)     # the real ceiling, 6.0205
        self.assertEqual(d["values"], {**{f"inputMatrix/{i}_{i}/level": 0.0 for i in range(4)},
                                       "system/deviceName": "FOH"})   # unity diagonal, as the profile
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


if __name__ == "__main__":
    unittest.main()
