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
    python3 mixer_hw.py dump [window]         # gains in dB: matrix (default),
                                              # busmatrix, inlevel, buslevel, outlevel
    python3 mixer_hw.py set <out> <in> <dB> [window]   # one crosspoint, then COMMIT
                                              # (window: matrix or busmatrix)
    python3 mixer_hw.py level <window> <ch> <dB>       # one channel of a level
                                              # stage (Phase 12), then COMMIT
    python3 mixer_hw.py identity [window]     # unity diagonal, rest off
    python3 mixer_hw.py link [seconds]        # PS<->PL link counters (Phase 8);
                                              # with seconds: deltas and rates
    python3 mixer_hw.py link2 [seconds]       # the same for link #2 (Phase 9
                                              # P9.5, card FPGAmixerLink2)
    python3 mixer_hw.py mclk [seconds]        # mclk vs gPTP (Phase 9 P9.3): the
                                              # last interval, or every interval
                                              # for <seconds> and the mean, in ppm
    python3 mixer_hw.py steer [ppm]           # mclk steering (P9.4b): show, or set
                                              # a frequency change by hand (+ = faster)
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


class WindowAbsent(RuntimeError):
    """The running device tree has no node for this window: the bitstream
    doesn't have it. Raised before the bus is touched; callers that treat a
    window as optional (an older bitstream) catch exactly this."""


