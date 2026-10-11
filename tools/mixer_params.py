#!/usr/bin/env python3
"""
The parameter model: which parameters the mixer has, and the rules for their
values. It knows nothing about sockets, OSC encoding or hardware. Backends
describe their zone with it (osc_mixer_server.Backend.describe), the server
validates every set and get against it, and the config reply (amendment B)
is built from the same descriptions, so what the mixer advertises and what
it accepts can't drift apart.

Standard: docs/FPGA Mixer OSC Standard.md ("Values", "Set and get", "The
system zone", "Config", "Error reply").

  ModuleSpec   one module's (or system setting's) metadata: type (float,
               int, bool, enum, string), unit, min, max, default, options
               (+ option_labels, Phase 15), group, read_only, linked,
               max_length. apply(value) is the value rule:
                 - numbers: non-finite remapped (NaN, -inf -> -99.9; +inf ->
                   +99.9), clamped to min/max, bool snapped to 0/1 (>= 0.5
                   is 1), int rounded (halves away from zero); an enum value
                   must be one of options;
                   the result is a float rounded to float32 (OSC's precision,
                   so stored, echoed and snapshot values agree);
                 - strings only for string modules, numbers only for the rest;
                 - clamping is not a refusal: the applied value is returned.
  ZoneSpec     a zone's shape (channels: count; matrix: rows x cols) and the
               modules it implements, in order.
  Model        zones + module metadata + system settings. resolve(tail) turns
               an address tail into a Param, or raises Refused with the path
               (normalised, no trailing slash) and the reason for the error
               reply. config(...) is the config reply's JSON object, built
               from the same descriptions (describe() on each spec) and the
               current values (sparse: non-defaults, plus system/deviceName).

Indices are canonical in Param.path ('01_1' resolves to '1_1'), so the state
tree only ever holds canonical keys.
"""

import math
import struct
from dataclasses import dataclass, field

TYPES = ("float", "int", "bool", "enum", "string")
CHANNEL_ZONES = ("inputChannel", "busChannel", "outputChannel")
MATRIX_ZONES = ("inputMatrix", "busMatrix")
SYSTEM_ZONE = "system"
SCHEMA_VERSION = 1       # the config's breaking-change number (D29)

NONFINITE_LOW = -99.9    # mirrors mixer_state: NaN and -inf
NONFINITE_HIGH = 99.9    # +inf


class Refused(Exception):
    """A request the mixer refuses. path and reason go into the error reply."""

    def __init__(self, path, reason):
        super().__init__(f"{path}: {reason}")
        self.path = path
        self.reason = reason


def float32(x):
    return struct.unpack(">f", struct.pack(">f", x))[0]


def _is_number(value):
    return isinstance(value, (int, float))     # bool is an int: T/F are numbers


@dataclass(frozen=True)
class ModuleSpec:
    type: str
    unit: str = None
    min: float = None
    max: float = None
    default: object = None
    options: tuple = ()
    group: str = None
    read_only: bool = False
    linked: bool = False      # follows virtual groups (standard "Virtual groups")
    max_length: int = None    # strings: at most this many UTF-8 bytes (config "maxLength")
    option_labels: tuple = () # enums: a label per option, same order (config "optionLabels", Phase 15)

    def __post_init__(self):
        if self.type not in TYPES:
            raise ValueError(f"unknown module type {self.type!r}")
        if self.min is not None and self.max is not None and self.min > self.max:
            raise ValueError(f"min {self.min} > max {self.max}")
        if self.type == "enum" and not self.options:
            raise ValueError("an enum needs options")
        if self.option_labels and len(self.option_labels) != len(self.options):
            raise ValueError(f"{len(self.option_labels)} option labels for "
                             f"{len(self.options)} options")

    def default_value(self):
        """The declared default, or the implicit one: '' for strings, the
        first option for enums, else 0 moved into range."""
        if self.default is not None:
            return self.default
        if self.type == "string":
            return ""
        if self.type == "enum":
            return self.options[0]
        lo = 0.0
        if self.min is not None:
            lo = max(lo, self.min)
        if self.max is not None:
            lo = min(lo, self.max)
        return lo

    def apply(self, value):
        """(applied_value, None), or (None, reason) if the value is refused."""
        if self.type == "string":
            if not isinstance(value, str):
                return None, "expected a string"
            if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
                return None, "control characters aren't allowed"
            if self.max_length is not None and len(value.encode("utf-8")) > self.max_length:
                return None, f"at most {self.max_length} bytes"
            return value, None
        if isinstance(value, str):
            return None, "expected a number, got a string"
        if not _is_number(value):
            return None, f"unsupported value {value!r}"
        x = float(value)
        if math.isnan(x):
            x = NONFINITE_LOW
        elif math.isinf(x):
            x = NONFINITE_HIGH if x > 0 else NONFINITE_LOW
        lo, hi = self.min, self.max
        if lo is not None:
            x = max(x, lo)
        if hi is not None:
            x = min(x, hi)
        if self.type == "bool":
            x = 1.0 if x >= 0.5 else 0.0
        elif self.type == "int":
            x = math.copysign(math.floor(abs(x) + 0.5), x)   # halves away from zero, as the mock
        elif self.type == "enum":
            if not any(_is_number(o) and float(o) == x for o in self.options):
                return None, f"{value!r} is not one of {list(self.options)}"
        return float32(x), None

    def describe(self):
        """The config JSON's metadata object (amendment B): only the fields
        that are set; readOnly only when true; default always (explicit)."""
        d = {"type": self.type}
        for key, value in (("unit", self.unit), ("min", self.min), ("max", self.max),
                           ("group", self.group)):
            if value is not None:
                d[key] = value
        d["default"] = self.default_value()
        if self.options:
            d["options"] = list(self.options)
        if self.option_labels:
            d["optionLabels"] = list(self.option_labels)
        if self.read_only:
            d["readOnly"] = True
        if self.linked:
            d["linked"] = True
        if self.max_length is not None:
            d["maxLength"] = self.max_length
        return d


