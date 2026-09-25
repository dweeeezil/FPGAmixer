#!/usr/bin/env python3
"""
Hardware backend for the FPGA mixer: talks to matrix_regs_axil in the PL.

Phase 5 register block (src/rtl/matrix_regs_axil.sv), reached from the PS over
M_AXI_HPM0_LPD at 0x8000_0000 (4 KB):

    0x000  ID       RO  0x4D58_5001
    0x004  CONFIG   RO  [31:24] outputs, [23:16] inputs, [15:8] gain width,
                        [7:0] gain fraction bits
    0x008  CTRL     W   bit0 = COMMIT (shadow bank -> active bank)
                    R   bit0 = BUSY, bit1 = QUEUED
    0x00C  COMMITS  RO  commits applied (wraps)
    0x100  GAIN[k]  RW  k = out*N + in, signed Q2.16 (0x10000 = 1.0 = 0 dB)

Gains are written to a shadow bank and only reach the audio when COMMIT is
written; the whole bank then changes on one frame. COMMIT never has to be
polled: one written while BUSY is queued in hardware.

Access is by mmap of /dev/mem (root). WARNING: only run this against a
bitstream that has the register block (Phase 5 or later). On an older image
nothing answers at 0x8000_0000, and the first access hangs the interconnect.

As a bring-up CLI, on the board:
    python3 mixer_hw.py info                  # ID, CONFIG, CTRL, COMMITS
    python3 mixer_hw.py dump                  # gain matrix, in dB
    python3 mixer_hw.py set <out> <in> <dB>   # one crosspoint, then COMMIT
    python3 mixer_hw.py identity              # unity diagonal, rest off
"""

import math
import mmap
import os
import struct
import sys
import threading

BASE_ADDR = 0x8000_0000
MAP_SIZE = 0x1000

REG_ID = 0x000
REG_CONFIG = 0x004
REG_CTRL = 0x008
REG_COMMITS = 0x00C
REG_GAIN0 = 0x100

EXPECTED_ID = 0x4D58_5001

# Levels at or below this are a hard zero (crosspoint off). The Q2.16 LSB is
# -96.3 dB, so anything this low is already at the resolution floor.
OFF_DB = -90.0


def db_to_code(db, frac_bits, width):
    """dB -> signed fixed-point code, clamped to the register's range.
    Returns (code, applied_db); applied_db differs from db only if clamped."""
    max_code = (1 << (width - 1)) - 1
    max_db = 20.0 * math.log10(max_code / (1 << frac_bits))
    if db is None or math.isnan(db) or db <= OFF_DB:
        return 0, db
    if db > max_db:
        db = max_db
    code = int(round(10.0 ** (db / 20.0) * (1 << frac_bits)))
    return min(code, max_code), db


def code_to_db(code, frac_bits):
    if code <= 0:
        return float("-inf") if code == 0 else 20.0 * math.log10(-code / (1 << frac_bits))
    return 20.0 * math.log10(code / (1 << frac_bits))


class MatrixHW:
    def __init__(self, base=BASE_ADDR, dev="/dev/mem"):
        self._lock = threading.Lock()
        fd = os.open(dev, os.O_RDWR | os.O_SYNC)
        try:
            self._mm = mmap.mmap(fd, MAP_SIZE, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        finally:
            os.close(fd)
        # A 32-bit view, so every access is a single aligned 32-bit load or
        # store. Slicing the mmap directly (mm[a:a+4]) may be done with byte
        # or unaligned accesses, which device memory does not tolerate.
        self._regs = memoryview(self._mm).cast("I")

        ident = self.rd(REG_ID)
        if ident != EXPECTED_ID:
            raise RuntimeError(f"matrix registers at 0x{base:08x}: ID 0x{ident:08x}, "
                               f"expected 0x{EXPECTED_ID:08x} (wrong bitstream?)")
        cfg = self.rd(REG_CONFIG)
        self.n_out = (cfg >> 24) & 0xFF
        self.n_in = (cfg >> 16) & 0xFF
        self.gain_width = (cfg >> 8) & 0xFF
        self.gain_frac = cfg & 0xFF

    # ----- raw access -----
    def rd(self, off):
        return self._regs[off >> 2]

    def wr(self, off, val):
        self._regs[off >> 2] = val & 0xFFFF_FFFF

    # ----- gains -----
    def _gain_off(self, out, inp):
        if not (0 <= out < self.n_out and 0 <= inp < self.n_in):
            raise IndexError(f"crosspoint out {out} / in {inp} outside "
                             f"{self.n_out}x{self.n_in} matrix")
        return REG_GAIN0 + 4 * (out * self.n_in + inp)

    def read_code(self, out, inp):
        raw = self.rd(self._gain_off(out, inp))
        return struct.unpack("<i", struct.pack("<I", raw))[0]  # sign-extended by HW

    def set_db(self, out, inp, db, commit=True):
        """Set one crosspoint in dB. Returns the dB actually applied."""
        code, applied = db_to_code(db, self.gain_frac, self.gain_width)
        with self._lock:
            self.wr(self._gain_off(out, inp), code)
            if commit:
                self.wr(REG_CTRL, 1)
        return applied

    def set_bank_db(self, levels):
        """levels: {(out, in): dB}. Written to the shadow bank, one COMMIT, so
        they all change on the same audio frame."""
        with self._lock:
            for (out, inp), db in levels.items():
                code, _ = db_to_code(db, self.gain_frac, self.gain_width)
                self.wr(self._gain_off(out, inp), code)
            self.wr(REG_CTRL, 1)

    def status(self):
        ctrl = self.rd(REG_CTRL)
        return {"busy": bool(ctrl & 1), "queued": bool(ctrl & 2),
                "commits": self.rd(REG_COMMITS)}


def _main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    hw = MatrixHW()
    cmd = argv[1]
    if cmd == "info":
        print(f"ID      0x{hw.rd(REG_ID):08x}")
        print(f"CONFIG  {hw.n_out} out x {hw.n_in} in, Q{hw.gain_width - hw.gain_frac}.{hw.gain_frac}")
        print(f"CTRL    {hw.status()}")
    elif cmd == "dump":
        print("out\\in " + "".join(f"{i:>9}" for i in range(hw.n_in)))
        for o in range(hw.n_out):
            cells = []
            for i in range(hw.n_in):
                db = code_to_db(hw.read_code(o, i), hw.gain_frac)
                cells.append(f"{'off':>9}" if db == float("-inf") else f"{db:9.2f}")
            print(f"{o:>6} " + "".join(cells))
    elif cmd == "set" and len(argv) == 5:
        applied = hw.set_db(int(argv[2]), int(argv[3]), float(argv[4]))
        print(f"out {argv[2]} <- in {argv[3]}: {applied:.2f} dB, {hw.status()}")
    elif cmd == "identity":
        hw.set_bank_db({(o, i): (0.0 if o == i else OFF_DB)
                        for o in range(hw.n_out) for i in range(hw.n_in)})
        print(f"identity applied, {hw.status()}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
