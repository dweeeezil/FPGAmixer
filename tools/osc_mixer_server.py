#!/usr/bin/env python3
"""
Reference / simulator server for the FPGA mixer's OSC control protocol.

The goal: from a controller's perspective (your Swift app, or the
osc_mixer_test.py suite), this should look and behave exactly like the real
mixer will — same TCP set/get/echo semantics, same UDP write-only path, same
multi-controller broadcast sync, and the same save-on-change/restore-on-boot
persistence described in your other project docs. Point your control
software at this instead of hardware and develop against it.

The OSC codec and the TCP framers are osc_codec.py, shared with every other
tool in tools/, so they all speak identically.

DESIGN DECISIONS (the standard doc leaves these open; documenting the calls
made here so you can compare against the real firmware once it exists):

  - get replies: sent as a '.../set/...' message (mirrors the echo format,
    since 'set' is described as the one sync vehicle every controller
    already parses), to the requesting TCP client ONLY — not broadcast,
    since nothing changed.
  - set broadcast: every successful set — from ANY TCP client, or from
    UDP — is broadcast to ALL connected TCP clients, including whichever
    one sent it. That single broadcast IS the echo/confirmation; there's no
    separate "echo the sender, sync everyone else" split.
  - Address root (standard: "Mixer name and the /mixer/ alias"): the server
    answers to its current name AND to the reserved alias 'mixer', on TCP
    and UDP; any other root is logged and ignored. Everything it sends is
    under its current name. A mixer never named is called 'mixer'.
  - deviceName: the address root genuinely changes. The confirmation of an
    accepted rename is broadcast under the OLD name, and every message after
    that uses the NEW one; messages still addressed to the old name are
    ignored (the alias keeps working). Name rules (name_problem): letters,
    digits, '-', '_', '.', 1-63 bytes, not 'mixer'. A refused rename (or a
    non-string value) is answered to the sender only with the name that
    stands, then /<name>/error (D38); over UDP it's only logged. A stored
    name that breaks the rules (older state files) loads as it is.
  - TCP framing (--tcp-framing, one per port, rules in osc_codec.py):
      * len32 (default): OSC 1.0 stream framing, a 4-byte big-endian size
        before each packet; packets may be bundles, whose messages are
        handled in order. A packet that doesn't decode (truncated, bad type
        tag) is dropped on its own and the stream stays in step. An
        impossible size (> 4 MB) loses the stream position, so the
        connection is closed.
      * none: the older unframed stream, messages back to back. A message
        left truncated mid-argument (as osc_mixer_test.py's
        truncated_argument_then_recovery test does) corrupts the parse of
        whatever arrives after it; there is deliberately no timeout-based
        reset. A malformed message (bad type tag, bad address) clears the
        buffer, since more bytes can never fix it.
    Every reply, echo and broadcast is framed the same way.
  - UDP: one packet per datagram (a message or a bundle), never framed.
  - Only what the mixer has is accepted (controller decision C2). The
    parameter model (mixer_params.Model, built from each backend's
    describe() plus SYSTEM_SETTINGS) decides; a set or get of anything else
    -- unknown zone, index out of range, module not implemented there,
    unknown setting -- is refused with an error reply. Values for such paths
    already in an old state file stay in the file, untouched and unreachable.
  - Error reply (amendment G): /<name>/error <path> <reason>, to the TCP
    requester only, for every refused request: unknown path, a set without
    a value, a value of the wrong kind, a read-only setting, an enum value
    outside its options, an invalid deviceName. path is the request's tail,
    normalised (no trailing slash; canonical index once it resolves).
    Requests over UDP are never answered; refusals are logged.
  - Values (mixer_params.ModuleSpec.apply, D37): numbers are clamped to the
    module's range, bools snapped, ints rounded, non-finite numbers remapped
    first (NaN, -inf -> -99.9; +inf -> +99.9); the echo carries the applied
    value, rounded to float32. Clamping is not an error.
  - Levels (Phase 5; the bus layer since Phase 12): the signal flow is
    inputChannel -> inputMatrix -> busChannel -> busMatrix -> outputChannel.
    '/<root>/set/inputMatrix/<in>_<bus>/level <dB>' sets the gain from
    input <in> to bus <bus>; busMatrix/<bus>_<out> from bus to output;
    inputChannel/<n>/level (and busChannel, outputChannel) a channel's
    level. One 'level' module everywhere (level_module): -90 dB (off, hard
    zero) to the gain ceiling read from the windows (+6.02 dB for Q2.16),
    default off. The rules are the same with or without --hw, so the
    simulator behaves like the board. At startup every parameter without a
    stored level gets the reset state the bitstream has: matrices 0 dB on
    the diagonal and off elsewhere (bus k -> output k, so a state file from
    before Phase 12, whose inputMatrix was input -> output, sounds the same:
    decision L3), channel levels 0 dB; stored levels outside the range are
    brought inside it. With --hw every bank is written to the PL on startup
    (restored state included), then each set is applied as it arrives. On a
    bitstream without the bus-layer windows only inputMatrix is served, as
    input -> output (build_backends).
  - Zones and backends: each OSC zone is served by one backend (a Backend
    subclass), listed in BACKENDS; one backend drives one register window
    (mixer_hw.WINDOWS) and describes its own zone. A new core block = a new
    window in mixer_hw + a new Backend + one BACKENDS entry; its description
    comes with it.
  - system: deviceName (string) and sampleRate (enum 48000, read-only).
  - Config (amendment B, F1): '/<root>/get/system/config' is answered, to
    the requester only, with '/<name>/set/system/config "<json>"' built by
    mixer_params.Model.config from the backends' own descriptions:
    schemaVersion 1, deviceName, firmware (firmware_version: VERSION from
    the image, else git, else 'dev'), sampleRate, zones, modules, system,
    and values (sparse: non-defaults, plus system/deviceName).
  - Discovery (amendment E, F5): --advertise dnssd publishes
    _studiorunner._tcp (instance = the mixer name; TXT name, v=1, framing)
    through systemd-resolved (osc_discovery.py), at startup and after every
    rename. The board service uses it; the default is none.
  - Ping (amendment H, F7): '/<root>/ping <int>' -> '/<name>/pong <int>',
    same token, to the sender (TCP only; UDP never replies).
  - Metering (standard "Metering", F4; Phase 13): '/<root>/meter/subscribe
    <port> <rateHz> <zoneMask>' over TCP (handle_meter_subscribe validates;
    malformed -> error reply); the subscriptions, the 5 s lease and the UDP
    stream to the TCP peer's address are mixer_meters.MeterHub's. The source
    is the PL's three peak-meter windows with --hw (all or none: none on a
    bitstream from before Phase 13), or with --meter-source synthetic a
    simulated one that follows each channel's level (never with --hw). No
    source: a subscribe is answered with an error reply. Meter sends never
    take the control lock.
  - Snapshots (standard "Snapshots", Phase 14): '/<root>/snapshot/<request>'
    over TCP (handle_snapshot): list, save, load, delete, fetch, apply,
    store. The store and the format are mixer_snapshots.py (files in
    --snapshot-dir, default 'snapshots' next to the state file). A recall
    checks every entry first (fit_snapshot: a refused value refuses the
    whole recall; entries the mixer lacks are skipped), saves the live state
    as 'Before load', pushes each changed zone with one COMMIT
    (Backend.apply_many), stores, broadcasts a set per changed value, then
    snapshot/loaded; all under the ordering lock. save/store/delete are
    confirmed by a broadcast snapshot/list. The config lists
    "capabilities": ["snapshots"].
  - Ordering (F3): ClientRegistry.lock is held while a change is applied,
    stored and echoed, while any packet is sent, and while the config
    snapshot is read and sent. Echoes therefore follow the store order, two
    threads never write into one socket, and no broadcast falls between a
    snapshot's read and its send. A controller that stops reading is dropped
    after ClientRegistry.SEND_TIMEOUT (5 s) and its connection closed.

Usage:
    python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --mixer-name mixer
    # older controllers that send unframed TCP:
    python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --tcp-framing none
    # on the board (root), driving the PL matrix; mixer_hw.py must sit
    # next to this script:
    python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --hw

STATE: the parameter tree and its file are mixer_state.py (format,
durability, recovery rules are in its docstring). In short: the file mirrors
the OSC address tree, saves are batched (<= SAVE_DELAY after a change) and
crash-safe (fsync + atomic rename + a .bak), a corrupt file is moved aside
rather than overwritten, and SIGTERM writes anything pending before exiting.
Default file: mixer_state.json in the working directory; the board service
uses /var/lib/fpgamixer/mixer_state.json. --state-file '' disables it.

Every stored path is canonical and every stored value has passed its
module's rules, so it is finite. A set whose path can't fit the tree (only
possible with a hand-edited state file: a value where a branch is) is
refused with an error reply.
--mixer-name is only the default for a state file without a name.
"""

