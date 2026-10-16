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

    def test_diagnosis_tells_why_nothing_locks(self):
        """Bench 2026-10-15 (AVB): a run that never locked said nothing;
        the diagnosis tells silence, the sequence intact, inverted or cut to
        16 bits apart, and reports the level."""
        d = nt.Diagnosis(self.seq, self.loc, -20.0)
        d.feed(nt.to24(array("i", [0] * 5000)))
        text, m = d.summary()
        self.assertIn("zeros 100%", text)
        self.assertIn("peak -inf", text)
        self.assertEqual(m, [])
        good = nt.to24(self.stream(900, 5000))
        d.feed(good)
        text, m = d.summary()
        self.assertIn("exact", m)
        self.assertIn("peak -20.0 dBFS", text)
        d.feed(array("i", [-x for x in good]))
        self.assertIn("inverted", d.summary()[1])
        d.feed(array("i", [x & ~0xFF for x in good]))          # the low 8 bits lost
        m = d.summary()[1]
        self.assertIn("16-bit", m)
        self.assertNotIn("exact", m)
        self.assertEqual(d.summary(), ("nothing received", []))   # each summary is a new window

    def test_output_tape(self):
        tape = array("i")
        tape.frombytes(nt.output_tape(self.seq, [0, 2], 3))
        self.assertEqual(len(tape), 3 * nt.PERIOD)
        self.assertEqual(tape[0::3][:10], self.seq[:10])
        self.assertEqual(tape[2::3][:10], self.seq[2 * nt.STRIDE:2 * nt.STRIDE + 10])
        self.assertEqual(set(tape[1::3]), {0})


class FakeSoundDevice:
    """Enough of sounddevice for main(): one duplex device whose output
    channels come back on the same input channels `delay` frames later,
    optionally transformed, at about real time."""

    PortAudioError = RuntimeError

    def __init__(self, delay=700, transform=lambda x: x, inputs=10):
        self.delay, self.transform, self.inputs = delay, transform, inputs

    def query_devices(self, device=None, kind=None):
        if device is None:
            return "0 Fake USB, 10 in, 10 out"
        if "Fake" not in device:
            raise ValueError(f"No {kind} device matching {device!r}")
        return {"name": "Fake USB", "max_input_channels": self.inputs, "max_output_channels": 10}

    def RawStream(self, device, channels, dtype, samplerate, blocksize, callback, **opts):
        fake = self
        assert opts.get("dither_off") is True and dtype == "int32"

        class Stream:
            def __init__(self):
                self.run = False

            def start(self):
                import threading
                self.run = True
                self.t = threading.Thread(target=self.loop, daemon=True)
                self.t.start()

            def loop(self):
                import time as _t
                n_in, n_out = channels
                assert fake.delay >= blocksize, "a loop shorter than a block isn't causal"
                line = array("i", [0] * (fake.delay * n_out))     # frames in flight
                while self.run:
                    back, line = line[:blocksize * n_out], line[blocksize * n_out:]
                    inp = array("i", [0] * (blocksize * n_in))      # what comes back now
                    for f in range(blocksize):
                        for c in range(min(n_in, n_out)):
                            inp[f * n_in + c] = fake.transform(back[f * n_out + c])
                    out = bytearray(4 * blocksize * n_out)
                    callback(inp.tobytes(), out, blocksize, None, None)
                    sent = array("i")
                    sent.frombytes(bytes(out))
                    line += sent                                     # goes out now
                    _t.sleep(blocksize / samplerate / 4)

            def stop(self):
                self.run = False
                self.t.join()

            def close(self):
                pass

        return Stream()


class MainLoop(unittest.TestCase):
    """main() end to end over FakeSoundDevice (no audio hardware)."""

    def run_main(self, fake, *args):
        import io
        import contextlib
        import sys
        sys.modules["sounddevice"] = fake
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                code = nt.main(list(args))
        finally:
            del sys.modules["sounddevice"]
        return code, out.getvalue()

    def test_a_clean_loop_passes_with_its_latency_and_source(self):
        code, text = self.run_main(FakeSoundDevice(delay=700), "--device", "Fake", "--out", "8",
                                   "--in", "8", "--minutes", "0.03", "--report", "0.5")
        self.assertEqual(code, 0, text)
        self.assertIn("on 'Fake USB'", text)
        self.assertIn("from out 8, latency 700 samples", text)
        self.assertIn("PASS", text)

    def test_an_inverted_loop_fails_and_says_so(self):
        code, text = self.run_main(FakeSoundDevice(transform=lambda x: -x), "--device", "Fake",
                                   "--out", "8", "--in", "8", "--minutes", "0.02", "--report", "0.4")
        self.assertEqual(code, 1, text)
        self.assertIn("input 8 (test):", text)
        self.assertIn("inverted", text)

    def test_an_unknown_device_is_named(self):
        code, _text = self.run_main(FakeSoundDevice(), "--device", "Nope", "--out", "1", "--in", "1")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
