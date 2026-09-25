#!/usr/bin/env python3
"""
Reference / simulator server for the FPGA mixer's OSC control protocol.

The goal: from a controller's perspective (your Swift app, or the
osc_mixer_test.py suite), this should look and behave exactly like the real
mixer will — same TCP set/get/echo semantics, same UDP write-only path, same
multi-controller broadcast sync, and the same save-on-change/restore-on-boot
persistence described in your other project docs. Point your control
software at this instead of hardware and develop against it.

The OSC codec (osc_string / encode_message / decode_message /
OSCIncomplete / OSCMalformed) is copied verbatim from osc_mixer_test.py so
both tools speak identically. If you extract a shared module later, this is
the block to move.

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
  - deviceName: the doc's own caveat ("this may cause sync issues if
    controllers don't know to start listening to the new address space")
    implies the address root genuinely changes. So it does: the
    confirmation of a deviceName set goes out under the OLD root (that's
    the address the request arrived on), and every message after that must
    use the NEW root — messages still addressed to the old root are logged
    and ignored, exactly the footgun the doc describes.
  - TCP framing: naive and self-delimiting, same assumption as the test
    client — no length prefix, no reassembly timeout. That means a message
    left truncated mid-argument (as osc_mixer_test.py's
    truncated_argument_then_recovery test deliberately does) will corrupt
    the parse of whatever arrives after it. This is deliberately NOT
    papered over with a timeout-based buffer reset: it's a real risk of the
    "no explicit framing" design, and this simulator is meant to let you
    feel it rather than hide it. A genuinely malformed message (bad type
    tag, bad address) DOES clear the buffer and recover, since more bytes
    can never fix those.
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
import os
import signal
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# OSC wire format (identical to osc_mixer_test.py)
# ---------------------------------------------------------------------------

class OSCIncomplete(Exception):
    """Buffer doesn't yet hold a complete field. Caller should read more bytes."""


class OSCMalformed(Exception):
    """Buffer holds bytes that are not valid OSC. More bytes won't fix it."""


def osc_string(s: str) -> bytes:
    b = s.encode("ascii") + b"\x00"
    pad = (-len(b)) % 4
    return b + b"\x00" * pad