import argparse
import json
import math
import os
import re
import signal
import socket
import sys
import threading

from osc_codec import (FRAMINGS, DEFAULT_FRAMING, OSCMalformed, FramingLost,
                       encode_message, decode_packet, make_framer)


# ---------------------------------------------------------------------------
# Logging + the parameter store (mixer_state.py)
# ---------------------------------------------------------------------------

from mixer_state import MixerState, split_path, is_device_name  # noqa: E402
from mixer_params import SYSTEM_ZONE, Model, ModuleSpec, Param, Refused, ZoneSpec, float32  # noqa: E402
from osc_discovery import DNSSD_FILE, DNSSD_RELOAD, NoAdvertiser, make_advertiser  # noqa: E402
import mixer_meters  # noqa: E402
import mixer_snapshots  # noqa: E402

DEVICE_NAME_KEY = "system/deviceName"  # as sent; requests may add a trailing slash

VERBOSE = False

_log_lock = threading.Lock()


def log(msg):
    """print() calls from different threads can interleave mid-line; this
    serializes them so the server's log stays readable."""
    with _log_lock:
        print(msg, flush=True)


class ClientRegistry:
    """Connected TCP controller sockets, and the server's ORDERING LOCK.

    Every TCP send goes through here (send() or broadcast()), framed with the
    port's framing (--tcp-framing), and happens while holding self.lock. Every
    change (apply, store, broadcast: apply_set, the rename) and every config
    snapshot (reply_config) also runs under it. So:
      - the echoes of two changes go out in the order the changes were stored,
        never the reverse;
      - two threads never write into one socket at once;
      - no broadcast can fall between reading the state for a snapshot and
        sending it (contract F3: everything after the snapshot is newer).
    The lock is re-entrant, so code holding it can call send/broadcast.

    The price: a controller that stops reading holds everyone up, for at most
    SEND_TIMEOUT; then it is dropped and its connection closed (it reconnects
    and resyncs from a new snapshot)."""

    SEND_TIMEOUT = 5.0

    def __init__(self, framing=DEFAULT_FRAMING):
        self.lock = threading.RLock()
        self.clients = set()
        self.framing = framing
        self.frame = make_framer(framing).frame

    def send(self, sock, packet: bytes):
        """One packet to one controller (get replies, errors, the snapshot).
        A failure drops and closes that controller, then raises."""
        with self.lock:
            try:
                sock.sendall(self.frame(packet))
            except OSError:
                self._drop(sock)
                raise

    def add(self, sock):
        sock.settimeout(self.SEND_TIMEOUT)   # bounds a stalled send (and paces the reader's recv)
        with self.lock:
            self.clients.add(sock)

    def remove(self, sock):
        with self.lock:
            self.clients.discard(sock)

    def _drop(self, sock):
        """Forget a controller whose send failed and close its connection, so
        its reader thread ends instead of serving a client that no longer
        gets broadcasts (a timed-out sendall may have left half a packet)."""
        self.clients.discard(sock)
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def broadcast(self, packet: bytes):
        data = self.frame(packet)
        with self.lock:
            for sock in list(self.clients):
                try:
                    sock.sendall(data)
                except OSError:
                    self._drop(sock)


# ---------------------------------------------------------------------------
# Protocol handling (shared by TCP and UDP paths)
# ---------------------------------------------------------------------------

ALIAS = "mixer"            # the reserved address root every mixer answers to
NAME_MAX_BYTES = 63         # a Bonjour label
_NAME_CHARS = re.compile(r"[A-Za-z0-9._-]+")


def split_after_mixer_name(address, mixer_name):
    """(kind, tail) for '/<root>/<kind>/<tail>' when <root> is the current
    name or the alias; (None, None) for any other root. kind is 'set',
    'get', ...; tail is everything after it (may be empty)."""
    root, sep, rest = address[1:].partition("/") if address.startswith("/") else ("", "", "")
    if not sep or root not in (mixer_name, ALIAS):
        return None, None
    kind, _, tail = rest.partition("/")
    return kind, tail


def name_problem(name):
    """Why `name` can't be the mixer name (standard: "Mixer name and the
    /mixer/ alias"), or None if it can. 'mixer' is the factory name, which a
    mixer may have but can't be renamed to."""
    if not isinstance(name, str):
        return "the name must be a string"
    if not name:
        return "the name can't be empty"
    if len(name.encode("utf-8")) > NAME_MAX_BYTES:
        return f"the name can be at most {NAME_MAX_BYTES} bytes"
    if name == ALIAS:
        return f"'{ALIAS}' is reserved"
    if not _NAME_CHARS.fullmatch(name):
        return "use only letters, digits, '-', '_' and '.'"
    return None


def send_error(reply, state, path, reason, via):
    """Amendment G: tell the requester why its request was refused. reply is
    the requester's send function (TCP), or None (UDP: logged only, since UDP
    never replies)."""
    log(f"    [{via}] refused {path}: {reason}")
    if reply is not None:
        reply(encode_message(f"/{state.mixer_name}/error", [path, reason]))


# ---------------------------------------------------------------------------
# Levels -> matrices and gain stages (hardware, or simulated with the same rules)
# ---------------------------------------------------------------------------