class RegWindow:
    """One axil_coef_window, mapped from /dev/mem."""

    ID = None  # subclasses set the ID they expect

    def __init__(self, base, dev="/dev/mem"):
        self.base = base
        self._lock = threading.Lock()
        if dev == "/dev/mem" and not dt_node_for(base):
            raise WindowAbsent(
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


class GainHW(RegWindow):
    """A pcm_gain window (src/rtl/gain_regs_axil.sv, Phase 12): one level per
    channel, in dB. CONFIG = [31:24] channels, [23:16] TAP (0 input, 1 bus,
    2 output), [15:8] gain width, [7:0] gain fraction bits; COEF[c] = gain
    of channel c. The three level stages share the ID; a subclass names the
    TAP it expects, so opening the wrong one of the three is refused like a
    wrong ID."""

    ID = 0x474E_5001
    TAP = None
    TAP_NAMES = {0: "input", 1: "bus", 2: "output"}

    def __init__(self, base, dev="/dev/mem"):
        super().__init__(base, dev)
        self.n = (self.config >> 24) & 0xFF
        self.tap = (self.config >> 16) & 0xFF
        self.gain_width = (self.config >> 8) & 0xFF
        self.gain_frac = self.config & 0xFF
        if self.TAP is not None and self.tap != self.TAP:
            raise RuntimeError(f"window at 0x{base:08x}: gain stage TAP {self.tap}, expected "
                               f"{self.TAP} ({self.TAP_NAMES.get(self.TAP)} levels; wrong address map?)")

    def describe(self):
        return (f"{self.TAP_NAMES.get(self.tap, f'tap {self.tap}')} levels, {self.n} channels, "
                f"Q{self.gain_width - self.gain_frac}.{self.gain_frac}")

    def _c(self, ch):
        if not 0 <= ch < self.n:
            raise IndexError(f"channel {ch} outside {self.n} channels")
        return ch

    def read_db(self, ch):
        return code_to_db(self.read_coef(self._c(ch)), self.gain_frac)

    def set_db(self, ch, db, commit=True):
        """Set one channel's level in dB. Returns the dB actually applied."""
        code, applied = db_to_code(db, self.gain_frac, self.gain_width)
        self.write_coefs({self._c(ch): code}, commit=commit)
        return applied

    def set_bank_db(self, levels):
        """levels: {channel: dB}; one COMMIT for the lot."""
        self.write_coefs({self._c(c): db_to_code(db, self.gain_frac, self.gain_width)[0]
                          for c, db in levels.items()})


class InputLevelHW(GainHW):
    TAP = 0


class BusLevelHW(GainHW):
    TAP = 1


class OutputLevelHW(GainHW):
    TAP = 2


class LinkStatHW(RegWindow):
    """A pcm_link status window (src/rtl/pcm_link_stat_regs.sv, Phase 8):
    read-only, same header, 0x00C = snapshot sequence. Counters are
    free-running and wrap at 32 bits; take differences (no CLEAR).
    CONFIG = [31:24] channels PL->PS, [23:16] channels PS->PL,
    [15:0] PS->PL FIFO depth in words."""

    ID = 0x4C4B_5001
    WORDS = ("frames_rx", "frames_tx", "underruns", "starved", "overruns",
             "tid_errors", "rx_fill", "rx_fill_low", "rx_fill_high", "flags")

    def __init__(self, base, dev="/dev/mem"):
        super().__init__(base, dev)
        self.n_tx = (self.config >> 24) & 0xFF
        self.n_rx = (self.config >> 16) & 0xFF
        self.fifo_words = self.config & 0xFFFF

    def describe(self):
        return (f"PS<->PL link, {self.n_rx} ch PS->PL, {self.n_tx} ch PL->PS, "
                f"FIFO {self.fifo_words} words")

    def status(self):
        return {"snapshots": self.rd(REG_COMMITS)}

    def read_all(self):
        """All words, from one snapshot when possible: re-read if the
        snapshot sequence moved while reading (a new one lands per frame)."""
        for _ in range(5):
            seq = self.rd(REG_COMMITS)
            vals = {n: self.rd(REG_COEF0 + 4 * k) for k, n in enumerate(self.WORDS)}
            if self.rd(REG_COMMITS) == seq:
                break
        vals["snapshots"] = seq
        vals["rx_running"] = bool(vals.pop("flags") & 1)
        return vals


U32 = 0xFFFF_FFFF


def mclk_ppm(cycles, seconds, nominal):
    """Frequency offset of mclk against the reference, in ppm, from a cycle
    count over a whole number of reference seconds."""
    return (cycles / (seconds * nominal) - 1.0) * 1e6


class MediaClockHW(RegWindow):
    """The media-clock meter's window (src/rtl/media_clock_stat_regs.sv,
    Phase 9 P9.3): mclk measured against a 1PPS on the gPTP second (the GEM
    TSU counter's bit 45, inverted). Read-only, same header, 0x00C = snapshot
    sequence; CONFIG = nominal mclk cycles per second (12,288,000). The PL
    only captures; frequency and phase are computed here (decision T2).
    Counts wrap at 32 bits (CYC_* every ~349 s): take differences mod 2^32."""

    ID = 0x4D43_5001
    WORDS = ("pps_count", "cyc_at_pps", "cyc_at_prev", "frames_at_pps",
             "phase_at_pps", "implausible", "cyc_now")

    def __init__(self, base, dev="/dev/mem"):
        super().__init__(base, dev)
        self.nominal = self.config

    def describe(self):
        return f"media-clock meter, nominal {self.nominal} mclk cycles per reference second"

    def status(self):
        return {"snapshots": self.rd(REG_COMMITS)}

    def read_all(self):
        """All words from one snapshot (re-read if a new one landed)."""
        for _ in range(5):
            seq = self.rd(REG_COMMITS)
            vals = {n: self.rd(REG_COEF0 + 4 * k) for k, n in enumerate(self.WORDS)}
            if self.rd(REG_COMMITS) == seq:
                break
        vals["snapshots"] = seq
        return vals

    def interval(self, v):
        """mclk cycles between the last two reference edges."""
        return (v["cyc_at_pps"] - v["cyc_at_prev"]) & U32

    def ref_alive(self, v):
        """True if a reference edge came within the last 1.5 s of mclk."""
        return v["pps_count"] > 0 and ((v["cyc_now"] - v["cyc_at_pps"]) & U32) < 1.5 * self.nominal


class MediaClockSteerHW(RegWindow):
    """The media-clock steering window (src/rtl/media_clock_ctrl_regs.sv,
    Phase 9 P9.4b): one RW word, RATE, driving the MMCM's fine phase shift,
    plus status. CONFIG = PSCLK in Hz; VCO_HZ and PS_DIV (steps per VCO
    period) are read-only words, so the conversion below uses what the
    hardware reports rather than constants.

    Sign convention here: ppm is the change applied to mclk's FREQUENCY,
    + = faster. The hardware's RATE is the opposite way round (> 0 = phase
    increments = slower), which this class hides."""

    ID = 0x4D53_5001
    REG_RATE = REG_COEF0 + 0x00
    REG_STEPS_INC = REG_COEF0 + 0x04
    REG_STEPS_DEC = REG_COEF0 + 0x08
    REG_DROPPED = REG_COEF0 + 0x0C
    REG_FLAGS = REG_COEF0 + 0x10
    REG_VCO_HZ = REG_COEF0 + 0x14
    REG_PS_DIV = REG_COEF0 + 0x18
    CYCLES_PER_STEP = 14          # PSEN, PSDONE 12 cycles later, next PSEN after it

    def __init__(self, base, dev="/dev/mem"):
        super().__init__(base, dev)
        self.psclk_hz = self.config
        self.vco_hz = self.rd(self.REG_VCO_HZ)
        self.ps_div = self.rd(self.REG_PS_DIV)
        self.step_s = 1.0 / (self.vco_hz * self.ps_div)       # phase per step, seconds
        self.max_ppm = self.psclk_hz / self.CYCLES_PER_STEP * self.step_s * 1e6

    def describe(self):
        return (f"media-clock steering, PSCLK {self.psclk_hz / 1e6:g} MHz, "
                f"step {self.step_s * 1e12:.3f} ps, max +/-{self.max_ppm:.1f} ppm")

    def status(self):
        f = self.rd(self.REG_FLAGS)
        return {"ppm": round(self.get_ppm(), 4), "locked": bool(f & 1),
                "steps_inc": self.rd(self.REG_STEPS_INC),
                "steps_dec": self.rd(self.REG_STEPS_DEC),
                "dropped": self.rd(self.REG_DROPPED)}

    def rate_for_ppm(self, ppm):
        """RATE register value (two's complement) for a frequency change of
        ppm (+ = faster), clamped to what the MMCM can do."""
        ppm = max(-self.max_ppm, min(self.max_ppm, ppm))
        steps_per_cycle = ppm * 1e-6 / self.step_s / self.psclk_hz
        rate = -int(round(steps_per_cycle * 2 ** 32))          # + ppm = decrements
        return rate & U32

    def ppm_for_rate(self, reg):
        rate = reg - (1 << 32) if reg & 0x8000_0000 else reg
        return -rate / 2 ** 32 * self.psclk_hz * self.step_s * 1e6

    def set_ppm(self, ppm):
        self.wr(self.REG_RATE, self.rate_for_ppm(ppm))
        return self.get_ppm()

    def get_ppm(self):
        return self.ppm_for_rate(self.rd(self.REG_RATE))


# name -> (physical base, class). Mirrors assign_bd_address; see ADDRESS MAP.
# (The Audio Formatter at 0x8010_0000 is driver-owned, not listed here.)
WINDOWS = {
    "matrix":   (0x8000_0000, MatrixHW),
    "linkstat": (0x8000_1000, LinkStatHW),     # Phase 8 bitstreams only
    "mclk":     (0x8000_2000, MediaClockHW),   # Phase 9 (phase9 bitstreams) only
    "mclkctl":  (0x8000_3000, MediaClockSteerHW),  # Phase 9 P9.4b bitstreams only
    "linkstat2": (0x8000_4000, LinkStatHW),    # link #2, Phase 9 P9.5 bitstreams only
    # Phase 12 (every PS bitstream from then on): the bus layer. "matrix" is
    # then the input matrix (input -> bus); "busmatrix" is bus -> output.
    "busmatrix": (0x8000_5000, MatrixHW),
    "inlevel":   (0x8000_6000, InputLevelHW),
    "buslevel":  (0x8000_7000, BusLevelHW),
    "outlevel":  (0x8000_8000, OutputLevelHW),
}

# The bus layer's windows: present all together (a Phase 12 bitstream) or not
# at all (older ones, where "matrix" is input -> output).
BUS_LAYER = ("busmatrix", "inlevel", "buslevel", "outlevel")

COUNTERS = ("frames_rx", "frames_tx", "underruns", "starved", "overruns", "tid_errors")


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
            try:
                w = open_window(name)
            except RuntimeError as e:    # absent from this bitstream: say so, go on
                print(f"{name:9} @ 0x{WINDOWS[name][0]:08x}: not available ({e})")
                continue
            print(f"{name:9} @ 0x{w.base:08x}: {w.describe()}  ({RegWindow.describe(w)}), "
                  f"{w.status()}")
        return 0

    if cmd in ("link", "link2"):
        # link           one reading (link2: the same for link #2)
        # link <sec>     two readings <sec> apart: counter deltas and rates
        ls = open_window("linkstat" if cmd == "link" else "linkstat2")
        a = ls.read_all()
        if len(argv) == 3:
            import time
            dt = float(argv[2])
            time.sleep(dt)
            b = ls.read_all()
            for n in COUNTERS:
                d = (b[n] - a[n]) & 0xFFFF_FFFF
                print(f"{n:12} +{d:<10} {d / dt:10.1f}/s")
            a = b
        else:
            for n in COUNTERS:
                print(f"{n:12} {a[n]}")
        print(f"rx_fill      {a['rx_fill']} words (low {a['rx_fill_low']}, "
              f"high {a['rx_fill_high']} since the stream started; 65535 = never ran)")
        print(f"rx_running   {a['rx_running']}   snapshots {a['snapshots']}")
        return 0

    if cmd == "mclk":
        # mclk           one reading: the last interval
        # mclk <sec>     watch for <sec> seconds: every interval, then the mean
        import time
        mc = open_window("mclk")
        v = mc.read_all()
        alive = mc.ref_alive(v)
        print(f"reference {'alive' if alive else 'NOT SEEN (no 1PPS in the last 1.5 s)'}, "
              f"{v['pps_count']} edges, {v['implausible']} implausible intervals")
        if len(argv) != 3:
            if v["pps_count"] >= 2:
                n = mc.interval(v)
                print(f"last interval {n} cycles = {mclk_ppm(n, 1, mc.nominal):+.3f} ppm vs gPTP, "
                      f"frame phase {v['phase_at_pps']} cycles at the second")
            return 0
        end = time.monotonic() + float(argv[2])
        ivals, last = [], v
        while time.monotonic() < end:
            time.sleep(0.25)
            v = mc.read_all()
            new = (v["pps_count"] - last["pps_count"]) & U32
            if new == 0:
                continue
            if new == 1 and v["implausible"] == last["implausible"]:
                n = mc.interval(v)
                ivals.append(n)
                print(f"#{v['pps_count']:<6} {n} cycles  {mclk_ppm(n, 1, mc.nominal):+9.3f} ppm  "
                      f"phase {v['phase_at_pps']:3}  frames {v['frames_at_pps']}")
            else:
                print(f"#{v['pps_count']:<6} skipped: {new} edges since the last read, "
                      f"implausible +{(v['implausible'] - last['implausible']) & U32}")
            last = v
        if ivals:
            total = sum(ivals)
            lo, hi = min(ivals), max(ivals)
            print(f"{len(ivals)} intervals: mean {mclk_ppm(total, len(ivals), mc.nominal):+.3f} ppm "
                  f"(single intervals {mclk_ppm(lo, 1, mc.nominal):+.3f} .. "
                  f"{mclk_ppm(hi, 1, mc.nominal):+.3f})")
        return 0

    if cmd == "steer":
        # steer          show the steering state
        # steer <ppm>    set mclk's frequency change by hand (+ = faster), open
        #                loop; the fpgamixer-mediaclock service overwrites it
        st = open_window("mclkctl")
        if len(argv) == 3:
            applied = st.set_ppm(float(argv[2]))
            print(f"rate set: {applied:+.4f} ppm (register 0x{st.rd(st.REG_RATE):08x})")
        print(f"{st.describe()}: {st.status()}")
        return 0

    def fmt(db):
        return f"{'off':>9}" if db == float("-inf") else f"{db:9.2f}"

    if cmd == "level" and len(argv) == 5:
        lv = open_window(argv[2])
        if not isinstance(lv, GainHW):
            print(f"{argv[2]} is not a level window ({', '.join(BUS_LAYER[1:])})")
            return 2
        applied = lv.set_db(int(argv[3]), float(argv[4]))
        print(f"{argv[2]} ch {argv[3]}: {applied:.2f} dB, {lv.status()}")
        return 0

    # dump [window]; set <out> <in> <dB> [window]; identity [window]
    name = {"dump": 2, "set": 5, "identity": 2}.get(cmd)
    name = argv[name] if name is not None and len(argv) > name else "matrix"
    hw = open_window(name)
    if cmd == "dump" and isinstance(hw, GainHW):
        print(f"{hw.describe()}")
        for c in range(hw.n):
            print(f"{c:>6} {fmt(hw.read_db(c))}")
    elif cmd == "dump":
        print("out\\in " + "".join(f"{i:>9}" for i in range(hw.n_in)))
        for o in range(hw.n_out):
            print(f"{o:>6} " + "".join(fmt(hw.read_db(o, i)) for i in range(hw.n_in)))
    elif cmd == "set" and len(argv) in (5, 6) and isinstance(hw, MatrixHW):
        applied = hw.set_db(int(argv[2]), int(argv[3]), float(argv[4]))
        print(f"{name}: out {argv[2]} <- in {argv[3]}: {applied:.2f} dB, {hw.status()}")
    elif cmd == "identity" and isinstance(hw, MatrixHW):
        hw.set_bank_db({(o, i): (0.0 if o == i else OFF_DB)
                        for o in range(hw.n_out) for i in range(hw.n_in)})
        print(f"{name}: identity applied, {hw.status()}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
