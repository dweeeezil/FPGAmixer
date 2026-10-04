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
  - Unknown addresses aren't validated — anything under the current
    address root is accepted, stored, and echoed back generically. The one
    exception is the crosspoint level, which drives real hardware (below).
  - Crosspoints (Phase 5): '/<root>/set/inputMatrix/<in>_<out>/level <dB>'
    sets the gain from input <in> to output <out> of the PL matrix. The
    hardware has no bus layer yet, so "bus" = output for now. The rules are
    the same with or without --hw, so the simulator behaves like the board:
      * indices outside the matrix (--matrix-size, or the size the hardware
        reports) are ignored: not stored, not echoed;
      * a non-numeric level is ignored the same way;
      * levels <= -90 dB mean off (hard zero); levels above the gain
        ceiling (+6.02 dB for Q2.16) are clamped, and the echo carries the
        clamped value, since the echo confirms what was applied;
      * every crosspoint without a stored level is seeded at startup:
        0 dB on the diagonal, -90 dB (off) elsewhere -- the routing the
        bitstream resets to -- so a get always reports what is in effect.
    With --hw the full matrix is written to the PL on startup (restored
    state included), then each set is applied as it arrives.
  - Zones and backends: each OSC zone that drives hardware is served by one
    backend (a Backend subclass), listed in BACKENDS; one backend drives one
    register window (mixer_hw.WINDOWS). A set goes to the backend for its
    zone; zones with no backend are stored and echoed generically. A new core
    block = a new window in mixer_hw + a new Backend + one BACKENDS entry.

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

On the wire, before a value reaches the store: non-finite floats are
remapped (NaN, -inf -> -99.9; +inf -> +99.9, and the echo confirms the
remapped value), and a set whose path can't fit the tree (a value where a
branch is, or the reverse; an empty segment) is ignored: not stored, not
echoed, logged. A get on a missing path or a branch replies 0.0.
--mixer-name is only the default for a state file without a name.
"""

import argparse
import math
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

from mixer_state import MixerState, split_path, is_device_name, finite_value  # noqa: E402

DEVICE_NAME_KEY = "system/deviceName"  # as sent; requests may add a trailing slash

VERBOSE = False

_log_lock = threading.Lock()


def log(msg):
    """print() calls from different threads can interleave mid-line; this
    serializes them so the server's log stays readable."""
    with _log_lock:
        print(msg, flush=True)


class ClientRegistry:
    """Connected TCP controller sockets, for broadcasting set/echo/sync
    messages. Every TCP send goes through here (send() or broadcast()), so
    each packet is framed with the port's framing (--tcp-framing)."""

    def __init__(self, framing=DEFAULT_FRAMING):
        self.lock = threading.Lock()
        self.clients = set()
        self.framing = framing
        self.frame = make_framer(framing).frame

    def send(self, sock, packet: bytes):
        """One packet to one controller (get replies)."""
        sock.sendall(self.frame(packet))

    def add(self, sock):
        with self.lock:
            self.clients.add(sock)

    def remove(self, sock):
        with self.lock:
            self.clients.discard(sock)

    def broadcast(self, packet: bytes):
        data = self.frame(packet)
        with self.lock:
            targets = list(self.clients)
        dead = []
        for sock in targets:
            try:
                sock.sendall(data)
            except OSError:
                dead.append(sock)
        if dead:
            with self.lock:
                for sock in dead:
                    self.clients.discard(sock)


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
# Crosspoint levels -> matrix (hardware, or simulated with the same rules)
# ---------------------------------------------------------------------------

MATRIX_ZONE = "inputMatrix"
OFF_DB = -90.0            # mirrors mixer_hw.OFF_DB
SIM_MAX_DB = 20.0 * math.log10(((1 << 17) - 1) / (1 << 16))  # Q2.16 ceiling