MATRIX_ZONE = "inputMatrix"
BUS_MATRIX_ZONE = "busMatrix"
LEVEL_ZONES = ("inputChannel", "busChannel", "outputChannel")
OFF_DB = -90.0            # mirrors mixer_hw.OFF_DB
SIM_MAX_DB = 20.0 * math.log10(((1 << 17) - 1) / (1 << 16))  # Q2.16 ceiling


def level_module(max_db):
    """The one 'level' module (controller D77): float dB, -90 (off) to the
    hardware ceiling, default off. Every zone describes it through this, so
    matrices and channels can't drift apart (the model refuses a module two
    zones describe differently)."""
    return ModuleSpec("float", unit="dB", min=OFF_DB, max=float32(max_db),
                      default=OFF_DB, group="level", linked=True)


# Virtual groups (standard "Virtual groups", Phase 14): a channel's group
# number, 0 = none. Fixed range rather than the zone's count: module
# metadata is one description for every zone, and a number is only a label.
VGROUP_MAX = 64
VGROUP_MODULE = ModuleSpec("int", min=0, max=VGROUP_MAX, default=0, group="link")


class Backend:
    """Serves one OSC zone.

      describe()  -> (ZoneSpec, {module: ModuleSpec}): the zone's shape and
                     its modules' metadata. This is the only description of
                     the zone: the server validates against it and the config
                     reply is built from it (mixer_params).
      apply(index, module, value) -> the value actually applied. Called only
                     with a canonical index the zone has, a module it lists,
                     and a value the module's rules already accepted (clamped,
                     snapped); the backend drives its hardware and may report
                     a further-adjusted value.
      seed_and_push(state) runs once at startup, after the state file loaded.
    """

    def __init__(self, zone):
        self.zone = zone

    def describe(self):
        raise NotImplementedError

    def apply(self, index, module, value):
        return value

    def apply_many(self, changes):
        """Many values at once (a snapshot recall): changes is {(index,
        module): value}, each already through its module's rules. Returns
        {(index, module): applied}. A backend with a window overrides this to
        push the lot with one COMMIT."""
        return {(index, module): self.apply(index, module, value)
                for (index, module), value in changes.items()}

    def seed_and_push(self, state):
        pass


def q_ceiling_db(width, frac):
    """The largest gain a signed fixed-point Q<width-frac>.<frac> holds, in dB."""
    return 20.0 * math.log10(((1 << (width - 1)) - 1) / (1 << frac))


class MatrixBackend(Backend):
    """<zone>/<src>_<dst>/level -> one pcm_matrix (inputMatrix: input -> bus;
    busMatrix: bus -> output). With hw (a mixer_hw.MatrixHW) the level goes to
    the PL; with hw None the same rules run without it (simulator). Levels:
    -90 dB (off) to the gain ceiling, default off; at startup crosspoints
    without a stored level get the reset routing (0 dB on the diagonal from
    input identity_from on, the rest off: the PL's own reset, so a first
    boot and a restore agree)."""

    def __init__(self, zone, hw, n_in, n_out, max_db=SIM_MAX_DB, identity_from=0):
        super().__init__(zone)
        self.hw = hw
        self.n_in = n_in
        self.n_out = n_out
        self.level = level_module(max_db)
        self.identity_from = identity_from

    def describe(self):
        return (ZoneSpec("matrix", ("level",), rows=self.n_in, cols=self.n_out),
                {"level": self.level})

    def crosspoint_key(self, inp, out):
        return f"{self.zone}/{inp}_{out}/level"

    def apply(self, index, module, value):
        inp, out = (int(x) for x in index.split("_"))
        if self.hw is not None:
            return float32(self.hw.set_db(out, inp, value))
        return value

    def apply_many(self, changes):
        """One bank write and one COMMIT for all of them."""
        if self.hw is None:
            return dict(changes)
        where = {}
        for (index, module) in changes:
            inp, out = (int(x) for x in index.split("_"))
            where[(index, module)] = (out, inp)
        applied = self.hw.set_bank_db({where[k]: v for k, v in changes.items()})
        return {k: float32(applied[where[k]]) for k in changes}

    def seed_and_push(self, state):
        """Fill in missing crosspoints with the reset routing, bring stored
        levels inside the rules (e.g. -99.9 or -120 from older servers become
        -90), then (hw) push the whole bank in one commit."""
        levels = {}
        seeded = {}
        normalised = 0
        for inp in range(self.n_in):
            for out in range(self.n_out):
                key = self.crosspoint_key(inp, out)
                stored = state.get(key, default=None)
                db, why = self.level.apply(stored) if stored is not None else (None, "missing")
                if db is None:
                    db = 0.0 if inp == out and inp >= self.identity_from else OFF_DB
                    seeded[key] = db
                elif db != stored:
                    seeded[key] = db
                    normalised += 1
                levels[(out, inp)] = db
        if seeded:
            for tail, why in state.set_many(seeded).items():
                log(f"    could not seed {tail}: {why}")
        if normalised:
            log(f"    {normalised} stored {self.zone} level(s) brought inside "
                f"{self.level.min}..{self.level.max} dB")
        if self.hw is not None:
            self.hw.set_bank_db(levels)
            log(f"Pushed {len(levels)} {self.zone} level(s) to the PL "
                f"({self.hw.status()})")


class GainBackend(Backend):
    """<zone>/<channel>/level -> one pcm_gain (Phase 12: inputChannel,
    busChannel, outputChannel). With hw (a mixer_hw.GainHW) the level goes to
    the PL; with hw None the same rules run without it (simulator). The
    module is the shared 'level' (default off, D77), so at startup every
    channel without a stored level is seeded at 0 dB (unity, decision L7: the
    gain stage's reset), the way the matrix seeds its diagonal; the config
    then lists those levels explicitly. Phase 14: each channel also has a
    'vgroup' (VGROUP_MODULE), a plain stored parameter that never reaches
    the hardware; the server's linking uses it (link_targets)."""

    def __init__(self, zone, hw, n, max_db=SIM_MAX_DB):
        super().__init__(zone)
        self.hw = hw
        self.n = n
        self.level = level_module(max_db)

    def describe(self):
        return (ZoneSpec("channels", ("level", "vgroup"), count=self.n),
                {"level": self.level, "vgroup": VGROUP_MODULE})

    def level_key(self, ch):
        return f"{self.zone}/{ch}/level"

    def apply(self, index, module, value):
        if self.hw is not None and module == "level":
            return float32(self.hw.set_db(int(index), value))
        return value

    def apply_many(self, changes):
        """The levels in one bank write and one COMMIT; other modules
        (vgroup) as given."""
        got = dict(changes)
        levels = {int(index): v for (index, m), v in changes.items() if m == "level"}
        if self.hw is not None and levels:
            applied = self.hw.set_bank_db(levels)
            for (index, m) in changes:
                if m == "level":
                    got[(index, m)] = float32(applied[int(index)])
        return got

    def seed_and_push(self, state):
        """Fill in missing levels with 0 dB, bring stored ones inside the
        rules, then (hw) push the whole bank in one commit."""
        levels, seeded, normalised = {}, {}, 0
        for ch in range(self.n):
            key = self.level_key(ch)
            stored = state.get(key, default=None)
            db, why = self.level.apply(stored) if stored is not None else (None, "missing")
            if db is None:
                db = 0.0
                seeded[key] = db
            elif db != stored:
                seeded[key] = db
                normalised += 1
            levels[ch] = db
        if seeded:
            for tail, why in state.set_many(seeded).items():
                log(f"    could not seed {tail}: {why}")
        if normalised:
            log(f"    {normalised} stored {self.zone} level(s) brought inside "
                f"{self.level.min}..{self.level.max} dB")
        if self.hw is not None:
            self.hw.set_bank_db(levels)
            log(f"Pushed {len(levels)} {self.zone} level(s) to the PL ({self.hw.status()})")