@dataclass(frozen=True)
class ZoneSpec:
    """kind 'channels' (count) or 'matrix' (rows x cols); modules in order."""
    kind: str
    modules: tuple
    count: int = 0
    rows: int = 0
    cols: int = 0

    def __post_init__(self):
        if self.kind not in ("channels", "matrix"):
            raise ValueError(f"unknown zone kind {self.kind!r}")

    def indices(self):
        """Every canonical index, in order (channels, or row-major crosspoints)."""
        if self.kind == "channels":
            return [str(i) for i in range(self.count)]
        return [f"{r}_{c}" for r in range(self.rows) for c in range(self.cols)]

    def describe(self):
        """The config JSON's zone object."""
        shape = {"count": self.count} if self.kind == "channels" else {"rows": self.rows, "cols": self.cols}
        return dict(shape, modules=list(self.modules))

    def index(self, text):
        """The canonical index for `text`, or None if it isn't one of this
        zone's indices."""
        if self.kind == "channels":
            n = _parse_int(text)
            return str(n) if n is not None and n < self.count else None
        a, sep, b = text.partition("_")
        r, c = _parse_int(a), _parse_int(b)
        if not sep or r is None or c is None or r >= self.rows or c >= self.cols:
            return None
        return f"{r}_{c}"


def _parse_int(text):
    """A non-negative decimal integer, digits only (as the app parses it)."""
    if not text or len(text) > 9 or not (text.isascii() and text.isdigit()):
        return None
    return int(text)


@dataclass(frozen=True)
class Param:
    zone: str
    index: str          # canonical channel / crosspoint, or the setting name
    module: str         # None for a system setting
    spec: ModuleSpec

    @property
    def path(self):
        head = f"{self.zone}/{self.index}"
        return head if self.module is None else f"{head}/{self.module}"


@dataclass
class Model:
    zones: dict = field(default_factory=dict)      # zone -> ZoneSpec
    modules: dict = field(default_factory=dict)    # module name -> ModuleSpec
    system: dict = field(default_factory=dict)     # setting name -> ModuleSpec

    def add_zone(self, zone, spec, modules):
        """Add a backend's zone and its module metadata. A module two zones
        share must be described identically (the config has one 'modules')."""
        if zone in self.zones or zone == SYSTEM_ZONE:
            raise ValueError(f"zone {zone!r} described twice")
        expected = CHANNEL_ZONES if spec.kind == "channels" else MATRIX_ZONES
        if zone not in expected:
            raise ValueError(f"{zone!r} is not a {spec.kind} zone of the standard")
        for name in spec.modules:
            if name not in modules:
                raise ValueError(f"{zone} lists module {name!r} without metadata")
        for name, m in modules.items():
            if name in self.modules and self.modules[name] != m:
                raise ValueError(f"module {name!r} described differently by two zones")
            self.modules[name] = m
        self.zones[zone] = spec

    def params(self):
        """Every parameter the mixer has: zones in insertion order (index,
        then module), then the system settings."""
        for zone, spec in self.zones.items():
            for index in spec.indices():
                for module in spec.modules:
                    yield Param(zone, index, module, self.modules[module])
        for name, spec in self.system.items():
            yield Param(SYSTEM_ZONE, name, None, spec)

    def config(self, device_name, firmware, sample_rate, value_of):
        """The config reply's JSON object (amendment B, schemaVersion 1).
        value_of(param) is the parameter's current value. values is sparse:
        only values that differ from their default, plus system/deviceName
        always; read-only settings are never listed (they are their default)."""
        values = {}
        for p in self.params():
            if p.spec.read_only:
                continue
            value = value_of(p)
            if value != p.spec.default_value() or p.path == "system/deviceName":
                values[p.path] = value
        return {
            "schemaVersion": SCHEMA_VERSION,
            "deviceName": device_name,
            "firmware": firmware,
            "sampleRate": sample_rate,
            "zones": {zone: spec.describe() for zone, spec in self.zones.items()},
            "modules": {name: m.describe() for name, m in self.modules.items()},
            "system": {name: m.describe() for name, m in self.system.items()},
            "values": values,
        }

    def resolve(self, tail):
        """The Param `tail` names, or raise Refused."""
        parts = tail.split("/")
        while parts and parts[-1] == "":
            parts.pop()
        path = "/".join(parts)
        if not parts or any(p == "" for p in parts):
            raise Refused(path, "unknown path")
        zone = parts[0]
        if zone == SYSTEM_ZONE:
            if len(parts) != 2 or parts[1] not in self.system:
                raise Refused(path, f"the mixer has no {path}")
            return Param(zone, parts[1], None, self.system[parts[1]])
        spec = self.zones.get(zone)
        if spec is None:
            raise Refused(path, f"the mixer has no zone {zone!r}")
        if len(parts) != 3:
            raise Refused(path, "expected <zone>/<index>/<module>")
        index = spec.index(parts[1])
        if index is None:
            raise Refused(path, f"{zone} has no index {parts[1]!r}")
        if parts[2] not in spec.modules:
            raise Refused(f"{zone}/{index}/{parts[2]}", f"{zone} has no module {parts[2]!r}")
        return Param(zone, index, parts[2], self.modules[parts[2]])
