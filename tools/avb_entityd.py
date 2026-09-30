#!/usr/bin/env python3
"""
avb_entityd: the FPGAmixer's AVDECC entity and MSRP/MVRP participant on end0
(Phase 10). It makes the board show up in an AVB controller (e.g. macOS's
Audio MIDI Setup > Network Device Browser) as one talker and one listener
of 8 channels, and connects the streams a controller asks for to the bridge
(fpgamixer-avb-bridge, AAF devices <-> link #2).

    AVDECC   avdecc_entity.Entity (ADP, AECP/AEM, ACMP), model from
             avdecc_model.Model; raw AVTP frames on end0 (untagged),
             a BPF filter keeps the AAF stream frames out of Python
    MSRP     msrp.Declarer: Domain, our Talker Advertise, a Listener Ready
             for the bound stream; MVRP: VLAN 2
    gPTP     grandmaster, asCapable, peer delay from ptp4l (pmc) every 5 s,
             in a thread; a grandmaster change re-advertises
    binding  when a controller connects our listener or sets a stream format:
             /run/fpgamixer/avb-stream.json (avb_net.write_runtime), the ALSA
             devices and bridge arguments re-rendered (avb_net), and the
             bridge restarted. The talker's stream ID and destination MAC
             are the static ones in /etc/fpgamixer/avb.conf [tx].

Runs as root (raw sockets), after fpgamixer-avb-net (VLAN, qdiscs, TAI).
    avb_entityd.py [--config /etc/fpgamixer/avb.conf] [-v]

Design: docs/phase10_status_2026-09-29.md.
"""

import argparse
import configparser
import ctypes
import os
import select
import socket
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import avb_net                                   # noqa: E402
import avdecc_model as M                         # noqa: E402
import avdecc_pdu as P                           # noqa: E402
import msrp                                      # noqa: E402
from avdecc_entity import Entity                 # noqa: E402

GPTP_CFG = "/etc/fpgamixer/gptp.cfg"
BRIDGE_UNIT = "fpgamixer-avb-bridge.service"
SOL_PACKET = 263
PACKET_ADD_MEMBERSHIP = 1
PACKET_MR_MULTICAST = 0
PACKET_OUTGOING = 4
SO_ATTACH_FILTER = 26
TALKER_LATENCY_NS = 125000       # our MSRP AccumulatedLatency contribution


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- sockets

def attach_filter(sock, insns):
    """Classic BPF: insns = [(code, jt, jf, k)]."""
    prog = b"".join(struct.pack("HBBI", *i) for i in insns)
    buf = ctypes.create_string_buffer(prog, len(prog))
    fprog = struct.pack("HL", len(insns), ctypes.addressof(buf))
    sock.setsockopt(socket.SOL_SOCKET, SO_ATTACH_FILTER, fprog)


# keep only AVTP control frames (subtype 0xFA ADP, 0xFB AECP, 0xFC ACMP): the
# AAF stream frames (subtype 0x02, 8000/s each way) never reach Python
AVTP_CONTROL_ONLY = [
    (0x30, 0, 0, 14),        # ldb [14]        (the AVTP subtype)
    (0x35, 0, 1, 0xFA),      # jge #0xfa, else drop
    (0x06, 0, 0, 0xFFFF),    # ret #65535      (accept)
    (0x06, 0, 0, 0),         # ret #0          (drop)
]


def open_socket(ifname, ethertype, macs, bpf=None):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ethertype))
    if bpf:
        attach_filter(s, bpf)
    s.bind((ifname, ethertype))
    idx = socket.if_nametoindex(ifname)
    for mac in macs:
        mreq = struct.pack("iHH8s", idx, PACKET_MR_MULTICAST, 6, bytes(mac) + b"\0\0")
        s.setsockopt(SOL_PACKET, PACKET_ADD_MEMBERSHIP, mreq)
    s.setblocking(False)
    return s


# ------------------------------------------------------------------ gPTP

def parse_clock_id(s):
    """'00183e.fffe.050648' -> (int, bytes)"""
    h = s.replace(".", "")
    return int(h, 16), bytes.fromhex(h)


