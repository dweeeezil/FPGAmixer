#!/usr/bin/env python3
"""
Metering (Phase 13; OSC standard "Metering"; controller contract F4): who is
subscribed to which zones, at what rate, and the meter stream itself. No OSC
parsing and no TCP here: the server validates `meter/subscribe` and calls
MeterHub; this module samples a MeterSource and sends UDP datagrams.

  MeterSource             zones() -> {zone: channels}; sample() -> {zone:
                          [linear peak per channel]}: the largest magnitude
                          since the previous sample(), 0 .. 2^23-1 (the PL's
                          raw 24-bit magnitude).
    HardwareMeterSource   the PL's peak meters (mixer_hw.PeakHW windows):
                          SNAP every window, then read them. The PL keeps the
                          max since the last SNAP, so nothing is lost between
                          samples however late a sample is. One reader: this.
    SyntheticMeterSource  for tests and the simulator only (server flag
                          --meter-source synthetic, never with --hw: decision
                          M8): each channel's peak follows its `level`, so a
                          fader move is visible in the meters.

  MeterHub                the subscriptions (standard "Metering"):
    subscribe(key, ip, port, rate, zones)  key = the TCP connection; zones the
                          source has (the server maps the mask); rate already
                          clamped 1..120. A new key starts a subscription; the
                          same key renews the lease (5 s), updates rate and
                          zones, and with a new port moves the stream (its
                          sequences continue). Empty zones = unsubscribe.
    drop(key)             the TCP connection closed.
    tick()                one sampler step (the sampler thread calls it at the
                          highest subscribed rate): expired leases dropped;
                          ONE source sample folded into every subscriber's
                          per-zone running max; each subscriber whose period
                          has elapsed gets one message per zone and its maxima
                          restart. So every subscriber sees every peak exactly
                          once whatever the rates (decision M5).
    run()                 the sampler thread: sleeps while nobody subscribes.

Stream format (standard): /<name>/meter/<zone> <blob>; blob = big-endian
uint32 sequence, then N x int16 peaks in 0.01 dBFS, -32768 = silence.
Sequences are per zone per subscriber, start at 0, +1 per message, wrap at
2^32. Scale (decision M6): 2^23 = 0 dBFS; only an exact 0 is silence; other
values clamp to -32767 .. 32767.

The clock and the send function are injected, so tests drive tick() with a
fake clock and capture datagrams without sockets or sleeps.
"""

import math
import struct
import threading
import time

METER_ZONES = ("inputChannel", "busChannel", "outputChannel")   # mask bits 0, 1, 2
FULL_SCALE = 1 << 23
SILENCE = -32768
LEASE_S = 5.0
RATE_MIN, RATE_MAX = 1, 120


def centibels(peak):
    """A linear 24-bit magnitude -> int16 0.01 dBFS (2^23 = 0 dBFS)."""
    if peak <= 0:
        return SILENCE
    cb = round(2000.0 * math.log10(peak / FULL_SCALE))
    return max(-32767, min(32767, cb))


def meter_blob(seq, peaks):
    """The stream's blob: big-endian uint32 sequence + int16 per channel."""
    return struct.pack(f">I{len(peaks)}h", seq & 0xFFFF_FFFF, *(centibels(p) for p in peaks))


def zones_from_mask(mask, available):
    """The zones a subscription's mask selects, among those the mixer meters
    (bits for zones it doesn't have are ignored), in METER_ZONES order."""
    return [z for bit, z in enumerate(METER_ZONES) if (mask >> bit) & 1 and z in available]


class MeterSource:
    def zones(self):
        raise NotImplementedError

    def sample(self):
        raise NotImplementedError


class HardwareMeterSource(MeterSource):
    """The PL's peak meters: {zone: mixer_hw.PeakHW}."""

    def __init__(self, windows):
        self.windows = dict(windows)

    def zones(self):
        return {z: w.n for z, w in self.windows.items()}

    def sample(self):
        for w in self.windows.values():          # close every window first ...
            w.request_snap()
        return {z: w.wait_and_read() for z, w in self.windows.items()}   # ... then read


class SyntheticMeterSource(MeterSource):
    """Deterministic, for tests and the simulator: channel c of a zone peaks at
    BASE_DB - 3*(c % 6) dBFS plus the channel's level (level_of(zone, c), dB;
    None or <= -90 -> silence)."""

    BASE_DB = -12.0

    def __init__(self, sizes, level_of):
        self.sizes = dict(sizes)
        self.level_of = level_of

    def zones(self):
        return dict(self.sizes)

    def peak(self, zone, ch):
        level = self.level_of(zone, ch)
        if level is None or level <= -90.0:
            return 0
        db = self.BASE_DB - 3.0 * (ch % 6) + level
        return min(FULL_SCALE - 1, int(round(FULL_SCALE * 10.0 ** (db / 20.0))))

    def sample(self):
        return {z: [self.peak(z, c) for c in range(n)] for z, n in self.sizes.items()}


