#!/usr/bin/env python3
"""
Phase 8 bench test S4 (the Phase 6 follow-up): the power-cycle restore test
with real audio on every crosspoint. Standard library only, so the same file
runs on the Pi, the board and the Mac. `set` also needs the shared
osc_codec.py next to it (TCP framing: --tcp-framing, default len32); the
other subcommands run from this file alone.

The idea: every one of the 400 crosspoints of the 20 x 20 core (Phase 9,
P9.5: 4 Pmod + 8 USB (link #1) + 8 AVB (link #2) channels) gets its own
level (PATTERN). The Mac plays one tone per USB input (TONES_HZ, FPGAmixer
outputs 1-8 = core inputs 4-11) and records FPGAmixer inputs 1-8 (core
outputs 4-11). Each recording is then a mix of the 8 tones at 8 known levels,
so measuring every tone's amplitude in every recording recovers the gain of
all 64 USB -> USB crosspoints. The other 336 (those that touch the Pmods,
whose input signals are unknown, and the AVB channels, which have no source
on this bench yet) are checked through the gain registers, and JB_L/JC_L by
ear. The 144 levels of the Phase 8 (12 x 12) test are unchanged; the 256 AVB
crosspoints use level ranges of their own (build_pattern), so a bank written
to the wrong place can't match by accident.

Phase 12 adds the bus layer: input levels -> inputMatrix (now input -> bus)
-> bus levels -> busMatrix -> output levels. BUS_PATTERN gives 32 of those
parameters their own levels, on the AVB channels only, so everything above
still holds (input k -> bus k -> output k at 0 dB elsewhere); check-hw reads
all four bus-layer windows too (860 registers in all). --no-bus-layer: the
old 400 only.

    set      (Mac)    send all 400 (+32) levels over OSC, check each echo
    check-hw (board)  read all gain registers, compare with the patterns
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
import os
import sys
import wave

N = 20
PMOD = range(0, 4)          # core channels 0-3: JB_L, JB_R, JC_L, JC_R
USB = range(4, 12)          # core channels 4-11: link #1 / USB 1-8
AVB = range(12, 20)         # core channels 12-19: link #2 / AVB 1-8 (P9.5)
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
    # --- P9.5: the AVB channels (link #2). Ranges disjoint from the above
    # and from each other; the finest steps are below the Q2.16 resolution
    # at the lowest levels, so not every code is unique there, only every
    # range.
    # AVB -> AVB: like USB -> USB, on the quarter dB (-6.25 .. -37.75).
    for o in AVB:
        for i in AVB:
            k = (o - 12) * 8 + (i - 12)
            p[(i, o)] = -6.25 - 0.5 * ((k * 29) % 64)
    # USB -> AVB: -38.0 .. -45.875
    k = 0
    for o in AVB:
        for i in USB:
            p[(i, o)] = -38.0 - 0.125 * k
            k += 1
    # AVB -> Pmod: -46.0 .. -49.875
    k = 0
    for o in PMOD:
        for i in AVB:
            p[(i, o)] = -46.0 - 0.125 * k
            k += 1
    # Pmod -> AVB: -64.0 .. -67.875
    k = 0
    for o in AVB:
        for i in PMOD:
            p[(i, o)] = -64.0 - 0.125 * k
            k += 1
    # AVB -> USB: the lowest (-78.0 .. -85.875), so an AVB source, once there
    # is one, barely touches the USB tone measurement.
    k = 0
    for o in USB:
        for i in AVB:
            p[(i, o)] = -78.0 - 0.125 * k
            k += 1
    assert len(p) == N * N
    return p


PATTERN = build_pattern()


def build_bus_pattern():
    """Phase 12: {OSC tail: dB} for the bus layer, ON THE AVB CHANNELS ONLY
    (they have no source on the bench), so the USB audio analysis and the
    Pmods by ear still see input k -> bus k -> output k at 0 dB. Ranges
    disjoint from each other: input levels -1.0 .. -2.75, bus levels
    -3.0 .. -4.75, output levels -5.0 .. -6.75, and AVB bus b -> AVB output
    b+1 (wrapping) at -20.0 .. -21.75 in the bus matrix."""
    p = {}
    for n, c in enumerate(AVB):
        p[f"inputChannel/{c}/level"] = -1.0 - 0.25 * n
        p[f"busChannel/{c}/level"] = -3.0 - 0.25 * n
        p[f"outputChannel/{c}/level"] = -5.0 - 0.25 * n
        p[f"busMatrix/{c}_{AVB[(n + 1) % len(AVB)]}/level"] = -20.0 - 0.25 * n
    return p


BUS_PATTERN = build_bus_pattern()


def bus_layer_expected():
    """What the four bus-layer windows must hold after `set`: the reset state
    (bus matrix identity, levels 0 dB) with BUS_PATTERN on top.
    {window: {index: dB}}, index (out, bus) for the bus matrix, else channel."""
    exp = {"busmatrix": {(o, b): (0.0 if o == b else OFF_DB) for o in range(N) for b in range(N)},
           "inlevel": {c: 0.0 for c in range(N)},
           "buslevel": {c: 0.0 for c in range(N)},
           "outlevel": {c: 0.0 for c in range(N)}}
    window = {"inputChannel": "inlevel", "busChannel": "buslevel", "outputChannel": "outlevel"}
    for tail, db in BUS_PATTERN.items():
        zone, index, _module = tail.split("/")
        if zone == "busMatrix":
            b, o = (int(x) for x in index.split("_"))
            exp["busmatrix"][(o, b)] = db
        else:
            exp[window[zone]][int(index)] = db
    return exp


# ----------------------------------------------------------------- OSC (set)

def cmd_set(a):
    # Only `set` speaks OSC, so only it needs the shared codec next to this
    # file; analyze/compare/pattern still run from this file alone (the Mac).
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from osc_codec import TCPLink
    link = TCPLink(a.host, a.port, timeout=3, framing=a.tcp_framing).connect()
    params = [(f"inputMatrix/{i}_{o}/level", db)
              for (i, o), db in sorted(PATTERN.items(), key=lambda x: (x[0][1], x[0][0]))]
    if not a.no_bus_layer:
        params += sorted(BUS_PATTERN.items())
    bad = 0
    for tail, db in params:
        addr = f"/{a.name}/set/{tail}"
        link.send_message(addr, [float(db)])
        while True:                                  # wait for this echo (or its refusal)
            try:
                m = link.read_message()
            except ConnectionResetError:
                sys.exit("connection closed by the server")
            if m.address == addr or (m.address.endswith("/error") and m.args and m.args[0] == tail):
                break
        if m.address != addr:
            print(f"  {tail}: refused ({m.args[1] if len(m.args) > 1 else '?'})")
            bad += 1
            continue
        got = m.args[0] if m.args else None
        if got is None or abs(got - db) > 0.01:
            print(f"  {tail}: sent {db}, echoed {got}")
            bad += 1
    link.close()
    print(f"set: {len(params)} levels sent, {len(params) - bad} echoed as sent, {bad} differ")
    return 1 if bad else 0


# ------------------------------------------------------------ check-hw (board)

def cmd_check_hw(a):
    sys.path.insert(0, a.tools)
    import mixer_hw
    m = mixer_hw.open_window("matrix")
    if (m.n_in, m.n_out) != (N, N):
        sys.exit(f"matrix is {m.n_in}x{m.n_out}, expected {N}x{N}")
    bad = total = 0
    for (i, o), db in sorted(PATTERN.items()):
        want = mixer_hw.db_to_code(db, m.gain_frac, m.gain_width)[0]
        got = m.read_coef(o * m.n_in + i)
        total += 1
        if got != want:
            print(f"  inputMatrix {i}_{o}: register {got:#x}, expected {want:#x} ({db} dB)")
            bad += 1
    if not a.no_bus_layer:                           # Phase 12: the four bus-layer windows
        for name, levels in bus_layer_expected().items():
            w = mixer_hw.open_window(name)
            for index, db in sorted(levels.items()):
                want = mixer_hw.db_to_code(db, w.gain_frac, w.gain_width)[0]
                got = w.read_coef(index[0] * w.n_in + index[1] if name == "busmatrix" else index)
                total += 1
                if got != want:
                    print(f"  {name} {index}: register {got:#x}, expected {want:#x} ({db} dB)")
                    bad += 1
    print(f"check-hw: {total - bad}/{total} gain registers match the pattern")
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
    s.add_argument("--tcp-framing", choices=("len32", "none"), default="len32",
                   help="TCP framing the mixer uses (default len32; none for older firmware)")
    s.add_argument("--no-bus-layer", action="store_true",
                   help="inputMatrix only (a mixer from before Phase 12)")
    s = sub.add_parser("check-hw")
    s.add_argument("--tools", default="/usr/lib/fpgamixer", help="where mixer_hw.py is")
    s.add_argument("--no-bus-layer", action="store_true",
                   help="the input matrix only (a bitstream from before Phase 12)")
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