BACKENDS = {}  # zone -> Backend, filled in main()


def build_backends(use_hw, matrix_size, bus_layer=True, identity_from=0):
    """The zone -> backend table. With use_hw each backend opens its register
    window (mixer_hw.WINDOWS, checked by ID; the level windows also by TAP);
    without, the same backends run in simulation with the given size
    (bus_layer False: as a bitstream from before Phase 12). identity_from:
    the input matrix's first input seeded on the diagonal (Phase 11 H5: the
    USB host's inputs 0-3 start off, so the service passes 4); the bus
    matrix is always a full identity.

    The bus layer (Phase 12): inputChannel -> inputMatrix -> busChannel ->
    busMatrix -> outputChannel. Its four windows are present together or not
    at all; on an older bitstream (none present) only inputMatrix is served,
    and there it is still input -> output. A partial set, or sizes that don't
    chain, is refused: the hardware isn't what this server describes."""
    if not use_hw:
        n = matrix_size
        if not bus_layer:
            return {MATRIX_ZONE: MatrixBackend(MATRIX_ZONE, None, n, n, identity_from=identity_from)}
        backends = [GainBackend("inputChannel", None, n),
                    MatrixBackend(MATRIX_ZONE, None, n, n, identity_from=identity_from),
                    GainBackend("busChannel", None, n), MatrixBackend(BUS_MATRIX_ZONE, None, n, n),
                    GainBackend("outputChannel", None, n)]
        return {b.zone: b for b in backends}

    import mixer_hw  # next to this script; needs /dev/mem
    m = mixer_hw.open_window("matrix")
    log(f"PL window 'matrix' at 0x{m.base:08x}: {m.describe()}")
    max_db = q_ceiling_db(m.gain_width, m.gain_frac)
    found = {}
    for name in mixer_hw.BUS_LAYER:
        try:
            found[name] = mixer_hw.open_window(name)
        except mixer_hw.WindowAbsent:
            continue
        log(f"PL window '{name}' at 0x{found[name].base:08x}: {found[name].describe()}")
    if not found:
        log("No bus-layer windows (a bitstream from before Phase 12): inputMatrix is input -> output")
        return {MATRIX_ZONE: MatrixBackend(MATRIX_ZONE, m, m.n_in, m.n_out, max_db=max_db,
                                           identity_from=identity_from)}
    missing = [name for name in mixer_hw.BUS_LAYER if name not in found]
    if missing:
        raise RuntimeError(f"bus layer incomplete: no window {', '.join(missing)}")
    bm, il, bl, ol = (found[name] for name in mixer_hw.BUS_LAYER)
    chain = ((il.n, m.n_in, "input levels / input matrix inputs"),
             (m.n_out, bm.n_in, "input matrix outputs / bus matrix inputs"),
             (bl.n, bm.n_in, "bus levels / buses"),
             (ol.n, bm.n_out, "output levels / bus matrix outputs"))
    for a, b, what in chain:
        if a != b:
            raise RuntimeError(f"bus layer doesn't chain: {what} = {a} / {b}")
    for w in (bm, il, bl, ol):
        if (w.gain_width, w.gain_frac) != (m.gain_width, m.gain_frac):
            raise RuntimeError(f"window at 0x{w.base:08x}: Q{w.gain_width - w.gain_frac}."
                               f"{w.gain_frac}, the input matrix is Q{m.gain_width - m.gain_frac}."
                               f"{m.gain_frac} ('level' is one module, D77)")
    backends = [GainBackend("inputChannel", il, il.n, max_db=max_db),
                MatrixBackend(MATRIX_ZONE, m, m.n_in, m.n_out, max_db=max_db,
                              identity_from=identity_from),
                GainBackend("busChannel", bl, bl.n, max_db=max_db),
                MatrixBackend(BUS_MATRIX_ZONE, bm, bm.n_in, bm.n_out, max_db=max_db),
                GainBackend("outputChannel", ol, ol.n, max_db=max_db)]
    return {b.zone: b for b in backends}


# The system zone's settings (standard: "The system zone"). deviceName is
# handled by the rename path; a read-only setting's value is its default.
# 'config' is a request, not a setting (handle_get -> reply_config).
SAMPLE_RATE = 48000      # nominal; the core runs on mclk (roadmap section 4)
SYSTEM_SETTINGS = {
    "deviceName": ModuleSpec("string", default=ALIAS),
    "sampleRate": ModuleSpec("enum", unit="Hz", options=(SAMPLE_RATE,), default=SAMPLE_RATE,
                             read_only=True),
}
CONFIG_PATH = "system/config"


def firmware_version(here=os.path.dirname(os.path.abspath(__file__))):
    """The config's 'firmware': the commit this server was built from.
    On the board: VERSION next to this file, installed by the fpgamixer-osc
    recipe from the .synced-from that scripts/sync_buildhost.sh writes (the
    commit, '-dirty' if the tree had changes). In a checkout: git. Else 'dev'."""
    try:
        with open(os.path.join(here, "VERSION")) as f:
            version = f.read().strip()
        if version:
            return version
    except OSError:
        pass
    try:
        import subprocess    # here, not at the top: only a checkout needs it
        rev = subprocess.run(["git", "describe", "--always", "--dirty"], cwd=here,
                             capture_output=True, text=True, timeout=5)
        if rev.returncode == 0 and rev.stdout.strip():
            return rev.stdout.strip()
    except Exception:        # no git, no subprocess module, a timeout: a version is never fatal
        pass
    return "dev"


FIRMWARE = "dev"     # set once in main()
ADVERTISER = NoAdvertiser()   # discovery (osc_discovery); set in main() from --advertise


def reply_config(state, registry, reply_sock, via):
    """The config reply (amendment B), to the requester only. The state is
    read and the reply sent while holding the ordering lock, so no broadcast
    falls between them (contract F3): any set the controller receives after
    the snapshot is newer than it."""
    with registry.lock:
        body = MODEL.config(state.mixer_name, FIRMWARE, SAMPLE_RATE,
                            lambda p: current_value(p, state))
        if SNAPSHOTS is not None:
            body["capabilities"] = ["snapshots"]
        text = json.dumps(body, separators=(",", ":"), allow_nan=False)
        registry.send(reply_sock, encode_message(f"/{state.mixer_name}/set/{CONFIG_PATH}", [text]))
    log(f"    [{via}] config sent ({len(text)} bytes, {len(body['values'])} value(s))")

