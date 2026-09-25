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

Usage:
    python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --mixer-name mixer
    # on the board (root), driving the PL matrix; mixer_hw.py must sit
    # next to this script:
    python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --hw

State persists to mixer_state.json (in the working directory by default)
and is reloaded on the next launch, simulating power-cycle restore. Pass
--state-file '' to disable persistence.

STATE FILE FORMAT: the file mirrors the OSC address tree. The address tail
'<zone>/<index>/<module>' becomes nested JSON objects, and the value is the
leaf:

    /FOHmixer/set/inputChannel/0/level -6.0      ->  {"inputChannel": {"0": {"level": -6.0}}}
    /FOHmixer/set/inputMatrix/5_8/delay 2.39     ->  {"inputMatrix": {"5_8": {"delay": 2.39}}}
    /mixer/set/system/deviceName/ "FOHmixer"     ->  {"system": {"deviceName": "FOHmixer"}}

  - Nothing wraps the tree: the top-level keys ARE the zones.
  - The mixer name (the address root) is stored only at system.deviceName.
    --mixer-name is just the default for a file that doesn't have one.
  - Trailing empty segments are dropped, so the standard's literal
    'system/deviceName/' and 'system/deviceName' are the same node.
  - A path that would put a value where the tree already has a branch, or a
    branch where it has a value (say 'inputChannel/0' = 1 when
    'inputChannel/0/level' exists), can't be stored in a tree. Such a set is
    ignored: not stored, not echoed, logged. Empty segments inside a path
    ('a//b') are ignored the same way.
  - A get on a missing path, or on a branch, replies with the default 0.0.
  - Files in the earlier flat format ({"mixer_name": ..., "values": {...}})
    are converted on load; the original is kept as <file>.flat.bak.
"""

import argparse
import json
import math
import os
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
# State + persistence
# ---------------------------------------------------------------------------

DEVICE_NAME_KEY = "system/deviceName/"  # mirrors the doc's own literal example format
DEVICE_NAME_PATH = ("system", "deviceName")

VERBOSE = False

_log_lock = threading.Lock()


def log(msg):
    """print() calls from different threads can interleave mid-line; this
    serializes them so the server's log stays readable."""
    with _log_lock:
        print(msg, flush=True)


def split_path(tail):
    """'zone/index/module' -> ('zone', 'index', 'module'), or None if the
    tail can't name a tree node. Trailing empty segments are dropped (the
    standard writes 'system/deviceName/'); any other empty segment is invalid."""
    parts = tail.split("/")
    while parts and parts[-1] == "":
        parts.pop()
    if not parts or any(p == "" for p in parts):
        return None
    return tuple(parts)


def is_device_name(tail):
    return split_path(tail) == DEVICE_NAME_PATH