class GptpPoller(threading.Thread):
    """ptp4l's view, every 5 s through pmc (fpgamixer-gptp's config)."""

    def __init__(self):
        super().__init__(daemon=True)
        self.state = None
        self.lock = threading.Lock()

    def poll(self):
        out = subprocess.run(
            ["pmc", "-u", "-b", "0", "-f", GPTP_CFG, "GET PARENT_DATA_SET",
             "GET PORT_DATA_SET", "GET PORT_DATA_SET_NP", "GET DEFAULT_DATA_SET"],
            capture_output=True, text=True, timeout=5).stdout
        kv = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 2:
                kv.setdefault(parts[0], parts[1])
        if "grandmasterIdentity" not in kv:
            return None
        gm, gm_b = parse_clock_id(kv["grandmasterIdentity"])
        own = parse_clock_id(kv["clockIdentity"])[1] if "clockIdentity" in kv else None
        slave = kv.get("portState") == "SLAVE"
        path = [gm_b] + ([own] if own and slave and own != gm_b else [])
        return {"gm_id": gm, "domain": int(kv.get("domainNumber", 0)),
                "as_capable": kv.get("asCapable") == "1", "path": path,
                "propagation_delay": int(float(kv.get("peerMeanPathDelay", 0))),
                "port_state": kv.get("portState", "?")}

    def run(self):
        while True:
            try:
                st = self.poll()
            except Exception as e:                   # noqa: BLE001
                log(f"gptp: pmc failed: {e}")
                st = None
            with self.lock:
                self.state = st
            time.sleep(5.0)

    def get(self):
        with self.lock:
            return self.state


# ------------------------------------------------------------------- main

