#!/usr/bin/env python3
"""
ltc_gen.py -- LTC (SMPTE 12M linear timecode) as audio samples: the reference
for ltc_decoder.sv, independent of it. Standard library only; runs on the PC.

  python ltc_gen.py --vectors DIR    the testbench's vectors (regression pre-step)
  python ltc_gen.py --wav DIR        the bench's WAV files, 48 kHz, 24-bit, mono

Vectors (hex, one word per line, for $readmemh):
  ltc_samples.mem   24-bit samples, all the test segments one after the other
  ltc_expect.mem    the frames the decoder must report, in order, each
                    {sample index of the frame's last bit (32), LTC bits 63:0}
  ltc_meta.mem      per segment {first sample, last sample, kind, frames
                    expected}, 32 bits each; kind 1 = LTC (locked at its end),
                    0 = not LTC (never locks), 2 = below the slicer (no signal)
  ltc_params.svh    the counts as localparams for the testbench

A segment's first and last frames are never expected. The first: the decoder
reports a frame only after a previous sync word. The last: its final bit is
known only at the next frame's first edge, and no frame follows it.
"""

import argparse
import math
import os
import random
import struct
import wave

FS = 48000
FULL = (1 << 23) - 1
SYNC = (0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1)    # bits 64..79, in the order sent

# name: (frames per second, nominal frames per second, drop-frame)
RATES = {
    "23.976": (24000 / 1001, 24, False),
    "24": (24.0, 24, False),
    "25": (25.0, 25, False),
    "29.97": (30000 / 1001, 30, False),
    "29.97df": (30000 / 1001, 30, True),
    "30": (30.0, 30, False),
}


