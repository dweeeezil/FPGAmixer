#!/usr/bin/env python3
"""
Tests for mixer_eq.py (the EQ's server side) and the server's EqPoolDriver.
Standard library only; runs on the PC:

    python -m unittest -v test_mixer_eq        (from tools/)

The design formulas in mixer_eq are a copy of the library's reference model
(src/lib/model/svf_eq.py, the submodule): checked here word for word, so the
copy the board runs and the model the block was verified against can't drift.
"""

import os
import sys
import unittest

import mixer_eq as e

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "..", "src", "lib", "model")


class AgainstTheLibraryModel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(os.path.join(MODEL, "svf_eq.py")):
            raise unittest.SkipTest("the library submodule isn't checked out (git submodule update --init)")
        sys.path.insert(0, MODEL)
        import svf_eq
        cls.m = svf_eq

    def test_the_format_is_the_models(self):
        f = self.m.EQ_FMT
        self.assertEqual((e.AF, e.MF, e.MI), (f.af, f.mf, f.mi))
        self.assertEqual(e.KINDS, self.m.KINDS)
        self.assertEqual(e.FLAT, self.m.quantize(self.m.IDENTITY, f))

    def test_every_word_of_a_grid_of_settings(self):
        f = self.m.EQ_FMT
        n = 0
        for kind in e.KINDS:
            for freq in (20.0, 31.5, 100.0, 997.0, 4000.0, 12500.0, 20000.0):
                for gain in (-15.0, -3.5, 0.0, 6.02, 15.0):
                    for q in (0.1, 0.7071, 1.0, 3.3, 10.0):
                        self.assertEqual(e.quantize(e.design(kind, freq, gain, q)),
                                         self.m.quantize(self.m.design(kind, freq, gain, q), f),
                                         (kind, freq, gain, q))
                        n += 1
        self.assertEqual(n, 875)


class Words(unittest.TestCase):
    def defaults(self):
        return {name: spec.default_value() for name, spec in e.module_specs(Spec).items()}

    def test_the_defaults_are_flat_and_41_modules(self):
        d = self.defaults()
        self.assertEqual(len(d), 41)
        self.assertEqual(list(d), e.module_names())
        for words, kind in e.bands_of(d):
            self.assertTrue(e.is_flat(words))
            self.assertEqual(kind, 0)

    def test_off_bands_and_eq_off_are_flat_and_filters_ignore_gain(self):
        d = self.defaults()
        d.update({"eq_band2_type": 1.0, "eq_band2_gain": 9.0, "eq_band2_freq": 100.0})
        self.assertFalse(e.is_flat(e.bands_of(d)[1][0]))
        self.assertEqual(e.bands_of(dict(d, eq_band2_on=0.0))[1][0], e.FLAT)
        self.assertEqual(e.bands_of(dict(d, eq_on=0.0))[1][0], e.FLAT)
        hp = dict(d, eq_band3_type=3.0, eq_band3_freq=80.0)
        self.assertEqual(e.bands_of(hp)[2][0], e.bands_of(dict(hp, eq_band3_gain=12.0))[2][0])

    def test_word_index(self):
        self.assertEqual(e.word_index(0, 0, 0), 0)
        self.assertEqual(e.word_index(1, 2, 5), (1 * 8 + 2) * 6 + 5)


class Steps(unittest.TestCase):
    PEAK = e.quantize(e.design("peak", 1000.0, 6.0, 1.0))
    PEAK2 = e.quantize(e.design("peak", 2000.0, 6.0, 1.0))
    SHELF = e.quantize(e.design("lowshelf", 100.0, 6.0, 0.7071))
    FLAT_AT_PEAK = PEAK[:3] + e.FLAT_M

    def test_within_a_type_at_once(self):
        self.assertEqual(e.band_steps(self.PEAK, 0, self.PEAK2, 0), [self.PEAK2])

    def test_to_flat_keeps_the_filter(self):
        self.assertEqual(e.band_steps(self.PEAK, 0, e.FLAT, 0), [self.FLAT_AT_PEAK])

    def test_from_flat_filter_first_then_mix(self):
        self.assertEqual(e.band_steps(e.FLAT, 0, self.SHELF, 1), [self.SHELF[:3] + e.FLAT_M, self.SHELF])

    def test_a_type_change_goes_through_flat(self):
        self.assertEqual(e.band_steps(self.PEAK, 0, self.SHELF, 1),
                         [self.FLAT_AT_PEAK, self.SHELF[:3] + e.FLAT_M, self.SHELF])

    def test_nothing_to_do(self):
        self.assertEqual(e.band_steps(self.PEAK, 0, self.PEAK, 0), [])


class Spec:
    """A minimal stand-in for mixer_params.ModuleSpec (only default_value is used)."""

    def __init__(self, type, default=None, **kw):
        self.default = default

    def default_value(self):
        return self.default


