#!/usr/bin/env python3
"""
Snapshots (Phase 14; standard "Snapshots"; docs/phase14_status_2026-10-08.md):
the snapshot JSON format and the store of named snapshots on the board.

It knows nothing about OSC, sockets, hardware or the parameter model: the
server (osc_mixer_server.py) builds a snapshot from its live values, checks a
snapshot's entries against its model, and recalls it. This module owns the
format's envelope, the name rules, the limits and the files.

FORMAT (the same on the board and in a controller's file):

    {"snapshotVersion": 1, "name": "Song A", "savedAt": "2026-10-08T17:02:11Z",
     "source": {"deviceName": ..., "firmware": ...}, "zones": {...},
     "values": {"inputChannel/0/level": -6.0, ...}}

  - snapshotVersion (required): a breaking-change number; newer is refused.
  - values (required): the config's `values` keys (a set's address tail);
    complete when the mixer wrote it; each value a number or a string.
  - name, savedAt, source, zones: informational. "auto": true marks the
    snapshot the mixer makes before a recall (AUTO_NAME).
  - Unknown keys are ignored.

STORE: one file per snapshot in the snapshot directory
(/var/lib/fpgamixer/snapshots on the board), named after a percent-encoding
of the snapshot's name (the name inside the file is the truth). Written as
the state file is (mixer_state.py): <file>.tmp, flush + fsync, rename over
the file, fsync the directory; a crash leaves the old file or the new one,
never a partial one. A leftover .tmp is ignored and removed on open; a file
that doesn't parse is skipped (logged), never deleted. With directory None
the store lives in memory (the simulator without a state file, tests).
"""

import json
import os
import threading
import time

SNAPSHOT_VERSION = 1
NAME_MAX_BYTES = 63
MAX_SNAPSHOTS = 128
MAX_BYTES = 1 << 20          # one snapshot's JSON, encoded
AUTO_NAME = "Before load"    # the live state, saved just before every recall
SUFFIX = ".json"


class SnapshotRefused(Exception):
    """A request the store refuses; str() is the reason for the error reply."""


def name_problem(name):
    """Why `name` can't name a snapshot (standard "Snapshots"), or None."""
    if not isinstance(name, str):
        return "the snapshot name must be a string"
    if not name:
        return "the snapshot name can't be empty"
    if len(name.encode("utf-8")) > NAME_MAX_BYTES:
        return f"the snapshot name can be at most {NAME_MAX_BYTES} bytes"
    if any(c in "/\\" or ord(c) < 0x20 or ord(c) == 0x7F for c in name):
        return "the snapshot name can't contain '/', '\\' or control characters"
    if name.startswith("."):
        return "the snapshot name can't start with '.'"
    if name != name.strip(" "):
        return "the snapshot name can't start or end with a space"
    return None


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def make_snapshot(name, values, zones, device_name, firmware, saved_at=None, auto=False):
    """The snapshot object for `values` ({path: value}, every parameter but
    system/*), as the mixer writes it."""
    doc = {
        "snapshotVersion": SNAPSHOT_VERSION,
        "name": name,
        "savedAt": saved_at or utc_now(),
        "source": {"deviceName": device_name, "firmware": firmware},
        "zones": zones,
        "values": values,
    }
    if auto:
        doc["auto"] = True
    return doc


def encode(doc):
    return json.dumps(doc, separators=(",", ":"), allow_nan=False)


def parse(text):
    """(doc, None) for a well-formed snapshot JSON string, else (None, reason).
    Checks the envelope only; whether each entry fits a mixer is the
    server's (its model)."""
    if not isinstance(text, str):
        return None, "the snapshot must be a JSON string"
    if len(text.encode("utf-8")) > MAX_BYTES:
        return None, f"the snapshot is larger than {MAX_BYTES} bytes"
    try:
        doc = json.loads(text)
    except ValueError as e:
        return None, f"not JSON ({e})"
    if not isinstance(doc, dict):
        return None, "the snapshot must be a JSON object"
    version = doc.get("snapshotVersion")
    if isinstance(version, bool) or not isinstance(version, int):
        return None, "snapshotVersion missing or not an integer"
    if not 1 <= version <= SNAPSHOT_VERSION:
        return None, f"snapshotVersion {version} is not supported (this mixer reads up to {SNAPSHOT_VERSION})"
    values = doc.get("values")
    if not isinstance(values, dict):
        return None, "values missing or not an object"
    for path, value in values.items():
        if isinstance(value, float) and value != value:     # NaN can't come from strict JSON, but json.loads accepts it
            return None, f"{path}: not a finite number"
        if not isinstance(value, (int, float, str)):
            return None, f"{path}: a value must be a number or a string"
    return doc, None