def frame_bits(h, m, s, f, nominal, drop, user=0):
    """The 80 bits of one frame, bit 0 first (the order they are sent)."""
    b = [0] * 80

    def put(pos, width, value):
        for i in range(width):
            b[pos + i] = (value >> i) & 1

    put(0, 4, f % 10)
    put(8, 2, f // 10)
    b[10] = 1 if drop else 0
    put(16, 4, s % 10)
    put(24, 3, s // 10)
    put(32, 4, m % 10)
    put(40, 3, m // 10)
    put(48, 4, h % 10)
    put(56, 2, h // 10)
    for i, pos in enumerate((4, 12, 20, 28, 36, 44, 52, 60)):   # the user bit groups
        put(pos, 4, (user >> (4 * i)) & 0xF)
    b[64:80] = SYNC
    # The polarity correction bit makes the frame's count of zeros even, so
    # every sync word starts with the same polarity.
    parity_bit = 59 if nominal == 25 else 27
    if b.count(0) % 2:
        b[parity_bit] ^= 1
    return b


def next_label(h, m, s, f, nominal, drop):
    f += 1
    if f == nominal:
        f = 0
        s += 1
        if s == 60:
            s = 0
            m += 1
            if m == 60:
                m = 0
                h = (h + 1) % 24
    if drop and s == 0 and f < 2 and m % 10:
        f = 2
    return h, m, s, f


def labels(start, count, nominal, drop):
    t = start
    for _ in range(count):
        yield t
        t = next_label(*t, nominal, drop)


def bits_to_word(bits):
    return sum(bit << i for i, bit in enumerate(bits[:64]))


def render(start, n_frames, rate="30", amp=0.5, speed=1.0, invert=False, rise=2.0,
           clip=False, noise=0.0, seed=1, user=0):
    """One segment: (samples as ints, [(index of last bit's sample, word)]).
    Biphase mark: the level flips at every bit start, and in mid-bit for a 1.
    `rise` is the edge's length in samples (SMPTE: about 25 us = 1.2 samples)."""
    fps, nominal, drop = RATES[rate]
    bit_len = FS / (fps * speed * 80)
    rng = random.Random(seed)
    edges = []                     # (time in samples, level after the edge)
    frames = []
    level = -1
    t = 8.0                        # a little silence first
    for label in labels(start, n_frames, nominal, drop):
        bits = frame_bits(*label, nominal, drop, user)
        for bit in bits:
            level = -level
            edges.append((t, level))
            if bit:
                level = -level
                edges.append((t + bit_len / 2, level))
            t += bit_len
        frames.append((t, bits_to_word(bits)))
    n = int(t) + 16
    out = []
    e = 0
    cur = -edges[0][1]
    for i in range(n):
        while e < len(edges) and edges[e][0] + rise / 2 <= i:
            cur = edges[e][1]
            e += 1
        v = float(cur)
        if e < len(edges) and edges[e][0] - rise / 2 < i:      # inside an edge's ramp
            v = cur + (edges[e][1] - cur) * (i - (edges[e][0] - rise / 2)) / rise
        if i < edges[0][0] - rise / 2 or i > edges[-1][0] + bit_len:
            v = 0.0                # silence before and after
        x = v * amp
        if invert:
            x = -x
        if noise:
            x += rng.gauss(0.0, noise)
        if clip:
            x = max(-amp / 4, min(amp / 4, x)) * 4
        out.append(max(-FULL - 1, min(FULL, int(round(x * FULL)))))
    # the expected list (see the header), each at the sample where the frame ends
    return out, [(int(math.ceil(end)), word) for end, word in frames[1:-1]]


def silence(n):
    return [0] * n


def music_like(n, seed):
    """Tones and noise: audio that isn't LTC, and must never lock."""
    rng = random.Random(seed)
    out = []
    for i in range(n):
        x = 0.3 * math.sin(2 * math.pi * 440 * i / FS) + 0.2 * math.sin(2 * math.pi * 1237 * i / FS)
        x += 0.15 * math.sin(2 * math.pi * 2400 * i / FS) + rng.gauss(0.0, 0.05)
        out.append(int(round(max(-1.0, min(1.0, x)) * FULL)))
    return out


def noise_only(n, seed):
    rng = random.Random(seed)
    return [int(round(max(-1.0, min(1.0, rng.gauss(0.0, 0.25))) * FULL)) for _ in range(n)]


def square_at(n, half_period):
    """A steady tone of even intervals: valid half bits with no sync word."""
    return [int(0.5 * FULL) if (i // half_period) % 2 == 0 else -int(0.5 * FULL) for i in range(n)]


GAP = 6000       # silence between segments: longer than the decoder's 4,800-sample hold


def segments():
    """(name, samples, expected frames, must be locked at the end of the signal)"""
    s = []

    def ltc(name, *a, **k):
        x, f = render(*a, **k)
        s.append((name, x, f, True))

    # every rate, across the rollovers that matter
    ltc("30 fps", (1, 0, 0, 0), 40, "30")
    ltc("30 fps, the hour", (0, 59, 59, 20), 20, "30")
    ltc("the day wraps", (23, 59, 59, 20), 20, "30")
    ltc("29.97", (2, 3, 4, 5), 40, "29.97")
    ltc("29.97 drop-frame, a dropped minute", (0, 0, 59, 15), 30, "29.97df")
    ltc("29.97 drop-frame, a kept minute", (0, 9, 59, 15), 30, "29.97df")
    ltc("25 fps", (10, 20, 30, 0), 40, "25")
    ltc("24 fps", (11, 22, 33, 0), 40, "24")
    ltc("23.976", (12, 34, 56, 0), 40, "23.976")
    # the signal's condition
    ltc("inverted", (3, 0, 0, 0), 30, "30", invert=True)
    ltc("inverted 25", (3, 0, 0, 0), 30, "25", invert=True)
    ltc("-40 dBFS", (4, 0, 0, 0), 30, "30", amp=0.01)
    ltc("-40 dBFS 24", (4, 0, 0, 0), 30, "24", amp=0.01)
    ltc("full scale", (5, 0, 0, 0), 30, "30", amp=1.0)
    ltc("clipped", (6, 0, 0, 0), 30, "30", clip=True)
    ltc("slow edges", (7, 0, 0, 0), 30, "30", rise=4.0)
    ltc("noise at -46 dB under the signal", (8, 0, 0, 0), 40, "30", amp=0.5, noise=0.0025, seed=3)
    ltc("noise on a quiet signal", (8, 30, 0, 0), 40, "25", amp=0.05, noise=0.0005, seed=4)
    # the user bits are not timecode, and may hold anything
    ltc("user bits all ones", (9, 0, 0, 0), 30, "30", user=0xFFFFFFFF)
    ltc("user bits random", (9, 1, 0, 0), 30, "25", user=0x5A3CC3A5)
    # speed
    for rate in ("30", "25", "24"):
        ltc(f"0.85x {rate}", (13, 0, 0, 0), 30, rate, speed=0.85)
        ltc(f"1.2x {rate}", (14, 0, 0, 0), 30, rate, speed=1.2)
    # not timecode: nothing may be reported
    s.append(("music", music_like(48000, 5), [], False))
    s.append(("noise", noise_only(48000, 6), [], False))
    s.append(("a steady tone of half bits", square_at(24000, 10), [], False))
    s.append(("a steady tone of full bits", square_at(24000, 20), [], False))
    # below the slicer's threshold (-48 dBFS): not even a signal (must = 2)
    rng = random.Random(7)
    s.append(("noise at -66 dBFS", [int(round(rng.gauss(0.0, 0.0005 / 3) * FULL)) for _ in range(24000)], [], 2))
    # a one-sample spike inside frame 10: that frame is lost, its neighbours aren't
    x, f = render((17, 0, 0, 0), 20, "30")
    spike = 8 + 1600 * 10 + 805
    x[spike] = -x[spike]
    s.append(("a glitch", x, f[:9] + f[10:], True))
    # a damaged 1: frame 10's bit 8 (the frames' tens) gets a half bit and then
    # a full bit. It must not be read as a 0: that frame is lost, the rest shift
    x, f = render((18, 0, 0, 0), 20, "30")
    held = 8 + 1600 * 10 + 8 * 20 + 15
    x = x[:held] + [x[held]] * 10 + x[held:]
    s.append(("a damaged bit", x, f[:9] + [(i + 10, w) for i, w in f[10:]], True))
    # a dropout in the middle: the frames around it are reported, none invented
    a, fa = render((15, 0, 0, 0), 20, "30")
    b, fb = render((15, 0, 2, 0), 20, "30")
    joined = a + silence(1000) + b
    s.append(("a dropout", joined, fa + [(i + len(a) + 1000, w) for i, w in fb], True))
    # a splice: a cut into the middle of another frame
    a, fa = render((16, 0, 0, 0), 20, "30")
    b, fb = render((16, 30, 0, 0), 20, "30")
    cut = len(a) - 900
    fa = [(i, w) for i, w in fa if i <= cut]
    s.append(("a splice", a[:cut] + b[300:], fa + [(i + cut - 300, w) for i, w in fb], True))
    return s


def write_vectors(out):
    os.makedirs(out, exist_ok=True)
    samples, expect, meta = [], [], []
    for name, x, frames, locks in segments():
        base = len(samples)
        samples += x
        expect += [(base + i, w) for i, w in frames]
        meta.append((base, len(samples) - 1, int(locks), len(frames)))
        samples += silence(GAP)
    with open(os.path.join(out, "ltc_samples.mem"), "w") as f:
        f.writelines(f"{v & 0xFFFFFF:06x}\n" for v in samples)
    with open(os.path.join(out, "ltc_expect.mem"), "w") as f:
        f.writelines(f"{i:08x}{w:016x}\n" for i, w in expect)
    with open(os.path.join(out, "ltc_meta.mem"), "w") as f:
        f.writelines(f"{a:08x}{b:08x}{c:08x}{d:08x}\n" for a, b, c, d in meta)
    with open(os.path.join(out, "ltc_params.svh"), "w") as f:
        f.write(f"localparam int N_SAMPLES = {len(samples)};\n")
        f.write(f"localparam int N_EXPECT = {len(expect)};\n")
        f.write(f"localparam int N_SEG = {len(meta)};\n")
        f.write(f"localparam int GAP = {GAP};\n")
    print(f"ltc_gen: {len(samples)} samples, {len(expect)} frames, {len(meta)} segments")


WAVS = (("30", "ltc_30fps_01h.wav", (1, 0, 0, 0)),
        ("25", "ltc_25fps_01h.wav", (1, 0, 0, 0)),
        ("29.97df", "ltc_2997df_01h.wav", (0, 59, 50, 0)),
        ("24", "ltc_24fps_01h.wav", (1, 0, 0, 0)))


def write_wavs(out, seconds=120):
    os.makedirs(out, exist_ok=True)
    for rate, name, start in WAVS:
        x, _ = render(start, int(seconds * RATES[rate][0]), rate, amp=0.25)
        with wave.open(os.path.join(out, name), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(3)
            w.setframerate(FS)
            w.writeframes(b"".join(struct.pack("<i", v)[:3] for v in x))
        print(f"ltc_gen: {name}, {seconds} s from {start[0]:02d}:{start[1]:02d}:{start[2]:02d}:{start[3]:02d}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--vectors", metavar="DIR")
    p.add_argument("--wav", metavar="DIR")
    a = p.parse_args()
    if a.vectors:
        write_vectors(a.vectors)
    if a.wav:
        write_wavs(a.wav)
    if not (a.vectors or a.wav):
        p.print_help()