MODEL = Model()  # what the mixer has: filled from BACKENDS in main() (build_model)


def build_model(backends, system_settings):
    """The parameter model from each backend's own description."""
    model = Model(system=dict(system_settings))
    for backend in backends.values():
        zone_spec, modules = backend.describe()
        model.add_zone(backend.zone, zone_spec, modules)
    return model


def current_value(param, state):
    """A parameter's value: stored, else its module's default (state is
    sparse: never-set parameters of a new zone aren't in the file). A
    read-only setting is never stored, so its value is its default."""
    if param.path == "system/deviceName":
        return state.mixer_name
    value = state.get(param.path, default=None)
    return param.spec.default_value() if value is None else value


def group_members(zone, index, state):
    """The channels of `zone` in the same virtual group as channel `index`
    (str), in index order, itself included; [index] when it isn't grouped
    or the zone has no vgroup (the matrices: crosspoints never link)."""
    spec = MODEL.zones.get(zone)
    if spec is None or "vgroup" not in spec.modules:
        return [index]
    group = state.get(f"{zone}/{index}/vgroup", default=0)
    if not group:
        return [index]
    return [i for i in spec.indices() if state.get(f"{zone}/{i}/vgroup", default=0) == group]


def link_targets(param, state):
    """Every parameter a set of `param` applies to (standard "Virtual
    groups"): `param` first, then the same module on the other members of
    its channel's group, in index order. Only modules marked linked, only on
    channels: matrix crosspoints never link, so grouped channels can still
    be routed independently (user, 2026-10-08)."""
    if not param.spec.linked:
        return [param]
    others = [ix for ix in group_members(param.zone, param.index, state) if ix != param.index]
    return [param] + [Param(param.zone, ix, param.module, param.spec) for ix in others]


def apply_set(tail, value, state, registry, reply, via):
    """The one path every set takes (TCP and UDP): resolve the path against
    the model, apply the module's value rules, hand the value to its zone's
    backend, store, then broadcast the confirmation (the echo). Any refusal
    goes back to the requester as an error reply (amendment G); clamping is
    not a refusal."""
    try:
        param = MODEL.resolve(tail)
    except Refused as r:
        return send_error(reply, state, r.path, r.reason, via)
    if param.spec.read_only:
        return send_error(reply, state, param.path, f"{param.path} is read-only", via)
    applied, why = param.spec.apply(value)
    if why is not None:
        return send_error(reply, state, param.path, why, via)
    conflict = state.check(param.path)
    if conflict is not None:     # only an old, hand-edited state file can do this
        return send_error(reply, state, param.path, f"can't store: {conflict}", via)
    backend = BACKENDS.get(param.zone)
    with registry.lock:          # apply, store and echo as one step (ClientRegistry)
        targets = link_targets(param, state)   # read under the lock: groups can't change midway
        if len(targets) == 1:
            if backend is not None:
                applied = backend.apply(param.index, param.module, applied)
            state.set(param.path, applied)
            registry.broadcast(encode_message(f"/{state.mixer_name}/set/{param.path}", [applied]))
        else:                    # a virtual group: one push (one COMMIT) for every member
            changes = {(t.index, t.module): applied for t in targets}
            got = backend.apply_many(changes) if backend is not None else changes
            stored = {t.path: got[(t.index, t.module)] for t in targets}
            rejected = state.set_many(stored)
            for t in targets:    # the requested parameter first (app D44), then the members
                if t.path in rejected:
                    log(f"    [{via}] could not store linked {t.path}: {rejected[t.path]}")
                    continue
                registry.broadcast(encode_message(f"/{state.mixer_name}/set/{t.path}",
                                                  [stored[t.path]]))
            applied = stored[param.path]
    if VERBOSE:
        log(f"    [{via}] SET {param.path} = {applied!r}"
            + (f" (+{len(targets) - 1} linked)" if len(targets) > 1 else ""))


def handle_devicename_change(new_name, state, registry, reply, via):
    """A rename. Accepted: broadcast under the old name, then the new name
    applies (the alias keeps working). Refused (D33 rules): the sender alone
    gets the name that stands, then an error reply (D38); nobody else hears
    anything."""
    with registry.lock:          # the name read, the confirmation and the rename are one step
        old_name = state.mixer_name
        why = name_problem(new_name)
        if why is not None:
            if reply is not None:
                reply(encode_message(f"/{old_name}/set/{DEVICE_NAME_KEY}", [old_name]))
            send_error(reply, state, DEVICE_NAME_KEY, why, via)
            return
        registry.broadcast(encode_message(f"/{old_name}/set/{DEVICE_NAME_KEY}", [new_name]))
        state.rename(new_name)
    ADVERTISER.advertise(new_name)   # outside the lock: may write a file and restart a service
    log(f"    *** [{via}] device name changed: {old_name!r} -> {new_name!r}. "
          f"Address root is now /{new_name}/ (and /{ALIAS}/); /{old_name}/ is ignored. ***")


def handle_set(tail, args, state, registry, reply, via):
    """Every set, TCP and UDP. reply sends to the requester (TCP), or is None
    (UDP, which never replies)."""
    if not args:
        path = "/".join(split_path(tail) or ())
        return send_error(reply, state, path, "set needs a value", via)
    if len(args) > 1:
        log(f"    [{via}] set for {tail!r} carried {len(args)} args, using the first")
    value = args[0]

    if is_device_name(tail):
        handle_devicename_change(value, state, registry, reply, via)
        return

    apply_set(tail, value, state, registry, reply, via)


def handle_get(tail, state, reply, via):
    """A get: the value as a set, to the requester only; an unknown path is
    an error reply (no more 0.0 for a parameter the mixer doesn't have)."""
    try:
        param = MODEL.resolve(tail)
    except Refused as r:
        return send_error(reply, state, r.path, r.reason, via)
    value = current_value(param, state)
    if VERBOSE:
        log(f"    [{via}] GET {param.path} -> {value!r}")
    reply(encode_message(f"/{state.mixer_name}/set/{param.path}", [value]))


def handle_tcp_message(msg, state, registry, reply_sock, via):
    kind, tail = split_after_mixer_name(msg.address, state.mixer_name)
    if kind is None:
        log(f"    [{via}] ignoring message under unknown root: {msg.address!r} "
              f"(currently listening as {state.mixer_name!r})")
        return
    reply = lambda packet: registry.send(reply_sock, packet)  # noqa: E731
    if kind == "set":
        handle_set(tail, msg.args, state, registry, reply, via)
    elif kind == "get" and "/".join(split_path(tail) or ()) == CONFIG_PATH:
        reply_config(state, registry, reply_sock, via)
    elif kind == "get":
        handle_get(tail, state, reply, via)
    elif kind == "ping" and not tail:
        handle_ping(msg.args, state, reply, via)
    elif kind == "meter" and "/".join(split_path(tail) or ()) == "subscribe":
        handle_meter_subscribe(msg.args, state, reply, reply_sock, via)
    elif kind == "snapshot":
        handle_snapshot(tail, msg.args, state, registry, reply, via)
    else:
        log(f"    [{via}] ignoring unknown command kind {kind!r} in {msg.address!r}")


