#!/usr/bin/env python3
"""
The mixer's persistent parameter store (Phase 6).

Holds every parameter as a tree shaped like the OSC address space and keeps
it on disk so it survives a power cycle. It knows nothing about OSC, sockets
or hardware: the server (osc_mixer_server.py) calls it, and the format is a
contract any future server keeps (docs/architecture_modules.md 4.2).

TREE / FILE FORMAT: the address tail '<zone>/<index>/<module>' becomes nested
JSON objects, and the value is the leaf:

    /FOHmixer/set/inputChannel/0/level -6.0      ->  {"inputChannel": {"0": {"level": -6.0}}}
    /FOHmixer/set/inputMatrix/5_8/delay 2.39     ->  {"inputMatrix": {"5_8": {"delay": 2.39}}}
    /mixer/set/system/deviceName/ "FOHmixer"     ->  {"system": {"deviceName": "FOHmixer"}}

  - Nothing wraps the tree: the top-level keys ARE the zones.
  - The mixer name (the address root) is stored only at system.deviceName.
  - Trailing empty segments are dropped, so 'system/deviceName/' and
    'system/deviceName' are the same node. Other empty segments are invalid.
  - A value can't sit where the tree has a branch, or a branch where it has a
    value; such a set is refused (check() says why).
  - Every value in the file is finite, so it's strict JSON. Callers pass
    values through finite_value() first (NaN, -inf -> -99.9; +inf -> +99.9),
    and a file with NaN/Infinity is remapped on load.
  - Files in the earlier flat format ({"mixer_name": ..., "values": {...}})
    are converted on load; the original is kept as <file>.flat.bak.

DURABILITY (what survives what):

  Files, next to each other:
    <file>                  the current state
    <file>.bak              the previous good state (one save older)
    <file>.tmp              a save in flight (only ever transient)
    <file>.corrupt-<time>   a file that failed to parse, kept for inspection

  Saving is BATCHED: a change marks the store dirty and a background thread
  writes it SAVE_DELAY seconds later, so a fader sweep of hundreds of sets
  becomes a few writes instead of hundreds. Nothing on the network path waits
  for the SD card. The cost: a power cut loses at most the changes of the
  last SAVE_DELAY (plus the write itself). close() -- called on SIGTERM, i.e.
  a normal shutdown or `systemctl stop` -- writes anything pending first.

  Each save: write <file>.tmp, flush + fsync it, rename <file> -> <file>.bak,
  rename <file>.tmp -> <file>, fsync the directory. Renames are atomic on
  ext4, so at every instant at least one of <file> / <file>.bak is a
  complete, fsync'd state:
    - crash while writing .tmp          -> <file> is intact
    - crash between the two renames     -> <file> is missing, .bak is intact
    - crash after                       -> <file> is the new state

  Loading tries <file>, then <file>.bak. A file that exists but doesn't parse
  (SD corruption, a bad hand edit) is renamed to .corrupt-<time>, never
  overwritten. If the state came from .bak, <file> is rewritten at once.
  Only if neither is usable does the store start empty (then the backends
  seed their defaults).

  A failed save (disk full, read-only filesystem) is logged and retried on
  the next change; the in-memory state stays authoritative meanwhile.
"""

import json
import math
import os
import threading
import time

DEVICE_NAME_PATH = ("system", "deviceName")

NONFINITE_LOW = -99.9    # NaN and -inf become this ("off" for any dB level)
NONFINITE_HIGH = 99.9    # +inf becomes this

SAVE_DELAY = 0.25        # seconds from the first unsaved change to the write


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


def finite_value(value):
    """Remap non-finite floats to finite stand-ins; everything else passes
    through unchanged."""
    if isinstance(value, float) and not math.isfinite(value):
        return NONFINITE_HIGH if value > 0 else NONFINITE_LOW
    return value


def _finite_tree(node):
    if isinstance(node, dict):
        return {k: _finite_tree(v) for k, v in node.items()}
    return finite_value(node)


def _count(node):
    if not isinstance(node, dict):
        return 1
    return sum(_count(v) for v in node.values())


