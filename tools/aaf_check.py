#!/usr/bin/env python3
"""
Bench checker for IEEE 1722 AAF streams (Phase 9, P9.6). Standard library
only; runs on the Pi and the PC. NOT on the board: its image's Python has
no 'statistics' module (found on the bench, 2026-09-28).

    aaf_check.py pcap FILE [--tai-offset 37] [--rate 48000]
        A tcpdump capture (classic pcap, Ethernet). For every AAF PDU:
        VLAN / PCP, destination, stream ID, header fields, sequence gaps,
        PDU rate, spacing between arrivals (paced ~125 us, or bursts), the
        presentation time minus the arrival time, and which channels carry
        a tone (RMS and a zero-crossing frequency per channel).

    aaf_check.py raw FILE [--channels 8] [--format S24_3BE] [--rate 48000]
        A raw recording (arecord -t raw): RMS and frequency per channel.

    aaf_check.py tone [--seconds 60] [--freq 440] [--level -20] [--channel 1]
                      [--channels 8] [--format S24_3BE] [--rate 48000]
        Writes a continuous sine at a known level (dBFS RMS) on one channel,
        silence on the others, as raw audio to stdout, for aplay:
          python3 aaf_check.py tone | sudo aplay -D avb_tx -t raw -f S24_3BE -c 8 -r 48000 -F 12500

Presentation time vs arrival: the AVTP timestamp is the low 32 bits of the
presentation time in gPTP (TAI) nanoseconds; pcap timestamps are the
capturing host's CLOCK_REALTIME (UTC), so --tai-offset (37 s) is added
before comparing. Only meaningful when that host's system clock follows
its PHC (phc2sys). The talker sets presentation = launch tick +
time_uncertainty + mtt, so a healthy stream arrives well before it (about
mtt ahead, 2 ms for class A), never after.

Capture example (Pi):  sudo timeout 5 tcpdump -i eth4 -w /tmp/s.pcap 'vlan 2 and ether proto 0x22f0'
Design: docs/phase9_status_2026-09-26.md sec. 6.12-6.13.
"""

import argparse
import math
import statistics
import struct
import sys

ETH_P_TSN = 0x22F0
ETH_P_8021Q = 0x8100
AVTP_SUBTYPE_AAF = 0x02
FORMATS = {1: ("FLOAT_32BIT", 4), 2: ("INT_32BIT", 4), 3: ("INT_24BIT", 3),
           4: ("INT_16BIT", 2)}
NSR_HZ = {1: 8000, 2: 16000, 3: 32000, 4: 44100, 5: 48000, 6: 88200, 7: 96000,
          8: 176400, 9: 192000, 10: 24000}
RAW_FORMATS = {"S16_BE": 2, "S24_3BE": 3, "S32_BE": 4}


# --------------------------------------------------------------- parsing

def read_pcap(path):
    """Yield (timestamp_s as float, frame bytes) from a classic pcap file
    (micro- or nanosecond resolution, either byte order, Ethernet)."""
    with open(path, "rb") as f:
        hdr = f.read(24)
        if len(hdr) < 24:
            raise SystemExit(f"{path}: not a pcap file")
        magic = struct.unpack("<I", hdr[:4])[0]
        if magic in (0xA1B2C3D4, 0xA1B23C4D):
            e = "<"
        elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
            e = ">"
            magic = struct.unpack(">I", hdr[:4])[0]
        else:
            raise SystemExit(f"{path}: not a classic pcap file (pcapng? use tcpdump -w)")
        frac = 1e-9 if magic == 0xA1B23C4D else 1e-6
        linktype = struct.unpack(e + "I", hdr[20:24])[0]
        if linktype != 1:
            raise SystemExit(f"{path}: link type {linktype}, expected Ethernet (1)")
        while True:
            rec = f.read(16)
            if len(rec) < 16:
                return
            sec, sub, incl, _orig = struct.unpack(e + "IIII", rec)
            data = f.read(incl)
            if len(data) < incl:
                return
            yield sec + sub * frac, data


def parse_aaf(frame):
    """An AAF PDU from an Ethernet frame (tagged or not), as a dict, or None."""
    if len(frame) < 14:
        return None
    dst = frame[0:6]
    etype = struct.unpack(">H", frame[12:14])[0]
    off, vlan = 14, None
    if etype == ETH_P_8021Q:
        tci, etype = struct.unpack(">HH", frame[14:18])
        vlan = (tci >> 13, tci & 0x0FFF)       # (PCP, VID)
        off = 18
    if etype != ETH_P_TSN or len(frame) < off + 24:
        return None
    h = frame[off:off + 24]
    if h[0] != AVTP_SUBTYPE_AAF:
        return None
    fmt = h[16]
    nsr = h[17] >> 4
    chans = ((h[17] & 0x03) << 8) | h[18]
    length = struct.unpack(">H", h[20:22])[0]
    return {
        "dst": dst, "vlan": vlan,
        "sv": h[1] >> 7, "version": (h[1] >> 4) & 7, "mr": (h[1] >> 3) & 1,
        "tv": h[1] & 1, "seq": h[2],
        "stream_id": h[4:12],
        "ts": struct.unpack(">I", h[12:16])[0],
        "format": fmt, "nsr": nsr, "channels": chans, "bit_depth": h[19],
        "length": length, "sp": (h[22] >> 4) & 1,
        "payload": frame[off + 24: off + 24 + length],
    }