def handle_ping(args, state, reply, via):
    """Amendment H (F7): /<name>/ping <token:int> -> /<name>/pong <token:int>,
    the same token, to the sender. Anything but one int token is ignored, as
    the mock does (a ping is optional; no error reply)."""
    if len(args) != 1 or not isinstance(args[0], int) or isinstance(args[0], bool):
        log(f"    [{via}] ping without one int token {args!r}; ignored")
        return
    reply(encode_message(f"/{state.mixer_name}/pong", [args[0]]))


METER_PATH = "meter/subscribe"
METER_HUB = None   # mixer_meters.MeterHub, or None: this mixer has no meters (main)


def handle_meter_subscribe(args, state, reply, conn, via):
    """Standard "Metering" (F4): /<name>/meter/subscribe <port> <rateHz>
    <zoneMask>, three integers (OSC i, or f with an integral value); port
    1..65535; rate clamped 1..120; mask bits for zones the mixer doesn't meter
    are ignored; mask 0 unsubscribes. The stream goes to the TCP peer's address.
    Anything else is refused with an error reply (TCP only: UDP never gets
    here)."""
    def as_int(v):
        if isinstance(v, bool):
            return None
        if isinstance(v, int):
            return v
        if isinstance(v, float) and math.isfinite(v) and v.is_integer():
            return int(v)
        return None

    if METER_HUB is None:
        return send_error(reply, state, METER_PATH, "this mixer has no meters", via)
    ints = [as_int(v) for v in args]
    if len(args) != 3 or any(v is None for v in ints):
        return send_error(reply, state, METER_PATH,
                          "needs three integers: port, rateHz, zoneMask", via)
    port, rate, mask = ints
    if not 1 <= port <= 65535:
        return send_error(reply, state, METER_PATH, f"port {port} outside 1..65535", via)
    rate = max(mixer_meters.RATE_MIN, min(mixer_meters.RATE_MAX, rate))
    try:
        ip = conn.getpeername()[0]
    except OSError:
        return
    METER_HUB.subscribe(conn, ip, port, rate, mixer_meters.zones_from_mask(mask, METER_HUB.available))


SNAPSHOTS = None   # mixer_snapshots.SnapshotStore (main)


def live_values(state):
    """Every parameter but system/*, at its current value: what a snapshot holds."""
    return {p.path: current_value(p, state) for p in MODEL.params() if p.zone != SYSTEM_ZONE}


def snapshot_of(state, name, auto=False):
    zones = {zone: spec.describe() for zone, spec in MODEL.zones.items()}
    return mixer_snapshots.make_snapshot(name, live_values(state), zones, state.mixer_name,
                                         FIRMWARE, auto=auto)


def snapshot_list_message(state):
    return encode_message(f"/{state.mixer_name}/snapshot/list",
                          [json.dumps(SNAPSHOTS.list(), separators=(",", ":"))])


def fit_snapshot(doc):
    """A snapshot's entries against this mixer: ({path: (Param, applied)},
    skipped, None), or (None, None, reason) if any entry the mixer has holds a
    value its module refuses (a wrong kind, an enum outside its options): then
    nothing may be applied. Entries the mixer doesn't have are skipped and
    counted; system/* entries are ignored (the name stays with the device)."""
    fitted, skipped = {}, 0
    for path, value in doc["values"].items():
        if path.split("/", 1)[0] == SYSTEM_ZONE:
            continue
        try:
            param = MODEL.resolve(path)
        except Refused:
            skipped += 1
            continue
        applied, why = param.spec.apply(value)
        if why is not None:
            return None, None, f"{param.path}: {why}"
        fitted[param.path] = (param, applied)
    return fitted, skipped, None


def recall_snapshot(fitted, skipped, label, state, registry, via):
    """Standard "Snapshots", recall steps 3-6, under the ordering lock: save
    the live state as AUTO_NAME (the undo point), push every changed value
    with one COMMIT per window, store, broadcast a set per changed value, then
    snapshot/loaded. Parameters the snapshot doesn't mention are untouched."""
    with registry.lock:
        try:
            SNAPSHOTS.write(snapshot_of(state, mixer_snapshots.AUTO_NAME, auto=True))
        except (mixer_snapshots.SnapshotRefused, OSError) as e:
            log(f"    [{via}] could not save '{mixer_snapshots.AUTO_NAME}' ({e}); recalling anyway")
        by_zone = {}
        for param, value in fitted.values():
            if value != current_value(param, state):
                by_zone.setdefault(param.zone, {})[(param.index, param.module)] = value
        stored = {}
        for zone, changes in by_zone.items():
            backend = BACKENDS.get(zone)
            applied = backend.apply_many(changes) if backend is not None else dict(changes)
            for (index, module), value in applied.items():
                stored[f"{zone}/{index}/{module}"] = value
        rejected = state.set_many(stored) if stored else {}
        for path, why in rejected.items():
            log(f"    [{via}] could not store {path}: {why}")
        for path, value in stored.items():
            if path not in rejected:
                registry.broadcast(encode_message(f"/{state.mixer_name}/set/{path}", [value]))
        registry.broadcast(encode_message(f"/{state.mixer_name}/snapshot/loaded",
                                          [label, len(fitted), skipped]))
    log(f"    [{via}] snapshot {label!r} recalled: {len(fitted)} applied, "
        f"{len(stored)} changed, {skipped} skipped")