class Backend:
    """Serves one OSC zone. apply() gets the path below the zone (e.g.
    ('0_1', 'level')) and returns (accepted, value_to_store_and_echo); a
    backend may ignore paths it doesn't drive by accepting them unchanged.
    seed_and_push() runs once at startup, after the state file is loaded."""

    def __init__(self, zone):
        self.zone = zone

    def apply(self, rest, value, via):
        return True, value

    def seed_and_push(self, state):
        pass


class MatrixBackend(Backend):
    """<zone>/<in>_<out>/level -> one pcm_matrix. With hw (a mixer_hw.MatrixHW)
    the level goes to the PL; with hw None it is only validated and clamped
    the same way (simulator)."""

    def __init__(self, zone, hw, n_in, n_out):
        super().__init__(zone)
        self.hw = hw
        self.n_in = n_in
        self.n_out = n_out

    def crosspoint_key(self, inp, out):
        return f"{self.zone}/{inp}_{out}/level"

    @staticmethod
    def parse(rest):
        """(in, out) if rest is ('<in>_<out>', 'level'), else None."""
        if len(rest) != 2 or rest[1] != "level":
            return None
        a, sep, b = rest[0].partition("_")
        if not (sep and a.isdigit() and b.isdigit()):
            return None
        return int(a), int(b)

    def apply(self, rest, value, via):
        xp = self.parse(rest)
        if xp is None:
            return True, value  # e.g. .../delay: no hardware yet, generic store/echo
        inp, out = xp
        if not (0 <= inp < self.n_in and 0 <= out < self.n_out):
            log(f"    [{via}] crosspoint {inp}_{out} outside the "
                f"{self.n_in}x{self.n_out} matrix, ignored")
            return False, value
        if isinstance(value, (str, bool)):
            log(f"    [{via}] non-numeric level {value!r} for "
                f"{self.crosspoint_key(inp, out)}, ignored")
            return False, value
        db = float(value)  # finite: apply_set remaps NaN/inf first
        if self.hw is not None:
            applied = self.hw.set_db(out, inp, db)
        else:
            applied = min(db, SIM_MAX_DB)
        return True, applied

    def seed_and_push(self, state):
        """Fill in missing crosspoints with the reset routing, then (hw) push
        the whole bank in one commit."""
        levels = {}
        seeded = {}
        for inp in range(self.n_in):
            for out in range(self.n_out):
                key = self.crosspoint_key(inp, out)
                db = state.get(key, default=None)
                if isinstance(db, (int, float)) and not isinstance(db, bool):
                    db = float(db)
                else:
                    db = 0.0 if inp == out else OFF_DB
                    seeded[key] = db
                levels[(out, inp)] = db
        if seeded:
            for tail, why in state.set_many(seeded).items():
                log(f"    could not seed {tail}: {why}")
        if self.hw is not None:
            self.hw.set_bank_db(levels)
            log(f"Pushed {len(levels)} {self.zone} level(s) to the PL "
                f"({self.hw.status()})")


BACKENDS = {}  # zone -> Backend, filled in main()


def build_backends(use_hw, matrix_size):
    """The zone -> backend table. With use_hw each backend opens its register
    window (mixer_hw.WINDOWS, checked by ID); without, the same backends run
    in simulation with the given sizes."""
    if use_hw:
        import mixer_hw  # next to this script; needs /dev/mem
        m = mixer_hw.open_window("matrix")
        log(f"PL window 'matrix' at 0x{m.base:08x}: {m.describe()}")
        backends = [MatrixBackend(MATRIX_ZONE, m, m.n_in, m.n_out)]
    else:
        backends = [MatrixBackend(MATRIX_ZONE, None, matrix_size, matrix_size)]
    return {b.zone: b for b in backends}