class Daemon:
    def __init__(self, cfg_path, verbose=False):
        self.cfg_path = cfg_path
        self.verbose = verbose
        self.cfg = avb_net.load_config(cfg_path)
        cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
        cp.read(cfg_path)
        ent = cp["entity"] if cp.has_section("entity") else {}
        self.ifname = self.cfg["parent"]
        with open(f"/sys/class/net/{self.ifname}/address") as f:
            self.mac = bytes.fromhex(f.read().strip().replace(":", ""))
        eid = int.from_bytes(self.mac[:3] + b"\xff\xfe" + self.mac[3:], "big")
        model_id = (int.from_bytes(self.mac[:3], "big") << 40) | 0x01
        self.model = M.Model(eid, model_id, self.mac,
                             entity_name=ent.get("name", "FPGAmixer"),
                             firmware=self.firmware(), serial=self.mac.hex(),
                             formats=avb_net.AAF_FORMATS)
        fmt = M.aaf_format(self.cfg["format"])
        self.model.current_format = {M.STREAM_INPUT: fmt, M.STREAM_OUTPUT: fmt}
        tx_sid = int(self.cfg["tx_streamid"].replace(":", ""), 16)
        tx_dest = bytes.fromhex(self.cfg["tx_addr"].replace(":", ""))
        self.entity = Entity(self.model, tx_stream_id=tx_sid, tx_dest_mac=tx_dest,
                             vlan_id=self.cfg["vlan_id"], send=self.send_avtp,
                             on_listener=self.on_listener, on_format=self.on_format,
                             on_transit=self.on_transit,
                             max_transit_ns=self.cfg["mtt_us"] * 1000, log=log)
        self.decl = msrp.Declarer(vlan_id=self.cfg["vlan_id"], log=log)
        self.tx_sid, self.tx_dest = tx_sid, tx_dest
        self.update_talker_decl()
        self.apply_at = None             # when to re-render + restart the bridge
        self.rx = None                   # the bound listener stream, for the runtime file
        self.gptp = GptpPoller()
        self.last_gptp = None

    @staticmethod
    def firmware():
        try:
            with open("/etc/fpgamixer/version") as f:
                return f.read().strip()[:63]
        except OSError:
            return "FPGAmixer"

    # ----- outputs
    def send_avtp(self, dst, pdu):
        self.avtp.send(P.eth_frame(dst, self.mac, pdu))

    def update_talker_decl(self):
        fmt = M.decode_aaf_format(self.model.current_format[M.STREAM_OUTPUT])[0]
        self.decl.set_talker(msrp.talker_value(
            self.tx_sid, self.tx_dest, self.cfg["vlan_id"],
            avb_net.avtpdu_bytes(self.cfg, fmt), 1, self.cfg["pcp"], 1, TALKER_LATENCY_NS))

    def on_listener(self, binding):
        if binding is None:
            self.rx = None
            self.decl.set_listener(None)
            log("avb_entityd: listener unbound; the bridge keeps the static stream from avb.conf")
            avb_net.write_runtime(rx={}, path=avb_net.RUNTIME)
        else:
            fmt = M.decode_aaf_format(self.model.current_format[M.STREAM_INPUT])[0]
            self.rx = {"addr": P.mac_str(binding["dest_mac"]).upper(),
                       "streamid": avb_net.sid_str(binding["stream_id"]), "format": fmt}
            self.decl.set_listener(binding["stream_id"])
            avb_net.write_runtime(rx=self.rx, path=avb_net.RUNTIME)
        self.apply_at = time.monotonic() + 0.3

    def on_format(self, dtype, alsa_fmt):
        log(f"avb_entityd: {'input' if dtype == M.STREAM_INPUT else 'output'} stream "
            f"format -> {alsa_fmt}")
        if dtype == M.STREAM_OUTPUT:
            avb_net.write_runtime(tx_format=alsa_fmt, path=avb_net.RUNTIME)
            self.update_talker_decl()
        else:
            rx = dict(self.rx or {})
            rx["format"] = alsa_fmt
            if self.rx:
                self.rx = rx
            avb_net.write_runtime(rx=rx, path=avb_net.RUNTIME)
        self.apply_at = time.monotonic() + 0.3

    def on_transit(self, ns):
        """A controller set our talker's max transit time: the AAF plugin's mtt
        (presentation time = launch + time_uncertainty + mtt)."""
        us = max(1, min(1_000_000, (ns + 999) // 1000))
        avb_net.write_runtime(tx_mtt_us=us, path=avb_net.RUNTIME)
        self.apply_at = time.monotonic() + 0.3

    def apply(self):
        """Re-render the ALSA devices and the bridge's arguments, restart it."""
        try:
            cfg = avb_net.apply_runtime(self.cfg, path=avb_net.RUNTIME)
            avb_net.write_stream_files(cfg)
        except SystemExit as e:
            log(f"avb_entityd: stream files not written: {e}")
            return
        subprocess.Popen(["systemctl", "restart", BRIDGE_UNIT])
        log("avb_entityd: bridge restarted with the new stream settings")

    # ----- the loop
    def run(self):
        self.avtp = open_socket(self.ifname, P.AVTP_ETHERTYPE, [P.ADP_ACMP_MAC],
                                bpf=AVTP_CONTROL_ONLY)
        self.msrp_s = open_socket(self.ifname, msrp.MSRP_ETHERTYPE, [msrp.MSRP_MAC])
        self.mvrp_s = open_socket(self.ifname, msrp.MVRP_ETHERTYPE, [msrp.MVRP_MAC])
        # A fresh start: no binding survives a restart (the controller reconnects)
        avb_net.write_runtime(rx={}, path=avb_net.RUNTIME)
        self.gptp.start()
        now = time.monotonic()
        self.entity.start(now)
        log(f"avb_entityd: on {self.ifname} ({P.mac_str(self.mac)}), talker stream "
            f"{self.tx_sid:016x} -> {P.mac_str(self.tx_dest)}, vlan {self.cfg['vlan_id']}")
        try:
            while True:
                r, _, _ = select.select([self.avtp, self.msrp_s, self.mvrp_s], [], [], 0.1)
                now = time.monotonic()
                for s in r:
                    self.receive(s, now)
                self.housekeeping(now)
        except KeyboardInterrupt:
            pass
        finally:
            self.entity.stop()

    def receive(self, s, now):
        while True:
            try:
                data, addr = s.recvfrom(2048)
            except BlockingIOError:
                return
            if addr[2] == PACKET_OUTGOING or len(data) < 14:
                continue
            src = data[6:12]
            etype = struct.unpack_from(">H", data, 12)[0]
            payload = data[14:]
            try:
                if s is self.avtp and etype == P.AVTP_ETHERTYPE:
                    if self.verbose:
                        log(f"rx {P.mac_str(src)} subtype {payload[0]:#x} "
                            f"type {payload[1] & 0x0F}")
                    self.entity.handle(src, payload, now)
                elif s is self.msrp_s and etype == msrp.MSRP_ETHERTYPE:
                    if self.decl.handle_msrp(payload, now):
                        self.send_mrp(now)
            except Exception as e:                     # noqa: BLE001
                log(f"avb_entityd: dropped a malformed frame from {P.mac_str(src)}: {e!r}")

    def send_mrp(self, now):
        self.msrp_s.send(P.eth_frame(msrp.MSRP_MAC, self.mac, self.decl.msrp_pdu(now),
                                     msrp.MSRP_ETHERTYPE))
        self.mvrp_s.send(P.eth_frame(msrp.MVRP_MAC, self.mac, self.decl.mvrp_pdu(),
                                     msrp.MVRP_ETHERTYPE))

    def housekeeping(self, now):
        self.entity.tick(now)
        self.decl.expire(now)
        if self.entity.binding:
            self.entity.msrp_acc_latency = self.decl.talker_latency(
                self.entity.binding["stream_id"])
        if self.decl.due(now):
            self.send_mrp(now)
        if self.apply_at is not None and now >= self.apply_at:
            self.apply_at = None
            self.apply()
        g = self.gptp.get()
        if g and g != self.last_gptp:
            if not self.last_gptp or g["gm_id"] != self.last_gptp["gm_id"] or \
                    g["port_state"] != self.last_gptp["port_state"]:
                log(f"avb_entityd: gPTP {g['port_state']}, grandmaster {g['gm_id']:016x}, "
                    f"asCapable {g['as_capable']}, peer delay {g['propagation_delay']} ns")
            self.entity.set_gptp(g["gm_id"], g["domain"], g["as_capable"], g["path"],
                                 g["propagation_delay"])
            self.last_gptp = g


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--config", default=avb_net.DEFAULT_CONFIG)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    Daemon(a.config, a.verbose).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
