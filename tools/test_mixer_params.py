#!/usr/bin/env python3
"""
Unit tests for mixer_params.py: the value rules (D37), defaults, path
resolution and the model's consistency checks. Standard library only.

    python3 -m unittest -v test_mixer_params        (from tools/)
"""

import json
import math
import unittest

from mixer_params import Model, ModuleSpec, Refused, ZoneSpec, float32

LEVEL = ModuleSpec("float", unit="dB", min=-90.0, max=6.02, default=-90.0, group="level")


class ValueRules(unittest.TestCase):
    def ok(self, spec, value):
        applied, why = spec.apply(value)
        self.assertIsNone(why, f"{value!r} refused: {why}")
        return applied

    def refused(self, spec, value):
        applied, why = spec.apply(value)
        self.assertIsNone(applied, f"{value!r} accepted as {applied!r}")
        self.assertIsInstance(why, str)
        return why

    def test_float_in_range_passes_as_float32(self):
        self.assertEqual(self.ok(LEVEL, -6.0), -6.0)
        self.assertEqual(self.ok(LEVEL, 2.39), float32(2.39))
        self.assertIsInstance(self.ok(LEVEL, -6), float)          # an OSC int is a number

    def test_clamped_not_refused(self):
        self.assertEqual(self.ok(LEVEL, -120.0), -90.0)
        self.assertEqual(self.ok(LEVEL, 1e30), float32(6.02))
        self.assertEqual(self.ok(LEVEL, -90.0), -90.0)

    def test_non_finite_remapped_then_clamped(self):
        self.assertEqual(self.ok(LEVEL, float("nan")), -90.0)
        self.assertEqual(self.ok(LEVEL, float("-inf")), -90.0)
        self.assertEqual(self.ok(LEVEL, float("inf")), float32(6.02))
        free = ModuleSpec("float")
        self.assertEqual(self.ok(free, float("nan")), float32(-99.9))
        self.assertEqual(self.ok(free, float("inf")), float32(99.9))

    def test_bool_snaps(self):
        mute = ModuleSpec("bool", default=0)
        for value, want in ((0.49, 0.0), (0.5, 1.0), (7, 1.0), (-3, 0.0), (True, 1.0),
                            (False, 0.0), (float("nan"), 0.0)):
            self.assertEqual(self.ok(mute, value), want, value)

    def test_int_rounds_halves_away_from_zero(self):
        n = ModuleSpec("int", min=-10, max=10)
        for value, want in ((2.4, 2.0), (2.5, 3.0), (-2.5, -3.0), (-2.4, -2.0), (99, 10.0)):
            self.assertEqual(self.ok(n, value), want, value)

    def test_enum_must_be_an_option(self):
        rate = ModuleSpec("enum", options=(44100, 48000))
        self.assertEqual(self.ok(rate, 48000.0), 48000.0)
        self.assertEqual(self.ok(rate, 44100), 44100.0)
        self.assertIn("not one of", self.refused(rate, 48001))

    def test_enum_is_clamped_before_the_options_check(self):
        e = ModuleSpec("enum", options=(0, 1, 2), min=0, max=2)
        self.assertEqual(self.ok(e, 5), 2.0)

    def test_kinds(self):
        name = ModuleSpec("string")
        self.assertEqual(self.ok(name, "Kick"), "Kick")
        self.assertEqual(self.ok(name, ""), "")
        self.refused(name, 1.0)
        self.assertIn("string", self.refused(LEVEL, "-6"))
        for bad in (None, b"blob", [1.0]):
            self.refused(LEVEL, bad)

    def test_defaults(self):
        self.assertEqual(LEVEL.default_value(), -90.0)
        self.assertEqual(ModuleSpec("float", min=-90, max=6).default_value(), 0.0)
        self.assertEqual(ModuleSpec("float", min=10, max=20).default_value(), 10)
        self.assertEqual(ModuleSpec("float", min=-20, max=-10).default_value(), -10)
        self.assertEqual(ModuleSpec("enum", options=(3, 4)).default_value(), 3)
        self.assertEqual(ModuleSpec("string").default_value(), "")
        self.assertEqual(ModuleSpec("bool").default_value(), 0.0)

    def test_bad_specs(self):
        for kwargs in ({"type": "colour"}, {"type": "float", "min": 2, "max": 1},
                       {"type": "enum"}):
            with self.assertRaises(ValueError, msg=kwargs):
                ModuleSpec(**kwargs)

    def test_results_are_float32_representable(self):
        for v in (0.1, -6.02, 1 / 3):
            x = self.ok(ModuleSpec("float"), v)
            self.assertEqual(x, float32(x))
            self.assertFalse(math.isnan(x))


