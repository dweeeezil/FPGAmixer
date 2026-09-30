#!/usr/bin/env python3
"""
The FPGAmixer's AVDECC entity (IEEE 1722.1): one talker stream, one listener
stream, 8 channels each, served from avdecc_model.Model.

    ADP   advertises ENTITY_AVAILABLE every ADV_INTERVAL_S, answers
          ENTITY_DISCOVER, re-advertises when the gPTP grandmaster changes,
          says ENTITY_DEPARTING on stop.
    AECP  AEM responder: acquire / lock, READ_DESCRIPTOR, stream format and
          info, names, sampling rate, clock source, AVB info, AS path,
          counters, audio map, unsolicited notifications. Anything else:
          NOT_IMPLEMENTED (a controller then falls back or skips it).
    ACMP  listener: CONNECT_RX -> CONNECT_TX to the talker -> bind -> reply;
          DISCONNECT_RX, GET_RX_STATE. Talker: CONNECT_TX / DISCONNECT_TX /
          GET_TX_STATE / GET_TX_CONNECTION, with our static stream ID and
          destination MAC (avb.conf [tx]).

No sockets and no clock of its own: the daemon (avb_entityd.py) feeds
handle(src_mac, pdu) and tick(now), and receives:

    send(dst_mac, pdu)                   a PDU to transmit (AVTP ethertype)
    on_listener(binding or None)         the listener was bound or unbound
                                         (binding: stream_id, dest_mac,
                                         vlan_id, talker, talker_uid)
    on_format(dtype, alsa_fmt)           a controller set a stream format

Phase 10, docs/phase10_status_2026-09-29.md.
"""

import struct

import avdecc_model as M
from avdecc_pdu import (
    ACMP, ACMP_NAME, ADP_ACMP_MAC, ADP_ENTITY_AVAILABLE, ADP_ENTITY_DEPARTING,
    ADP_ENTITY_DISCOVER, AECP_AEM_COMMAND, AECP_AEM_RESPONSE, CMD, CMD_NAME,
    AEM_SUCCESS, AEM_NOT_IMPLEMENTED, AEM_NO_SUCH_DESCRIPTOR, AEM_ENTITY_LOCKED,
    AEM_ENTITY_ACQUIRED, AEM_BAD_ARGUMENTS, AEM_NOT_SUPPORTED,
    ACQUIRE_FLAG_RELEASE, LOCK_FLAG_UNLOCK,
    ACMP_SUCCESS, ACMP_LISTENER_UNKNOWN_ID, ACMP_TALKER_UNKNOWN_ID,
    ACMP_LISTENER_TALKER_TIMEOUT, ACMP_NOT_CONNECTED, ACMP_NO_SUCH_CONNECTION,
    SUBTYPE_ADP, SUBTYPE_AECP, SUBTYPE_ACMP,
    CAP_AEM_SUPPORTED, CAP_CLASS_A_SUPPORTED, CAP_GPTP_SUPPORTED,
    TALKER_IMPLEMENTED, TALKER_AUDIO_SOURCE, LISTENER_IMPLEMENTED, LISTENER_AUDIO_SINK,
    pack_adp, unpack_adp, unpack_aecp, pack_aem, pack_aecp_other, unpack_header,
    pack_acmp, unpack_acmp, acmp_args, eui64_str, mac_str,
)

VALID_TIME = 10            # ADP valid_time, in 2-second units: 20 s
ADV_INTERVAL_S = 5.0       # re-advertise well inside valid_time
CONNECT_TX_TIMEOUT_S = 2.0 # 1722.1 ACMP CONNECT_TX timeout (retried once)
LOCK_TIMEOUT_S = 60.0
STREAM_INFO_FLAGS = {"CLASS_B": 0x00000001, "FAST_CONNECT": 0x00000002,
                     "STREAMING_WAIT": 0x00000008,
                     "STREAM_VLAN_ID_VALID": 0x02000000, "CONNECTED": 0x04000000,
                     "MSRP_FAILURE_VALID": 0x08000000, "STREAM_DEST_MAC_VALID": 0x10000000,
                     "MSRP_ACC_LAT_VALID": 0x20000000, "STREAM_ID_VALID": 0x40000000,
                     "STREAM_FORMAT_VALID": 0x80000000}
