#!/usr/bin/env python3
"""
Phase 8 bench test S4 (the Phase 6 follow-up): the power-cycle restore test
with real audio on every crosspoint. Standard library only, so the same file
runs on the Pi, the board and the Mac.

The idea: every one of the 144 crosspoints gets its own level (PATTERN). The
Mac plays one tone per USB input (TONES_HZ, FPGAmixer outputs 1-8 = core
inputs 4-11) and records FPGAmixer inputs 1-8 (core outputs 4-11). Each
recording is then a mix of the 8 tones at 8 known levels, so measuring every
tone's amplitude in every recording recovers the gain of all 64 USB -> USB
crosspoints. The 80 crosspoints that touch the Pmods (whose input signals are
unknown) are checked through the gain registers, and JB_L/JC_L by ear.

    set      (Pi)     send all 144 levels over OSC, check each echo
    check-hw (board)  read all 144 gain registers, compare with PATTERN
    analyze  (Mac)    measure the 64 USB crosspoints from a recording
    compare  (any)    two analyze results (before / after the power pull)
    pattern  (any)    print the table

    python3 crosspoint_restore_test.py set --host 10.0.0.2
    sudo python3 crosspoint_restore_test.py check-hw
    python3 crosspoint_restore_test.py analyze rec.wav --save before.json
    python3 crosspoint_restore_test.py analyze in1.wav ... in8.wav --save after.json
    python3 crosspoint_restore_test.py compare before.json after.json

Recordings: WAV, 48 kHz, 16/24/32-bit integer PCM (not float); either one
8-channel file or eight mono files in FPGAmixer input order. The analysis uses
2 s from the middle of the file.

Source levels don't need to be known: for each tone, its level is estimated
from all 8 recordings (median of measured - expected), and what's reported
per crosspoint is the residual after that. A crosspoint restored wrong, or a
bank written to the wrong place, shows up as a residual of several dB; the
pass threshold is 0.5 dB.
"""

import argparse
import json
import math
import socket
import struct
import sys
import wave

N = 12
PMOD = range(0, 4)          # core channels 0-3: JB_L, JB_R, JC_L, JC_R
USB = range(4, 12)          # core channels 4-11: link / USB 1-8
TONES_HZ = [211, 307, 401, 503, 601, 701, 809, 907]   # USB in 1..8 (primes)
OFF_DB = -90.0
PASS_DB = 0.5


def build_pattern():
    """{(in, out): dB}, every crosspoint on and at its own level."""
    p = {}
    # USB -> USB: 64 distinct levels, -6.0 .. -37.5 dB in 0.5 dB steps,
    # scrambled (29 is coprime with 64) so no row or column is monotonic.
    for o in USB:
        for i in USB:
            k = (o - 4) * 8 + (i - 4)
            p[(i, o)] = -6.0 - 0.5 * ((k * 29) % 64)
    # USB -> Pmod: the two audible routes, the rest quiet and distinct.
    k = 0
    for o in PMOD:
        for i in USB:
            p[(i, o)] = -50.0 - 0.25 * k
            k += 1
    p[(4, 0)] = -6.0        # USB 1 (211 Hz) -> JB_L: audible
    p[(5, 2)] = -6.0        # USB 2 (307 Hz) -> JC_L: audible
    # Pmod -> Pmod: the analog passthrough on the heard outputs, rest quiet.
    k = 0
    for o in PMOD:
        for i in PMOD:
            p[(i, o)] = -60.0 - 0.25 * k
            k += 1
    p[(0, 0)] = -12.0       # JB_L in -> JB_L out
    p[(2, 2)] = -12.0       # JC_L in -> JC_L out
    # Pmod -> USB: very low, so an analog source barely touches the tones.
    k = 0
    for o in USB:
        for i in PMOD:
            p[(i, o)] = -70.0 - 0.25 * k
            k += 1
    assert len(p) == N * N
    return p


PATTERN = build_pattern()


# ----------------------------------------------------------------- OSC (set)

def _osc_str(s):
    b = s.encode() + b"\0"
    return b + b"\0" * (-len(b) % 4)


