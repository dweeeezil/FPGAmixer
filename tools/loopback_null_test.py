#!/usr/bin/env python3
"""
Bit-exact loopback null test (hardening T1, docs/hardening_status_2026-10-10.md).

Plays a deterministic pseudo-random 24-bit sequence on one or more output
channels of an audio device, records one or more input channels, and checks
EVERY received sample against the sequence. Route the board so the signal
comes back at unity (patch, levels 0 dB, one crosspoint 0 dB, nothing else
into that bus): the mixer's arithmetic is exact at unity, so every sample
must match. Anything else is reported with its time:

  error   one received sample is wrong and the sequence continues where it
          should (a corrupted sample)
  slip    the sequence continues at another place: samples dropped (slip -n)
          or repeated (slip +n). This is what a clock-domain slip or a FIFO
          under/overrun looks like, even when it is far too quiet to hear
  lost    lock lost (silence, noise, a route change), regained later

Output channel c carries the sequence c * STRIDE samples ahead, so with one
device for both directions (USB -> USB, AVB -> AVB: a duplex stream) the tool
tells which output channel each input came from (a routing check) and the
round-trip latency in samples (the Mac's own buffering included). With two
devices (USB -> AVB) it checks continuity only: every sample must arrive, in
order; the source and latency aren't knowable from one side.

The Mac's own glitches (PortAudio input overflow, output underflow) are
counted separately, so a slip can be told apart from a Mac-side hiccup.

Needs python3 and `pip3 install sounddevice` (no numpy: raw streams and the
standard library). In Audio MIDI Setup set the device(s) to 48 kHz and the
output volume to full (0 dB): any volume below 0 dB, or a rate conversion,
changes every sample.

Usage (on the Mac):
    python3 loopback_null_test.py --list
    python3 loopback_null_test.py --device FPGAmixer --out 1 --in 1 --minutes 60
    python3 loopback_null_test.py --out-device FPGAmixer --in-device "AVB" --out 1,2 --in 1,2
    options: --level-db -20 (default), --report 10 (seconds), --log run.log
Exit code 0 only if samples were checked and every one matched.
"""

import argparse
import queue
import sys
import threading
import time
from array import array

PERIOD = 1 << 17              # sequence length in samples: 2.73 s at 48 kHz
MAX_OUT = 8                   # output channels the offsets can tell apart
STRIDE = PERIOD // MAX_OUT    # 16384 samples (341 ms) between their copies
KEY_LEN = 3                   # received samples that locate a position
SEED = 0x5EED_F00D
RATE = 48000


def make_sequence(level_db=-20.0, period=PERIOD, seed=SEED):
    """`period` pseudo-random 24-bit samples, left-justified in int32 (as
    CoreAudio delivers 24-bit audio), uniform within +-level dBFS and never
    0, so silence never matches. xorshift32: the same on every machine."""
    amp = int(round((1 << 23) * 10.0 ** (level_db / 20.0)))
    amp = max(1, min(amp, (1 << 23) - 1))
    x = seed & 0xFFFF_FFFF
    out = array("i", bytes(4 * period))
    for n in range(period):
        x ^= (x << 13) & 0xFFFF_FFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFF_FFFF
        v = (x % (2 * amp)) - amp
        out[n] = (v + 1 if v >= 0 else v) << 8     # -amp .. -1, 1 .. amp
    return out


class Locator:
    """Where KEY_LEN consecutive received samples sit in the sequence.
    Keys that occur twice are dropped: they never lock."""

    def __init__(self, seq):
        n = len(seq)
        self.index, dup = {}, set()
        for i in range(n):
            k = (seq[i], seq[(i + 1) % n], seq[(i + 2) % n])
            if k in self.index:
                dup.add(k)
            self.index[k] = i
        for k in dup:
            del self.index[k]

    def find(self, a, j):
        """The sequence index of a[j], or None; needs a[j : j + KEY_LEN]."""
        if j + KEY_LEN > len(a):
            return None
        return self.index.get((a[j], a[j + 1], a[j + 2]))


