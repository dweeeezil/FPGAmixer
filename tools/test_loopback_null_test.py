#!/usr/bin/env python3
"""
Tests for loopback_null_test.py's checker (no audio, standard library only):
the received stream is built from the sequence by hand, with the faults the
tool must find, and fed in blocks of awkward sizes.

    python3 -m unittest -v test_loopback_null_test        (from tools/)
"""

import random
import unittest
from array import array

import loopback_null_test as nt


class Checker(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.seq = nt.make_sequence(-20.0)
        cls.loc = nt.Locator(cls.seq)

    def stream(self, start, count):
        """count samples of the sequence from index start, wrapping."""
        n = len(self.seq)
        out = array("i")
        while count > 0:
            take = min(count, n - start)
            out += self.seq[start:start + take]
            count -= take
            start = (start + take) % n
        return out

    def run_blocks(self, data, seed=1, frame=0):
        ck = nt.ChannelChecker(self.seq, self.loc)
        rng = random.Random(seed)
        j = 0
        while j < len(data):
            size = rng.choice([1, 2, 3, 7, 64, 511, 512, 2048])
            ck.feed(data[j:j + size], frame + j)
            j += size
        return ck

    def kinds(self, ck):
        return [k for _f, k, _d in ck.events]

    def test_the_sequence(self):
        s = self.seq
        self.assertEqual(len(s), nt.PERIOD)
        self.assertEqual(nt.make_sequence(-20.0)[:100], s[:100])          # deterministic
        amp = round((1 << 23) * 10 ** (-20 / 20))
        self.assertTrue(all(v != 0 and v & 0xFF == 0 and abs(v >> 8) <= amp for v in s[:5000]))
        self.assertGreater(len(self.loc.index), 0.99 * nt.PERIOD)        # almost every key locates
        tiny = nt.make_sequence(-200.0, period=2000)                      # amplitude 1 LSB
        self.assertEqual(set(tiny), {-(1 << 8), 1 << 8})                  # never 0: silence never matches

    def test_clean_after_silence_in_any_block_sizes(self):
        data = array("i", [0] * 1000) + self.stream(12345, 100_000)
        for seed in (1, 2, 3):
            ck = self.run_blocks(data, seed)
            self.assertEqual((ck.checked, ck.errors, ck.slips, ck.losses), (100_000, 0, 0, 0))
            self.assertEqual(ck.unlocked, 1000)
            self.assertEqual(self.kinds(ck), ["lock"])
            self.assertEqual(ck.offset, (1000 - 12345) % nt.PERIOD)

    def test_runs_across_the_period(self):
        ck = self.run_blocks(self.stream(nt.PERIOD - 50, 3 * nt.PERIOD))
        self.assertEqual((ck.checked, ck.errors, ck.slips), (3 * nt.PERIOD, 0, 0))

    def test_a_dropped_sample_is_a_slip_of_minus_one(self):
        data = self.stream(500, 20_000)
        del data[7777]
        ck = self.run_blocks(data)
        self.assertEqual((ck.slips, ck.errors, ck.losses), (1, 0, 0))
        f, kind, detail = ck.events[-1]
        self.assertEqual((f, kind), (7777, "slip"))
        self.assertIn("-1 samples (dropped)", detail)
        self.assertEqual(ck.checked, len(data))

    def test_repeated_samples_are_a_slip_of_plus_n(self):
        data = self.stream(500, 20_000)
        data[9000:9000] = data[8997:9000]                # three samples again
        ck = self.run_blocks(data, seed=4)
        self.assertEqual((ck.slips, ck.errors), (1, 0))
        self.assertIn("+3 samples (repeated)", ck.events[-1][2])

    def test_a_corrupted_sample_is_an_error_not_a_slip(self):
        data = self.stream(500, 20_000)
        data[4242] += 1 << 8                             # one LSB
        ck = self.run_blocks(data, seed=5)
        self.assertEqual((ck.errors, ck.slips, ck.losses), (1, 0, 0))
        self.assertEqual(ck.events[-1][:2], (4242, "error"))
        self.assertEqual(ck.checked, len(data) - 1)

    def test_noise_below_24_bits_is_not_an_error(self):
        """Bench 2026-10-15: the Mac's float path moved the low bits of the
        32-bit words (PortAudio dither); compared exactly, nearly every
        sample "failed". Up to +-127 (half a 24-bit step) is the same sample;
        one 24-bit LSB is an error."""
        rng = random.Random(12)
        data = self.stream(500, 30_000)
        for j in range(len(data)):
            data[j] += rng.randint(-127, 127)
        ck = self.run_blocks(data, seed=7)
        self.assertEqual((ck.checked, ck.errors, ck.slips, ck.losses), (30_000, 0, 0, 0))
        data[777] = (((data[777] + 128) >> 8) + 1) << 8   # a real 1-LSB change at 24 bits
        ck = self.run_blocks(data, seed=7)
        self.assertEqual((ck.errors, ck.slips, ck.losses), (1, 0, 0))

    def test_a_dropout_is_lost_then_locks_again_at_the_same_place(self):
        data = self.stream(500, 20_000)
        data[5000:6000] = array("i", [0] * 1000)          # muted for 1000 samples
        ck = self.run_blocks(data, seed=6)
        self.assertEqual((ck.losses, ck.slips, ck.errors), (1, 0, 0))
        self.assertEqual(self.kinds(ck), ["lock", "lost", "lock"])
        self.assertIn("same position", ck.events[-1][2])

    def test_decisions_wait_for_samples_across_block_edges(self):
        data = self.stream(500, 3000)
        data[1023] += 1 << 8                             # the last sample of a block
        ck = nt.ChannelChecker(self.seq, self.loc)
        for j in range(0, len(data), 1024):
            ck.feed(data[j:j + 1024], j)
        self.assertEqual((ck.errors, ck.slips, ck.checked), (1, 0, len(data) - 1))
        data = self.stream(500, 3000)
        del data[1022]                                   # a drop at the edge
        ck = nt.ChannelChecker(self.seq, self.loc)
        for j in range(0, len(data), 1023):
            ck.feed(data[j:j + 1023], j)
        self.assertEqual((ck.errors, ck.slips), (0, 1))

    def test_noise_never_locks(self):
        rng = random.Random(9)
        noise = array("i", [rng.randrange(-(1 << 31), 1 << 31) for _ in range(20_000)])
        ck = self.run_blocks(noise)
        self.assertFalse(ck.locked)
        self.assertEqual(ck.checked, 0)

    def test_source_and_latency_on_a_duplex_stream(self):
        """Output channel c sends seq[f + c*STRIDE] at frame f; it arrives
        `lat` frames later."""
        for c, lat in ((0, 0), (0, 700), (2, 1234), (7, nt.STRIDE - 1)):
            data = array("i", [0] * lat) + self.stream(c * nt.STRIDE, 5000)   # frame 0 sent seq[c*STRIDE]
            ck = nt.ChannelChecker(self.seq, self.loc)
            ck.feed(data, 0)
            self.assertEqual(ck.source_and_latency(), (c, lat), (c, lat))

    def test_output_tape(self):
        tape = array("i")
        tape.frombytes(nt.output_tape(self.seq, [0, 2], 3))
        self.assertEqual(len(tape), 3 * nt.PERIOD)
        self.assertEqual(tape[0::3][:10], self.seq[:10])
        self.assertEqual(tape[2::3][:10], self.seq[2 * nt.STRIDE:2 * nt.STRIDE + 10])
        self.assertEqual(set(tape[1::3]), {0})


if __name__ == "__main__":
    unittest.main()
