#!/usr/bin/env python3
"""
MSRP and MVRP (IEEE 802.1Q clauses 35 and 11) for an AVB end station: just
enough MRP to declare our attributes and see the peer's.

    declare  Domain (SR class A: ID 6, priority 3, VID 2), a Talker Advertise
             for our output stream, a Listener Ready for the stream our
             listener is bound to, and (MVRP) membership of VLAN 2
    register the peer's Talker Advertise / Listener declarations, with ages

This is a simplified applicant: every declaration is sent as JoinIn once a
second (MRP's periodic transmission) and at once after a change or a
LeaveAll from the peer; a Leave is sent when a declaration is withdrawn.
Enough for an end station on a point-to-point link or behind an AVB bridge
(which runs the full state machines); it doesn't originate LeaveAll.

Encodings from OpenAvnu's mrpd (msrp.h, mrp.h, mrpd.h):
    MRPDU = ProtocolVersion(1) Message* EndMark(0x0000)
    Message = AttributeType(1) AttributeLength(1) [AttributeListLength(2),
              MSRP only] VectorAttribute* EndMark
    VectorAttribute = VectorHeader(2: LeaveAllEvent(3) << 13 | NumberOfValues)
              FirstValue ThreePackedEvents [FourPackedEvents, Listener only]
    ThreePackedEvents = ((e1 * 6) + e2) * 6 + e3; events New 0, JoinIn 1,
              In 2, JoinMt 3, Mt 4, Lv 5
    FourPackedEvents = d1 * 64 + d2 * 16 + d3 * 4 + d4; Ignore 0,
              AskingFailed 1, Ready 2, ReadyFailed 3
    Talker Advertise (type 1, 25 bytes): StreamID 8, DestMAC 6, VLAN ID 2,
              MaxFrameSize 2, MaxIntervalFrames 2, PriorityAndRank 1
              (priority << 5 | rank << 4), AccumulatedLatency 4 (ns)
    Talker Failed (type 2, 34 bytes): the above + BridgeID 8, FailureCode 1
    Listener (type 3, 8 bytes): StreamID
    Domain (type 4, 4 bytes): SRclassID 1, SRclassPriority 1, SRclassVID 2
    MVRP VID (type 1, 2 bytes)

Phase 10, docs/phase10_status_2026-09-29.md.
"""

import struct

MSRP_ETHERTYPE = 0x22EA
MVRP_ETHERTYPE = 0x88F5
MSRP_MAC = bytes.fromhex("0180c200000e")      # nearest bridge
MVRP_MAC = bytes.fromhex("0180c2000021")

TALKER_ADVERTISE = 1
TALKER_FAILED = 2
LISTENER = 3
DOMAIN = 4
MVRP_VID = 1

NEW, JOININ, IN, JOINMT, MT, LV = range(6)
EVENT_NAME = ("New", "JoinIn", "In", "JoinMt", "Mt", "Lv")
IGNORE, ASKING_FAILED, READY, READY_FAILED = range(4)
LISTENER_NAME = ("Ignore", "AskingFailed", "Ready", "ReadyFailed")

ATTR_LEN = {TALKER_ADVERTISE: 25, TALKER_FAILED: 34, LISTENER: 8, DOMAIN: 4}
LVA = 1 << 13


def talker_value(stream_id, dest_mac, vlan_id, max_frame, max_interval=1,
                 priority=3, rank=1, latency_ns=0):
    return (struct.pack(">Q", stream_id) + bytes(dest_mac) +
            struct.pack(">HHHBI", vlan_id, max_frame, max_interval,
                        (priority << 5) | (rank << 4), latency_ns))


def parse_talker(v):
    sid, = struct.unpack_from(">Q", v, 0)
    vlan, mfs, mif, pr, lat = struct.unpack_from(">HHHBI", v, 14)
    d = {"stream_id": sid, "dest_mac": bytes(v[8:14]), "vlan_id": vlan,
         "max_frame": mfs, "max_interval": mif, "priority": pr >> 5,
         "rank": (pr >> 4) & 1, "latency_ns": lat}
    if len(v) >= 34:
        d["bridge_id"] = bytes(v[25:33])
        d["failure_code"] = v[33]
    return d