def handle_snapshot(tail, args, state, registry, reply, via):
    """Standard "Snapshots" (TCP only): list, save, load, delete, fetch,
    apply, store. Every refusal is an error reply on snapshot/<request> and
    changes nothing."""
    request = "/".join(split_path(tail) or ())
    path = f"snapshot/{request}"

    def refuse(reason):
        send_error(reply, state, path, reason, via)

    def text_arg(v):   # a string, or a blob of UTF-8 (as the config may travel)
        if isinstance(v, str):
            return v
        if isinstance(v, (bytes, bytearray)):
            try:
                return bytes(v).decode("utf-8")
            except UnicodeDecodeError:
                return None
        return None

    texts = [text_arg(a) for a in args]
    if SNAPSHOTS is None:
        return refuse("this mixer has no snapshots")

    if request == "list":
        if args:
            return refuse("list takes no arguments")
        return reply(snapshot_list_message(state))

    if request == "fetch":
        if not args:
            with registry.lock:      # ordered with the broadcasts, like the config reply
                text = mixer_snapshots.encode(snapshot_of(state, ""))
                reply(encode_message(f"/{state.mixer_name}/snapshot/data", ["", text]))
            return
        if len(args) != 1 or texts[0] is None:
            return refuse("fetch takes nothing (the live state) or a snapshot name")
        try:
            text = SNAPSHOTS.read(texts[0])
        except KeyError:
            return refuse(f"no snapshot named {texts[0]!r}")
        return reply(encode_message(f"/{state.mixer_name}/snapshot/data", [texts[0], text]))

    if request in ("save", "load", "delete"):
        if len(args) != 1 or texts[0] is None:
            return refuse(f"{request} needs a snapshot name")
        name = texts[0]
        if request == "save":
            why = mixer_snapshots.name_problem(name)
            if why is not None:
                return refuse(why)
            with registry.lock:      # the values read, the file written and the list broadcast as one step
                try:
                    SNAPSHOTS.write(snapshot_of(state, name))
                except mixer_snapshots.SnapshotRefused as e:
                    return refuse(str(e))
                except OSError as e:
                    return refuse(f"could not write the snapshot ({e})")
                registry.broadcast(snapshot_list_message(state))
            log(f"    [{via}] snapshot {name!r} saved")
            return
        if request == "delete":
            with registry.lock:
                try:
                    SNAPSHOTS.delete(name)
                except KeyError:
                    return refuse(f"no snapshot named {name!r}")
                except OSError as e:
                    return refuse(f"could not delete the snapshot ({e})")
                registry.broadcast(snapshot_list_message(state))
            log(f"    [{via}] snapshot {name!r} deleted")
            return
        try:                         # load
            text = SNAPSHOTS.read(name)
        except KeyError:
            return refuse(f"no snapshot named {name!r}")
        except OSError as e:
            return refuse(f"could not read the snapshot ({e})")
        doc, why = mixer_snapshots.parse(text)
        if doc is None:
            return refuse(f"the stored snapshot is not valid: {why}")
        fitted, skipped, why = fit_snapshot(doc)
        if why is not None:
            return refuse(why)
        return recall_snapshot(fitted, skipped, name, state, registry, via)

    if request == "apply":
        if len(args) != 1 or texts[0] is None:
            return refuse("apply needs the snapshot JSON as a string")
        doc, why = mixer_snapshots.parse(texts[0])
        if doc is None:
            return refuse(why)
        fitted, skipped, why = fit_snapshot(doc)
        if why is not None:
            return refuse(why)
        label = doc.get("name") if isinstance(doc.get("name"), str) else ""
        return recall_snapshot(fitted, skipped, label, state, registry, via)

    if request == "store":
        if len(args) != 2 or None in texts:
            return refuse("store needs a snapshot name and the snapshot JSON as strings")
        name, text = texts
        why = mixer_snapshots.name_problem(name)
        if why is not None:
            return refuse(why)
        doc, why = mixer_snapshots.parse(text)
        if doc is None:
            return refuse(why)
        _fitted, _skipped, why = fit_snapshot(doc)    # the same checks a recall makes
        if why is not None:
            return refuse(why)
        doc = dict(doc, name=name)
        doc.pop("auto", None)
        if not isinstance(doc.get("savedAt"), str):
            doc["savedAt"] = mixer_snapshots.utc_now()
        with registry.lock:
            try:
                SNAPSHOTS.write(doc)
            except mixer_snapshots.SnapshotRefused as e:
                return refuse(str(e))
            except OSError as e:
                return refuse(f"could not write the snapshot ({e})")
            registry.broadcast(snapshot_list_message(state))
        log(f"    [{via}] snapshot {name!r} stored (uploaded)")
        return

    refuse(f"unknown snapshot request {request!r}")


def handle_packet(packet, state, registry, reply_sock, via):
    """One TCP packet: a message, or a bundle whose messages run in order.
    A packet that doesn't decode is dropped whole; nothing in it runs."""
    try:
        messages = decode_packet(packet)
    except OSCMalformed as e:
        log(f"    [{via}] malformed OSC packet ({e}); dropped {len(packet)} byte(s)")
        return
    for msg in messages:
        handle_tcp_message(msg, state, registry, reply_sock, via)


# ---------------------------------------------------------------------------
# TCP server
# ---------------------------------------------------------------------------

def handle_tcp_client(conn, addr, state, registry):
    via = f"TCP {addr[0]}:{addr[1]}"
    log(f"[+] {via} connected")   # already in the registry (tcp_accept_loop)
    framer = make_framer(registry.framing)
    # The socket's timeout is the registry's send bound (ClientRegistry.add);
    # a recv that times out just waits again: an idle controller is fine.
    try:
        while True:
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break  # client closed
            unframed_error = None
            try:
                packets = framer.push(chunk)
            except OSCMalformed as e:   # unframed only: the buffer was cleared
                packets, unframed_error = e.packets, e
            except FramingLost as e:    # len32 only: stream position lost
                log(f"    [{via}] {e}; closing the connection")
                break
            for packet in packets:
                handle_packet(packet, state, registry, conn, via)
            if unframed_error is not None:
                log(f"    [{via}] malformed OSC ({unframed_error}); dropped the buffered bytes")
    except (ConnectionResetError, OSError) as e:
        log(f"    [{via}] connection error: {e}")
    finally:
        registry.remove(conn)
        if METER_HUB is not None:
            METER_HUB.drop(conn)     # "Closing the TCP connection ends the subscription"
        try:
            conn.close()
        except OSError:
            pass
        log(f"[-] {via} disconnected")


def tcp_accept_loop(host, port, state, registry):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(32)
    log(f"TCP OSC server listening on {host}:{port}")
    while True:
        conn, addr = srv.accept()
        # Register for broadcasts HERE, before the handler thread exists, so a
        # change made by another client right after this accept reaches this
        # one too. (Registering inside the thread left a window of thread
        # start-up time in which broadcasts were missed.) A connection still
        # waiting in the listen backlog can't be reached by any server; a
        # controller that needs to be sure it is live does a round trip first.
        registry.add(conn)
        threading.Thread(target=handle_tcp_client, args=(conn, addr, state, registry), daemon=True).start()


# ---------------------------------------------------------------------------
# UDP server (write-only, no reply — per the roadmap doc)
# ---------------------------------------------------------------------------

def udp_serve(host, port, state, registry):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((host, port))
    log(f"UDP OSC server listening on {host}:{port}")
    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except OSError:
            break
        via = f"UDP {addr[0]}:{addr[1]}"
        try:
            messages = decode_packet(data)   # a message or a bundle; nothing else
        except OSCMalformed as e:
            log(f"    [{via}] malformed datagram, ignoring: {e}")
            continue
        for msg in messages:
            handle_udp_message(msg, state, registry, via)