def samples_be(payload, width):
    """Signed big-endian samples of `width` bytes, full scale = 1.0."""
    n = len(payload) // width
    scale = float(1 << (8 * width - 1))
    out = []
    for i in range(n):
        b = payload[i * width:(i + 1) * width]
        v = int.from_bytes(b, "big", signed=True)
        out.append(v / scale)
    return out


# -------------------------------------------------------------- analysis

def channel_report(chans, rate):
    """[(rms_dbfs, freq_hz)] per channel: RMS, and the frequency from
    positive-going zero crossings (fine for a clean tone)."""
    res = []
    for x in chans:
        if not x:
            res.append((float("-inf"), 0.0))
            continue
        m = sum(x) / len(x)
        rms = math.sqrt(sum((v - m) ** 2 for v in x) / len(x))
        db = 20 * math.log10(rms) if rms > 0 else float("-inf")
        ups = [i for i in range(1, len(x)) if x[i - 1] - m < 0 <= x[i] - m]
        f = (len(ups) - 1) * rate / (ups[-1] - ups[0]) if len(ups) > 2 else 0.0
        res.append((db, f))
    return res


def print_channels(rep, tone_db=-60.0):
    for c, (db, f) in enumerate(rep):
        tag = f"{f:8.1f} Hz" if db > tone_db else "   (quiet)"
        print(f"  ch {c + 1}: {db:7.1f} dBFS {tag}")


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(p / 100 * (len(xs) - 1)))))]


def summarize(items, tai_offset, rate_hint):
    """One stream's [(arrival_s, pdu)] -> a dict of everything reported."""
    p0 = items[0][1]
    fmt_name, width = FORMATS.get(p0["format"], (f"format {p0['format']}", 0))
    rate = NSR_HZ.get(p0["nsr"], rate_hint)
    n = len(items)
    span = items[-1][0] - items[0][0]
    s = {
        "stream_id": bytes(p0["stream_id"]), "dst": bytes(p0["dst"]),
        "vlans": sorted({p["vlan"] for _, p in items}, key=str),
        "format": fmt_name, "channels": p0["channels"], "rate": rate,
        "bit_depth": p0["bit_depth"], "length": p0["length"],
        "sv": p0["sv"], "tv": p0["tv"], "version": p0["version"],
        "n": n, "span": span, "per_s": (n - 1) / span if span > 0 else 0.0,
        "seq_gaps": sum(1 for (_, a), (_, b) in zip(items, items[1:])
                        if (b["seq"] - a["seq"]) % 256 != 1),
        "dt_us": [(b[0] - a[0]) * 1e6 for a, b in zip(items, items[1:])],
    }
    # presentation time minus arrival, both as TAI ns modulo 2^32
    lead = []
    for t, p in items:
        arr = int(round((t + tai_offset) * 1e9)) & 0xFFFFFFFF
        d = (p["ts"] - arr) & 0xFFFFFFFF
        if d >= 1 << 31:
            d -= 1 << 32
        lead.append(d / 1000.0)
    s["lead_us"] = lead
    s["late"] = sum(1 for x in lead if x < 0)
    s["chan"] = []
    if width:
        ch = [[] for _ in range(p0["channels"])]
        for _, p in items:
            for i, v in enumerate(samples_be(p["payload"], width)):
                ch[i % p0["channels"]].append(v)
        s["chan"] = channel_report(ch, rate)
    return s


def fmt_mac(b):
    return ":".join(f"{x:02X}" for x in b)