AVB_INFO_AS_CAPABLE = 0x01
AVB_INFO_GPTP_ENABLED = 0x02
AVB_INFO_SRP_ENABLED = 0x04
SR_CLASS_A = 6
SR_CLASS_A_PRIORITY = 3


class Entity:
    def __init__(self, model, *, tx_stream_id, tx_dest_mac, vlan_id,
                 send, on_listener=None, on_format=None, on_transit=None,
                 max_transit_ns=2_000_000, log=print):
        self.m = model
        self.tx_stream_id = tx_stream_id
        self.tx_dest_mac = bytes(tx_dest_mac)
        self.vlan_id = vlan_id
        self.send = send
        self.on_listener = on_listener or (lambda b: None)
        self.on_format = on_format or (lambda d, f: None)
        self.on_transit = on_transit or (lambda ns: None)
        # our talker's max transit time (the AAF plugin's mtt), and what a
        # controller last set on the input (reported back; not ours to use)
        self.max_transit = {M.STREAM_OUTPUT: max_transit_ns, M.STREAM_INPUT: max_transit_ns}
        self.log = log

        self.gm_id = 0
        self.gptp_domain = 0
        self.as_capable = False
        self.path = []                  # clock identities, grandmaster first
        self.propagation_delay = 0

        self.acquired_by = None
        self.locked_by = None
        self.locked_until = 0.0
        self.unsolicited = {}           # controller entity id -> MAC

        self.binding = None             # the listener's current connection
        self.pending = {}               # our sequence_id -> (CONNECT_RX command, src, t, tries)
        self.seq = 0
        self.tx_listeners = []          # [(listener entity id, unique id)]
        self.streaming = {M.STREAM_INPUT: True, M.STREAM_OUTPUT: True}
        self.msrp_acc_latency = None    # from MSRP, for GET_STREAM_INFO (daemon sets)

        self.next_adv = 0.0
        self.running = False

    # ------------------------------------------------------------ ADP
    def _adp(self, message_type):
        caps = CAP_AEM_SUPPORTED | CAP_CLASS_A_SUPPORTED | CAP_GPTP_SUPPORTED
        pdu = pack_adp(message_type, VALID_TIME, self.m.entity_id, self.m.model_id, caps,
                       1, TALKER_IMPLEMENTED | TALKER_AUDIO_SOURCE,
                       1, LISTENER_IMPLEMENTED | LISTENER_AUDIO_SINK, 0,
                       self.m.available_index, self.gm_id, self.gptp_domain)
        self.send(ADP_ACMP_MAC, pdu)
        if message_type == ADP_ENTITY_AVAILABLE:
            self.m.available_index = (self.m.available_index + 1) & 0xFFFFFFFF

    def start(self, now):
        self.running = True
        self._adp(ADP_ENTITY_AVAILABLE)
        self.next_adv = now + ADV_INTERVAL_S
        self.log(f"avdecc: entity {eui64_str(self.m.entity_id)} "
                 f"({self.m.entity_name}) available")

    def stop(self):
        if self.running:
            self._adp(ADP_ENTITY_DEPARTING)
        self.running = False

    def set_gptp(self, gm_id, domain=0, as_capable=False, path=None, propagation_delay=0):
        changed = (gm_id, domain) != (self.gm_id, self.gptp_domain)
        self.gm_id, self.gptp_domain = gm_id, domain
        self.as_capable = as_capable
        self.path = list(path or [])
        self.propagation_delay = propagation_delay
        if changed and self.running:
            self.log(f"avdecc: gPTP grandmaster {eui64_str(gm_id)}: re-advertising")
            self._adp(ADP_ENTITY_AVAILABLE)

    # ----------------------------------------------------------- input
    def handle(self, src_mac, pdu, now):
        if len(pdu) < 12:
            return
        subtype = pdu[0]
        if subtype == SUBTYPE_ADP:
            a = unpack_adp(pdu)
            if a["message_type"] == ADP_ENTITY_DISCOVER and \
               a["entity_id"] in (0, self.m.entity_id) and self.running:
                self._adp(ADP_ENTITY_AVAILABLE)
                self.next_adv = now + ADV_INTERVAL_S
        elif subtype == SUBTYPE_AECP:
            self._aecp(src_mac, pdu, now)
        elif subtype == SUBTYPE_ACMP:
            self._acmp(unpack_acmp(pdu), now)

    def tick(self, now):
        if self.running and now >= self.next_adv:
            self._adp(ADP_ENTITY_AVAILABLE)
            self.next_adv = now + ADV_INTERVAL_S
        if self.locked_by is not None and now >= self.locked_until:
            self.log(f"avdecc: lock by {eui64_str(self.locked_by)} expired")
            self.locked_by = None
        for seq, (cmd, t, tries) in list(self.pending.items()):
            if now - t < CONNECT_TX_TIMEOUT_S:
                continue
            del self.pending[seq]
            if tries < 2:
                self._send_connect_tx(cmd, now, tries + 1)
            else:
                self.log(f"avdecc: talker {eui64_str(cmd['talker'])} didn't answer CONNECT_TX")
                self._reply_acmp(cmd, "CONNECT_RX_RESPONSE", ACMP_LISTENER_TALKER_TIMEOUT)

    # ------------------------------------------------------------ AECP
    def _aecp(self, src_mac, pdu, now):
        d = unpack_aecp(pdu)
        if d["target"] != self.m.entity_id:
            return
        mt = d["message_type"]
        if mt % 2 == 1:
            return                                   # a response: not ours to answer
        if mt != AECP_AEM_COMMAND:
            # address access, AVC, vendor unique (e.g. Milan MVU), extended:
            # not implemented, echoed back
            self.send(src_mac, pack_aecp_other(mt + 1, AEM_NOT_IMPLEMENTED, d["target"],
                                               d["controller"], d["sequence_id"],
                                               d["payload"]))
            return
        ct = d["command_type"]
        handler = getattr(self, "_aem_" + CMD_NAME.get(ct, "unknown").lower(), None)
        if handler is None:
            status, payload = AEM_NOT_IMPLEMENTED, d["payload"]
        else:
            status, payload = handler(d, src_mac, now)
        self.send(src_mac, pack_aem(AECP_AEM_RESPONSE, status, self.m.entity_id,
                                    d["controller"], d["sequence_id"], ct, payload))
        name = CMD_NAME.get(ct, f"0x{ct:04x}")
        if status != AEM_SUCCESS or ct not in (CMD["READ_DESCRIPTOR"], CMD["GET_STREAM_INFO"],
                                               CMD["GET_COUNTERS"], CMD["GET_AVB_INFO"],
                                               CMD["GET_AS_PATH"]):
            self.log(f"avdecc: AEM {name} from {eui64_str(d['controller'])}: status {status}")

    def _guard(self, controller, now):
        """None if this controller may change state, else a status."""
        if self.acquired_by not in (None, controller):
            return AEM_ENTITY_ACQUIRED
        if self.locked_by not in (None, controller) and now < self.locked_until:
            return AEM_ENTITY_LOCKED
        return None

    def notify(self, command_type, payload):
        """Unsolicited response to every registered controller."""
        for ctrl, mac in self.unsolicited.items():
            self.seq = (self.seq + 1) & 0xFFFF
            self.send(mac, pack_aem(AECP_AEM_RESPONSE, AEM_SUCCESS, self.m.entity_id,
                                    ctrl, self.seq, command_type, payload, unsolicited=True))

    # AEM handlers: (command dict, src MAC, now) -> (status, response payload)
    def _aem_acquire_entity(self, d, src, now):
        p = d["payload"]
        flags, owner, dtype, dindex = struct.unpack_from(">IQHH", p, 0)
        c = d["controller"]
        if flags & ACQUIRE_FLAG_RELEASE:
            if self.acquired_by == c:
                self.acquired_by = None
            elif self.acquired_by is not None:
                return AEM_ENTITY_ACQUIRED, struct.pack(">IQHH", flags, self.acquired_by, dtype, dindex)
            return AEM_SUCCESS, struct.pack(">IQHH", flags, 0, dtype, dindex)
        if self.acquired_by not in (None, c):
            return AEM_ENTITY_ACQUIRED, struct.pack(">IQHH", flags, self.acquired_by, dtype, dindex)
        self.acquired_by = c
        return AEM_SUCCESS, struct.pack(">IQHH", flags, c, dtype, dindex)

    def _aem_lock_entity(self, d, src, now):
        flags, locked, dtype, dindex = struct.unpack_from(">IQHH", d["payload"], 0)
        c = d["controller"]
        if self.locked_by is not None and now >= self.locked_until:
            self.locked_by = None
        if flags & LOCK_FLAG_UNLOCK:
            if self.locked_by in (None, c):
                self.locked_by = None
                return AEM_SUCCESS, struct.pack(">IQHH", flags, 0, dtype, dindex)
            return AEM_ENTITY_LOCKED, struct.pack(">IQHH", flags, self.locked_by, dtype, dindex)
        if self.locked_by not in (None, c):
            return AEM_ENTITY_LOCKED, struct.pack(">IQHH", flags, self.locked_by, dtype, dindex)
        self.locked_by, self.locked_until = c, now + LOCK_TIMEOUT_S
        return AEM_SUCCESS, struct.pack(">IQHH", flags, c, dtype, dindex)

    def _aem_entity_available(self, d, src, now):
        return AEM_SUCCESS, d["payload"]

    def _aem_read_descriptor(self, d, src, now):
        cfg, _res, dtype, dindex = struct.unpack_from(">HHHH", d["payload"], 0)
        desc = self.m.descriptor(dtype, dindex) if cfg == 0 or dtype == M.ENTITY else None
        if desc is None:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:8]
        return AEM_SUCCESS, struct.pack(">HH", cfg, 0) + desc

    def _aem_get_configuration(self, d, src, now):
        return AEM_SUCCESS, struct.pack(">HH", 0, 0)

    def _aem_set_configuration(self, d, src, now):
        _r, cfg = struct.unpack_from(">HH", d["payload"], 0)
        return (AEM_SUCCESS if cfg == 0 else AEM_BAD_ARGUMENTS), struct.pack(">HH", 0, 0)

    def _stream_desc(self, dtype, dindex):
        return dtype in (M.STREAM_INPUT, M.STREAM_OUTPUT) and dindex == 0

    def _aem_get_stream_format(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 8
        return AEM_SUCCESS, struct.pack(">HHQ", dtype, dindex, self.m.current_format[dtype])

    def _aem_set_stream_format(self, d, src, now):
        dtype, dindex, fmt = struct.unpack_from(">HHQ", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:12]
        g = self._guard(d["controller"], now)
        if g is not None:
            return g, struct.pack(">HHQ", dtype, dindex, self.m.current_format[dtype])
        if fmt not in self.m.formats:
            self.log(f"avdecc: SET_STREAM_FORMAT {fmt:016x} refused (not one of ours)")
            return AEM_NOT_SUPPORTED, struct.pack(">HHQ", dtype, dindex, self.m.current_format[dtype])
        if fmt != self.m.current_format[dtype]:
            self.m.current_format[dtype] = fmt
            self.on_format(dtype, M.decode_aaf_format(fmt)[0])
        return AEM_SUCCESS, struct.pack(">HHQ", dtype, dindex, fmt)

    def stream_info(self, dtype):
        """GET_STREAM_INFO's payload (after descriptor type and index)."""
        F = STREAM_INFO_FLAGS
        flags = F["STREAM_FORMAT_VALID"]
        sid, dest, vlan, lat = 0, b"\0" * 6, 0, 0
        if dtype == M.STREAM_OUTPUT:
            flags |= F["STREAM_ID_VALID"] | F["STREAM_DEST_MAC_VALID"] | F["STREAM_VLAN_ID_VALID"]
            if self.tx_listeners:
                flags |= F["CONNECTED"]
            sid, dest, vlan = self.tx_stream_id, self.tx_dest_mac, self.vlan_id
        elif self.binding:
            b = self.binding
            flags |= (F["CONNECTED"] | F["STREAM_ID_VALID"] | F["STREAM_DEST_MAC_VALID"] |
                      F["STREAM_VLAN_ID_VALID"])
            sid, dest, vlan = b["stream_id"], b["dest_mac"], b["vlan_id"]
            if self.msrp_acc_latency is not None:
                flags |= F["MSRP_ACC_LAT_VALID"]
                lat = self.msrp_acc_latency
        # flags 4, format 8, stream_id 8, msrp_accumulated_latency 4, dest MAC 6,
        # msrp_failure_code 1, reserved 1, msrp_failure_bridge_id 8, vlan 2, reserved 2
        return struct.pack(">IQQI6sBBQHH", flags, self.m.current_format[dtype], sid, lat,
                           bytes(dest), 0, 0, 0, vlan, 0)

    def _aem_get_stream_info(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 48
        return AEM_SUCCESS, struct.pack(">HH", dtype, dindex) + self.stream_info(dtype)

    def _name_ref(self, dtype, dindex, name_index):
        """(get, set) for a name, or None."""
        if dtype == M.ENTITY and dindex == 0 and name_index in (0, 1):
            attr = "entity_name" if name_index == 0 else "group_name"
            return (lambda: getattr(self.m, attr),
                    lambda v: setattr(self.m, attr, v))
        if name_index == 0 and self.m.descriptor(dtype, dindex) is not None and \
                dtype not in (M.ENTITY, M.LOCALE, M.STRINGS, M.STREAM_PORT_INPUT,
                              M.STREAM_PORT_OUTPUT, M.AUDIO_MAP):
            desc = self.m.descriptor(dtype, dindex)
            return (lambda: desc[4:68].rstrip(b"\0").decode("utf-8", "replace"),
                    lambda v: self.m.names.__setitem__((dtype, dindex), v))
        return None

    def _aem_get_name(self, d, src, now):
        dtype, dindex, ni, cfg = struct.unpack_from(">HHHH", d["payload"], 0)
        ref = self._name_ref(dtype, dindex, ni)
        if ref is None:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:8] + b"\0" * 64
        return AEM_SUCCESS, struct.pack(">HHHH", dtype, dindex, ni, cfg) + M.s64(ref[0]())

    def _aem_set_name(self, d, src, now):
        dtype, dindex, ni, cfg = struct.unpack_from(">HHHH", d["payload"], 0)
        name = d["payload"][8:72].rstrip(b"\0").decode("utf-8", "replace")
        ref = self._name_ref(dtype, dindex, ni)
        if ref is None:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:72]
        g = self._guard(d["controller"], now)
        if g is not None:
            return g, struct.pack(">HHHH", dtype, dindex, ni, cfg) + M.s64(ref[0]())
        ref[1](name)
        self.log(f"avdecc: name of {dtype:#x}/{dindex}/{ni} set to {name!r}")
        return AEM_SUCCESS, struct.pack(">HHHH", dtype, dindex, ni, cfg) + M.s64(name)

    def _aem_get_sampling_rate(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if (dtype, dindex) != (M.AUDIO_UNIT, 0):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 4
        return AEM_SUCCESS, struct.pack(">HHI", dtype, dindex, M.sampling_rate(48000))

    def _aem_set_sampling_rate(self, d, src, now):
        dtype, dindex, rate = struct.unpack_from(">HHI", d["payload"], 0)
        if (dtype, dindex) != (M.AUDIO_UNIT, 0):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:8]
        ok = rate & 0x1FFFFFFF == 48000
        return (AEM_SUCCESS if ok else AEM_NOT_SUPPORTED), \
            struct.pack(">HHI", dtype, dindex, M.sampling_rate(48000))

    def _aem_get_clock_source(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if (dtype, dindex) != (M.CLOCK_DOMAIN, 0):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 4
        return AEM_SUCCESS, struct.pack(">HHHH", dtype, dindex, 0, 0)

    def _aem_set_clock_source(self, d, src, now):
        dtype, dindex, idx = struct.unpack_from(">HHH", d["payload"], 0)
        if (dtype, dindex) != (M.CLOCK_DOMAIN, 0):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:8]
        return (AEM_SUCCESS if idx == 0 else AEM_BAD_ARGUMENTS), struct.pack(">HHHH", dtype, dindex, 0, 0)

    def _aem_start_streaming(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4]
        self.streaming[dtype] = True
        return AEM_SUCCESS, d["payload"][:4]

    def _aem_stop_streaming(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4]
        # v1: the bridge keeps running (decision V5); the state is reported
        self.streaming[dtype] = False
        return AEM_SUCCESS, d["payload"][:4]

    def _aem_register_unsolicited_notification(self, d, src, now):
        self.unsolicited[d["controller"]] = bytes(src)
        return AEM_SUCCESS, d["payload"]

    def _aem_deregister_unsolicited_notification(self, d, src, now):
        self.unsolicited.pop(d["controller"], None)
        return AEM_SUCCESS, d["payload"]

    def _aem_identify_notification(self, d, src, now):
        return AEM_SUCCESS, d["payload"]

    def _aem_get_avb_info(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if (dtype, dindex) != (M.AVB_INTERFACE, 0):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 16
        flags = AVB_INFO_GPTP_ENABLED | AVB_INFO_SRP_ENABLED | \
            (AVB_INFO_AS_CAPABLE if self.as_capable else 0)
        # gm id 8, propagation delay 4, domain 1, flags 1, msrp_mappings_count 2,
        # mappings: traffic class 1, priority 1, vlan id 2
        return AEM_SUCCESS, (struct.pack(">HHQIBBH", dtype, dindex, self.gm_id,
                                         self.propagation_delay, self.gptp_domain, flags, 1) +
                             struct.pack(">BBH", SR_CLASS_A, SR_CLASS_A_PRIORITY, self.vlan_id))

    def _aem_get_as_path(self, d, src, now):
        (dindex,) = struct.unpack_from(">H", d["payload"], 0)
        if dindex != 0:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4]
        path = self.path or [self.m.gptp["clock_identity"]]
        return AEM_SUCCESS, struct.pack(">HH", dindex, len(path)) + b"".join(bytes(p) for p in path)

    def _aem_get_counters(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if self.m.descriptor(dtype, dindex) is None:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 132
        # counters_valid 4 + 32 counters: none kept yet (v1)
        return AEM_SUCCESS, struct.pack(">HHI", dtype, dindex, 0) + b"\0" * 128

    def _aem_get_audio_map(self, d, src, now):
        dtype, dindex, map_index = struct.unpack_from(">HHH", d["payload"], 0)
        if dtype not in (M.STREAM_PORT_INPUT, M.STREAM_PORT_OUTPUT) or dindex != 0 or map_index != 0:
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:8] + b"\0" * 4
        maps = self.m.mappings()
        return AEM_SUCCESS, struct.pack(">HHHHHH", dtype, dindex, 0, 1, len(maps) // 8, 0) + maps

    def _aem_set_max_transit_time(self, d, src, now):
        dtype, dindex, ns = struct.unpack_from(">HHQ", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:12]
        g = self._guard(d["controller"], now)
        if g is not None:
            return g, struct.pack(">HHQ", dtype, dindex, self.max_transit[dtype])
        if ns != self.max_transit[dtype]:
            self.max_transit[dtype] = ns
            self.log(f"avdecc: max transit time of the {'output' if dtype == M.STREAM_OUTPUT else 'input'}"
                     f" stream set to {ns} ns")
            if dtype == M.STREAM_OUTPUT:
                self.on_transit(ns)
        return AEM_SUCCESS, struct.pack(">HHQ", dtype, dindex, ns)

    def _aem_get_max_transit_time(self, d, src, now):
        dtype, dindex = struct.unpack_from(">HH", d["payload"], 0)
        if not self._stream_desc(dtype, dindex):
            return AEM_NO_SUCH_DESCRIPTOR, d["payload"][:4] + b"\0" * 8
        return AEM_SUCCESS, struct.pack(">HHQ", dtype, dindex, self.max_transit[dtype])

    # ------------------------------------------------------------ ACMP
    def _next_seq(self):
        self.seq = (self.seq + 1) & 0xFFFF
        return self.seq

    def _reply_acmp(self, cmd, name, status, **over):
        a = acmp_args(cmd)
        a.update(status=status)
        a.update(over)
        self.send(ADP_ACMP_MAC, pack_acmp(ACMP[name], **a))
        self.log(f"avdecc: ACMP {name} status {status}")

    def _send_connect_tx(self, cmd, now, tries):
        seq = self._next_seq()
        self.pending[seq] = (cmd, now, tries)
        a = acmp_args(cmd)
        a.update(status=0, stream_id=0, dest_mac=b"\0" * 6, connection_count=0,
                 sequence_id=seq, vlan_id=0)
        self.send(ADP_ACMP_MAC, pack_acmp(ACMP["CONNECT_TX_COMMAND"], **a))

    def _acmp(self, a, now):
        mt, me = a["message_type"], self.m.entity_id
        name = ACMP_NAME.get(mt, str(mt))

        # ----- we are the listener
        if name == "CONNECT_RX_COMMAND" and a["listener"] == me:
            self.log(f"avdecc: CONNECT_RX from controller {eui64_str(a['controller'])}: "
                     f"talker {eui64_str(a['talker'])}/{a['talker_uid']}")
            if a["listener_uid"] != 0:
                return self._reply_acmp(a, "CONNECT_RX_RESPONSE", ACMP_LISTENER_UNKNOWN_ID)
            self._send_connect_tx(a, now, 1)
        elif name == "CONNECT_TX_RESPONSE" and a["listener"] == me and a["sequence_id"] in self.pending:
            cmd, _t, _tries = self.pending.pop(a["sequence_id"])
            if a["status"] != ACMP_SUCCESS:
                return self._reply_acmp(cmd, "CONNECT_RX_RESPONSE", a["status"])
            self.binding = {"stream_id": a["stream_id"], "dest_mac": bytes(a["dest_mac"]),
                            "vlan_id": a["vlan_id"] or self.vlan_id, "talker": a["talker"],
                            "talker_uid": a["talker_uid"], "controller": cmd["controller"]}
            self.log(f"avdecc: listener bound: stream {eui64_str(a['stream_id'])} "
                     f"-> {mac_str(a['dest_mac'])} vlan {self.binding['vlan_id']}")
            self.on_listener(dict(self.binding))
            self._reply_acmp(cmd, "CONNECT_RX_RESPONSE", ACMP_SUCCESS,
                             stream_id=a["stream_id"], dest_mac=a["dest_mac"],
                             connection_count=1, flags=a["flags"], vlan_id=a["vlan_id"])
            self.notify(CMD["GET_STREAM_INFO"],
                        struct.pack(">HH", M.STREAM_INPUT, 0) + self.stream_info(M.STREAM_INPUT))
        elif name == "DISCONNECT_RX_COMMAND" and a["listener"] == me:
            if not self.binding:
                return self._reply_acmp(a, "DISCONNECT_RX_RESPONSE", ACMP_NOT_CONNECTED)
            b = self.binding
            self.binding = None
            self.on_listener(None)
            dis = dict(a, stream_id=b["stream_id"], sequence_id=self._next_seq())
            self.send(ADP_ACMP_MAC, pack_acmp(ACMP["DISCONNECT_TX_COMMAND"], **acmp_args(dis)))
            self._reply_acmp(a, "DISCONNECT_RX_RESPONSE", ACMP_SUCCESS,
                             stream_id=b["stream_id"], dest_mac=b["dest_mac"],
                             connection_count=0)
            self.notify(CMD["GET_STREAM_INFO"],
                        struct.pack(">HH", M.STREAM_INPUT, 0) + self.stream_info(M.STREAM_INPUT))
        elif name == "GET_RX_STATE_COMMAND" and a["listener"] == me:
            if a["listener_uid"] != 0:
                return self._reply_acmp(a, "GET_RX_STATE_RESPONSE", ACMP_LISTENER_UNKNOWN_ID)
            b = self.binding
            if b:
                self._reply_acmp(a, "GET_RX_STATE_RESPONSE", ACMP_SUCCESS,
                                 stream_id=b["stream_id"], dest_mac=b["dest_mac"],
                                 talker=b["talker"], talker_uid=b["talker_uid"],
                                 connection_count=1, vlan_id=b["vlan_id"])
            else:
                self._reply_acmp(a, "GET_RX_STATE_RESPONSE", ACMP_SUCCESS,
                                 stream_id=0, dest_mac=b"\0" * 6, talker=0, talker_uid=0,
                                 connection_count=0, vlan_id=0)

        # ----- we are the talker
        elif name in ("CONNECT_TX_COMMAND", "DISCONNECT_TX_COMMAND", "GET_TX_STATE_COMMAND",
                      "GET_TX_CONNECTION_COMMAND") and a["talker"] == me:
            resp = name.replace("COMMAND", "RESPONSE")
            if a["talker_uid"] != 0:
                return self._reply_acmp(a, resp, ACMP_TALKER_UNKNOWN_ID)
            key = (a["listener"], a["listener_uid"])
            if name == "CONNECT_TX_COMMAND":
                if key not in self.tx_listeners:
                    self.tx_listeners.append(key)
                self.log(f"avdecc: talker connected to listener {eui64_str(key[0])}/{key[1]} "
                         f"({len(self.tx_listeners)} total)")
            elif name == "DISCONNECT_TX_COMMAND":
                if key in self.tx_listeners:
                    self.tx_listeners.remove(key)
            elif name == "GET_TX_CONNECTION_COMMAND":
                i = a["connection_count"]
                if i >= len(self.tx_listeners):
                    return self._reply_acmp(a, resp, ACMP_NO_SUCH_CONNECTION)
                lid, luid = self.tx_listeners[i]
                return self._reply_acmp(a, resp, ACMP_SUCCESS, stream_id=self.tx_stream_id,
                                        dest_mac=self.tx_dest_mac, listener=lid,
                                        listener_uid=luid,
                                        connection_count=len(self.tx_listeners),
                                        vlan_id=self.vlan_id)
            self._reply_acmp(a, resp, ACMP_SUCCESS, stream_id=self.tx_stream_id,
                             dest_mac=self.tx_dest_mac, connection_count=len(self.tx_listeners),
                             vlan_id=self.vlan_id,
                             flags=a["flags"] & ~0x0002)       # no fast connect
            if name in ("CONNECT_TX_COMMAND", "DISCONNECT_TX_COMMAND"):
                self.notify(CMD["GET_STREAM_INFO"], struct.pack(">HH", M.STREAM_OUTPUT, 0) +
                            self.stream_info(M.STREAM_OUTPUT))