class ChannelChecker:
    """One received channel against the sequence. feed(block, frame) takes
    the channel's samples in order, in blocks of any size, with the stream
    frame number of the block's first sample. While locked, `offset` is
    (frame - sequence index) mod PERIOD; a slip is a change of it. events:
    (frame, kind, detail), kind in lock, error, slip, lost."""

    def __init__(self, seq, locator):
        self.seq, self.loc, self.n = seq, locator, len(seq)
        self.locked = False
        self.expect = 0            # sequence index of the next sample
        self.offset = None         # (frame - index) mod n of the current lock
        self.checked = 0           # samples that matched
        self.unlocked = 0          # samples seen while not locked
        self.errors = self.slips = self.losses = 0
        self.events = []
        self.pending = array("i")  # samples kept for a decision that needs more
        self.pending_frame = None

    def _expected(self, start, count):
        end = start + count
        if end <= self.n:
            return self.seq[start:end]
        return self.seq[start:] + self.seq[:end - self.n]

    def _lock(self, i, frame):
        new = (frame - i) % self.n
        if self.offset is None:
            self.events.append((frame, "lock", f"sequence index {i}"))
        elif new != self.offset:
            d = (new - self.offset) % self.n
            d = d - self.n if d > self.n // 2 else d
            self.slips += 1
            self.events.append((frame, "slip", f"{d:+d} samples "
                                f"({'repeated' if d > 0 else 'dropped'})"))
        else:
            self.events.append((frame, "lock", "again, same position"))
        self.offset, self.expect, self.locked = new, i, True

    def feed(self, block, frame):
        if self.pending:
            a, frame0 = self.pending + block, self.pending_frame
        else:
            a, frame0 = block, frame
        n, j = len(a), 0
        while j < n:
            if not self.locked:
                while j + KEY_LEN <= n:
                    i = self.loc.find(a, j)
                    if i is not None:
                        self._lock(i, frame0 + j)
                        break
                    self.unlocked += 1
                    j += 1
                if not self.locked:
                    break                   # keep the tail: it may start a key
                continue
            exp = self._expected(self.expect, n - j)
            if a[j:] == exp:
                self.checked += n - j
                self.expect = (self.expect + n - j) % self.n
                j = n
                break
            k = j
            while a[k] == exp[k - j]:
                k += 1
            self.checked += k - j
            self.expect = (self.expect + k - j) % self.n
            j = k
            if k + 1 + KEY_LEN > n:
                break                       # decide when more samples arrive
            if a[k + 1:k + 1 + KEY_LEN] == self._expected((self.expect + 1) % self.n, KEY_LEN):
                self.errors += 1
                self.events.append((frame0 + k, "error", f"got {a[k] >> 8}, "
                                    f"expected {self.seq[self.expect] >> 8}"))
                self.expect = (self.expect + 1) % self.n
                j = k + 1
                continue
            i = self.loc.find(a, k)
            if i is not None:
                self._lock(i, frame0 + k)   # a slip: the loop checks on from k
                continue
            self.locked = False
            self.losses += 1
            self.events.append((frame0 + k, "lost", "lock lost"))
        self.pending = a[j:]
        self.pending_frame = frame0 + j

    def source_and_latency(self):
        """For a duplex stream (one device both ways, one frame counter):
        (output channel, latency in samples), assuming the round trip is
        shorter than STRIDE; (None, None) when not locked."""
        if self.offset is None:
            return None, None
        back = (-self.offset) % self.n        # = channel * STRIDE - latency
        ch = -(-back // STRIDE) % MAX_OUT       # ceil(back / STRIDE)
        return ch, (ch * STRIDE - back) % self.n


# ----------------------------------------------------------------------------
# Audio (the Mac): only below this line needs sounddevice.
# ----------------------------------------------------------------------------

def output_tape(seq, out_channels, n_channels):
    """One period of interleaved int32 frames: output channel c (0-based,
    within out_channels) carries seq c * STRIDE ahead; other channels 0."""
    tape = array("i", bytes(4 * len(seq) * n_channels))
    for c in out_channels:
        off = c * STRIDE
        rotated = seq[off:] + seq[:off]
        tape[c::n_channels] = rotated
    return tape.tobytes()


def channel_list(text):
    chans = [int(x) - 1 for x in text.split(",") if x.strip()]
    if not chans or min(chans) < 0:
        raise argparse.ArgumentTypeError("channels are 1-based, e.g. 1 or 1,2")
    return chans


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--list", action="store_true", help="list audio devices and exit")
    p.add_argument("--device", help="one device for both directions (duplex: latency + source)")
    p.add_argument("--out-device", help="output device (with --in-device: continuity only)")
    p.add_argument("--in-device", help="input device")
    p.add_argument("--out", type=channel_list, default=[0], help="output channels, 1-based (default 1)")
    p.add_argument("--in", dest="inp", type=channel_list, default=[0], help="input channels (default 1)")
    p.add_argument("--level-db", type=float, default=-20.0, help="sequence level in dBFS (default -20)")
    p.add_argument("--minutes", type=float, default=0, help="stop after this long (default: Ctrl-C)")
    p.add_argument("--report", type=float, default=10.0, help="seconds between reports (default 10)")
    p.add_argument("--block", type=int, default=512, help="frames per audio callback (default 512)")
    p.add_argument("--log", help="also append every report and event to this file")
    args = p.parse_args(argv)

    try:
        import sounddevice as sd
    except ImportError:
        print("needs sounddevice: pip3 install sounddevice", file=sys.stderr)
        return 2
    if args.list:
        print(sd.query_devices())
        return 0
    if max(args.out) >= MAX_OUT:
        p.error(f"at most {MAX_OUT} output channels can be told apart (1..{MAX_OUT})")
    duplex = args.device is not None
    if duplex == bool(args.out_device or args.in_device):
        p.error("give --device, or both --out-device and --in-device")
    out_dev = args.device if duplex else args.out_device
    in_dev = args.device if duplex else args.in_device

    log_file = open(args.log, "a") if args.log else None

    def say(text):
        line = f"{time.strftime('%H:%M:%S')} {text}"
        print(line, flush=True)
        if log_file:
            log_file.write(line + "\n")
            log_file.flush()

    seq = make_sequence(args.level_db)
    loc = Locator(seq)
    n_out, n_in = max(args.out) + 1, max(args.inp) + 1
    tape = output_tape(seq, args.out, n_out)
    frame_bytes = 4 * n_out
    tape_len = len(tape)
    checkers = {c: ChannelChecker(seq, loc) for c in args.inp}
    blocks = queue.Queue()
    mac = {"input overflow": 0, "output underflow": 0, "other": 0}
    state = {"out_pos": 0, "in_frame": 0}

    def note(status):
        if status:
            if status.input_overflow:
                mac["input overflow"] += 1
            if status.output_underflow:
                mac["output underflow"] += 1
            if not (status.input_overflow or status.output_underflow):
                mac["other"] += 1

    def fill(outdata, frames):
        want, pos, out = frames * frame_bytes, state["out_pos"], bytearray()
        while len(out) < want:
            take = min(want - len(out), tape_len - pos)
            out += tape[pos:pos + take]
            pos = (pos + take) % tape_len
        outdata[:] = out
        state["out_pos"] = pos

    def take(indata, frames):
        blocks.put((state["in_frame"], bytes(indata)))
        state["in_frame"] += frames

    if duplex:
        def cb(indata, outdata, frames, t, status):
            note(status)
            fill(outdata, frames)
            take(indata, frames)
        streams = [sd.RawStream(device=(in_dev, out_dev), channels=(n_in, n_out), dtype="int32",
                                samplerate=RATE, blocksize=args.block, callback=cb)]
    else:
        def ocb(outdata, frames, t, status):
            note(status)
            fill(outdata, frames)

        def icb(indata, frames, t, status):
            note(status)
            take(indata, frames)
        streams = [sd.RawOutputStream(device=out_dev, channels=n_out, dtype="int32",
                                      samplerate=RATE, blocksize=args.block, callback=ocb),
                   sd.RawInputStream(device=in_dev, channels=n_in, dtype="int32",
                                     samplerate=RATE, blocksize=args.block, callback=icb)]

    say(f"null test: out {[c + 1 for c in args.out]} on {out_dev!r}, in "
        f"{[c + 1 for c in args.inp]} on {in_dev!r}, {args.level_db} dBFS, "
        f"{'duplex (latency + source)' if duplex else 'two devices (continuity only)'}")
    shown = {c: 0 for c in checkers}
    stop = threading.Event()
    start = time.monotonic()
    next_report = start + args.report

    def report(final=False):
        secs = time.monotonic() - start
        for c, ck in checkers.items():
            extra = ""
            if duplex and ck.offset is not None:
                src, lat = ck.source_and_latency()
                extra = f", from out {src + 1}, latency {lat} samples ({lat / RATE * 1000:.2f} ms)"
            say(f"{'FINAL ' if final else ''}in {c + 1}: {'locked' if ck.locked else 'NOT LOCKED'}, "
                f"{ck.checked} samples ok ({ck.checked / RATE / 60:.1f} min), "
                f"errors {ck.errors}, slips {ck.slips}, losses {ck.losses}{extra}")
        say(f"{'FINAL ' if final else ''}Mac side: {mac}  ({secs / 60:.1f} min)")

    try:
        for s in streams:
            s.start()
        while not stop.is_set():
            try:
                frame, data = blocks.get(timeout=0.2)
            except queue.Empty:
                data = None
            if data is not None:
                inter = array("i")
                inter.frombytes(data)
                for c, ck in checkers.items():
                    ck.feed(inter[c::n_in], frame)
                    while shown[c] < len(ck.events):
                        f, kind, detail = ck.events[shown[c]]
                        say(f"in {c + 1}: {kind.upper()} at {f / RATE:.3f} s: {detail}")
                        shown[c] += 1
            now = time.monotonic()
            if now >= next_report:
                report()
                next_report = now + args.report
            if args.minutes and now - start >= args.minutes * 60:
                stop.set()
    except KeyboardInterrupt:
        pass
    finally:
        for s in streams:
            s.stop()
            s.close()
    report(final=True)
    ok = all(ck.checked > 0 and ck.errors == 0 and ck.slips == 0 and ck.losses == 0
             for ck in checkers.values())
    say("PASS: every checked sample matched" if ok else "FAIL (see above)")
    if log_file:
        log_file.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
