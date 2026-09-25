#!/usr/bin/env python3
"""
Hardware backend for the FPGA mixer: talks to the PL register windows.

Mirrors the PL's control-plane split (docs/architecture_modules.md 4):

    RegWindow  -- any axil_coef_window: the common header + a coefficient
                  array, mmapped from /dev/mem. Knows nothing about what the
                  coefficients mean.
    MatrixHW   -- one pcm_matrix's window (matrix_regs_axil): gains in dB.

Every window has the same header (src/rtl/axil_coef_window.sv):

    0x000  ID       RO  block type + version
    0x004  CONFIG   RO  block geometry (meaning is per block)
    0x008  CTRL     W   bit0 = COMMIT (shadow bank -> active bank)
                    R   bit0 = BUSY, bit1 = QUEUED
    0x00C  COMMITS  RO  commits applied (wraps)
    0x100  COEF[k]  RW  k = 0.., signed, read back sign-extended

Coefficients are written to a shadow bank and only reach the audio when
COMMIT is written; the whole bank then changes on one frame. COMMIT never has
to be polled: one written while BUSY is queued in hardware.

ADDRESS MAP: WINDOWS below mirrors assign_bd_address in
scripts/create_project.tcl, one entry per block. It is explicit on purpose:
there is no safe way to scan for windows, because an access where no block
is mapped is answered with a bus error, and Linux turns that into a kernel
fault. Each entry is checked by its ID register when opened.

Access is by mmap of /dev/mem (root). On a bitstream without these windows
(anything before Phase 5) nothing answers at 0x8000_0000 and the first access
hangs the interconnect -- at boot, if the service does it. So before mapping
/dev/mem, a window must be present in the running device tree: sdtgen puts
a node named <something>@<base> (M_AXI_CTRL@80000000) into it, and the device
tree and the bitstream come from the same XSA, so the node exists exactly
when the bitstream has the window. No node -> refuse, without touching the bus.

As a bring-up CLI, on the board:
    python3 mixer_hw.py info                  # every window: ID, CONFIG, CTRL
    python3 mixer_hw.py dump                  # matrix gains, in dB
    python3 mixer_hw.py set <out> <in> <dB>   # one crosspoint, then COMMIT
    python3 mixer_hw.py identity              # unity diagonal, rest off
"""

import math
import mmap
import os
import struct
import sys
import threading

WINDOW_SIZE = 0x1000

REG_ID = 0x000
REG_CONFIG = 0x004
REG_CTRL = 0x008
REG_COMMITS = 0x00C
REG_COEF0 = 0x100

# Levels at or below this are a hard zero (crosspoint off). The Q2.16 LSB is
# -96.3 dB, so anything this low is already at the resolution floor.
OFF_DB = -90.0


DEVICE_TREE = "/proc/device-tree"


def dt_node_for(base, root=None, max_depth=4):
    """Path of a device-tree node named '<name>@<base in hex>', or None."""
    root = root or DEVICE_TREE
    suffix = f"@{base:x}"
    root_depth = root.rstrip("/").count("/")
    for path, dirs, _files in os.walk(root):
        for d in dirs:
            if d.endswith(suffix):
                return os.path.join(path, d)
        if path.count("/") - root_depth >= max_depth:
            dirs[:] = []
    return None