class Resolve(unittest.TestCase):
    def setUp(self):
        self.model = Model(system={"deviceName": ModuleSpec("string", default="mixer"),
                                   "sampleRate": ModuleSpec("enum", options=(48000,), read_only=True)})
        self.model.add_zone("inputMatrix", ZoneSpec("matrix", ("level",), rows=4, cols=3), {"level": LEVEL})
        self.model.add_zone("inputChannel", ZoneSpec("channels", ("level", "mute"), count=2),
                            {"level": LEVEL, "mute": ModuleSpec("bool")})

    def refused(self, tail):
        with self.assertRaises(Refused) as cm:
            self.model.resolve(tail)
        return cm.exception

    def test_matrix(self):
        p = self.model.resolve("inputMatrix/3_2/level")
        self.assertEqual((p.zone, p.index, p.module, p.path), ("inputMatrix", "3_2", "level", "inputMatrix/3_2/level"))
        self.assertIs(p.spec, LEVEL)

    def test_canonical_index_and_trailing_slash(self):
        self.assertEqual(self.model.resolve("inputMatrix/03_002/level/").path, "inputMatrix/3_2/level")
        self.assertEqual(self.model.resolve("inputChannel/01/mute").path, "inputChannel/1/mute")

    def test_system(self):
        p = self.model.resolve("system/deviceName/")
        self.assertEqual((p.zone, p.index, p.module, p.path), ("system", "deviceName", None, "system/deviceName"))
        self.assertTrue(self.model.resolve("system/sampleRate").spec.read_only)

    def test_refusals_and_their_paths(self):
        cases = {
            "inputMatrix/4_0/level": "inputMatrix/4_0/level",      # row out of range
            "inputMatrix/0_3/level": "inputMatrix/0_3/level",      # col out of range
            "inputMatrix/0_0/delay/": "inputMatrix/0_0/delay",     # module not there
            "inputMatrix/00_0/delay": "inputMatrix/0_0/delay",     # canonical once the index resolves
            "inputMatrix/0_0/mute": "inputMatrix/0_0/mute",        # another zone's module
            "inputMatrix/0-0/level": "inputMatrix/0-0/level",
            "inputMatrix/0_/level": "inputMatrix/0_/level",
            "inputMatrix/_0/level": "inputMatrix/_0/level",
            "inputMatrix/+1_0/level": "inputMatrix/+1_0/level",
            "inputMatrix/١_0/level": "inputMatrix/١_0/level",  # a non-ASCII digit
            "inputMatrix/0_0": "inputMatrix/0_0",
            "inputMatrix/0_0/level/x": "inputMatrix/0_0/level/x",
            "inputChannel/2/level": "inputChannel/2/level",
            "inputChannel/0_0/level": "inputChannel/0_0/level",
            "busMatrix/0_0/level": "busMatrix/0_0/level",            # zone not there
            "system/config": "system/config",
            "system/location": "system/location",
            "system/deviceName/extra": "system/deviceName/extra",
            "inputMatrix//level": "inputMatrix//level",
            "": "",
            "/": "",
        }
        for tail, path in cases.items():
            self.assertEqual(self.refused(tail).path, path, tail)

    def test_long_index_refused(self):
        self.refused("inputChannel/0000000001/level")       # 10 digits, as the app's parser