class _Sub:
    def __init__(self, ip, port, rate, zones, now):
        self.ip, self.port, self.rate = ip, port, rate
        self.zones = list(zones)
        self.expires = now + LEASE_S
        self.next_due = now                     # the first tick sends
        self.seq = {z: 0 for z in self.zones}
        self.peaks = {z: None for z in self.zones}


class MeterHub:
    def __init__(self, source, send, name, clock=time.monotonic, log=lambda m: None):
        """send(packet, (ip, port)); name() -> the mixer's current name."""
        self.source = source
        self.send = send
        self.name = name
        self.clock = clock
        self.log = log
        self.available = source.zones()
        self._subs = {}
        self._cond = threading.Condition()

    # ----- subscriptions (called from the TCP handlers) -----
    def subscribe(self, key, ip, port, rate, zones):
        now = self.clock()
        with self._cond:
            if not zones:
                if self._subs.pop(key, None) is not None:
                    self.log(f"meters: {ip} unsubscribed")
                return
            sub = self._subs.get(key)
            if sub is None:
                self._subs[key] = _Sub(ip, port, rate, zones, now)
                self.log(f"meters: {ip}:{port} subscribed to {', '.join(zones)} at {rate} Hz")
            else:
                if port != sub.port:
                    self.log(f"meters: {ip} moved the stream to port {port}")
                sub.ip, sub.port, sub.expires = ip, port, now + LEASE_S
                if rate != sub.rate:
                    sub.rate = rate
                    sub.next_due = min(sub.next_due, now + 1.0 / rate)
                for z in zones:
                    if z not in sub.seq:           # a new zone starts its own sequence
                        sub.seq[z] = 0
                        sub.peaks[z] = None
                for z in list(sub.seq):
                    if z not in zones:
                        del sub.seq[z]
                        del sub.peaks[z]
                sub.zones = list(zones)
            self._cond.notify()

    def drop(self, key):
        with self._cond:
            if self._subs.pop(key, None) is not None:
                self.log("meters: subscription ended with its connection")

    def active(self):
        with self._cond:
            return len(self._subs)

    # ----- the sampler -----
    def period(self):
        """The sampler's period: the highest subscribed rate (None: nobody)."""
        with self._cond:
            rates = [s.rate for s in self._subs.values()]
        return 1.0 / max(rates) if rates else None

    def tick(self):
        now = self.clock()
        with self._cond:
            for key in [k for k, s in self._subs.items() if now >= s.expires]:
                sub = self._subs.pop(key)
                self.log(f"meters: {sub.ip}:{sub.port} lease expired")
            if not self._subs:
                return 0
        sample = self.source.sample()             # outside the lock: may wait on the PL
        out = []
        with self._cond:
            for sub in self._subs.values():
                for z in sub.zones:
                    new = sample.get(z)
                    if new is None:
                        continue
                    old = sub.peaks[z]
                    sub.peaks[z] = list(new) if old is None else [max(a, b) for a, b in zip(old, new)]
                if now >= sub.next_due:
                    for z in sub.zones:
                        peaks = sub.peaks[z] or [0] * self.available[z]
                        out.append(((sub.ip, sub.port), z, sub.seq[z], peaks))
                        sub.seq[z] = (sub.seq[z] + 1) & 0xFFFF_FFFF
                        sub.peaks[z] = None
                    sub.next_due += 1.0 / sub.rate
                    if sub.next_due <= now:       # fell behind: don't burst to catch up
                        sub.next_due = now + 1.0 / sub.rate
        name = self.name()
        from osc_codec import encode_message      # the shared codec (tools/)
        for addr, zone, seq, peaks in out:
            try:
                self.send(encode_message(f"/{name}/meter/{zone}", [meter_blob(seq, peaks)]), addr)
            except OSError as e:                  # display-only: never let it stop the sampler
                self.log(f"meters: send to {addr[0]}:{addr[1]} failed: {e}")
        return len(out)

    def run(self, stop=None):
        """The sampler thread. Sleeps while nobody subscribes."""
        next_t = None
        while stop is None or not stop.is_set():
            with self._cond:
                while not self._subs and (stop is None or not stop.is_set()):
                    next_t = None
                    self._cond.wait(timeout=1.0)
            period = self.period()
            if period is None:
                continue
            now = time.monotonic()
            next_t = now if next_t is None else next_t
            if next_t > now:
                time.sleep(next_t - now)
            try:
                self.tick()
            except Exception as e:                # a PL that stops answering, say
                self.log(f"meters: sample failed: {e}")
                time.sleep(0.5)
            next_t += period
            if next_t < time.monotonic():
                next_t = time.monotonic()
