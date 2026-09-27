#!/usr/bin/env python3
"""
Unit tests for mediaclock.MediaClockLoop against a simulated mclk (no
hardware, no mmap: runs anywhere).

The plant: mclk runs at NOMINAL * (1 + (f0 + u) * 1e-6), where f0 is its own
offset from gPTP and u the correction the loop applied during that second (it
takes effect for the next second, as on the board). The meter is modelled
exactly: it captures the integer mclk count at each gPTP second, so the
interval and the frame phase carry the real +/-1 cycle quantization.

    python3 -m unittest -v test_mediaclock        (from tools/)
"""

import math
import unittest

from mediaclock import FRAME, NOMINAL_HZ, MediaClockLoop, wrap_phase


class Plant:
    def __init__(self, f0_ppm, phase0_cycles=0.0):
        self.f0 = f0_ppm
        self.total = float(phase0_cycles)     # exact mclk count
        self.captured = math.floor(self.total)

    def second(self, u_ppm):
        self.total += NOMINAL_HZ * (1.0 + (self.f0 + u_ppm) * 1e-6)
        c = math.floor(self.total)
        interval, self.captured = c - self.captured, c
        return interval, c % FRAME


def run(loop, plant, seconds, drift_ppm_per_s=0.0, invalid=()):
    trace = []
    u = loop.u
    for t in range(seconds):
        plant.f0 += drift_ppm_per_s
        interval, phase = plant.second(u)
        u = loop.update(interval, phase, valid=(t not in invalid))
        trace.append((t, loop.state, u, loop.last_phase_err, loop.last_freq_ppm))
    return trace


class Wrap(unittest.TestCase):
    def test_short_way(self):
        self.assertEqual(wrap_phase(255), -1)
        self.assertEqual(wrap_phase(1), 1)
        self.assertEqual(wrap_phase(128), -128)
        self.assertEqual(wrap_phase(-129), 127)


class Loop(unittest.TestCase):

    def test_locks_this_bench(self):
        # the board after P9.4a: +0.85 ppm vs gPTP, frame grid anywhere
        loop, plant = MediaClockLoop(max_ppm=80.0), Plant(0.852, phase0_cycles=97.3)
        trace = run(loop, plant, 400)
        locked_at = next(t for t, s, *_ in trace if s == "LOCKED")
        self.assertLess(locked_at, 30)
        t, s, u, e, f = trace[-1]
        self.assertEqual(s, "LOCKED")
        self.assertAlmostEqual(u, -0.852, delta=0.01)            # the frequency learned
        tail = [abs(e) for _, _, _, e, _ in trace[-100:]]
        self.assertLessEqual(max(tail), 2)                        # +/-2 cycles = +/-163 ns

    def test_no_large_overshoot(self):
        loop, plant = MediaClockLoop(), Plant(0.852, phase0_cycles=100.0)
        trace = run(loop, plant, 400)
        first_locked = next(i for i, x in enumerate(trace) if x[1] == "LOCKED")
        e0 = abs(trace[first_locked][3])
        worst = max(abs(x[3]) for x in trace[first_locked:])
        self.assertLessEqual(worst, e0 * 1.3 + 3)                 # damped, no ringing

    def test_large_offset(self):
        loop, plant = MediaClockLoop(max_ppm=80.0), Plant(50.0)
        trace = run(loop, plant, 600)
        self.assertEqual(trace[-1][1], "LOCKED")
        self.assertAlmostEqual(trace[-1][2], -50.0, delta=0.02)

    def test_tracks_drift(self):
        # warm-up drift as seen in P9.3: about -0.5 ppm per minute
        loop, plant = MediaClockLoop(), Plant(1.5)
        trace = run(loop, plant, 300)
        trace = run(loop, plant, 300, drift_ppm_per_s=-0.5 / 60)
        self.assertEqual(trace[-1][1], "LOCKED")
        self.assertLessEqual(max(abs(x[3]) for x in trace[-200:]), 12)   # < 1 us

    def test_holdover_freezes_and_recovers(self):
        loop, plant = MediaClockLoop(), Plant(0.852)
        run(loop, plant, 300)
        u_before = loop.u
        trace = run(loop, plant, 60, invalid=range(5, 15))
        held = [u for t, s, u, *_ in trace[5:15]]
        self.assertTrue(all(s == "HOLDOVER" for _, s, *_ in trace[5:15]))
        self.assertTrue(all(u == held[0] for u in held))           # frozen, not stepped
        self.assertAlmostEqual(held[0], u_before, delta=0.01)
        trace = run(loop, plant, 200)
        self.assertEqual(trace[-1][1], "LOCKED")

    def test_clamped_never_beyond_max(self):
        loop, plant = MediaClockLoop(max_ppm=80.0), Plant(200.0)
        trace = run(loop, plant, 60)
        self.assertTrue(all(abs(u) <= 80.0 + 1e-9 for _, _, u, *_ in trace))
        self.assertNotEqual(trace[-1][1], "LOCKED")

    def test_target_phase(self):
        loop, plant = MediaClockLoop(target_cycles=100), Plant(-2.0, phase0_cycles=10.0)
        trace = run(loop, plant, 500)
        self.assertEqual(trace[-1][1], "LOCKED")
        t, s, u, e, f = trace[-1]
        self.assertLessEqual(abs(e), 2)
        self.assertLessEqual(abs(plant.captured % FRAME - 100), 3)


if __name__ == "__main__":
    unittest.main()
