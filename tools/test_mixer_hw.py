#!/usr/bin/env python3
"""
Unit tests for mixer_hw.py and the server's matrix backend, without hardware:
a 4 KB temp file stands in for a register window (ID and CONFIG preloaded),
and a temp directory stands in for /proc/device-tree.

    python3 -m unittest -v test_mixer_hw          (from tools/)

The register tests mmap with Linux flags, so they run on Linux/macOS only.
"""

import os
import shutil
import struct
import tempfile
import unittest

import mixer_hw
from mixer_params import float32

# A stored level comes back at OSC's float32 precision: seeding brings every
# value inside the module's rules, rounding included (controller support
# step 3). The migration tests compared with the double until 2026-10-04.
DB_6 = float32(-6.0206)


def make_window_file(ident=0x4D585001, config=0x04041210):
    fd, path = tempfile.mkstemp(prefix="regwin-")
    with os.fdopen(fd, "wb") as f:
        f.write(bytearray(mixer_hw.WINDOW_SIZE))
        f.seek(0)
        f.write(struct.pack("<II", ident, config))
    return path


def reg(path, off, signed=False):
    with open(path, "rb") as f:
        f.seek(off)
        return struct.unpack("<i" if signed else "<I", f.read(4))[0]


def only_matrix(path):
    """open_window for a bitstream from before Phase 12: the matrix window at
    `path`, and no bus-layer windows (absent from the device tree)."""
    def open_window(name, dev=path):
        if name != "matrix":
            raise mixer_hw.WindowAbsent(f"no {name}")
        return mixer_hw.MatrixHW(0, dev)
    return open_window


def fake_windows(paths):
    """open_window over fake files: {name: path}; names not given are absent."""
    def open_window(name, dev=None):
        if name not in paths:
            raise mixer_hw.WindowAbsent(f"no {name}")
        return mixer_hw.WINDOWS[name][1](0, paths[name])
    return open_window