class FakeEqHW:
    def __init__(self):
        self.writes = []

    def set_words(self, words):
        self.writes.append(dict(words))


class FakeBackend:
    def __init__(self, params):
        self.params, self.state = params, None

    def params_of(self, slot, state):
        return dict(self.params[slot])


class Driver(unittest.TestCase):
    """The server's EqPoolDriver on a fake window and a fake clock."""

    def setUp(self):
        import osc_mixer_server as srv
        srv.log = lambda m: None
        self.t = [0.0]
        self.hw = FakeEqHW()
        self.drv = srv.EqPoolDriver(self.hw, 2, now=lambda: self.t[0])
        self.base = {name: spec.default_value() for name, spec in e.module_specs(Spec).items()}
        self.backend = FakeBackend({0: dict(self.base), 1: dict(self.base)})
        self.drv.backend = self.backend

    def band0(self, write):
        return tuple(write[e.word_index(0, 0, j)] for j in range(6))

    def set(self, **kw):
        self.backend.params[0].update(kw)
        self.drv.write({0: dict(self.backend.params[0])})

    def tick(self, dt):
        self.t[0] += dt
        self.drv.run_due(self.t[0])

    def test_a_gain_change_is_written_at_once_only_that_band(self):
        self.set()                                     # defaults: the hardware's flat already
        self.assertEqual(self.hw.writes, [{}] * 0)
        self.set(eq_band1_gain=6.0)
        # from flat: the new filter silently first, then the mix after a wait
        self.assertEqual(len(self.hw.writes), 1)
        self.assertEqual(set(self.hw.writes[0]), {e.word_index(0, 0, j) for j in range(6)})
        self.assertTrue(e.is_flat(self.band0(self.hw.writes[0])))
        self.tick(0.05)
        self.assertEqual(len(self.hw.writes), 1)       # not yet
        self.tick(0.06)
        self.assertEqual(len(self.hw.writes), 2)
        want = e.quantize(e.design("peak", 30.0, 6.0, 1.0))
        self.assertEqual(self.band0(self.hw.writes[1]), want)
        self.set(eq_band1_gain=3.0)                    # within the type: at once
        self.assertEqual(self.band0(self.hw.writes[2]), e.quantize(e.design("peak", 30.0, 3.0, 1.0)))

    def test_a_type_change_takes_three_writes_and_two_waits(self):
        self.set(eq_band1_gain=6.0)
        self.tick(0.2)
        n = len(self.hw.writes)
        peak = e.quantize(e.design("peak", 30.0, 6.0, 1.0))
        shelf = e.quantize(e.design("lowshelf", 30.0, 6.0, 1.0))
        self.set(eq_band1_type=1.0)
        self.assertEqual(self.band0(self.hw.writes[n]), peak[:3] + e.FLAT_M)
        self.tick(0.11)
        self.assertEqual(self.band0(self.hw.writes[n + 1]), shelf[:3] + e.FLAT_M)
        self.tick(0.11)
        self.assertEqual(self.band0(self.hw.writes[n + 2]), shelf)
        self.tick(1.0)
        self.assertEqual(len(self.hw.writes), n + 3)

    def test_a_change_during_the_glide_waits_and_lands_at_the_end(self):
        self.set(eq_band1_gain=6.0)
        self.tick(0.2)
        n = len(self.hw.writes)
        self.set(eq_band1_type=1.0)
        self.set(eq_band1_gain=12.0)                   # during: no write
        self.assertEqual(len(self.hw.writes), n + 1)
        self.tick(0.11)
        self.tick(0.11)
        # the plan made after the wait starts from the +6 dB shelf's filter with a
        # flat mix: the +12 dB shelf's filter goes in silently first, then its mix
        shelf12 = e.quantize(e.design("lowshelf", 30.0, 12.0, 1.0))
        self.assertEqual(self.band0(self.hw.writes[-1]), shelf12[:3] + e.FLAT_M)
        self.tick(0.11)
        self.assertEqual(self.band0(self.hw.writes[-1]), shelf12)

    def test_switching_a_band_off_is_a_crossfade_to_dry(self):
        self.set(eq_band1_gain=6.0)
        self.tick(0.2)
        peak = e.quantize(e.design("peak", 30.0, 6.0, 1.0))
        self.set(eq_band1_on=0.0)
        self.assertEqual(self.band0(self.hw.writes[-1]), peak[:3] + e.FLAT_M)

    def test_direct_writes_at_once(self):
        self.backend.params[0].update(eq_band1_type=2.0, eq_band1_gain=-6.0)
        self.drv.write({0: dict(self.backend.params[0])}, direct=True)
        self.assertEqual(self.band0(self.hw.writes[-1]), e.quantize(e.design("highshelf", 30.0, -6.0, 1.0)))
        self.tick(1.0)
        self.assertEqual(len(self.hw.writes), 1)


if __name__ == "__main__":
    unittest.main()