class Config(unittest.TestCase):
    def model(self):
        m = Model(system={"deviceName": ModuleSpec("string", default="mixer"),
                          "sampleRate": ModuleSpec("enum", unit="Hz", options=(48000,), default=48000,
                                                   read_only=True),
                          "location": ModuleSpec("string")})
        m.add_zone("inputMatrix", ZoneSpec("matrix", ("level",), rows=2, cols=3), {"level": LEVEL})
        m.add_zone("inputChannel", ZoneSpec("channels", ("level", "mute"), count=2),
                   {"level": LEVEL, "mute": ModuleSpec("bool", group="level")})
        return m

    def test_shape(self):
        c = self.model().config("FOH", "abc123", 48000, lambda p: p.spec.default_value())
        self.assertEqual(c["schemaVersion"], 1)
        self.assertEqual((c["deviceName"], c["firmware"], c["sampleRate"]), ("FOH", "abc123", 48000))
        self.assertEqual(c["zones"], {"inputMatrix": {"rows": 2, "cols": 3, "modules": ["level"]},
                                      "inputChannel": {"count": 2, "modules": ["level", "mute"]}})
        self.assertEqual(c["modules"]["level"], {"type": "float", "unit": "dB", "min": -90.0, "max": 6.02,
                                                 "group": "level", "default": -90.0})
        self.assertEqual(c["modules"]["mute"], {"type": "bool", "group": "level", "default": 0.0})
        self.assertEqual(c["system"]["sampleRate"], {"type": "enum", "unit": "Hz", "default": 48000,
                                                     "options": [48000], "readOnly": True})
        self.assertEqual(c["system"]["deviceName"], {"type": "string", "default": "mixer"})

    def test_linked_is_listed_only_when_true(self):
        """Phase 14 (standard "Virtual groups"): `linked` is optional metadata."""
        self.assertEqual(ModuleSpec("float", linked=True).describe(),
                         {"type": "float", "default": 0.0, "linked": True})
        self.assertNotIn("linked", ModuleSpec("float").describe())

    def test_string_rules_and_max_length(self):
        """Phase 14 (channel names): no control characters in any string;
        max_length counts UTF-8 bytes and is described as maxLength."""
        name = ModuleSpec("string", default="", max_length=4)
        self.assertEqual(name.describe(), {"type": "string", "default": "", "maxLength": 4})
        self.assertNotIn("maxLength", ModuleSpec("string").describe())
        self.assertEqual(name.apply("abcd"), ("abcd", None))
        self.assertEqual(name.apply("éé"), ("éé", None))               # 4 bytes
        for bad in ("abcde", "ééé", "a\tb", "\x7f", 1.0):
            self.assertIsNone(name.apply(bad)[0], repr(bad))
        self.assertEqual(ModuleSpec("string").apply("x" * 500)[1], None)   # no limit by default

    def test_values_are_sparse_plus_device_name(self):
        current = {"inputMatrix/1_2/level": 0.0, "inputChannel/1/mute": 1.0,
                   "system/deviceName": "mixer", "system/location": "FOH riser"}
        c = self.model().config("mixer", "x", 48000, lambda p: current.get(p.path, p.spec.default_value()))
        self.assertEqual(c["values"], current)        # deviceName listed although it is the default

    def test_read_only_settings_are_not_values(self):
        c = self.model().config("FOH", "x", 48000, lambda p: 44100.0 if p.index == "sampleRate" else
                                p.spec.default_value())
        self.assertNotIn("system/sampleRate", c["values"])

    def test_params_cover_every_parameter_once(self):
        paths = [p.path for p in self.model().params()]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(len(paths), 2 * 3 + 2 * 2 + 3)
        self.assertIn("inputMatrix/1_2/level", paths)
        self.assertIn("inputChannel/1/mute", paths)

    def test_json_is_strict(self):
        c = self.model().config("FOH", "x", 48000, lambda p: p.spec.default_value())
        json.dumps(c, allow_nan=False)


class ModelChecks(unittest.TestCase):
    def test_module_shared_by_two_zones_must_match(self):
        m = Model()
        m.add_zone("inputMatrix", ZoneSpec("matrix", ("level",), rows=1, cols=1), {"level": LEVEL})
        m.add_zone("busMatrix", ZoneSpec("matrix", ("level",), rows=1, cols=1), {"level": LEVEL})
        with self.assertRaises(ValueError):
            m.add_zone("inputChannel", ZoneSpec("channels", ("level",), count=1),
                       {"level": ModuleSpec("float", min=-60, max=0)})

    def test_zone_errors(self):
        m = Model()
        m.add_zone("inputMatrix", ZoneSpec("matrix", ("level",), rows=1, cols=1), {"level": LEVEL})
        bad = [("inputMatrix", ZoneSpec("matrix", ("level",), rows=1, cols=1), {"level": LEVEL}),   # twice
               ("inputChannel", ZoneSpec("matrix", ("level",), rows=1, cols=1), {"level": LEVEL}),  # wrong kind
               ("system", ZoneSpec("channels", ("level",), count=1), {"level": LEVEL}),
               ("busMatrix", ZoneSpec("matrix", ("level", "delay"), rows=1, cols=1), {"level": LEVEL})]
        for zone, spec, modules in bad:
            with self.assertRaises(ValueError, msg=zone):
                m.add_zone(zone, spec, modules)
        with self.assertRaises(ValueError):
            ZoneSpec("cube", ())


if __name__ == "__main__":
    unittest.main()