def domain_value(class_id=6, priority=3, vid=2):
    return struct.pack(">BBH", class_id, priority, vid)


def _vector(first_value, event, lva=False, four=None):
    """One VectorAttribute carrying a single value."""
    v = struct.pack(">H", (LVA if lva else 0) | 1) + first_value + bytes([event * 36])
    if four is not None:
        v += bytes([four * 64])
    return v


def encode_msrp(decls, leave_all=False):
    """decls: [(attr_type, first_value, event, four_or_None)] -> the MRPDU
    payload (after the Ethernet header). Each value is its own vector."""
    by_type = {}
    for t, val, ev, four in decls:
        by_type.setdefault(t, []).append(_vector(val, ev, leave_all, four))
    out = bytes([0])                                   # ProtocolVersion
    for t in sorted(by_type):
        body = b"".join(by_type[t]) + b"\0\0"         # vectors + EndMark
        out += struct.pack(">BBH", t, ATTR_LEN[t], len(body)) + body
    return out + b"\0\0"


def encode_mvrp(vids, event=JOININ, leave_all=False):
    out = bytes([0])
    body = b"".join(_vector(struct.pack(">H", v), event, leave_all) for v in vids)
    return out + struct.pack(">BB", MVRP_VID, 2) + body + b"\0\0" + b"\0\0"


def _increment(value, attr_type, k):
    """The k-th value after FirstValue: the StreamID (and a talker's
    destination MAC) count up, as 802.1Q 35.2.2.8.4 describes."""
    if k == 0:
        return bytes(value)
    b = bytearray(value)
    sid = (int.from_bytes(b[0:8], "big") + k) & ((1 << 64) - 1)
    b[0:8] = sid.to_bytes(8, "big")
    if attr_type in (TALKER_ADVERTISE, TALKER_FAILED):
        mac = (int.from_bytes(b[8:14], "big") + k) & ((1 << 48) - 1)
        b[8:14] = mac.to_bytes(6, "big")
    return bytes(b)