def analyze_pcap(path, tai_offset, rate_hint):
    streams = {}
    for t, frame in read_pcap(path):
        p = parse_aaf(frame)
        if p:
            streams.setdefault(bytes(p["stream_id"]), []).append((t, p))
    if not streams:
        print("no AAF PDUs in the capture")
        return 1
    rc = 0
    for items in streams.values():
        s = summarize(items, tai_offset, rate_hint)
        sid = s["stream_id"]
        print(f"stream {fmt_mac(sid[:6])}:{sid[6:].hex().upper()} -> {fmt_mac(s['dst'])}")
        print(f"  VLAN (PCP, VID): {', '.join(str(v) for v in s['vlans'])}")
        print(f"  {s['format']}, {s['channels']} ch, {s['rate']} Hz, bit depth "
              f"{s['bit_depth']}, {s['length']} B payload, sv {s['sv']} tv {s['tv']} "
              f"version {s['version']}")
        print(f"  {s['n']} PDUs over {s['span']:.3f} s = {s['per_s']:.1f} PDU/s; "
              f"sequence gaps: {s['seq_gaps']}")
        dt = s["dt_us"]
        if dt:
            burst = sum(1 for d in dt if d < 30) / len(dt)
            print(f"  arrival spacing: median {statistics.median(dt):.1f} us, "
                  f"p1 {pct(dt, 1):.1f}, p99 {pct(dt, 99):.1f}, max {max(dt):.1f}; "
                  f"{100 * burst:.1f} % closer than 30 us (bursts)")
        lead = s["lead_us"]
        print(f"  presentation - arrival: median {statistics.median(lead):.0f} us, "
              f"min {min(lead):.0f}, max {max(lead):.0f}; {s['late']} PDUs arrived after "
              f"their presentation time")
        print_channels(s["chan"])
        if s["seq_gaps"] or s["late"]:
            rc = 1
    return rc


def analyze_raw(path, channels, fmt, rate):
    width = RAW_FORMATS[fmt]
    with open(path, "rb") as f:
        data = f.read()
    s = samples_be(data, width)
    ch = [s[c::channels] for c in range(channels)]
    print(f"{path}: {len(s) // channels} frames ({len(s) / channels / rate:.2f} s), "
          f"{channels} ch {fmt}")
    print_channels(channel_report(ch, rate))
    return 0


def tone_frames(n_frames, start, freq, level_db, channel, channels, fmt, rate):
    """Raw big-endian frames [start, start + n_frames): a sine whose RMS is
    level_db dBFS on `channel` (1-based), zeros elsewhere."""
    width = RAW_FORMATS[fmt]
    full = (1 << (8 * width - 1)) - 1
    amp = math.sqrt(2) * 10 ** (level_db / 20)
    zero = bytes(width)
    out = bytearray()
    for k in range(start, start + n_frames):
        v = int(round(amp * full * math.sin(2 * math.pi * freq * k / rate)))
        s = v.to_bytes(width, "big", signed=True)
        for c in range(channels):
            out += s if c == channel - 1 else zero
    return bytes(out)


def write_tone(a, out=None):
    out = out or sys.stdout.buffer
    if not 1 <= a.channel <= a.channels:
        raise SystemExit("tone: --channel must be 1..--channels")
    if a.level > -3.02:
        raise SystemExit("tone: --level must be at most -3.02 dBFS (a sine's peak is +3 dB)")
    if a.freq != int(a.freq) or a.freq <= 0:
        raise SystemExit("tone: --freq must be a whole number of Hz (one second is looped)")
    # One second, computed once and repeated: an integer frequency makes it
    # seamless, and the board's CPU can't compute samples one by one in time.
    second = tone_frames(a.rate, 0, a.freq, a.level, a.channel, a.channels,
                         a.format, a.rate)
    frame = len(second) // a.rate
    left = int(a.seconds * a.rate)
    try:
        while left > 0:
            n = min(a.rate, left)
            out.write(second[:n * frame])
            left -= n
        out.flush()
    except BrokenPipeError:
        pass
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("pcap")
    a.add_argument("file")
    a.add_argument("--tai-offset", type=float, default=37.0)
    a.add_argument("--rate", type=int, default=48000)
    b = sub.add_parser("raw")
    b.add_argument("file")
    b.add_argument("--channels", type=int, default=8)
    b.add_argument("--format", default="S24_3BE", choices=sorted(RAW_FORMATS))
    b.add_argument("--rate", type=int, default=48000)
    c = sub.add_parser("tone")
    c.add_argument("--seconds", type=float, default=60.0)
    c.add_argument("--freq", type=float, default=440.0)
    c.add_argument("--level", type=float, default=-20.0, help="dBFS RMS")
    c.add_argument("--channel", type=int, default=1)
    c.add_argument("--channels", type=int, default=8)
    c.add_argument("--format", default="S24_3BE", choices=sorted(RAW_FORMATS))
    c.add_argument("--rate", type=int, default=48000)
    args = ap.parse_args(argv)
    if args.cmd == "tone":
        return write_tone(args)
    if args.cmd == "pcap":
        return analyze_pcap(args.file, args.tai_offset, args.rate)
    return analyze_raw(args.file, args.channels, args.format, args.rate)


if __name__ == "__main__":
    sys.exit(main())
