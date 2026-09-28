#!/usr/bin/env python3
"""
Unit tests for aaf_check.py: a synthetic capture of an AAF stream, packed
here independently of the parser (field positions from libavtp 0.2.0,
src/avtp_stream.c and src/avtp_aaf.c), then read back. Runs anywhere:

    python3 -m unittest -v test_aaf_check          (from tools/)
"""

import math
import os
import shutil
import struct
import tempfile
import unittest

import aaf_check

DST = bytes.fromhex("91E0F000FE00")
SRC = bytes.fromhex("00183E050648")
SID = SRC + b"\x00\x00"
TAI = 37.0


def aaf_frame(seq, ts, samples, chans=8, width=3, vlan=(3, 2)):
    """One VLAN-tagged AAF PDU, INT_24BIT (width 3) or INT_16BIT (width 2)."""
    payload = b"".join(int(round(v * ((1 << (8 * width - 1)) - 1))).to_bytes(
        width, "big", signed=True) for v in samples)
    fmt = {3: 0x03, 2: 0x04}[width]
    w0 = (0x02 << 24) | (1 << 23) | (0 << 20) | (1 << 16) | (seq << 8)  # subtype, sv, version 0, tv
    w4 = (fmt << 24) | (0x05 << 20) | (chans << 8) | (8 * width)          # format, NSR 48 kHz, chans, depth
    w5 = (len(payload) << 16) | (1 << 12)                                 # length, sp
    avtp = struct.pack(">I", w0) + SID + struct.pack(">III", ts, w4, w5) + payload
    tag = struct.pack(">HH", 0x8100, (vlan[0] << 13) | vlan[1])
    return DST + SRC + tag + struct.pack(">H", 0x22F0) + avtp


def write_pcap(path, records, nano=False):
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B23C4D if nano else 0xA1B2C3D4,
                            2, 4, 0, 0, 65535, 1))
        for t, data in records:
            sec = int(t)
            sub = int(round((t - sec) * (1e9 if nano else 1e6)))
            f.write(struct.pack("<IIII", sec, sub, len(data), len(data)) + data)


def stream(n_pdus=4000, spacing=125e-6, lead=2e-3, t0=1_790_000_000.25, drop=None,
           burst=False):
    """8 ch, 6 frames/PDU: 440 Hz on ch 1, 1000 Hz on ch 2 at -6 dBFS, rest silent."""
    recs, k = [], 0
    for i in range(n_pdus):
        s = []
        for _ in range(6):
            a = 0.5 * math.sin(2 * math.pi * 440 * k / 48000)
            b = 0.5 * math.sin(2 * math.pi * 1000 * k / 48000)
            s += [a, b] + [0.0] * 6
            k += 1
        t = t0 + (i // 8) * 8 * spacing + (i % 8) * 1e-6 if burst else t0 + i * spacing
        ts = int(round((t0 + i * spacing + lead + TAI) * 1e9)) & 0xFFFFFFFF
        if drop is not None and i == drop:
            continue
        recs.append((t, aaf_frame(i % 256, ts, s)))
    return recs


class Pcap(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="aafchk-")
        self.path = os.path.join(self.d, "s.pcap")

    def tearDown(self):
        shutil.rmtree(self.d)

    def summary(self, recs, nano=False):
        write_pcap(self.path, recs, nano)
        items = []
        for t, fr in aaf_check.read_pcap(self.path):
            p = aaf_check.parse_aaf(fr)
            self.assertIsNotNone(p)
            items.append((t, p))
        return aaf_check.summarize(items, TAI, 48000)

    def test_header_fields(self):
        s = self.summary(stream(100))
        self.assertEqual(s["stream_id"], SID)
        self.assertEqual(s["dst"], DST)
        self.assertEqual(s["vlans"], [(3, 2)])
        self.assertEqual((s["format"], s["channels"], s["rate"], s["bit_depth"], s["length"]),
                         ("INT_24BIT", 8, 48000, 24, 144))
        self.assertEqual((s["sv"], s["tv"], s["version"]), (1, 1, 0))

    def test_rate_gaps_spacing(self):
        s = self.summary(stream(4000))
        self.assertAlmostEqual(s["per_s"], 8000, delta=1)
        self.assertEqual(s["seq_gaps"], 0)
        self.assertAlmostEqual(sorted(s["dt_us"])[len(s["dt_us"]) // 2], 125, delta=1)

    def test_seq_gap_counted(self):
        self.assertEqual(self.summary(stream(1000, drop=500))["seq_gaps"], 1)

    def test_bursts_seen(self):
        s = self.summary(stream(800, burst=True))
        close = sum(1 for d in s["dt_us"] if d < 30) / len(s["dt_us"])
        self.assertGreater(close, 0.8)       # 7 of every 8 gaps are 1 us

    def test_presentation_lead(self):
        for nano in (False, True):
            s = self.summary(stream(400, lead=2e-3), nano)
            self.assertTrue(all(abs(x - 2000) < 2 for x in s["lead_us"]), nano)
            self.assertEqual(s["late"], 0)
        s = self.summary(stream(400, lead=-300e-6))
        self.assertEqual(s["late"], 400)

    def test_tones_per_channel(self):
        s = self.summary(stream(4000))
        (db1, f1), (db2, f2) = s["chan"][0], s["chan"][1]
        self.assertAlmostEqual(f1, 440, delta=1)
        self.assertAlmostEqual(f2, 1000, delta=1)
        self.assertAlmostEqual(db1, 20 * math.log10(0.5 / math.sqrt(2)), delta=0.1)
        self.assertTrue(all(db == float("-inf") for db, _ in s["chan"][2:]))

    def test_not_aaf_ignored(self):
        self.assertIsNone(aaf_check.parse_aaf(DST + SRC + b"\x08\x00" + bytes(40)))


class Raw(unittest.TestCase):
    def test_raw_channels(self):
        d = tempfile.mkdtemp()
        try:
            p = os.path.join(d, "r.raw")
            with open(p, "wb") as f:
                for k in range(48000):
                    v = int(0.25 * 8388607 * math.sin(2 * math.pi * 440 * k / 48000))
                    f.write(b"".join((v if c == 3 else 0).to_bytes(3, "big", signed=True)
                                     for c in range(8)))
            with open(p, "rb") as f:
                s = aaf_check.samples_be(f.read(), 3)
            rep = aaf_check.channel_report([s[c::8] for c in range(8)], 48000)
            self.assertAlmostEqual(rep[3][1], 440, delta=1)
            self.assertEqual(rep[0][0], float("-inf"))
        finally:
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
