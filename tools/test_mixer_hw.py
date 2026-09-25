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
        mixer_hw.open_window = lambda name, dev=self.path: mixer_hw.MatrixHW(0, dev)
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


if __name__ == "__main__":
    unittest.main()