def read_osc_string(data: bytes, offset: int):
    if offset > len(data):
        raise OSCIncomplete()
    idx = data.find(b"\x00", offset)
    if idx == -1:
        if len(data) - offset > 1024:
            raise OSCMalformed(f"no NUL terminator within 1024 bytes of offset {offset}")
        raise OSCIncomplete()
    length = idx - offset + 1
    total = ((length + 3) // 4) * 4
    if offset + total > len(data):
        raise OSCIncomplete()
    s = data[offset:idx].decode("ascii", errors="replace")
    return s, offset + total


@dataclass
class OSCMessage:
    address: str
    args: list = field(default_factory=list)

    def __repr__(self):
        return f"OSCMessage({self.address!r}, {self.args!r})"


def encode_message(address: str, args=()) -> bytes:
    type_tags = ","
    arg_bytes = b""
    for a in args:
        if isinstance(a, bool):
            type_tags += "i"
            arg_bytes += struct.pack(">i", int(a))
        elif isinstance(a, float):
            type_tags += "f"
            arg_bytes += struct.pack(">f", a)
        elif isinstance(a, int):
            type_tags += "i"
            arg_bytes += struct.pack(">i", a)
        elif isinstance(a, str):
            type_tags += "s"
            arg_bytes += osc_string(a)
        else:
            raise TypeError(f"unsupported OSC arg type: {type(a)!r}")
    return osc_string(address) + osc_string(type_tags) + arg_bytes


def decode_message(data: bytes, offset: int = 0):
    start = offset
    address, offset = read_osc_string(data, offset)
    if not address.startswith("/"):
        raise OSCMalformed(f"address does not start with '/': {address!r}")
    type_tag_str, offset = read_osc_string(data, offset)
    if not type_tag_str.startswith(","):
        raise OSCMalformed(f"type-tag string does not start with ',': {type_tag_str!r}")
    args = []
    for tag in type_tag_str[1:]:
        if tag in ("f", "i"):
            if offset + 4 > len(data):
                raise OSCIncomplete()
            (val,) = struct.unpack_from(">f" if tag == "f" else ">i", data, offset)
            args.append(val)
            offset += 4
        elif tag == "s":
            s, offset = read_osc_string(data, offset)
            args.append(s)
        else:
            raise OSCMalformed(f"unsupported type tag {tag!r} in {type_tag_str!r}")
    return OSCMessage(address, args), offset - start


# ---------------------------------------------------------------------------
# Logging + the parameter store (mixer_state.py)
# ---------------------------------------------------------------------------

from mixer_state import MixerState, split_path, is_device_name, finite_value  # noqa: E402

DEVICE_NAME_KEY = "system/deviceName/"  # mirrors the doc's own literal example format

VERBOSE = False

_log_lock = threading.Lock()


def log(msg):
    """print() calls from different threads can interleave mid-line; this
    serializes them so the server's log stays readable."""
    with _log_lock:
        print(msg, flush=True)


class ClientRegistry:
    """Connected TCP controller sockets, for broadcasting set/echo/sync messages."""

    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()

    def add(self, sock):
        with self.lock:
            self.clients.add(sock)

    def remove(self, sock):
        with self.lock:
            self.clients.discard(sock)

    def broadcast(self, data: bytes):
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

def split_after_mixer_name(address, mixer_name):
    """('set'|'get', 'zone/index/module...') or (None, None) if the address
    isn't under the currently-active root."""
    prefix = f"/{mixer_name}/"
    if not address.startswith(prefix):
        return None, None
    rest = address[len(prefix):]
    kind, _, tail = rest.partition("/")
    return kind, tail


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


def handle_devicename_change(new_name, state, registry, via):
    old_name = state.mixer_name
    confirm_addr = f"/{old_name}/set/{DEVICE_NAME_KEY}"
    registry.broadcast(encode_message(confirm_addr, [new_name]))
    state.rename(new_name)
    log(f"    *** [{via}] device name changed: {old_name!r} -> {new_name!r}. "
          f"Address root is now /{new_name}/ — messages under /{old_name}/ will be ignored. ***")


def handle_set(tail, args, state, registry, via):
    if not args:
        log(f"    [{via}] set with no value for {tail!r}, ignoring")
        return
    if len(args) > 1:
        log(f"    [{via}] set for {tail!r} carried {len(args)} args, using the first")
    value = args[0]

    if is_device_name(tail):
        if isinstance(value, str):
            handle_devicename_change(value, state, registry, via)
        else:
            log(f"    [{via}] deviceName must be a string, got {value!r}; ignored")
        return

    apply_set(tail, value, state, registry, via)


def handle_get(tail, state, reply_sock, via):
    value = state.get(tail, default=0.0)
    if VERBOSE:
        log(f"    [{via}] GET {tail} -> {value!r}")
    reply_sock.sendall(encode_message(f"/{state.mixer_name}/set/{tail}", [value]))


def handle_tcp_message(msg, state, registry, reply_sock, via):
    kind, tail = split_after_mixer_name(msg.address, state.mixer_name)
    if kind is None:
        log(f"    [{via}] ignoring message under unknown root: {msg.address!r} "
              f"(currently listening as {state.mixer_name!r})")
        return
    if kind == "set":
        handle_set(tail, msg.args, state, registry, via)
    elif kind == "get":
        handle_get(tail, state, reply_sock, via)
    else:
        log(f"    [{via}] ignoring unknown command kind {kind!r} in {msg.address!r}")


# ---------------------------------------------------------------------------
# TCP server
# ---------------------------------------------------------------------------

def handle_tcp_client(conn, addr, state, registry):
    via = f"TCP {addr[0]}:{addr[1]}"
    log(f"[+] {via} connected")   # already in the registry (tcp_accept_loop)
    buffer = b""
    conn.settimeout(120.0)  # only to reap a truly dead/idle connection eventually
    try:
        while True:
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break  # client closed
            buffer += chunk
            while True:
                try:
                    msg, consumed = decode_message(buffer)
                except OSCIncomplete:
                    break  # wait for more bytes
                except OSCMalformed as e:
                    log(f"    [{via}] malformed OSC ({e}); dropping {len(buffer)} buffered byte(s)")
                    buffer = b""
                    break
                buffer = buffer[consumed:]
                handle_tcp_message(msg, state, registry, conn, via)
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
            data, addr = sock.recvfrom(4096)
        except OSError:
            break
        via = f"UDP {addr[0]}:{addr[1]}"
        try:
            msg, consumed = decode_message(data)
        except (OSCIncomplete, OSCMalformed) as e:
            log(f"    [{via}] malformed datagram, ignoring: {e}")
            continue
        if consumed < len(data):
            log(f"    [{via}] {len(data) - consumed} trailing byte(s) after the first "
                  f"message in this datagram — ignored (no bundle/multi-message support)")

        kind, tail = split_after_mixer_name(msg.address, state.mixer_name)
        if kind is None:
            log(f"    [{via}] ignoring message under unknown root: {msg.address!r}")
            continue
        if kind != "set":
            log(f"    [{via}] ignoring non-set command over UDP (write-only): {msg.address!r}")
            continue
        if not msg.args:
            continue
        value = msg.args[0]

        if is_device_name(tail):
            if isinstance(value, str):
                handle_devicename_change(value, state, registry, via)
            else:
                log(f"    [{via}] deviceName must be a string, got {value!r}; ignored")
            continue

        apply_set(tail, value, state, registry, via)


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
    p.add_argument("--matrix-size", type=int, default=4,
                   help="simulated matrix size N (NxN) without --hw (default: 4)")
    args = p.parse_args()
    VERBOSE = args.verbose

    state = MixerState(args.mixer_name, args.state_file or None, log=log)
    BACKENDS.update(build_backends(args.hw, args.matrix_size))
    for backend in BACKENDS.values():
        backend.seed_and_push(state)
    registry = ClientRegistry()

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