def _osc_msg(addr, value):
    return _osc_str(addr) + _osc_str(",f") + struct.pack(">f", value)


def _read_str(buf, off):
    end = buf.index(b"\0", off)
    s = buf[off:end].decode()
    return s, off + ((end - off) // 4 + 1) * 4


def _decode(buf):
    """(address, [args], consumed) or None if incomplete."""
    try:
        addr, off = _read_str(buf, 0)
        tags, off = _read_str(buf, off)
    except ValueError:
        return None
    args = []
    for t in tags[1:]:
        if len(buf) < off + 4:
            return None
        if t == "f":
            args.append(struct.unpack_from(">f", buf, off)[0])
            off += 4
        elif t == "i":
            args.append(struct.unpack_from(">i", buf, off)[0])
            off += 4
        elif t == "s":
            s, off = _read_str(buf, off)
            args.append(s)
    return addr, args, off


def cmd_set(a):
    sock = socket.create_connection((a.host, a.port), timeout=3)
    buf = b""
    bad = 0
    for (i, o), db in sorted(PATTERN.items(), key=lambda x: (x[0][1], x[0][0])):
        addr = f"/{a.name}/set/inputMatrix/{i}_{o}/level"
        sock.sendall(_osc_msg(addr, db))
        while True:                                  # wait for this echo
            m = _decode(buf)
            if m is None:
                chunk = sock.recv(4096)
                if not chunk:
                    sys.exit("connection closed by the server")
                buf += chunk
                continue
            buf = buf[m[2]:]
            if m[0] == addr:
                break
        got = m[1][0] if m[1] else None
        if got is None or abs(got - db) > 0.01:
            print(f"  {i}_{o}: sent {db}, echoed {got}")
            bad += 1
    sock.close()
    print(f"set: 144 crosspoints sent, {144 - bad} echoed as sent, {bad} differ")
    return 1 if bad else 0


# ------------------------------------------------------------ check-hw (board)

def cmd_check_hw(a):
    sys.path.insert(0, a.tools)
    import mixer_hw
    m = mixer_hw.open_window("matrix")
    if (m.n_in, m.n_out) != (N, N):
        sys.exit(f"matrix is {m.n_in}x{m.n_out}, expected {N}x{N}")
    bad = 0
    for (i, o), db in sorted(PATTERN.items()):
        want = mixer_hw.db_to_code(db, m.gain_frac, m.gain_width)[0]
        got = m.read_coef(o * m.n_in + i)
        if got != want:
            print(f"  {i}_{o}: register {got:#x}, expected {want:#x} ({db} dB)")
            bad += 1
    print(f"check-hw: {144 - bad}/144 gain registers match the pattern")
    return 1 if bad else 0


# ----------------------------------------------------------- analyze (Mac)

def _read_wav(path):
    """[channel][sample] as floats in -1..1, and the rate."""
    with wave.open(path, "rb") as w:
        nch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        mid = max(0, n // 2 - rate)                 # 2 s from the middle
        w.setpos(mid)
        raw = w.readframes(min(2 * rate, n - mid))
    frames = len(raw) // (sw * nch)
    full = float(1 << (8 * sw - 1))
    chans = [[0.0] * frames for _ in range(nch)]
    for f in range(frames):
        base = f * sw * nch
        for c in range(nch):
            b = raw[base + c * sw: base + (c + 1) * sw]
            if sw == 1:
                v = b[0] - 128
            else:
                v = int.from_bytes(b, "little", signed=True)
            chans[c][f] = v / full
    return chans, rate


def _tone_db(x, rate, hz):
    """Amplitude of one sine in x, dBFS (Goertzel + Hann window)."""
    n = len(x)
    w = 2 * math.pi * hz / rate
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    wsum = 0.0
    for k, v in enumerate(x):
        h = 0.5 - 0.5 * math.cos(2 * math.pi * k / (n - 1))
        wsum += h
        s0 = v * h + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    amp = 2 * math.sqrt(max(power, 0.0)) / wsum
    return 20 * math.log10(amp) if amp > 0 else -200.0


def cmd_analyze(a):
    if len(a.wav) == 1:
        chans, rate = _read_wav(a.wav[0])
    else:
        chans, rate = [], None
        for p in a.wav:
            c, rate = _read_wav(p)
            chans.append(c[0])
    if len(chans) != 8:
        sys.exit(f"need 8 channels (FPGAmixer inputs 1-8), got {len(chans)}")
    if rate != 48000:
        print(f"note: recording is {rate} Hz, not 48000")

    # meas[o][i]: tone of USB input i in recording o, dBFS
    meas = [[_tone_db(chans[o], rate, TONES_HZ[i]) for i in range(8)] for o in range(8)]
    exp = [[PATTERN[(4 + i, 4 + o)] for i in range(8)] for o in range(8)]
    # each tone's source level, from all 8 recordings
    src = []
    for i in range(8):
        d = sorted(meas[o][i] - exp[o][i] for o in range(8))
        src.append((d[3] + d[4]) / 2)
    res = [[meas[o][i] - exp[o][i] - src[i] for i in range(8)] for o in range(8)]

    print("residuals, dB (rows: FPGAmixer input 1-8 = core out 4-11; "
          "cols: tone of USB 1-8 = core in 4-11):")
    print("        " + "".join(f"{h:>7}Hz" for h in TONES_HZ))
    for o in range(8):
        print(f"  in{o + 1}  " + "".join(f"{res[o][i]:+9.2f}" for i in range(8)))
    print("tone levels at the source, dBFS: " + " ".join(f"{s:.1f}" for s in src))
    worst = max(abs(v) for row in res for v in row)
    ok = worst <= PASS_DB
    print(f"analyze: worst residual {worst:.2f} dB -> {'PASS' if ok else 'FAIL'} "
          f"(threshold {PASS_DB} dB)")
    if a.save:
        with open(a.save, "w") as f:
            json.dump({"meas_dbfs": meas, "source_dbfs": src, "residual_db": res}, f, indent=1)
        print(f"saved {a.save}")
    return 0 if ok else 1


def cmd_compare(a):
    x, y = (json.load(open(p)) for p in (a.before, a.after))
    # Residuals, not raw levels: each run is normalised to its own tone
    # levels, so a track fader moved between the recordings is not a fault.
    d = [[y["residual_db"][o][i] - x["residual_db"][o][i] for i in range(8)] for o in range(8)]
    worst, where = max((abs(d[o][i]), (o, i)) for o in range(8) for i in range(8))
    ok = worst <= PASS_DB
    o, i = where
    print(f"compare: worst crosspoint difference {worst:.2f} dB "
          f"(FPGAmixer input {o + 1} x tone {TONES_HZ[i]} Hz = core in {4 + i} -> out {4 + o})"
          f" -> {'PASS' if ok else 'FAIL'}")
    shift = [y["source_dbfs"][i] - x["source_dbfs"][i] for i in range(8)]
    print("tone level changes between the runs (not faults), dB: "
          + " ".join(f"{s:+.1f}" for s in shift))
    return 0 if ok else 1


def cmd_pattern(a):
    print("out\\in " + "".join(f"{i:>7}" for i in range(N)))
    for o in range(N):
        print(f"{o:>6} " + "".join(f"{PATTERN[(i, o)]:7.2f}" for i in range(N)))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set")
    s.add_argument("--host", default="10.0.0.2")
    s.add_argument("--port", type=int, default=8000)
    s.add_argument("--name", default="mixer", help="mixer name (OSC address root)")
    s = sub.add_parser("check-hw")
    s.add_argument("--tools", default="/usr/lib/fpgamixer", help="where mixer_hw.py is")
    s = sub.add_parser("analyze")
    s.add_argument("wav", nargs="+")
    s.add_argument("--save")
    s = sub.add_parser("compare")
    s.add_argument("before")
    s.add_argument("after")
    sub.add_parser("pattern")
    a = p.parse_args()
    return {"set": cmd_set, "check-hw": cmd_check_hw, "analyze": cmd_analyze,
            "compare": cmd_compare, "pattern": cmd_pattern}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