class MixerState:
    """Value store shaped like the OSC address tree (see STATE FILE FORMAT in
    the module docstring). Any 'zone/index/module' path is valid -- nothing is
    pre-declared, matching a standard that doesn't enumerate a fixed parameter
    list -- as long as it fits the tree."""

    def __init__(self, default_name, persist_path):
        self.lock = threading.RLock()
        self.persist_path = persist_path
        self.tree = {}
        self._load()
        if not isinstance(self._lookup(DEVICE_NAME_PATH), str):
            self._put(DEVICE_NAME_PATH, default_name)
            self._save()

    # ----- tree primitives (caller holds the lock) -----
    def _lookup(self, path):
        node = self.tree
        for seg in path:
            if not isinstance(node, dict) or seg not in node:
                return None
            node = node[seg]
        return node

    def _conflict(self, path):
        """Why a value can't be stored at path, or None if it can."""
        node = self.tree
        for i, seg in enumerate(path[:-1]):
            nxt = node.get(seg)
            if nxt is None:
                return None  # the rest of the branch gets created
            if not isinstance(nxt, dict):
                return f"'{'/'.join(path[:i + 1])}' already holds a value"
            node = nxt
        if isinstance(node.get(path[-1]), dict):
            return f"'{'/'.join(path)}' is a branch with values under it"
        return None

    def _put(self, path, value):
        node = self.tree
        for seg in path[:-1]:
            node = node.setdefault(seg, {})
        node[path[-1]] = value

    # ----- persistence -----
    def _load(self):
        if not (self.persist_path and os.path.exists(self.persist_path)):
            return
        try:
            with open(self.persist_path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            log(f"Could not load {self.persist_path} ({e}); starting fresh")
            return
        if not isinstance(data, dict):
            log(f"{self.persist_path} is not a JSON object; starting fresh")
            return

        if isinstance(data.get("values"), dict) and "mixer_name" in data:
            self._convert_flat(data)
        else:
            self.tree = data
        log(f"Restored {self._count(self.tree)} value(s), mixer name "
            f"{self.mixer_name!r}, from {self.persist_path}")

    def _convert_flat(self, data):
        """Earlier format: {"mixer_name": ..., "values": {"zone/index/module": v}}."""
        backup = f"{self.persist_path}.flat.bak"
        os.replace(self.persist_path, backup)
        for key, value in sorted(data["values"].items()):
            path = split_path(key)
            why = "not a valid path" if path is None else self._conflict(path)
            if why:
                log(f"    converting {backup}: dropped {key!r} = {value!r} ({why})")
                continue
            self._put(path, value)
        name = data.get("mixer_name")
        if isinstance(name, str):
            self._put(DEVICE_NAME_PATH, name)
        self._save()
        log(f"Converted flat state file to the OSC-tree format; original kept as {backup}")

    def _save(self):
        if not self.persist_path:
            return
        tmp = f"{self.persist_path}.tmp"
        with open(tmp, "w") as f:
            json.dump(self.tree, f, indent=2, sort_keys=True)
        os.replace(tmp, self.persist_path)  # atomic-ish, avoids a half-written file on a crash

    @staticmethod
    def _count(node):
        if not isinstance(node, dict):
            return 1
        return sum(MixerState._count(v) for v in node.values())

    # ----- public API (address tails, as they appear after /<name>/<kind>/) -----
    @property
    def mixer_name(self):
        with self.lock:
            return self._lookup(DEVICE_NAME_PATH)

    def check(self, tail):
        """None if a value can be stored at tail, else the reason it can't."""
        path = split_path(tail)
        if path is None:
            return "not a valid path (empty segment)"
        with self.lock:
            return self._conflict(path)

    def get(self, tail, default=0.0):
        path = split_path(tail)
        if path is None:
            return default
        with self.lock:
            value = self._lookup(path)
        return default if value is None or isinstance(value, dict) else value

    def set(self, tail, value):
        """Store one value. Returns None on success, else the reason it wasn't stored."""
        with self.lock:
            why = self.check(tail)
            if why is None:
                self._put(split_path(tail), value)
                self._save()
            return why

    def set_many(self, updates):
        """Store several values with one save. Returns {tail: reason} for any rejected."""
        rejected = {}
        with self.lock:
            for tail, value in updates.items():
                why = self.check(tail)
                if why is None:
                    self._put(split_path(tail), value)
                else:
                    rejected[tail] = why
            self._save()
        return rejected

    def rename(self, new_name):
        with self.lock:
            self._put(DEVICE_NAME_PATH, new_name)
            self._save()


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


class Matrix:
    """Applies inputMatrix/<in>_<out>/level to the PL matrix (hw given) or
    just validates and clamps it the same way (hw None, simulator)."""

    def __init__(self, hw, n_in, n_out):
        self.hw = hw
        self.n_in = n_in
        self.n_out = n_out

    @staticmethod
    def crosspoint_key(inp, out):
        return f"{MATRIX_ZONE}/{inp}_{out}/level"

    @staticmethod
    def parse(tail):
        """(in, out) if tail is a crosspoint level address, else None."""
        parts = tail.split("/")
        if len(parts) != 3 or parts[0] != MATRIX_ZONE or parts[2] != "level":
            return None
        a, sep, b = parts[1].partition("_")
        if not (sep and a.isdigit() and b.isdigit()):
            return None
        return int(a), int(b)

    def apply(self, tail, value, via):
        """Returns (accepted, value_to_store_and_echo)."""
        xp = self.parse(tail)
        if xp is None:
            return True, value  # not a crosspoint: generic store/echo
        inp, out = xp
        if not (0 <= inp < self.n_in and 0 <= out < self.n_out):
            log(f"    [{via}] crosspoint {inp}_{out} outside the "
                f"{self.n_in}x{self.n_out} matrix, ignored")
            return False, value
        if isinstance(value, (str, bool)):
            log(f"    [{via}] non-numeric level {value!r} for {tail}, ignored")
            return False, value
        db = float(value)
        if math.isnan(db):
            log(f"    [{via}] NaN level for {tail}, ignored")
            return False, value
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
            log(f"Pushed {len(levels)} crosspoint level(s) to the PL matrix "
                f"({self.hw.status()})")


MATRIX = None  # set in main()


def apply_set(tail, value, state, registry, via):
    """The one path every set takes (TCP and UDP): check the value fits the
    state tree, apply it to the matrix if it is a crosspoint, store, then
    broadcast the confirmation."""
    why = state.check(tail)
    if why is not None:
        log(f"    [{via}] set {tail!r} ignored: {why}")
        return
    accepted, value = MATRIX.apply(tail, value, via)
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
    log(f"[+] {via} connected")
    registry.add(conn)
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
                   help="drive the PL matrix through /dev/mem (on the board, as root; "
                        "Phase 5+ bitstream only)")
    p.add_argument("--hw-base", type=lambda x: int(x, 0), default=0x8000_0000,
                   help="physical address of the matrix registers (default: 0x80000000)")
    p.add_argument("--matrix-size", type=int, default=4,
                   help="simulated matrix size N (NxN) without --hw (default: 4)")
    args = p.parse_args()
    VERBOSE = args.verbose

    global MATRIX
    state = MixerState(args.mixer_name, args.state_file or None)
    if args.hw:
        from mixer_hw import MatrixHW  # next to this script; needs /dev/mem
        hw = MatrixHW(base=args.hw_base)
        log(f"PL matrix at 0x{args.hw_base:08x}: {hw.n_in} in x {hw.n_out} out, "
            f"Q{hw.gain_width - hw.gain_frac}.{hw.gain_frac}")
        MATRIX = Matrix(hw, hw.n_in, hw.n_out)
    else:
        MATRIX = Matrix(None, args.matrix_size, args.matrix_size)
    MATRIX.seed_and_push(state)
    registry = ClientRegistry()

    threading.Thread(target=udp_serve, args=(args.host, args.udp_port, state, registry), daemon=True).start()

    try:
        tcp_accept_loop(args.host, args.tcp_port, state, registry)
    except KeyboardInterrupt:
        print("\nShutting down.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