class RegWindow:
    """One axil_coef_window, mapped from /dev/mem."""

    ID = None  # subclasses set the ID they expect

    def __init__(self, base, dev="/dev/mem"):
        self.base = base
        self._lock = threading.Lock()
        if dev == "/dev/mem" and not dt_node_for(base):
            raise RuntimeError(
                f"no device-tree node for a register window at 0x{base:08x} under "
                f"{DEVICE_TREE}: this image's bitstream doesn't have it (pre-Phase 5?). "
                f"Refusing to touch the bus, since an access there would hang it.")
        fd = os.open(dev, os.O_RDWR | os.O_SYNC)
        try:
            self._mm = mmap.mmap(fd, WINDOW_SIZE, mmap.MAP_SHARED,
                                 mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        finally:
            os.close(fd)
        # A 32-bit view, so every access is a single aligned 32-bit load or
        # store. Slicing the mmap directly (mm[a:a+4]) may be done with byte
        # or unaligned accesses, which device memory does not tolerate.
        self._regs = memoryview(self._mm).cast("I")

        self.ident = self.rd(REG_ID)
        if self.ID is not None and self.ident != self.ID:
            raise RuntimeError(f"window at 0x{base:08x}: ID 0x{self.ident:08x}, "
                               f"expected 0x{self.ID:08x} (wrong bitstream or address map?)")
        self.config = self.rd(REG_CONFIG)

    # ----- raw access -----
    def rd(self, off):
        return self._regs[off >> 2]

    def wr(self, off, val):
        self._regs[off >> 2] = val & 0xFFFF_FFFF

    # ----- coefficients -----
    def read_coef(self, k):
        raw = self.rd(REG_COEF0 + 4 * k)
        return struct.unpack("<i", struct.pack("<I", raw))[0]  # sign-extended by HW

    def write_coefs(self, coefs, commit=True):
        """coefs: {k: signed int}. Written to the shadow bank, then (by
        default) one COMMIT, so they all change on the same audio frame."""
        with self._lock:
            for k, v in coefs.items():
                self.wr(REG_COEF0 + 4 * k, v)
            if commit:
                self.wr(REG_CTRL, 1)

    def status(self):
        ctrl = self.rd(REG_CTRL)
        return {"busy": bool(ctrl & 1), "queued": bool(ctrl & 2),
                "commits": self.rd(REG_COMMITS)}

    def describe(self):
        return f"ID 0x{self.ident:08x}, CONFIG 0x{self.config:08x}"


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


class MatrixHW(RegWindow):
    """A pcm_matrix window (src/rtl/matrix_regs_axil.sv): gains in dB.
    CONFIG = [31:24] outputs, [23:16] inputs, [15:8] gain width,
    [7:0] gain fraction bits; COEF[k] = gain, k = out*n_in + in."""

    ID = 0x4D58_5001

    def __init__(self, base, dev="/dev/mem"):
        super().__init__(base, dev)
        self.n_out = (self.config >> 24) & 0xFF
        self.n_in = (self.config >> 16) & 0xFF
        self.gain_width = (self.config >> 8) & 0xFF
        self.gain_frac = self.config & 0xFF

    def describe(self):
        return (f"matrix {self.n_in} in x {self.n_out} out, "
                f"Q{self.gain_width - self.gain_frac}.{self.gain_frac}")

    def _k(self, out, inp):
        if not (0 <= out < self.n_out and 0 <= inp < self.n_in):
            raise IndexError(f"crosspoint out {out} / in {inp} outside "
                             f"{self.n_out}x{self.n_in} matrix")
        return out * self.n_in + inp

    def read_db(self, out, inp):
        return code_to_db(self.read_coef(self._k(out, inp)), self.gain_frac)

    def set_db(self, out, inp, db, commit=True):
        """Set one crosspoint in dB. Returns the dB actually applied."""
        code, applied = db_to_code(db, self.gain_frac, self.gain_width)
        self.write_coefs({self._k(out, inp): code}, commit=commit)
        return applied

    def set_bank_db(self, levels):
        """levels: {(out, in): dB}; one COMMIT for the lot."""
        self.write_coefs({self._k(o, i): db_to_code(db, self.gain_frac, self.gain_width)[0]
                          for (o, i), db in levels.items()})


# name -> (physical base, class). Mirrors assign_bd_address; see ADDRESS MAP.
WINDOWS = {
    "matrix": (0x8000_0000, MatrixHW),
}


def open_window(name, dev="/dev/mem"):
    base, cls = WINDOWS[name]
    return cls(base, dev)


def _main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "info":
        for name in WINDOWS:
            w = open_window(name)
            print(f"{name:8} @ 0x{w.base:08x}: {w.describe()}  ({RegWindow.describe(w)}), "
                  f"{w.status()}")
        return 0

    hw = open_window("matrix")
    if cmd == "dump":
        print("out\\in " + "".join(f"{i:>9}" for i in range(hw.n_in)))
        for o in range(hw.n_out):
            cells = []
            for i in range(hw.n_in):
                db = hw.read_db(o, i)
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
