#!/usr/bin/env python3
"""
A minimal AVDECC controller for bench checks (Phase 10). Linux, root (raw
sockets), standard library + avdecc_pdu / avdecc_model from this directory.

    avdecc_probe.py -i IF discover             ENTITY_DISCOVER; list who answers
    avdecc_probe.py -i IF read ENTITY_ID       enumerate the entity model the
                                               way a controller does, print it
    avdecc_probe.py -i IF connect TALKER LISTENER
                                               ACMP CONNECT_RX (talker stream 0
                                               -> listener stream 0)
    avdecc_probe.py -i IF disconnect TALKER LISTENER
    avdecc_probe.py -i IF rxstate LISTENER     ACMP GET_RX_STATE

ENTITY_ID etc. are 16 hex digits (as `discover` prints them). Used against
avb_entityd on a veth pair (the VM test) and, if needed, on the bench.
"""

import argparse
import os
import random
import select
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import avdecc_model as M     # noqa: E402
import avdecc_pdu as P       # noqa: E402

CONTROLLER_ID = 0x0200000000C0FFEE     # locally administered, for the probe
NAMES = {v: k for k, v in vars(M).items() if k.isupper() and isinstance(v, int)
         and k in ("ENTITY", "CONFIGURATION", "AUDIO_UNIT", "STREAM_INPUT", "STREAM_OUTPUT",
                   "AVB_INTERFACE", "CLOCK_SOURCE", "LOCALE", "STRINGS", "STREAM_PORT_INPUT",
                   "STREAM_PORT_OUTPUT", "AUDIO_CLUSTER", "AUDIO_MAP", "CLOCK_DOMAIN")}


class Probe:
    def __init__(self, ifname):
        self.s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(P.AVTP_ETHERTYPE))
        self.s.bind((ifname, P.AVTP_ETHERTYPE))
        idx = socket.if_nametoindex(ifname)
        self.s.setsockopt(263, 1, struct.pack("iHH8s", idx, 0, 6, P.ADP_ACMP_MAC + b"\0\0"))
        with open(f"/sys/class/net/{ifname}/address") as f:
            self.mac = bytes.fromhex(f.read().strip().replace(":", ""))
        self.seq = random.randrange(0x10000)
        self.macs = {}                       # entity id -> MAC (from its ADP)

    def send(self, dst, pdu):
        self.s.send(P.eth_frame(dst, self.mac, pdu))

    def recv(self, timeout, want):
        """Frames until want(src, pdu) returns something, or the timeout."""
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return None
            r, _, _ = select.select([self.s], [], [], left)
            if not r:
                return None
            data, addr = self.s.recvfrom(2048)
            if addr[2] == 4:                                  # our own
                continue
            pdu = data[14:]
            if pdu and pdu[0] == P.SUBTYPE_ADP:
                a = P.unpack_adp(pdu)
                self.macs[a["entity_id"]] = data[6:12]
            v = want(data[6:12], pdu)
            if v is not None:
                return v

    def discover(self, timeout=2.0):
        self.send(P.ADP_ACMP_MAC, P.pack_adp(P.ADP_ENTITY_DISCOVER, 0, 0, 0, 0, 0, 0, 0,
                                             0, 0, 0, 0, 0))
        found = {}

        def want(src, pdu):
            if pdu and pdu[0] == P.SUBTYPE_ADP:
                a = P.unpack_adp(pdu)
                if a["message_type"] == P.ADP_ENTITY_AVAILABLE:
                    found[a["entity_id"]] = a
        self.recv(timeout, want)
        return found

    def aem(self, target, cmd, payload, timeout=1.0):
        mac = self.macs.get(target)
        if mac is None:
            self.discover(1.0)
            mac = self.macs.get(target)
            if mac is None:
                raise SystemExit(f"entity {target:016x} not found")
        self.seq = (self.seq + 1) & 0xFFFF
        seq = self.seq
        self.send(mac, P.pack_aem(P.AECP_AEM_COMMAND, 0, target, CONTROLLER_ID, seq,
                                  P.CMD[cmd], payload))

        def want(src, pdu):
            if pdu and pdu[0] == P.SUBTYPE_AECP:
                d = P.unpack_aecp(pdu)
                if d["message_type"] == P.AECP_AEM_RESPONSE and d["sequence_id"] == seq \
                        and d["controller"] == CONTROLLER_ID:
                    return d
        r = self.recv(timeout, want)
        if r is None:
            raise SystemExit(f"no response to {cmd}")
        return r

    def read_descriptor(self, target, dtype, index):
        r = self.aem(target, "READ_DESCRIPTOR", struct.pack(">HHHH", 0, 0, dtype, index))
        return r["status"], r["payload"][4:]

    def acmp(self, name, talker, listener, timeout=5.0):
        self.seq = (self.seq + 1) & 0xFFFF
        seq = self.seq
        self.send(P.ADP_ACMP_MAC, P.pack_acmp(P.ACMP[name], controller=CONTROLLER_ID,
                                              talker=talker, listener=listener, sequence_id=seq))
        resp = P.ACMP[name.replace("COMMAND", "RESPONSE")]

        def want(src, pdu):
            if pdu and pdu[0] == P.SUBTYPE_ACMP:
                a = P.unpack_acmp(pdu)
                if a["message_type"] == resp and a["sequence_id"] == seq and \
                        a["controller"] == CONTROLLER_ID:
                    return a
        r = self.recv(timeout, want)
        if r is None:
            raise SystemExit(f"no {name.replace('COMMAND', 'RESPONSE')}")
        return r