def decode(pdu, msrp=True):
    """[(attr_type, lva, value, event, four_or_None)] from an MSRP (or, with
    msrp=False, MVRP) MRPDU. Tolerates what it doesn't understand by stopping."""
    out = []
    if not pdu:
        return out
    i = 1                                              # ProtocolVersion
    while i + 2 <= len(pdu):
        t, alen = pdu[i], pdu[i + 1]
        if t == 0 and alen == 0:                       # EndMark of the message list
            break
        i += 2
        if msrp:
            (llen,) = struct.unpack_from(">H", pdu, i)
            i += 2
            end = i + llen
        else:
            end = len(pdu)
        while i + 2 <= end:
            (hdr,) = struct.unpack_from(">H", pdu, i)
            if hdr == 0:                               # EndMark of this message
                i += 2
                break
            i += 2
            lva = (hdr & (7 << 13)) == LVA
            n = hdr & 0x1FFF
            first = pdu[i:i + alen]
            i += alen
            n3 = (n + 2) // 3
            events = []
            for b in pdu[i:i + n3]:
                events += [b // 36, (b // 6) % 6, b % 6]
            i += n3
            fours = None
            if msrp and t == LISTENER:
                n4 = (n + 3) // 4
                fours = []
                for b in pdu[i:i + n4]:
                    fours += [b >> 6, (b >> 4) & 3, (b >> 2) & 3, b & 3]
                i += n4
            if n == 0:
                out.append((t, lva, bytes(first), None, None))
            for k in range(n):
                out.append((t, lva, _increment(first, t, k), events[k],
                            fours[k] if fours is not None else None))
        if msrp:
            i = end
    return out


class Declarer:
    """Our declarations and the peer's registrations. The daemon calls
    msrp_pdu()/mvrp_pdu() when due() says so, and handle_*() on reception."""

    PERIOD_S = 1.0
    EXPIRE_S = 35.0          # a registration not refreshed for this long is gone

    def __init__(self, vlan_id=2, log=print):
        self.vlan_id = vlan_id
        self.log = log
        self.talker = None               # our Talker Advertise value (bytes)
        self.listener = None             # stream ID our listener is bound to
        self.leaving = []                # [(attr_type, value, four)] to send as Lv once
        self.next_tx = 0.0
        self.reg_talkers = {}            # stream_id -> (parsed talker, failed?, t)
        self.reg_listeners = {}          # stream_id -> (four, t)

    def set_talker(self, value):
        if value != self.talker:
            if self.talker is not None:
                self.leaving.append((TALKER_ADVERTISE, self.talker, None))
            self.talker = value
            self.next_tx = 0.0

    def set_listener(self, stream_id):
        if stream_id != self.listener:
            if self.listener is not None:
                self.leaving.append((LISTENER, struct.pack(">Q", self.listener), READY))
            self.listener = stream_id
            self.next_tx = 0.0

    def due(self, now):
        return now >= self.next_tx

    def msrp_pdu(self, now):
        decls = [(DOMAIN, domain_value(vid=self.vlan_id), JOININ, None)]
        if self.talker is not None:
            decls.append((TALKER_ADVERTISE, self.talker, JOININ, None))
        if self.listener is not None:
            decls.append((LISTENER, struct.pack(">Q", self.listener), JOININ, READY))
        decls += [(t, v, LV, f) for t, v, f in self.leaving]
        self.leaving = []
        self.next_tx = now + self.PERIOD_S
        return encode_msrp(decls)

    def mvrp_pdu(self):
        return encode_mvrp([self.vlan_id])

    def handle_msrp(self, pdu, now):
        """Register the peer's declarations; True if it sent a LeaveAll (we
        then re-declare at once)."""
        leave_all = False
        for t, lva, val, ev, four in decode(pdu, msrp=True):
            leave_all |= lva
            if ev is None:
                continue
            if t in (TALKER_ADVERTISE, TALKER_FAILED):
                d = parse_talker(val)
                sid = d["stream_id"]
                if ev == LV or ev == MT:
                    if self.reg_talkers.pop(sid, None):
                        self.log(f"msrp: talker {sid:016x} withdrawn")
                else:
                    if sid not in self.reg_talkers:
                        self.log(f"msrp: talker {sid:016x} registered: dest "
                                 f"{d['dest_mac'].hex(':')} vlan {d['vlan_id']} "
                                 f"frame {d['max_frame']} B, latency {d['latency_ns']} ns"
                                 + (f", FAILED code {d['failure_code']}" if t == TALKER_FAILED else ""))
                    self.reg_talkers[sid] = (d, t == TALKER_FAILED, now)
            elif t == LISTENER:
                sid = struct.unpack(">Q", val)[0]
                if ev == LV or ev == MT:
                    if self.reg_listeners.pop(sid, None):
                        self.log(f"msrp: listener for {sid:016x} withdrawn")
                else:
                    old = self.reg_listeners.get(sid)
                    if old is None or old[0] != four:
                        self.log(f"msrp: listener for {sid:016x}: {LISTENER_NAME[four or 0]}")
                    self.reg_listeners[sid] = (four, now)
        if leave_all:
            self.next_tx = 0.0
        return leave_all

    def expire(self, now):
        for table, what in ((self.reg_talkers, "talker"), (self.reg_listeners, "listener")):
            for sid in [s for s, v in table.items() if now - v[-1] > self.EXPIRE_S]:
                del table[sid]
                self.log(f"msrp: {what} {sid:016x} expired")

    def talker_latency(self, stream_id):
        v = self.reg_talkers.get(stream_id)
        return v[0]["latency_ns"] if v else None
