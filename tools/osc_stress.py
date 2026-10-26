#!/usr/bin/env python3
"""
Control-plane stress test (hardening T3, docs/hardening_status_2026-10-10.md).

Changes the mixer's parameters as fast as it answers -- levels, crosspoints,
names, groups, sources, destinations, channel counts, snapshot recalls --
everywhere EXCEPT a protected path, while loopback_null_test.py checks that
path's audio sample by sample. The PL swaps every coefficient bank whole at
a frame strobe, so no change elsewhere may ever touch a protected sample.

Protected (never changed):
  - the null-test path given on the command line: --in I --bus B --out O
    (1-based, as the app numbers them), with everything that can reach it;
  - unless --allow-analog: every output patched to an Analog port (your
    speakers and headphones), and everything that feeds it;
  - "everything that feeds": the buses mixed into a protected output, the
    inputs mixed into a protected bus, and every channel in a virtual group
    with a protected channel. No destination ever moves onto a protected
    output's port, no Analog port is ever assigned (unless --allow-analog),
    and the counts never hide a protected channel.
Names change everywhere (they never reach the audio).

Before it starts it saves the live state as the snapshot "Before stress";
at the end it puts the counts back and loads that snapshot, so the mix is as
it was. (A recall also replaces the mixer's "Before load" undo point.) Turn
the monitors down anyway.

It checks, every report: the protected parameters still hold their starting
values (from the config), no request was refused (every value it sends is
valid), and how long the mixer took to answer (ping round trips).

Usage (any machine that reaches the board):
    python3 osc_stress.py --host amd-edf.local --in 1 --bus 1 --out 1 --minutes 60
    python3 osc_stress.py ... --rate 300 --report 10 --log stress.log
Exit code 0 only if nothing protected changed and nothing was refused.
"""

import argparse
import json
import random
import string
import sys
import time

from osc_codec import TCPLink

OFF = -90.0
CH_ZONES = ("inputChannel", "busChannel", "outputChannel")
COUNTS = {"inputChannel": "inputCount", "busChannel": "busCount", "outputChannel": "outputCount"}
PING_TOKEN0 = 7000


class Mixer:
    """The mixer as the config describes it, kept current from echoes."""

    def __init__(self, config):
        self.load(config)

    def load(self, config):
        self.config = config
        self.zones = config["zones"]
        self.modules = config["modules"]
        self.system = config.get("system", {})
        self.values = dict(config["values"])
        self.ports = [l for l in self.modules.get("destination", {}).get("optionLabels", [])]

    def count(self, zone):
        z = self.zones[zone]
        return z["count"] if "count" in z else None

    def value(self, path):
        if path in self.values:
            return self.values[path]
        module = path.rsplit("/", 1)[1]
        return self.modules[module].get("default")


def protected_sets(m, null_path, allow_analog):
    """{zone: set of channel indices} that must not change, closed over what
    feeds them and over virtual groups."""
    prot = {z: set() for z in CH_ZONES}
    if null_path:
        i, b, o = null_path
        prot["inputChannel"].add(i)
        prot["busChannel"].add(b)
        prot["outputChannel"].add(o)
    if not allow_analog and "destination" in m.modules:
        for o in range(m.count("outputChannel")):
            d = int(m.value(f"outputChannel/{o}/destination"))
            if d and m.ports[d].startswith("Analog"):
                prot["outputChannel"].add(o)
    n_in, n_bus, n_out = (m.count(z) for z in CH_ZONES)
    changed = True
    while changed:
        before = sum(len(s) for s in prot.values())
        for o in list(prot["outputChannel"]):        # buses feeding a protected output
            for b in range(n_bus):
                if m.value(f"busMatrix/{b}_{o}/level") > OFF:
                    prot["busChannel"].add(b)
        for b in list(prot["busChannel"]):           # inputs feeding a protected bus
            for i in range(n_in):
                if m.value(f"inputMatrix/{i}_{b}/level") > OFF:
                    prot["inputChannel"].add(i)
        for zone in CH_ZONES:                        # group members of protected channels
            groups = {m.value(f"{zone}/{c}/vgroup") for c in prot[zone]} - {0, 0.0}
            for c in range(m.count(zone)):
                if m.value(f"{zone}/{c}/vgroup") in groups:
                    prot[zone].add(c)
        changed = sum(len(s) for s in prot.values()) != before
    return prot