class DeviceTreeGuard(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="dt-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_finds_window_node(self):
        # the shipped dtb has /axi/M_AXI_CTRL@80000000
        os.makedirs(os.path.join(self.root, "axi", "M_AXI_CTRL@80000000"))
        os.makedirs(os.path.join(self.root, "axi", "serial@ff000000"))
        self.assertTrue(mixer_hw.dt_node_for(0x8000_0000, root=self.root)
                        .endswith("M_AXI_CTRL@80000000"))

    def test_no_node_means_none(self):
        os.makedirs(os.path.join(self.root, "axi", "serial@ff000000"))
        self.assertIsNone(mixer_hw.dt_node_for(0x8000_0000, root=self.root))

    def test_suffix_must_match_exactly(self):
        # @800000000 (one zero more) must not count as @80000000
        os.makedirs(os.path.join(self.root, "axi", "thing@800000000"))
        self.assertIsNone(mixer_hw.dt_node_for(0x8000_0000, root=self.root))

    def test_refuses_dev_mem_without_node(self):
        # Must refuse BEFORE opening /dev/mem (which doesn't even exist here).
        real = mixer_hw.DEVICE_TREE
        mixer_hw.DEVICE_TREE = self.root
        try:
            with self.assertRaises(RuntimeError) as cm:
                mixer_hw.MatrixHW(0x8000_0000, dev="/dev/mem")
            self.assertIn("Refusing to touch the bus", str(cm.exception))
        finally:
            mixer_hw.DEVICE_TREE = real


@unittest.skipIf(os.name == "nt", "mmap with Linux flags")
class Registers(unittest.TestCase):
    def setUp(self):
        self.path = make_window_file()

    def tearDown(self):
        os.unlink(self.path)

    def test_header(self):
        m = mixer_hw.MatrixHW(0, dev=self.path)
        self.assertEqual((m.n_in, m.n_out, m.gain_width, m.gain_frac), (4, 4, 18, 16))
        self.assertEqual(m.describe(), "matrix 4 in x 4 out, Q2.16")

    def test_wrong_id_refused(self):
        os.unlink(self.path)
        self.path = make_window_file(ident=0x12345678)
        with self.assertRaises(RuntimeError):
            mixer_hw.MatrixHW(0, dev=self.path)

    def test_gain_addressing_and_commit(self):
        m = mixer_hw.MatrixHW(0, dev=self.path)
        m.set_db(1, 2, -6.0206)                                  # out 1 <- in 2: k = 1*4 + 2
        self.assertEqual(reg(self.path, 0x100 + 4 * 6), 0x8000)
        self.assertEqual(reg(self.path, mixer_hw.REG_CTRL) & 1, 1)
        self.assertAlmostEqual(m.read_db(1, 2), -6.0206, places=3)

    def test_clamp_and_off(self):
        m = mixer_hw.MatrixHW(0, dev=self.path)
        self.assertAlmostEqual(m.set_db(3, 0, 20.0), 6.0205, places=3)
        self.assertEqual(reg(self.path, 0x100 + 4 * 12), 0x1FFFF)
        m.set_db(0, 3, -1000.0)
        self.assertEqual(reg(self.path, 0x100 + 4 * 3), 0)

    def test_negative_readback_is_signed(self):
        m = mixer_hw.MatrixHW(0, dev=self.path)
        with open(self.path, "r+b") as f:                       # HW sign-extends on read
            f.seek(0x100)
            f.write(struct.pack("<i", -0x10000))
        self.assertEqual(m.read_coef(0), -0x10000)

    def test_out_of_range(self):
        m = mixer_hw.MatrixHW(0, dev=self.path)
        with self.assertRaises(IndexError):
            m.set_db(4, 0, 0.0)

    def test_server_backend_seeds_restores_and_pushes_once(self):
        import osc_mixer_server as srv
        from mixer_state import MixerState
        srv.log = lambda m: None
        real_open = mixer_hw.open_window
        mixer_hw.open_window = only_matrix(self.path)      # a pre-Phase-12 bitstream
        try:
            state = MixerState("mixer", None)
            state.set("inputMatrix/2_1/level", -6.0206)          # restored: in 2 -> out 1
            backends = srv.build_backends(True, 4)
        finally:
            mixer_hw.open_window = real_open
        backends["inputMatrix"].seed_and_push(state)
        self.assertEqual(reg(self.path, 0x100 + 4 * 0), 0x10000)  # identity diagonal
        self.assertEqual(reg(self.path, 0x100 + 4 * 1), 0)        # off
        self.assertEqual(reg(self.path, 0x100 + 4 * 6), 0x8000)   # restored crosspoint
        self.assertEqual(state.get("inputMatrix/0_0/level"), 0.0)   # seeded into the store
        self.assertEqual(state.get("inputMatrix/0_1/level"), -90.0)

    def test_state_from_4x4_migrates_onto_12x12(self):
        """Phase 8: a state file saved on the 4x4 matrix, restored on the
        12x12 one (4 Pmod + 8 link channels, appended). The 16 old crosspoints
        keep their values at their new bank positions (k = out*12 + in); the
        128 new ones are seeded with the identity rule; one COMMIT."""
        import osc_mixer_server as srv
        from mixer_state import MixerState
        srv.log = lambda m: None
        os.unlink(self.path)
        self.path = make_window_file(config=0x0C0C1210)          # 12 out, 12 in, Q2.16
        real_open = mixer_hw.open_window
        mixer_hw.open_window = only_matrix(self.path)      # a pre-Phase-12 bitstream
        try:
            state = MixerState("mixer", None)
            for i in range(4):                                    # a full old 4x4 file
                for o in range(4):
                    state.set(f"inputMatrix/{i}_{o}/level", 0.0 if i == o else -90.0)
            state.set("inputMatrix/0_2/level", -6.0206)           # JB_L -> JC_L, as on the bench
            state.set("inputMatrix/2_2/level", -90.0)             # JC_L's own input off
            backends = srv.build_backends(True, 4)
        finally:
            mixer_hw.open_window = real_open
        b = backends["inputMatrix"]
        self.assertEqual((b.n_in, b.n_out), (12, 12))
        b.seed_and_push(state)
        k = lambda i, o: 0x100 + 4 * (o * 12 + i)
        self.assertEqual(reg(self.path, k(0, 2)), 0x8000)         # old values, new positions
        self.assertEqual(reg(self.path, k(2, 2)), 0)
        self.assertEqual(reg(self.path, k(1, 1)), 0x10000)
        self.assertEqual(reg(self.path, k(4, 4)), 0x10000)        # new: link identity
        self.assertEqual(reg(self.path, k(11, 11)), 0x10000)
        self.assertEqual(reg(self.path, k(4, 0)), 0)              # new: off
        self.assertEqual(reg(self.path, k(0, 4)), 0)
        self.assertEqual(state.get("inputMatrix/0_2/level"), DB_6)     # store keeps it (float32)
        self.assertEqual(state.get("inputMatrix/5_5/level"), 0.0)      # and seeded
        self.assertEqual(state.get("inputMatrix/5_3/level"), -90.0)
        self.assertEqual(reg(self.path, mixer_hw.REG_CTRL) & 1, 1)     # committed

    def test_state_from_12x12_migrates_onto_20x20(self):
        """Phase 9 (P9.5): a state file saved on the 12x12 matrix (bench-like:
        every crosspoint stored, two USB -> Pmod routes), restored on the
        20x20 one (link #2 = channels 12-19, appended). All 144 old values
        keep their meaning at k = out*20 + in; the 256 new crosspoints are
        seeded with the identity rule (decision L4: AVB k -> AVB k on, the
        rest off); the store keeps the old values; one COMMIT."""
        import osc_mixer_server as srv
        from mixer_state import MixerState
        srv.log = lambda m: None
        os.unlink(self.path)
        self.path = make_window_file(config=0x14141210)          # 20 out, 20 in, Q2.16
        real_open = mixer_hw.open_window
        mixer_hw.open_window = only_matrix(self.path)      # a pre-Phase-12 bitstream
        try:
            state = MixerState("mixer", None)
            for i in range(12):                                   # a full old 12x12 file
                for o in range(12):
                    state.set(f"inputMatrix/{i}_{o}/level", 0.0 if i == o else -90.0)
            state.set("inputMatrix/4_0/level", -6.0206)           # USB 1 -> JB_L
            state.set("inputMatrix/5_2/level", -6.0206)           # USB 2 -> JC_L
            state.set("inputMatrix/11_11/level", -90.0)           # an old diagonal off
            backends = srv.build_backends(True, 12)
        finally:
            mixer_hw.open_window = real_open
        b = backends["inputMatrix"]
        self.assertEqual((b.n_in, b.n_out), (20, 20))
        b.seed_and_push(state)
        k = lambda i, o: 0x100 + 4 * (o * 20 + i)
        self.assertEqual(reg(self.path, k(4, 0)), 0x8000)         # old values, new positions
        self.assertEqual(reg(self.path, k(5, 2)), 0x8000)
        self.assertEqual(reg(self.path, k(11, 11)), 0)
        self.assertEqual(reg(self.path, k(4, 4)), 0x10000)
        self.assertEqual(reg(self.path, k(0, 4)), 0)
        for c in range(12, 20):                                   # new: AVB identity
            self.assertEqual(reg(self.path, k(c, c)), 0x10000)
        self.assertEqual(reg(self.path, k(12, 13)), 0)            # new: off
        self.assertEqual(reg(self.path, k(12, 4)), 0)             # AVB 1 -> USB 1: off
        self.assertEqual(reg(self.path, k(4, 12)), 0)             # USB 1 -> AVB 1: off
        self.assertEqual(reg(self.path, k(12, 0)), 0)             # AVB 1 -> JB_L: off
        on = [kk for kk in range(400) if reg(self.path, 0x100 + 4 * kk)]
        self.assertEqual(len(on), 11 + 2 + 8)                     # 11 old diagonal + 2 routes + 8 AVB
        self.assertEqual(state.get("inputMatrix/4_0/level"), DB_6)     # store keeps it (float32)
        self.assertEqual(state.get("inputMatrix/11_11/level"), -90.0)
        self.assertEqual(state.get("inputMatrix/19_19/level"), 0.0)    # and seeded
        self.assertEqual(state.get("inputMatrix/19_4/level"), -90.0)
        self.assertEqual(reg(self.path, mixer_hw.REG_CTRL) & 1, 1)     # committed

    def test_windows_map(self):
        """The address map mirrors assign_bd_address (create_project.tcl):
        link #2's status window at 0x8000_4000 is a LinkStatHW; the Phase 12
        bus layer at 0x8000_5000..8000 (decision L6); no two windows share a
        base."""
        self.assertEqual(mixer_hw.WINDOWS["linkstat2"], (0x8000_4000, mixer_hw.LinkStatHW))
        self.assertEqual(mixer_hw.WINDOWS["busmatrix"], (0x8000_5000, mixer_hw.MatrixHW))
        self.assertEqual(mixer_hw.WINDOWS["inlevel"], (0x8000_6000, mixer_hw.InputLevelHW))
        self.assertEqual(mixer_hw.WINDOWS["buslevel"], (0x8000_7000, mixer_hw.BusLevelHW))
        self.assertEqual(mixer_hw.WINDOWS["outlevel"], (0x8000_8000, mixer_hw.OutputLevelHW))
        self.assertEqual(mixer_hw.BUS_LAYER, ("busmatrix", "inlevel", "buslevel", "outlevel"))
        self.assertEqual(mixer_hw.WINDOWS["inmeter"], (0x8000_9000, mixer_hw.InputMeterHW))
        self.assertEqual(mixer_hw.WINDOWS["busmeter"], (0x8000_A000, mixer_hw.BusMeterHW))
        self.assertEqual(mixer_hw.WINDOWS["outmeter"], (0x8000_B000, mixer_hw.OutputMeterHW))
        self.assertEqual(mixer_hw.METERS, ("inmeter", "busmeter", "outmeter"))
        bases = [b for b, _cls in mixer_hw.WINDOWS.values()]
        self.assertEqual(len(bases), len(set(bases)))
        self.assertTrue(all(b % mixer_hw.WINDOW_SIZE == 0 and 0x8000_0000 <= b < 0x8010_0000
                            for b in bases))


@unittest.skipIf(os.name == "nt", "mmap with Linux flags")
class BusLayer(unittest.TestCase):
    """Phase 12: the gain-stage windows (GainHW) and the server's bus layer
    over fake 20-channel windows."""

    GAIN_ID = 0x474E5001
    MATRIX_20 = 0x14141210                      # 20 out, 20 in, Q2.16

    def setUp(self):
        self.paths = {"matrix": make_window_file(config=self.MATRIX_20),
                      "busmatrix": make_window_file(config=self.MATRIX_20),
                      "inlevel": make_window_file(self.GAIN_ID, 0x14001210),
                      "buslevel": make_window_file(self.GAIN_ID, 0x14011210),
                      "outlevel": make_window_file(self.GAIN_ID, 0x14021210)}
        import osc_mixer_server as srv
        srv.log = lambda m: None
        self.srv = srv

    def tearDown(self):
        for p in self.paths.values():
            os.unlink(p)

    def build(self, paths):
        real_open = mixer_hw.open_window
        mixer_hw.open_window = fake_windows(paths)
        try:
            return self.srv.build_backends(True, 4)
        finally:
            mixer_hw.open_window = real_open

    def test_gain_header_and_tap(self):
        g = mixer_hw.OutputLevelHW(0, dev=self.paths["outlevel"])
        self.assertEqual((g.n, g.tap, g.gain_width, g.gain_frac), (20, 2, 18, 16))
        self.assertEqual(g.describe(), "output levels, 20 channels, Q2.16")

    def test_wrong_tap_refused(self):
        with self.assertRaises(RuntimeError) as cm:
            mixer_hw.InputLevelHW(0, dev=self.paths["outlevel"])
        self.assertIn("TAP 2, expected 0", str(cm.exception))

    def test_matrix_id_refused_as_a_gain_window(self):
        with self.assertRaises(RuntimeError):
            mixer_hw.BusLevelHW(0, dev=self.paths["busmatrix"])

    def test_gain_addressing_clamp_and_commit(self):
        g = mixer_hw.BusLevelHW(0, dev=self.paths["buslevel"])
        g.set_db(3, -6.0206)
        self.assertEqual(reg(self.paths["buslevel"], 0x100 + 4 * 3), 0x8000)
        self.assertEqual(reg(self.paths["buslevel"], mixer_hw.REG_CTRL) & 1, 1)
        self.assertAlmostEqual(g.read_db(3), -6.0206, places=3)
        self.assertAlmostEqual(g.set_db(19, 20.0), 6.0205, places=3)
        self.assertEqual(reg(self.paths["buslevel"], 0x100 + 4 * 19), 0x1FFFF)
        with self.assertRaises(IndexError):
            g.set_db(20, 0.0)

    def test_full_bus_layer_seeds_and_pushes_the_reset_state(self):
        from mixer_state import MixerState
        b = self.build(self.paths)
        self.assertEqual(list(b), ["inputChannel", "inputMatrix", "busChannel", "busMatrix",
                                   "outputChannel"])
        state = MixerState("mixer", None)
        state.set("busChannel/5/level", -6.0206)
        state.set("busMatrix/2_7/level", -6.0206)               # bus 2 -> out 7
        for backend in b.values():
            backend.seed_and_push(state)
        for name in ("inlevel", "outlevel"):
            self.assertEqual([reg(self.paths[name], 0x100 + 4 * c) for c in range(20)], [0x10000] * 20)
        self.assertEqual(reg(self.paths["buslevel"], 0x100 + 4 * 5), 0x8000)
        self.assertEqual(reg(self.paths["buslevel"], 0x100 + 4 * 4), 0x10000)
        k = lambda src, dst: 0x100 + 4 * (dst * 20 + src)
        self.assertEqual(reg(self.paths["busmatrix"], k(2, 7)), 0x8000)
        self.assertEqual(reg(self.paths["busmatrix"], k(7, 7)), 0x10000)
        self.assertEqual(reg(self.paths["busmatrix"], k(7, 2)), 0)
        self.assertEqual(reg(self.paths["matrix"], k(3, 3)), 0x10000)
        for name, p in self.paths.items():
            self.assertEqual(reg(p, mixer_hw.REG_CTRL) & 1, 1, name)   # each window committed
        self.assertEqual(state.get("outputChannel/19/level"), 0.0)       # seeded into the store
        self.assertEqual(state.get("busChannel/5/level"), DB_6)

    def test_sets_reach_the_right_window(self):
        b = self.build(self.paths)
        b["inputChannel"].apply("1", "level", -6.0206)
        b["outputChannel"].apply("2", "level", -6.0206)
        b["busMatrix"].apply("4_6", "level", -6.0206)           # bus 4 -> out 6
        self.assertEqual(reg(self.paths["inlevel"], 0x104), 0x8000)
        self.assertEqual(reg(self.paths["outlevel"], 0x108), 0x8000)
        self.assertEqual(reg(self.paths["buslevel"], 0x104), 0)
        self.assertEqual(reg(self.paths["busmatrix"], 0x100 + 4 * (6 * 20 + 4)), 0x8000)
        self.assertEqual(reg(self.paths["matrix"], 0x100 + 4 * (6 * 20 + 4)), 0)

    def test_older_bitstream_serves_the_matrix_only(self):
        b = self.build({"matrix": self.paths["matrix"]})
        self.assertEqual(list(b), ["inputMatrix"])

    def test_partial_bus_layer_refused(self):
        paths = dict(self.paths)
        del paths["buslevel"]
        with self.assertRaises(RuntimeError) as cm:
            self.build(paths)
        self.assertIn("incomplete: no window buslevel", str(cm.exception))

    def test_sizes_that_dont_chain_refused(self):
        os.unlink(self.paths["outlevel"])
        self.paths["outlevel"] = make_window_file(self.GAIN_ID, 0x0C021210)   # 12 channels
        with self.assertRaises(RuntimeError) as cm:
            self.build(self.paths)
        self.assertIn("output levels / bus matrix outputs = 12 / 20", str(cm.exception))

    def test_other_gain_format_refused(self):
        os.unlink(self.paths["inlevel"])
        self.paths["inlevel"] = make_window_file(self.GAIN_ID, 0x14001810)   # Q8.16
        with self.assertRaises(RuntimeError) as cm:
            self.build(self.paths)
        self.assertIn("'level' is one module", str(cm.exception))


@unittest.skipIf(os.name == "nt", "mmap with Linux flags")
class Meters(unittest.TestCase):
    """Phase 13: the peak-meter windows (PeakHW) and the server's meter source
    over fake 20-channel windows. A thread plays the PL for snapshots: it sees
    SNAP in CTRL, clears it and counts the snapshot."""

    PEAK_ID = 0x504B5001

    def setUp(self):
        self.paths = {name: make_window_file(self.PEAK_ID, 0x14001800 | (tap << 16))
                      for tap, name in enumerate(mixer_hw.METERS)}
        import osc_mixer_server as srv
        srv.log = lambda m: None
        self.srv = srv

    def tearDown(self):
        for p in self.paths.values():
            os.unlink(p)

    def fake_pl(self, path, peaks):
        """Write `peaks` into PEAK[c]; clear CTRL whenever SNAP appears."""
        import threading
        import time
        with open(path, "r+b") as f:
            f.seek(0x100)
            f.write(struct.pack(f"<{len(peaks)}I", *peaks))
        stop = threading.Event()

        def run():
            while not stop.is_set():
                if reg(path, mixer_hw.REG_CTRL) & 1:
                    with open(path, "r+b") as f:
                        f.seek(mixer_hw.REG_CTRL)
                        f.write(struct.pack("<II", 0, reg(path, mixer_hw.REG_COMMITS) + 1))
                time.sleep(0.0005)
        t = threading.Thread(target=run, daemon=True)
        t.start()
        self.addCleanup(stop.set)

    def test_header_and_tap(self):
        m = mixer_hw.BusMeterHW(0, dev=self.paths["busmeter"])
        self.assertEqual((m.n, m.tap, m.width), (20, 1, 24))
        self.assertEqual(m.describe(), "bus meter, 20 channels, 24-bit")
        with self.assertRaises(RuntimeError) as cm:
            mixer_hw.InputMeterHW(0, dev=self.paths["outmeter"])
        self.assertIn("TAP 2, expected 0", str(cm.exception))

    def test_snapshot_snaps_waits_and_reads_masked(self):
        peaks = [c * 1000 for c in range(19)] + [0xFF7F_FFFF]   # the top byte isn't data
        self.fake_pl(self.paths["inmeter"], peaks)
        m = mixer_hw.InputMeterHW(0, dev=self.paths["inmeter"])
        got = m.snapshot()
        self.assertEqual(got[:19], peaks[:19])
        self.assertEqual(got[19], 0x7F_FFFF)
        self.assertEqual(reg(self.paths["inmeter"], mixer_hw.REG_COMMITS), 1)

    def test_snapshot_times_out_without_frames(self):
        m = mixer_hw.InputMeterHW(0, dev=self.paths["inmeter"])          # nobody clears CTRL
        with self.assertRaises(TimeoutError):
            m.snapshot()

    def build(self, paths, sizes=20):
        real_open = mixer_hw.open_window
        mixer_hw.open_window = fake_windows(paths)
        backends = {z: type("B", (), {"n": sizes})() for z in ("inputChannel", "busChannel", "outputChannel")}
        try:
            return self.srv.build_meter_source(True, "none", backends, None)
        finally:
            mixer_hw.open_window = real_open

    def test_hardware_source_samples_every_zone(self):
        for tap, name in enumerate(mixer_hw.METERS):
            self.fake_pl(self.paths[name], [tap * 100 + c for c in range(20)])
        src = self.build(self.paths)
        self.assertEqual(src.zones(), {"inputChannel": 20, "busChannel": 20, "outputChannel": 20})
        s = src.sample()
        self.assertEqual(s["busChannel"][:3], [100, 101, 102])
        self.assertEqual(s["outputChannel"][19], 219)
        for name in mixer_hw.METERS:                     # every window was really snapshotted
            self.assertEqual(reg(self.paths[name], mixer_hw.REG_COMMITS), 1, name)

    def test_older_bitstream_has_no_meters(self):
        self.assertIsNone(self.build({}))

    def test_partial_meters_refused(self):
        paths = dict(self.paths)
        del paths["busmeter"]
        with self.assertRaises(RuntimeError) as cm:
            self.build(paths)
        self.assertIn("meters incomplete: none for busChannel", str(cm.exception))

    def test_meter_size_must_match_the_zone(self):
        with self.assertRaises(RuntimeError) as cm:
            self.build(self.paths, sizes=12)
        self.assertIn("meter has 20 channels, the zone 12", str(cm.exception))


@unittest.skipIf(os.name == "nt", "mmap with Linux flags")
class LinkStat(unittest.TestCase):
    """The Phase 8 link status window, against a fake 4 KB file."""

    def setUp(self):
        self.path = make_window_file(ident=0x4C4B5001, config=0x08080040)
        words = [1000, 999, 2, 50, 3, 0, 17, 9, 24, 1]          # see LinkStatHW.WORDS
        with open(self.path, "r+b") as f:
            f.seek(mixer_hw.REG_COMMITS)
            f.write(struct.pack("<I", 1234))
            f.seek(mixer_hw.REG_COEF0)
            f.write(struct.pack(f"<{len(words)}I", *words))

    def tearDown(self):
        os.unlink(self.path)

    def test_header_and_words(self):
        ls = mixer_hw.LinkStatHW(0, dev=self.path)
        self.assertEqual((ls.n_rx, ls.n_tx, ls.fifo_words), (8, 8, 64))
        v = ls.read_all()
        self.assertEqual(v["frames_rx"], 1000)
        self.assertEqual(v["starved"], 50)
        self.assertEqual((v["rx_fill"], v["rx_fill_low"], v["rx_fill_high"]), (17, 9, 24))
        self.assertTrue(v["rx_running"])
        self.assertEqual(v["snapshots"], 1234)
        self.assertEqual(ls.status(), {"snapshots": 1234})

    def test_matrix_id_refused(self):
        os.unlink(self.path)
        self.path = make_window_file()                           # a matrix window
        with self.assertRaises(RuntimeError):
            mixer_hw.LinkStatHW(0, dev=self.path)


class MediaClock(unittest.TestCase):
    """The Phase 9 media-clock meter window, against a fake 4 KB file."""

    NOMINAL = 12_288_000

    def write_words(self, words, seq=77):
        with open(self.path, "r+b") as f:
            f.seek(mixer_hw.REG_COMMITS)
            f.write(struct.pack("<I", seq))
            f.seek(mixer_hw.REG_COEF0)
            f.write(struct.pack(f"<{len(words)}I", *words))

    def setUp(self):
        self.path = make_window_file(ident=0x4D435001, config=self.NOMINAL)

    def tearDown(self):
        os.unlink(self.path)

    def test_header_words_interval(self):
        # +324 ppm: 12,291,981 cycles per second; the counter wrapped between
        # the two edges, so the interval must come out modulo 2^32
        prev = 0xFFFF_0000
        last = (prev + 12_291_981) & 0xFFFF_FFFF
        now = (last + 100_000) & 0xFFFF_FFFF
        self.write_words([42, last, prev, 48_000 * 42, 131, 1, now])     # see WORDS
        mc = mixer_hw.MediaClockHW(0, dev=self.path)
        self.assertEqual(mc.nominal, self.NOMINAL)
        v = mc.read_all()
        self.assertEqual((v["pps_count"], v["phase_at_pps"], v["implausible"]), (42, 131, 1))
        self.assertEqual(v["snapshots"], 77)
        self.assertEqual(mc.interval(v), 12_291_981)
        self.assertAlmostEqual(mixer_hw.mclk_ppm(12_291_981, 1, self.NOMINAL), 323.975, places=3)
        self.assertTrue(mc.ref_alive(v))

    def test_reference_not_seen(self):
        self.write_words([5, 1000, 0, 0, 0, 0, 1000 + 2 * self.NOMINAL])
        mc = mixer_hw.MediaClockHW(0, dev=self.path)
        self.assertFalse(mc.ref_alive(mc.read_all()))
        self.write_words([0, 0, 0, 0, 0, 0, 5])                         # never an edge
        self.assertFalse(mc.ref_alive(mc.read_all()))

    def test_mean_over_seconds(self):
        self.assertAlmostEqual(mixer_hw.mclk_ppm(10 * self.NOMINAL, 10, self.NOMINAL), 0.0)
        self.assertAlmostEqual(mixer_hw.mclk_ppm(10 * self.NOMINAL + 1, 10, self.NOMINAL),
                               1e6 / (10 * self.NOMINAL), places=6)

    def test_link_id_refused(self):
        os.unlink(self.path)
        self.path = make_window_file(ident=0x4C4B5001, config=0x08080040)
        with self.assertRaises(RuntimeError):
            mixer_hw.MediaClockHW(0, dev=self.path)


class MediaClockSteer(unittest.TestCase):
    """The Phase 9 P9.4b steering window, against a fake 4 KB file."""

    def setUp(self):
        self.path = make_window_file(ident=0x4D535001, config=100_000_000)
        with open(self.path, "r+b") as f:
            f.seek(mixer_hw.REG_COEF0 + 0x14)
            f.write(struct.pack("<II", 1_450_000_000, 56))            # VCO_HZ, PS_DIV

    def tearDown(self):
        os.unlink(self.path)

    def test_geometry_and_max(self):
        st = mixer_hw.MediaClockSteerHW(0, dev=self.path)
        self.assertAlmostEqual(st.step_s * 1e12, 12.3153, places=3)
        # one step per 14 PSCLK cycles at 100 MHz: 7.14 M steps/s x 12.315 ps
        self.assertAlmostEqual(st.max_ppm, 87.97, places=1)

    def test_sign_scale_roundtrip(self):
        st = mixer_hw.MediaClockSteerHW(0, dev=self.path)
        # +50 ppm faster = 4.06 M decrements/s = 0.0406 steps per 100 MHz cycle
        # = 174,375,672 units of 2^-32, negative (decrements); the magnitude
        # tb_media_clock_steer's rate_for_ppm(50.0) gives
        reg = st.rate_for_ppm(50.0)
        signed = reg - (1 << 32) if reg & 0x8000_0000 else reg
        self.assertTrue(-174_376_000 < signed < -174_375_000)
        self.assertLess(st.rate_for_ppm(-1.0) & 0x8000_0000, 1)       # slower: positive RATE
        for ppm in (0.0, 0.852, -3.25, 42.0):
            self.assertAlmostEqual(st.ppm_for_rate(st.rate_for_ppm(ppm)), ppm, places=5)

    def test_clamp_and_register(self):
        st = mixer_hw.MediaClockSteerHW(0, dev=self.path)
        self.assertAlmostEqual(st.set_ppm(500.0), st.max_ppm, places=3)
        self.assertEqual(reg(self.path, st.REG_RATE), st.rate_for_ppm(st.max_ppm))
        self.assertAlmostEqual(st.set_ppm(-0.85), -0.85, places=5)

    def test_wrong_id_refused(self):
        os.unlink(self.path)
        self.path = make_window_file(ident=0x4D435001, config=12_288_000)   # the meter
        with self.assertRaises(RuntimeError):
            mixer_hw.MediaClockSteerHW(0, dev=self.path)


if __name__ == "__main__":
    unittest.main()