def name_of(desc):
    return desc[4:68].rstrip(b"\0").decode("utf-8", "replace")


def cmd_read(p, target):
    st, ent = p.read_descriptor(target, M.ENTITY, 0)
    if st:
        raise SystemExit(f"READ_DESCRIPTOR ENTITY: status {st}")
    print(f"ENTITY {target:016x}: '{ent[48:112].rstrip(bytes(1)).decode()}', "
          f"model {struct.unpack_from('>Q', ent, 12)[0]:016x}, "
          f"caps {struct.unpack_from('>I', ent, 20)[0]:#010x}, "
          f"{struct.unpack_from('>H', ent, 308)[0]} configuration(s)")
    st, cfg = p.read_descriptor(target, M.CONFIGURATION, 0)
    n, off = struct.unpack_from(">HH", cfg, 70)
    counts = [struct.unpack_from(">HH", cfg, off + 4 * i) for i in range(n)]
    total = 2
    for t, c in counts:
        for i in range(c):
            st, d = p.read_descriptor(target, t, i)
            total += 1
            tn = NAMES.get(t, f"{t:#06x}")
            if st:
                print(f"  {tn} {i}: status {st}")
                continue
            extra = ""
            if t in (M.STREAM_INPUT, M.STREAM_OUTPUT):
                fo, nf = struct.unpack_from(">HH", d, 82)
                fmts = [struct.unpack_from(">Q", d, fo + 8 * k)[0] for k in range(nf)]
                extra = (f": current {struct.unpack_from('>Q', d, 74)[0]:016x}, formats "
                         + ", ".join(f"{f:016x}" for f in fmts))
            if t == M.AUDIO_UNIT:
                extra = f": {struct.unpack_from('>I', d, 136)[0] & 0x1FFFFFFF} Hz"
                for pt, base_off in ((M.STREAM_PORT_INPUT, 72), (M.STREAM_PORT_OUTPUT, 76)):
                    np_, base = struct.unpack_from(">HH", d, base_off)
                    for k in range(np_):
                        st2, sp = p.read_descriptor(target, pt, base + k)
                        nc, bc, nm, bm = struct.unpack_from(">HHHH", sp, 12)
                        total += 1
                        for ci in range(bc, bc + nc):
                            st3, cl = p.read_descriptor(target, M.AUDIO_CLUSTER, ci)
                            total += 1
                        for mi in range(bm, bm + nm):
                            st4, am = p.read_descriptor(target, M.AUDIO_MAP, mi)
                            total += 1
                        extra += (f"; {NAMES[pt]} {base + k}: {nc} clusters "
                                  f"(last '{name_of(cl)}'), {nm} map(s)")
            if t == M.LOCALE:
                ns, bs = struct.unpack_from(">HH", d, 68)
                for k in range(ns):
                    st5, sd = p.read_descriptor(target, M.STRINGS, bs + k)
                    total += 1
                    extra = f": strings '{sd[4:68].rstrip(bytes(1)).decode()}', ..."
            label = name_of(d) if t not in (M.LOCALE,) else d[4:68].rstrip(b"\0").decode()
            print(f"  {tn} {i} '{label}'{extra}")
    print(f"{total} descriptors read, all answered")
    for cmd, pl in (("GET_STREAM_INFO", struct.pack(">HH", M.STREAM_INPUT, 0)),
                    ("GET_STREAM_INFO", struct.pack(">HH", M.STREAM_OUTPUT, 0)),
                    ("GET_AVB_INFO", struct.pack(">HH", M.AVB_INTERFACE, 0)),
                    ("GET_SAMPLING_RATE", struct.pack(">HH", M.AUDIO_UNIT, 0))):
        r = p.aem(target, cmd, pl)
        print(f"  {cmd} {struct.unpack_from('>H', pl, 0)[0]:#06x}: status {r['status']}, "
              f"{r['payload'][4:].hex()}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-i", "--interface", default="end0")
    ap.add_argument("cmd", choices=["discover", "read", "connect", "disconnect", "rxstate"])
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args(argv)
    p = Probe(a.interface)
    ids = [int(x.replace(":", ""), 16) for x in a.ids]
    if a.cmd == "discover":
        for eid, e in p.discover().items():
            print(f"{eid:016x}  model {e['model_id']:016x}  caps {e['caps']:#010x}  "
                  f"talkers {e['talker_sources']} listeners {e['listener_sinks']}  "
                  f"gm {e['gm_id']:016x}  index {e['available_index']}")
    elif a.cmd == "read":
        cmd_read(p, ids[0])
    elif a.cmd in ("connect", "disconnect"):
        name = "CONNECT_RX_COMMAND" if a.cmd == "connect" else "DISCONNECT_RX_COMMAND"
        r = p.acmp(name, ids[0], ids[1])
        print(f"{P.ACMP_NAME[r['message_type']]}: status {r['status']}, stream "
              f"{r['stream_id']:016x} -> {P.mac_str(r['dest_mac'])} vlan {r['vlan_id']}, "
              f"count {r['connection_count']}")
    elif a.cmd == "rxstate":
        r = p.acmp("GET_RX_STATE_COMMAND", 0, ids[0])
        print(f"GET_RX_STATE: status {r['status']}, stream {r['stream_id']:016x}, talker "
              f"{r['talker']:016x}, count {r['connection_count']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