def protected_paths(m, prot):
    """Every parameter whose value must not change: the protected channels'
    audio modules (not names), crosspoints into protected buses and outputs,
    and the protected outputs' destinations."""
    paths = []
    for zone in CH_ZONES:
        for c in prot[zone]:
            for module in m.zones[zone]["modules"]:
                if module != "name":
                    paths.append(f"{zone}/{c}/{module}")
    for b in prot["busChannel"]:
        paths += [f"inputMatrix/{i}_{b}/level" for i in range(m.count("inputChannel"))]
    for o in prot["outputChannel"]:
        paths += [f"busMatrix/{b}_{o}/level" for b in range(m.count("busChannel"))]
    return sorted(set(paths))


class Stress:
    def __init__(self, link, rng, null_path=None, allow_analog=False, log=print):
        self.link, self.rng, self.log = link, rng, log
        self.null_path, self.allow_analog = null_path, allow_analog
        self.stats = {"sets": 0, "echoes": 0, "refused": 0, "recalls": 0, "count changes": 0,
                      "saves": 0, "batches": 0, "ping max ms": 0.0, "ping total ms": 0.0}
        self.refusals = []
        self.hidden = []                 # counts that hid a protected channel
        self.pongs = set()
        self.token = PING_TOKEN0
        self.m = Mixer(self.fetch_config())
        self.prot = protected_sets(self.m, null_path, allow_analog)
        self.paths = protected_paths(self.m, self.prot)
        self.start_values = {p: self.m.value(p) for p in self.paths}
        self.start_counts = {z: self.m.count(z) for z in CH_ZONES}
        self.min_counts = {z: max(self.prot[z], default=-1) + 1 for z in CH_ZONES}
        self.held_ports = {int(self.m.value(f"outputChannel/{o}/destination"))
                           for o in self.prot["outputChannel"]} - {0} if "destination" in self.m.modules else set()

    # ----- the wire -----
    def fetch_config(self):
        self.link.send_message("/mixer/get/system/config")
        while True:
            msg = self.link.read_message(timeout=5.0)
            if msg.address.endswith("/set/system/config"):
                return json.loads(msg.args[0])
            self.handle(msg)

    def handle(self, msg):
        """An incoming message other than the one awaited."""
        kind = msg.address.split("/", 2)[2] if msg.address.count("/") >= 2 else ""
        if kind.startswith("set/"):
            self.stats["echoes"] += 1
            path = kind[4:]
            if msg.args and not path.startswith("system/"):
                self.m.values[path] = msg.args[0]
        elif kind == "error":
            self.stats["refused"] += 1
            self.refusals.append(tuple(msg.args))
        elif kind == "pong" and msg.args:
            self.pongs.add(msg.args[0])      # may arrive while a config is being fetched
        return kind

    def sync(self):
        """Ping and read until its pong: everything sent before is answered
        (a config/changed on the way is followed by a fresh config)."""
        self.token += 1
        t0 = time.monotonic()
        self.link.send_message("/mixer/ping", [self.token])
        while self.token not in self.pongs:
            msg = self.link.read_message(timeout=10.0)
            if self.handle(msg) == "config/changed":
                self.m.load(self.fetch_config())
                self.hidden += self.hidden_protected()
        self.pongs.discard(self.token)
        ms = (time.monotonic() - t0) * 1000
        self.stats["ping max ms"] = max(self.stats["ping max ms"], ms)
        self.stats["ping total ms"] += ms
        self.stats["batches"] += 1

    def send(self, path, value):
        self.link.send_message(f"/mixer/set/{path}", [value])
        self.stats["sets"] += 1

    # ----- what may change -----
    def free(self, zone):
        return [c for c in range(self.m.count(zone)) if c not in self.prot[zone]]

    def random_change(self):
        """(path, value) of one allowed change, valid for the mixer as it is."""
        r, m = self.rng, self.m
        n_in, n_bus, n_out = (m.count(z) for z in CH_ZONES)
        while True:
            pick = r.random()
            if pick < 0.30:
                zone = r.choice(CH_ZONES)
                free = self.free(zone)
                if free:
                    return f"{zone}/{r.choice(free)}/level", round(r.uniform(-40.0, 0.0), 1)
            elif pick < 0.55:
                i, b = r.randrange(n_in), r.randrange(n_bus)
                if b not in self.prot["busChannel"]:
                    return f"inputMatrix/{i}_{b}/level", OFF if r.random() < 0.5 else round(r.uniform(-30, 0), 1)
            elif pick < 0.70:
                b, o = r.randrange(n_bus), r.randrange(n_out)
                if o not in self.prot["outputChannel"]:
                    return f"busMatrix/{b}_{o}/level", OFF if r.random() < 0.5 else round(r.uniform(-30, 0), 1)
            elif pick < 0.78:
                zone = r.choice(CH_ZONES)
                return (f"{zone}/{r.randrange(m.count(zone))}/name",
                        "s" + "".join(r.choice(string.ascii_letters) for _ in range(r.randrange(0, 12))))
            elif pick < 0.84:
                zone = r.choice(CH_ZONES)
                free = self.free(zone)
                used = {m.value(f"{zone}/{c}/vgroup") for c in self.prot[zone]}
                groups = [g for g in (0, 61, 62, 63, 64) if g not in used or g == 0]
                if free:
                    return f"{zone}/{r.choice(free)}/vgroup", float(r.choice(groups))
            elif pick < 0.92 and "source" in m.modules:
                free = self.free("inputChannel")
                if free:
                    return f"inputChannel/{r.choice(free)}/source", float(r.randrange(len(m.ports)))
            elif "destination" in m.modules:
                free = self.free("outputChannel")
                ok = [p for p in range(len(m.ports)) if p not in self.held_ports
                      and (self.allow_analog or not m.ports[p].startswith("Analog"))]
                if free:
                    return f"outputChannel/{r.choice(free)}/destination", float(r.choice(ok))

    # ----- the less frequent things -----
    def recall(self):
        values = dict(self.random_change() for _ in range(40))
        doc = {"snapshotVersion": 1, "name": "stress", "values": values}
        self.link.send_message("/mixer/snapshot/apply", [json.dumps(doc)])
        self.stats["recalls"] += 1

    def change_count(self):
        if "inputCount" not in self.m.system:
            return
        zone = self.rng.choice(CH_ZONES)
        top = self.m.system[COUNTS[zone]]["max"]
        n = self.rng.randrange(max(1, self.min_counts[zone]), top + 1)
        self.sync()
        self.send(f"system/{COUNTS[zone]}", float(n))
        self.sync()                       # the echo, config/changed, the new config
        self.stats["count changes"] += 1

    def save_load(self):
        self.link.send_message("/mixer/snapshot/save", ["stress temp"])
        self.sync()
        self.link.send_message("/mixer/snapshot/load", ["stress temp"])
        self.stats["saves"] += 1

    # ----- checks -----
    def check(self):
        """The protected parameters against their starting values (fresh
        config); a list of (path, start, now)."""
        self.sync()
        self.m.load(self.fetch_config())
        bad, self.hidden = self.hidden + self.hidden_protected(), []
        for p in self.paths:
            zone, index, _mod = p.split("/")
            if zone in self.m.zones and self._visible(zone, index) and self.m.value(p) != self.start_values[p]:
                bad.append((p, self.start_values[p], self.m.value(p)))
        return bad

    def hidden_protected(self):
        """A count that hides a protected channel is a protected change too:
        [(system/<count>, needed, now)]."""
        return [(f"system/{COUNTS[z]}", self.min_counts[z], self.m.count(z))
                for z in CH_ZONES if self.m.count(z) < self.min_counts[z]]

    def _visible(self, zone, index):
        z = self.m.zones[zone]
        if "count" in z:
            return int(index) < z["count"]
        r, c = (int(x) for x in index.split("_"))
        return r < z["rows"] and c < z["cols"]

    # ----- run -----
    def begin(self):
        self.link.send_message("/mixer/snapshot/save", ["Before stress"])
        self.sync()

    def finish(self):
        for zone, n in self.start_counts.items():
            if n is not None and self.m.count(zone) != n and COUNTS[zone] in self.m.system:
                self.send(f"system/{COUNTS[zone]}", float(n))
                self.sync()
        self.link.send_message("/mixer/snapshot/load", ["Before stress"])
        if self.stats["saves"]:
            self.link.send_message("/mixer/snapshot/delete", ["stress temp"])
        self.sync()

    def run(self, seconds, rate=200, batch=20, report=10.0, every=(7.0, 13.0, 29.0)):
        """Returns (ok, protected changes). every = seconds between recalls,
        count changes, save/loads."""
        self.begin()
        failures = []
        t_end = time.monotonic() + seconds
        t_report = time.monotonic() + report
        t_recall, t_count, t_save = (time.monotonic() + x for x in every)
        while time.monotonic() < t_end:
            t0 = time.monotonic()
            for _ in range(batch):
                self.send(*self.random_change())
            self.sync()
            now = time.monotonic()
            if now >= t_recall:
                self.recall()
                self.sync()
                t_recall = now + every[0]
            if now >= t_count:
                self.change_count()
                t_count = now + every[1]
            if now >= t_save:
                self.save_load()
                self.sync()
                t_save = now + every[2]
            if now >= t_report:
                bad = self.check()
                failures += bad
                self.report(bad)
                t_report = time.monotonic() + report
            spare = batch / rate - (time.monotonic() - t0)
            if spare > 0:
                time.sleep(spare)
        bad = self.check()
        failures += bad
        self.finish()
        self.report(bad, final=True)
        return not failures and not self.refusals, failures

    def report(self, bad, final=False):
        s = self.stats
        avg = s["ping total ms"] / s["batches"] if s["batches"] else 0.0
        self.log(f"{'FINAL ' if final else ''}sets {s['sets']}, echoes {s['echoes']}, refused "
                 f"{s['refused']}, recalls {s['recalls']}, count changes {s['count changes']}, "
                 f"save/loads {s['saves']}, ping avg {avg:.1f} ms max {s['ping max ms']:.1f} ms; "
                 f"protected: {'OK' if not bad else f'{len(bad)} CHANGED'}")
        for p, a, b in bad:
            self.log(f"  PROTECTED CHANGED: {p} {a!r} -> {b!r}")
        for r in self.refusals[-5:] if final else []:
            self.log(f"  refused: {r}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="amd-edf.local")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--in", dest="inp", type=int, help="the null test's input channel (1-based)")
    p.add_argument("--bus", type=int, help="its bus (1-based)")
    p.add_argument("--out", type=int, help="its output channel (1-based)")
    p.add_argument("--allow-analog", action="store_true",
                   help="also change outputs patched to Analog ports, and assign them (careful)")
    p.add_argument("--minutes", type=float, default=10.0)
    p.add_argument("--rate", type=float, default=200.0, help="sets per second (default 200)")
    p.add_argument("--report", type=float, default=10.0, help="seconds between checks (default 10)")
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--log", help="also append the reports to this file")
    args = p.parse_args(argv)
    path = (args.inp, args.bus, args.out)
    if any(x is not None for x in path) and not all(x is not None and x >= 1 for x in path):
        p.error("--in, --bus and --out go together (1-based)")
    null_path = tuple(x - 1 for x in path) if args.inp else None
    log_file = open(args.log, "a") if args.log else None

    def say(text):
        line = f"{time.strftime('%H:%M:%S')} {text}"
        print(line, flush=True)
        if log_file:
            log_file.write(line + "\n")
            log_file.flush()

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    link = TCPLink(args.host, args.port, timeout=5.0).connect()
    try:
        st = Stress(link, random.Random(seed), null_path, args.allow_analog, log=say)
        say(f"stress: seed {seed}; protected inputs {sorted(c + 1 for c in st.prot['inputChannel'])}, "
            f"buses {sorted(c + 1 for c in st.prot['busChannel'])}, outputs "
            f"{sorted(c + 1 for c in st.prot['outputChannel'])} ({len(st.paths)} parameters)")
        ok, _bad = st.run(args.minutes * 60, rate=args.rate, report=args.report)
    finally:
        link.close()
    say("PASS: nothing protected changed, nothing refused" if ok else "FAIL (see above)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
