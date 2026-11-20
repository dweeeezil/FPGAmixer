#!/usr/bin/env python3
"""
The parametric EQ's server side (docs/eq_proposal_2026-11-17.md): the
insert type 'eq' (the pool zone's 41 modules), and a slot's parameters ->
the EQ window's coefficient words. No OSC, no hardware, standard library
only (it runs on the board).

The design formulas and the number format are a COPY of the library's
reference model (src/lib/model/svf_eq.py: design, quantize, EQ_FMT);
test_mixer_eq.py checks the copy against the model word for word through
the submodule, so the two can't drift. The block: lib_svf_eq (the library).

COEFFICIENT WORDS: 6 per band, register index (slot * BANDS + band) * 6 + j,
j = a1, a2, a3, m0, m1, m2; a's with AF = 24 fraction bits, m's with MF = 18
(lib_svf_eq_pkg). A band that's off, or a slot with eq_on 0, is FLAT:
m = (1, 0, 0), the output exactly the input.

BAND CHANGES (proposal sec. 5, finding 4; the user, 2026-11-17, Q1): the
smoother glides every word by the same fraction per frame; that is safe
within one type, but the mix of two different types' filters can be a louder
shape on the way. So band_steps() plans a change as up to three writes:
  - to flat: keep the old a's, the m's go flat (a pure crossfade to dry);
  - from flat: the new a's with a flat mix first (silent), then the new mix;
  - a type change of a sounding band: the old a's with a flat mix, then the
    new a's with a flat mix, then the new mix;
  - anything else (frequency, gain, Q within one type): at once.
The waits between the writes are the server's (FLAT_WAIT_S); a recall writes
everything at once (the user, Q2).
"""

import math

FS = 48000.0
BANDS = 8
AF, MF, MI = 24, 18, 6          # lib_svf_eq_pkg / svf_eq.EQ_FMT
KINDS = ("peak", "lowshelf", "highshelf", "highpass", "lowpass")
KIND_LABELS = ("Peak", "Low shelf", "High shelf", "High-pass", "Low-pass")
DEFAULT_FREQS = (30.0, 80.0, 200.0, 500.0, 1200.0, 3000.0, 7000.0, 15000.0)
FREQ_MIN, FREQ_MAX = 20.0, 20000.0
GAIN_MIN, GAIN_MAX = -15.0, 15.0
Q_MIN, Q_MAX = 0.1, 10.0
FLAT_WAIT_S = 0.100             # each step of a change through flat (the smoother: exact in ~70 ms)


# ----- the design (a copy of svf_eq.design) -----

def design(kind, freq, gain_db=0.0, q=0.7071, fs=FS):
    if kind not in KINDS:
        raise ValueError(f"kind {kind!r}")
    w = math.tan(math.pi * freq / fs)
    a = 10.0 ** (gain_db / 40.0)
    if kind == "peak":
        g, k = w, 1.0 / (q * a)
        m = (1.0, k * (a * a - 1.0), 0.0)
    elif kind == "lowshelf":
        g, k = w / math.sqrt(a), 1.0 / q
        m = (1.0, k * (a - 1.0), a * a - 1.0)
    elif kind == "highshelf":
        g, k = w * math.sqrt(a), 1.0 / q
        m = (a * a, k * (1.0 - a) * a, 1.0 - a * a)
    elif kind == "highpass":
        g, k = w, 1.0 / q
        m = (1.0, -k, -1.0)
    else:
        g, k = w, 1.0 / q
        m = (0.0, 0.0, 1.0)
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    return (a1, a2, a3) + m


def quantize(c):
    """6 floats -> 6 ints (round to nearest, as svf_eq.quantize with EQ_FMT)."""
    a = [int(round(x * (1 << AF))) for x in c[:3]]
    m = [int(round(x * (1 << MF))) for x in c[3:]]
    lim = 1 << (MI + MF)
    for x in m:
        if not -lim <= x < lim:
            raise OverflowError(f"m {x / (1 << MF):.3f} out of range")
    return tuple(a + m)


FLAT = quantize(design("peak", 1000.0, 0.0, 1.0))      # a peak at 0 dB: m = (1, 0, 0)
FLAT_M = FLAT[3:]


def band_words(on, kind_index, freq, gain, q):
    """One band's 6 words; FLAT when it is off."""
    if not on:
        return FLAT
    kind = KINDS[int(kind_index)]
    return quantize(design(kind, freq, 0.0 if kind in ("highpass", "lowpass") else gain, q))


# ----- the modules (the pool zone 'eq') -----

def module_names():
    names = ["eq_on"]
    for n in range(1, BANDS + 1):
        names += [f"eq_band{n}_on", f"eq_band{n}_type", f"eq_band{n}_freq",
                  f"eq_band{n}_gain", f"eq_band{n}_q"]
    return names


def module_specs(ModuleSpec):
    """{name: ModuleSpec}, in order; every default together is the identity
    (every band a Peak at 0 dB). ModuleSpec is mixer_params' (passed in, so
    this module needs nothing but the standard library)."""
    specs = {"eq_on": ModuleSpec("bool", default=1.0, group="eq", linked=True)}
    for n in range(1, BANDS + 1):
        specs[f"eq_band{n}_on"] = ModuleSpec("bool", default=1.0, group="eq", linked=True)
        specs[f"eq_band{n}_type"] = ModuleSpec("enum", options=tuple(float(i) for i in range(len(KINDS))),
                                               option_labels=KIND_LABELS, default=0.0, group="eq",
                                               linked=True)
        specs[f"eq_band{n}_freq"] = ModuleSpec("float", unit="Hz", min=FREQ_MIN, max=FREQ_MAX,
                                               default=DEFAULT_FREQS[n - 1], group="eq", linked=True)
        specs[f"eq_band{n}_gain"] = ModuleSpec("float", unit="dB", min=GAIN_MIN, max=GAIN_MAX,
                                               default=0.0, group="eq", linked=True)
        specs[f"eq_band{n}_q"] = ModuleSpec("float", min=Q_MIN, max=Q_MAX, default=1.0, group="eq",
                                            linked=True)
    return specs


def bands_of(params):
    """A slot's parameters ({module: value}) -> [(words, kind_index)] per band."""
    on = bool(params.get("eq_on", 1.0))
    out = []
    for n in range(1, BANDS + 1):
        kind = int(params.get(f"eq_band{n}_type", 0.0))
        words = band_words(on and bool(params.get(f"eq_band{n}_on", 1.0)), kind,
                           params.get(f"eq_band{n}_freq", DEFAULT_FREQS[n - 1]),
                           params.get(f"eq_band{n}_gain", 0.0), params.get(f"eq_band{n}_q", 1.0))
        out.append((words, kind))
    return out


def word_index(slot, band, j=0):
    return (slot * BANDS + band) * 6 + j


def is_flat(words):
    return tuple(words[3:]) == FLAT_M


def band_steps(old, old_kind, new, new_kind):
    """The writes that take a band from `old` to `new` (6 words each):
    [words now, words after a wait, ...] (module docstring). [] if equal."""
    old, new = tuple(old), tuple(new)
    if old == new:
        return []
    if is_flat(new):                                    # the m's to flat, the filter left alone
        return [] if is_flat(old) else [old[:3] + FLAT_M]
    if is_flat(old):
        return [new[:3] + FLAT_M, new]                  # the filter silently, then the mix
    if old_kind != new_kind:
        return [old[:3] + FLAT_M, new[:3] + FLAT_M, new]
    return [new]