def _file_name(name):
    # Percent-encode everything but a readable safe set; the name rules keep
    # '/', a leading '.' and control characters out already. Names are
    # case-sensitive: right on the board's ext4; on a case-insensitive disk
    # (the simulator on Windows or macOS) "A" and "a" would share a file.
    # Done here rather than with urllib.parse, which isn't in the board's
    # python3-core.
    return "".join(chr(b) if chr(b) in _SAFE else f"%{b:02X}" for b in name.encode("utf-8")) + SUFFIX


_SAFE = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_.,()+=@&'!")


def _entry(doc):
    e = {"name": doc["name"], "savedAt": doc.get("savedAt") if isinstance(doc.get("savedAt"), str) else ""}
    if doc.get("auto") is True:
        e["auto"] = True
    return e


class SnapshotStore:
    """The named snapshots. Thread-safe. directory None: in memory only."""

    def __init__(self, directory, log=print, max_snapshots=MAX_SNAPSHOTS):
        self.directory = directory
        self.log = log
        self.max_snapshots = max_snapshots
        self.lock = threading.Lock()
        self._texts = {}           # name -> JSON text (memory store only)
        self._entries = {}         # name -> list entry
        if directory is not None:
            os.makedirs(directory, exist_ok=True)
            self._scan()

    def _path(self, name):
        return os.path.join(self.directory, _file_name(name))

    def _scan(self):
        for fn in sorted(os.listdir(self.directory)):
            full = os.path.join(self.directory, fn)
            if fn.endswith(SUFFIX + ".tmp"):
                self.log(f"snapshots: removing an unfinished write {fn}")
                try:
                    os.remove(full)
                except OSError:
                    pass
                continue
            if not fn.endswith(SUFFIX):
                continue
            try:
                with open(full, encoding="utf-8") as f:
                    text = f.read()
            except OSError as e:
                self.log(f"snapshots: can't read {fn} ({e}); skipped")
                continue
            doc, why = parse(text)
            if doc is None or not isinstance(doc.get("name"), str) or \
                    _file_name(doc["name"]) != fn:
                self.log(f"snapshots: {fn} is not a valid snapshot ({why or 'name mismatch'}); skipped")
                continue
            self._entries[doc["name"]] = _entry(doc)

    def list(self):
        """The list entries, sorted by name."""
        with self.lock:
            return [self._entries[n] for n in sorted(self._entries)]

    def read(self, name):
        """The stored JSON text; KeyError if there's no such snapshot."""
        with self.lock:
            if name not in self._entries:
                raise KeyError(name)
            if self.directory is None:
                return self._texts[name]
            with open(self._path(name), encoding="utf-8") as f:
                return f.read()

    def write(self, doc):
        """Store `doc` under doc['name'] (replacing one of that name).
        Raises SnapshotRefused (a rule or a limit) or OSError (the disk)."""
        name = doc["name"]
        why = name_problem(name)
        if why is not None:
            raise SnapshotRefused(why)
        text = encode(doc)
        if len(text.encode("utf-8")) > MAX_BYTES:
            raise SnapshotRefused(f"the snapshot is larger than {MAX_BYTES} bytes")
        with self.lock:
            if name not in self._entries and len(self._entries) >= self.max_snapshots:
                raise SnapshotRefused(f"the mixer holds at most {self.max_snapshots} snapshots; delete one first")
            if self.directory is None:
                self._texts[name] = text
            else:
                main = self._path(name)
                tmp = main + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(text)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, main)
                self._fsync_dir()
            self._entries[name] = _entry(doc)

    def delete(self, name):
        """KeyError if there's no such snapshot."""
        with self.lock:
            if name not in self._entries:
                raise KeyError(name)
            if self.directory is None:
                del self._texts[name]
            else:
                os.remove(self._path(name))
                self._fsync_dir()
            del self._entries[name]

    def _fsync_dir(self):
        if hasattr(os, "O_DIRECTORY"):   # POSIX: make the rename / unlink durable
            fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