def handle_udp_message(msg, state, registry, via):
    kind, tail = split_after_mixer_name(msg.address, state.mixer_name)
    if kind is None:
        log(f"    [{via}] ignoring message under unknown root: {msg.address!r}")
        return
    if kind != "set":
        log(f"    [{via}] ignoring non-set command over UDP (write-only): {msg.address!r}")
        return
    handle_set(tail, msg.args, state, registry, None, via)   # None: UDP never replies


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_meter_source(use_hw, kind, backends, state):
    """The meters (Phase 13), or None. With use_hw the PL's three peak-meter
    windows, all or none (none = a bitstream from before Phase 13: no meters),
    each matching its channel zone's size; without, the synthetic source if
    asked for (decision M8: never on hardware)."""
    sizes = {z: b.n for z, b in backends.items() if z in mixer_meters.METER_ZONES}
    if use_hw:
        import mixer_hw
        found = {}
        for name, zone in zip(mixer_hw.METERS, mixer_meters.METER_ZONES):
            try:
                found[zone] = mixer_hw.open_window(name)
            except mixer_hw.WindowAbsent:
                continue
            log(f"PL window '{name}' at 0x{found[zone].base:08x}: {found[zone].describe()}")
        if not found:
            log("No meter windows (a bitstream from before Phase 13): no meters")
            return None
        if len(found) != len(mixer_meters.METER_ZONES):
            missing = [z for z in mixer_meters.METER_ZONES if z not in found]
            raise RuntimeError(f"meters incomplete: none for {', '.join(missing)}")
        for zone, w in found.items():
            if sizes.get(zone) != w.n:
                raise RuntimeError(f"{zone} meter has {w.n} channels, the zone {sizes.get(zone)}")
        return mixer_meters.HardwareMeterSource(found)
    if kind == "synthetic" and sizes:
        def level_of(zone, ch):
            v = state.get(f"{zone}/{ch}/level", default=None)
            return v if isinstance(v, (int, float)) else None
        log("Meters: SYNTHETIC source (--meter-source synthetic; for tests, never on hardware)")
        return mixer_meters.SyntheticMeterSource(sizes, level_of)
    return None


def main():
    global VERBOSE, MODEL, FIRMWARE, ADVERTISER, METER_HUB, SNAPSHOTS
    p = argparse.ArgumentParser(description="Reference/simulator server for the FPGA mixer OSC protocol.")
    p.add_argument("--host", default="0.0.0.0", help="address to bind (default: all interfaces)")
    p.add_argument("--tcp-port", type=int, required=True)
    p.add_argument("--udp-port", type=int, required=True)
    p.add_argument("--mixer-name", default="mixer",
                   help="mixer name / address root if the state file has none (default: mixer)")
    p.add_argument("--state-file", default="mixer_state.json",
                    help="persistence file, restored on startup (default: mixer_state.json; "
                         "pass an empty string to disable persistence)")
    p.add_argument("--verbose", action="store_true", help="log every set/get, not just connects and notable events")
    p.add_argument("--hw", action="store_true",
                   help="drive the PL register windows (mixer_hw.WINDOWS) through /dev/mem "
                        "(on the board, as root; Phase 5+ bitstream only)")
    p.add_argument("--matrix-size", type=int, default=20,
                   help="simulated size N without --hw: N inputs, N buses, N outputs "
                        "(default: 20, the hardware: 4 link #3 (USB host) + 8 link #1 (USB) "
                        "+ 8 link #2 (AVB) channels)")
    p.add_argument("--identity-from", type=int, default=0,
                   help="input-matrix crosspoints with no stored level start at 0 dB on the "
                        "diagonal from this input on, the rest off (default 0: the whole "
                        "diagonal; the board's service passes 4, Phase 11 H5: the USB host's "
                        "inputs start off, matching the PL's reset)")
    p.add_argument("--no-bus-layer", action="store_true",
                   help="simulate a bitstream from before Phase 12: inputMatrix only, "
                        "input -> output (with --hw the windows decide)")
    p.add_argument("--tcp-framing", choices=FRAMINGS, default=DEFAULT_FRAMING,
                   help="TCP stream framing: len32 = OSC 1.0 4-byte size prefix per packet "
                        "(default); none = unframed messages back to back (older controllers)")
    p.add_argument("--advertise", choices=("none", "dnssd"), default="none",
                   help="discovery: dnssd = publish _studiorunner._tcp through systemd-resolved "
                        "(the board service); none = don't (default)")
    p.add_argument("--dnssd-file", default=DNSSD_FILE, help=f"(dnssd) the file to write (default {DNSSD_FILE})")
    p.add_argument("--dnssd-reload", default=DNSSD_RELOAD,
                   help=f"(dnssd) command run after the file changes (default '{DNSSD_RELOAD}'; '' = none)")
    p.add_argument("--snapshot-dir", default=None,
                   help="where named snapshots are kept (default: 'snapshots' next to the "
                        "state file; in memory only when persistence is off). On the board: "
                        "/var/lib/fpgamixer/snapshots")
    p.add_argument("--meter-source", choices=("none", "synthetic"), default="none",
                   help="without --hw: synthetic = meters that follow each channel's level "
                        "(tests, the simulator); none = no meters (default). With --hw the "
                        "PL's meter windows are used if the bitstream has them")
    args = p.parse_args()
    VERBOSE = args.verbose
    if args.hw and args.meter_source != "none":
        p.error("--meter-source is for the simulator; with --hw the meters are the PL's (decision M8)")

    state = MixerState(args.mixer_name, args.state_file or None, log=log)
    snapshot_dir = args.snapshot_dir
    if snapshot_dir is None and args.state_file:
        snapshot_dir = os.path.join(os.path.dirname(os.path.abspath(args.state_file)), "snapshots")
    SNAPSHOTS = mixer_snapshots.SnapshotStore(snapshot_dir, log=log)
    log(f"Snapshots: {snapshot_dir or 'in memory'} ({len(SNAPSHOTS.list())} stored)")
    BACKENDS.update(build_backends(args.hw, args.matrix_size, bus_layer=not args.no_bus_layer,
                                   identity_from=args.identity_from))
    MODEL = build_model(BACKENDS, SYSTEM_SETTINGS)
    FIRMWARE = firmware_version()
    log(f"Firmware {FIRMWARE}; zones: {', '.join(MODEL.zones) or 'none'}")
    for backend in BACKENDS.values():
        backend.seed_and_push(state)
    registry = ClientRegistry(args.tcp_framing)
    log(f"TCP framing: {args.tcp_framing}")
    ADVERTISER = make_advertiser(args.advertise, args.tcp_port, args.tcp_framing,
                                 args.dnssd_file, args.dnssd_reload, log)
    ADVERTISER.advertise(state.mixer_name)

    threading.Thread(target=udp_serve, args=(args.host, args.udp_port, state, registry), daemon=True).start()

    source = build_meter_source(args.hw, args.meter_source, BACKENDS, state)
    if source is not None:
        meter_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        METER_HUB = mixer_meters.MeterHub(source, meter_sock.sendto, lambda: state.mixer_name, log=log)
        threading.Thread(target=METER_HUB.run, daemon=True).start()
        log(f"Meters: {', '.join(f'{z} ({n})' for z, n in source.zones().items())}")

    # systemd stops the service with SIGTERM: turn it into a normal exit so
    # the finally-block writes any batched, not-yet-saved state.
    def on_sigterm(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, on_sigterm)

    try:
        tcp_accept_loop(args.host, args.tcp_port, state, registry)
    except KeyboardInterrupt:
        pass
    finally:
        saved = state.close()
        log(f"Shutting down; state {'saved' if saved else 'NOT saved (see above)'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