class MixerState:
    """The parameter tree plus its file. Thread-safe; see the module
    docstring for the format and the durability rules.

    persist_path None = memory only (no file, no saver thread)."""

    def __init__(self, default_name, persist_path, log=print, save_delay=SAVE_DELAY):
        self.lock = threading.RLock()
        self.persist_path = persist_path
        self.tree = {}
        self._log = log
        self._save_delay = save_delay
        self._save_lock = threading.Lock()   # one writer at a time
        self._cv = threading.Condition(self.lock)
        self._dirty = False
        self._stop = False
        self.saves = 0                        # completed writes (for tests / diagnostics)

        if persist_path:
            d = os.path.dirname(os.path.abspath(persist_path))
            os.makedirs(d, exist_ok=True)
            self._load()
        if not isinstance(self._lookup(DEVICE_NAME_PATH), str):
            self._put(DEVICE_NAME_PATH, default_name)
            self._dirty = True
        if persist_path:
            self.flush()  # anything the load step changed (bak restore, conversion, name)
            self._saver = threading.Thread(target=self._saver_loop, name="state-saver",
                                           daemon=True)
            self._saver.start()

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

    def _mark_dirty(self):
        # caller holds self.lock (== the condition's lock)
        self._dirty = True
        self._cv.notify()

    # ----- loading -----
    def _read(self, path):
        """The parsed tree from path, None if the file doesn't exist. A file
        that exists but can't be used is moved aside and None returned."""
        if not os.path.exists(path):
            return None
        try:
            with open(path) as f:
                data = json.load(f)
            if not isinstance(data, dict):
                raise ValueError("top level is not a JSON object")
            return data
        except (OSError, ValueError) as e:   # JSONDecodeError is a ValueError
            aside = f"{path}.corrupt-{time.strftime('%Y%m%dT%H%M%S')}"
            try:
                os.replace(path, aside)
                self._log(f"State file {path} unusable ({e}); moved to {aside}")
            except OSError as e2:
                self._log(f"State file {path} unusable ({e}); could not move it aside ({e2})")
            return None

    def _load(self):
        main, bak = self.persist_path, f"{self.persist_path}.bak"
        data, source = self._read(main), main
        if data is None:
            data, source = self._read(bak), bak
            if data is not None:
                self._log(f"Using the backup {bak}; {main} will be rewritten from it")
                self._dirty = True
        if data is None:
            self._log(f"No usable state file at {main}; starting empty")
            return

        if isinstance(data.get("values"), dict) and "mixer_name" in data:
            self._convert_flat(data, source)
        else:
            self.tree = _finite_tree(data)
        self._log(f"Restored {_count(self.tree)} value(s), mixer name "
                  f"{self._lookup(DEVICE_NAME_PATH)!r}, from {source}")

    def _convert_flat(self, data, source):
        """Earlier format: {"mixer_name": ..., "values": {"zone/index/module": v}}."""
        backup = f"{self.persist_path}.flat.bak"
        if source == self.persist_path:
            os.replace(self.persist_path, backup)
        for key, value in sorted(data["values"].items()):
            path = split_path(key)
            why = "not a valid path" if path is None else self._conflict(path)
            if why:
                self._log(f"    converting {backup}: dropped {key!r} = {value!r} ({why})")
                continue
            self._put(path, finite_value(value))
        name = data.get("mixer_name")
        if isinstance(name, str):
            self._put(DEVICE_NAME_PATH, name)
        self._dirty = True
        self._log(f"Converted flat state file to the OSC-tree format; original kept as {backup}")

    # ----- saving -----
    def _write(self, text):
        main = self.persist_path
        tmp, bak = f"{main}.tmp", f"{main}.bak"
        with open(tmp, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(main):
            os.replace(main, bak)
        os.replace(tmp, main)
        if hasattr(os, "O_DIRECTORY"):  # POSIX: make the renames themselves durable
            fd = os.open(os.path.dirname(os.path.abspath(main)), os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)

    def flush(self):
        """Write now if anything is unsaved. Returns True if the file is up
        to date afterwards."""
        if not self.persist_path:
            return True
        with self._save_lock:
            with self.lock:
                if not self._dirty:
                    return True
                try:
                    # allow_nan=False: values are remapped on the way in, so a
                    # non-finite float here is a bug -- fail loudly, never write NaN.
                    text = json.dumps(self.tree, indent=2, sort_keys=True, allow_nan=False)
                except ValueError as e:
                    self._log(f"State NOT saved: {e}")
                    return False
                self._dirty = False
            try:
                self._write(text)
                self.saves += 1
                return True
            except OSError as e:
                self._log(f"State NOT saved to {self.persist_path} ({e}); will retry on the next change")
                with self.lock:
                    self._dirty = True
                return False

    def _saver_loop(self):
        while True:
            with self._cv:
                while not self._dirty and not self._stop:
                    self._cv.wait()
                if self._stop:
                    return
            time.sleep(self._save_delay)   # let the rest of a burst arrive
            self.flush()

    def close(self):
        """Stop the saver and write anything pending (call on shutdown)."""
        if not self.persist_path:
            return True
        with self._cv:
            self._stop = True
            self._cv.notify()
        self._saver.join(timeout=5)
        return self.flush()

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
                self._mark_dirty()
            return why

    def set_many(self, updates):
        """Store several values. Returns {tail: reason} for any rejected."""
        rejected = {}
        with self.lock:
            for tail, value in updates.items():
                why = self.check(tail)
                if why is None:
                    self._put(split_path(tail), value)
                else:
                    rejected[tail] = why
            self._mark_dirty()
        return rejected

    def rename(self, new_name):
        with self.lock:
            self._put(DEVICE_NAME_PATH, new_name)
            self._mark_dirty()