def apply_set(tail, value, state, registry, via):
    """The one path every set takes (TCP and UDP): check the value fits the
    state tree, hand it to its zone's backend (if the zone has one), store,
    then broadcast the confirmation."""
    why = state.check(tail)
    if why is not None:
        log(f"    [{via}] set {tail!r} ignored: {why}")
        return
    remapped = finite_value(value)
    if remapped is not value:
        log(f"    [{via}] {tail}: non-finite {value!r} remapped to {remapped}")
        value = remapped
    path = split_path(tail)
    backend = BACKENDS.get(path[0])
    if backend is not None:
        accepted, value = backend.apply(path[1:], value, via)
        if not accepted:
            return
    state.set(tail, value)
    if VERBOSE:
        log(f"    [{via}] SET {tail} = {value!r}")
    registry.broadcast(encode_message(f"/{state.mixer_name}/set/{tail}", [value]))


def handle_devicename_change(new_name, state, registry, reply, via):
    """A rename. Accepted: broadcast under the old name, then the new name
    applies (the alias keeps working). Refused (D33 rules): the sender alone
    gets the name that stands, then an error reply (D38); nobody else hears
    anything."""
    old_name = state.mixer_name
    why = name_problem(new_name)
    if why is not None:
        if reply is not None:
            reply(encode_message(f"/{old_name}/set/{DEVICE_NAME_KEY}", [old_name]))
        send_error(reply, state, DEVICE_NAME_KEY, why, via)
        return
    registry.broadcast(encode_message(f"/{old_name}/set/{DEVICE_NAME_KEY}", [new_name]))
    state.rename(new_name)
    log(f"    *** [{via}] device name changed: {old_name!r} -> {new_name!r}. "
          f"Address root is now /{new_name}/ (and /{ALIAS}/); /{old_name}/ is ignored. ***")


def handle_set(tail, args, state, registry, reply, via):
    """Every set, TCP and UDP. reply sends to the requester (TCP), or is None
    (UDP, which never replies)."""
    if not args:
        log(f"    [{via}] set with no value for {tail!r}, ignoring")
        return
    if len(args) > 1:
        log(f"    [{via}] set for {tail!r} carried {len(args)} args, using the first")
    value = args[0]

    if is_device_name(tail):
        handle_devicename_change(value, state, registry, reply, via)
        return

    apply_set(tail, value, state, registry, via)


def handle_get(tail, state, registry, reply_sock, via):
    value = state.get(tail, default=0.0)
    if VERBOSE:
        log(f"    [{via}] GET {tail} -> {value!r}")
    registry.send(reply_sock, encode_message(f"/{state.mixer_name}/set/{tail}", [value]))


def handle_tcp_message(msg, state, registry, reply_sock, via):
    kind, tail = split_after_mixer_name(msg.address, state.mixer_name)
    if kind is None:
        log(f"    [{via}] ignoring message under unknown root: {msg.address!r} "
              f"(currently listening as {state.mixer_name!r})")
        return
    if kind == "set":
        handle_set(tail, msg.args, state, registry,
                   lambda packet: registry.send(reply_sock, packet), via)
    elif kind == "get":
        handle_get(tail, state, registry, reply_sock, via)
    else:
        log(f"    [{via}] ignoring unknown command kind {kind!r} in {msg.address!r}")


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
    conn.settimeout(120.0)  # only to reap a truly dead/idle connection eventually
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

def main():
    global VERBOSE
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
                   help="simulated matrix size N (NxN) without --hw (default: 20, the "
                        "Phase 9 hardware: 4 Pmod + 8 link #1 (USB) + 8 link #2 (AVB) "
                        "channels)")
    p.add_argument("--tcp-framing", choices=FRAMINGS, default=DEFAULT_FRAMING,
                   help="TCP stream framing: len32 = OSC 1.0 4-byte size prefix per packet "
                        "(default); none = unframed messages back to back (older controllers)")
    args = p.parse_args()
    VERBOSE = args.verbose

    state = MixerState(args.mixer_name, args.state_file or None, log=log)
    BACKENDS.update(build_backends(args.hw, args.matrix_size))
    for backend in BACKENDS.values():
        backend.seed_and_push(state)
    registry = ClientRegistry(args.tcp_framing)
    log(f"TCP framing: {args.tcp_framing}")

    threading.Thread(target=udp_serve, args=(args.host, args.udp_port, state, registry), daemon=True).start()

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
