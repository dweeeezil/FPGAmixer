#!/usr/bin/env python3
"""
IEEE 1722.1 (AVDECC) PDUs: ADP, AECP (AEM) and ACMP, packed and unpacked.
No I/O, no state: avdecc_entity.py uses these, the tests check them.

Layouts: IEEE 1722.1-2013 as encoded by jdksavdecc-c (include/jdksavdecc_adp.h,
_acmp.h, _aecp_aem.h, _aem_command.h; offsets quoted in the comments), cross-
checked against OpenAvnu's avtp_pipeline where they overlap. All fields are
big-endian. The AVTP control header (12 bytes) is common to all three:

    byte 0     subtype (0xFA ADP, 0xFB AECP, 0xFC ACMP)
    byte 1     sv(1) | version(3) | message_type(4)
    bytes 2-3  status (5 bits; ADP: valid_time) | control_data_length (11 bits)
    bytes 4-11 stream_id (ADP: entity_id; AECP: target_entity_id)

Phase 10, docs/phase10_status_2026-09-29.md.
"""

import struct

AVTP_ETHERTYPE = 0x22F0
ADP_ACMP_MAC = bytes.fromhex("91e0f0010000")     # 1722.1 Annex B.1

SUBTYPE_ADP = 0xFA
SUBTYPE_AECP = 0xFB
SUBTYPE_ACMP = 0xFC

HDR = struct.Struct(">BBHQ")


def pack_header(subtype, message_type, status, cdl, stream_id):
    return HDR.pack(subtype, message_type & 0x0F,
                    ((status & 0x1F) << 11) | (cdl & 0x7FF), stream_id)


def unpack_header(pdu):
    """(subtype, message_type, status, control_data_length, stream_id)"""
    subtype, b1, w, sid = HDR.unpack_from(pdu, 0)
    return subtype, b1 & 0x0F, w >> 11, w & 0x7FF, sid


# ------------------------------------------------------------------- ADP

ADP_ENTITY_AVAILABLE = 0
ADP_ENTITY_DEPARTING = 1
ADP_ENTITY_DISCOVER = 2
ADP_CDL = 56

# entity_capabilities (jdksavdecc_adp.h values)
CAP_AEM_SUPPORTED = 0x00000008
CAP_CLASS_A_SUPPORTED = 0x00000100
CAP_GPTP_SUPPORTED = 0x00000400
CAP_AEM_INTERFACE_INDEX_VALID = 0x00008000
# talker / listener capabilities
TALKER_IMPLEMENTED = 0x0001
TALKER_AUDIO_SOURCE = 0x4000
LISTENER_IMPLEMENTED = 0x0001
LISTENER_AUDIO_SINK = 0x4000

# after the 12-byte header: model_id 8, entity_capabilities 4, talker_stream
# _sources 2, talker_capabilities 2, listener_stream_sinks 2, listener_
# capabilities 2, controller_capabilities 4, available_index 4, gptp_
# grandmaster_id 8, gptp_domain_number 1, reserved 3, identify_control_index
# 2, interface_index 2, association_id 8, reserved 4  (= 56)
ADP_BODY = struct.Struct(">QIHHHHIIQB3sHHQ4s")
assert ADP_BODY.size == ADP_CDL


def pack_adp(message_type, valid_time, entity_id, model_id, caps, talker_sources,
             talker_caps, listener_sinks, listener_caps, controller_caps,
             available_index, gm_id, domain, identify_control_index=0,
             interface_index=0, association_id=0):
    return (pack_header(SUBTYPE_ADP, message_type, valid_time, ADP_CDL, entity_id) +
            ADP_BODY.pack(model_id, caps, talker_sources, talker_caps, listener_sinks,
                          listener_caps, controller_caps, available_index, gm_id,
                          domain, b"\0" * 3, identify_control_index, interface_index,
                          association_id, b"\0" * 4))


def unpack_adp(pdu):
    subtype, mt, valid_time, cdl, entity_id = unpack_header(pdu)
    f = ADP_BODY.unpack_from(pdu, 12)
    return {"message_type": mt, "valid_time": valid_time, "entity_id": entity_id,
            "model_id": f[0], "caps": f[1], "talker_sources": f[2], "talker_caps": f[3],
            "listener_sinks": f[4], "listener_caps": f[5], "controller_caps": f[6],
            "available_index": f[7], "gm_id": f[8], "domain": f[9]}


# ------------------------------------------------------------------ AECP

AECP_AEM_COMMAND = 0
AECP_AEM_RESPONSE = 1
AECP_UNSOLICITED = 0x8000          # the u bit, top of command_type

# AEM command types (jdksavdecc_aem_command.h)
CMD = {
    "ACQUIRE_ENTITY": 0x0000, "LOCK_ENTITY": 0x0001, "ENTITY_AVAILABLE": 0x0002,
    "CONTROLLER_AVAILABLE": 0x0003, "READ_DESCRIPTOR": 0x0004,
    "SET_CONFIGURATION": 0x0006, "GET_CONFIGURATION": 0x0007,
    "SET_STREAM_FORMAT": 0x0008, "GET_STREAM_FORMAT": 0x0009,
    "SET_STREAM_INFO": 0x000E, "GET_STREAM_INFO": 0x000F,
    "SET_NAME": 0x0010, "GET_NAME": 0x0011,
    "SET_SAMPLING_RATE": 0x0014, "GET_SAMPLING_RATE": 0x0015,
    "SET_CLOCK_SOURCE": 0x0016, "GET_CLOCK_SOURCE": 0x0017,
    "START_STREAMING": 0x0022, "STOP_STREAMING": 0x0023,
    "REGISTER_UNSOLICITED_NOTIFICATION": 0x0024,
    "DEREGISTER_UNSOLICITED_NOTIFICATION": 0x0025,
    "IDENTIFY_NOTIFICATION": 0x0026,
    "GET_AVB_INFO": 0x0027, "GET_AS_PATH": 0x0028, "GET_COUNTERS": 0x0029,
    "GET_AUDIO_MAP": 0x002B,
    # 1722.1-2021 (codes from la_avdecc src/protocol/protocolDefines.cpp;
    # payloads: descriptor type 2, index 2, max_transit_time 8 (ns)). macOS
    # sends these right after connecting (bench, 2026-09-30).
    "GET_DYNAMIC_INFO": 0x004B,
    "SET_MAX_TRANSIT_TIME": 0x004C,
    "GET_MAX_TRANSIT_TIME": 0x004D,
}
CMD_NAME = {v: k for k, v in CMD.items()}

# AEM status
AEM_SUCCESS = 0
AEM_NOT_IMPLEMENTED = 1
AEM_NO_SUCH_DESCRIPTOR = 2
AEM_ENTITY_LOCKED = 3
AEM_ENTITY_ACQUIRED = 4
AEM_BAD_ARGUMENTS = 7
AEM_NOT_SUPPORTED = 11
AEM_STREAM_IS_RUNNING = 12

ACQUIRE_FLAG_PERSISTENT = 0x00000001
ACQUIRE_FLAG_RELEASE = 0x80000000
LOCK_FLAG_UNLOCK = 0x00000001


def unpack_aecp(pdu):
    """AECP common part + AEM command type. For an AEM command/response,
    'payload' is everything after command_type (the command-specific data)."""
    subtype, mt, status, cdl, target = unpack_header(pdu)
    controller, seq = struct.unpack_from(">QH", pdu, 12)
    d = {"message_type": mt, "status": status, "cdl": cdl, "target": target,
         "controller": controller, "sequence_id": seq}
    end = 12 + cdl
    if mt in (AECP_AEM_COMMAND, AECP_AEM_RESPONSE) and cdl >= 12:
        ct = struct.unpack_from(">H", pdu, 22)[0]
        d["unsolicited"] = bool(ct & AECP_UNSOLICITED)
        d["command_type"] = ct & 0x7FFF
        d["payload"] = bytes(pdu[24:end])
    else:
        d["payload"] = bytes(pdu[22:end])       # after sequence_id
    return d


def pack_aem(message_type, status, target, controller, seq, command_type, payload,
             unsolicited=False):
    cdl = 8 + 2 + 2 + len(payload)
    ct = (command_type & 0x7FFF) | (AECP_UNSOLICITED if unsolicited else 0)
    return (pack_header(SUBTYPE_AECP, message_type, status, cdl, target) +
            struct.pack(">QHH", controller, seq, ct) + payload)


def pack_aecp_other(message_type, status, target, controller, seq, rest):
    """Any non-AEM AECP message (e.g. a NOT_IMPLEMENTED answer to a vendor-
    unique command): header, controller id, sequence id, then `rest`."""
    cdl = 8 + 2 + len(rest)
    return (pack_header(SUBTYPE_AECP, message_type, status, cdl, target) +
            struct.pack(">QH", controller, seq) + rest)


# ------------------------------------------------------------------ ACMP

ACMP = {
    "CONNECT_TX_COMMAND": 0, "CONNECT_TX_RESPONSE": 1,
    "DISCONNECT_TX_COMMAND": 2, "DISCONNECT_TX_RESPONSE": 3,
    "GET_TX_STATE_COMMAND": 4, "GET_TX_STATE_RESPONSE": 5,
    "CONNECT_RX_COMMAND": 6, "CONNECT_RX_RESPONSE": 7,
    "DISCONNECT_RX_COMMAND": 8, "DISCONNECT_RX_RESPONSE": 9,
    "GET_RX_STATE_COMMAND": 10, "GET_RX_STATE_RESPONSE": 11,
    "GET_TX_CONNECTION_COMMAND": 12, "GET_TX_CONNECTION_RESPONSE": 13,
}
ACMP_NAME = {v: k for k, v in ACMP.items()}

ACMP_SUCCESS = 0
ACMP_LISTENER_UNKNOWN_ID = 1
ACMP_TALKER_UNKNOWN_ID = 2
ACMP_LISTENER_TALKER_TIMEOUT = 7
ACMP_NOT_CONNECTED = 10
ACMP_NO_SUCH_CONNECTION = 11
ACMP_NOT_SUPPORTED = 31

ACMP_FLAG_CLASS_B = 0x0001
ACMP_FLAG_FAST_CONNECT = 0x0002
ACMP_FLAG_SAVED_STATE = 0x0004
ACMP_FLAG_STREAMING_WAIT = 0x0008

ACMP_CDL = 44
# after the header (stream_id in it): controller 8, talker 8, listener 8,
# talker_unique_id 2, listener_unique_id 2, stream_dest_mac 6,
# connection_count 2, sequence_id 2, flags 2, stream_vlan_id 2, reserved 2
ACMP_BODY = struct.Struct(">QQQHH6sHHHH2s")
assert ACMP_BODY.size == ACMP_CDL

ACMP_FIELDS = ("controller", "talker", "listener", "talker_uid", "listener_uid",
               "dest_mac", "connection_count", "sequence_id", "flags", "vlan_id")


def pack_acmp(message_type, status=0, stream_id=0, controller=0, talker=0, listener=0,
              talker_uid=0, listener_uid=0, dest_mac=b"\0" * 6, connection_count=0,
              sequence_id=0, flags=0, vlan_id=0):
    return (pack_header(SUBTYPE_ACMP, message_type, status, ACMP_CDL, stream_id) +
            ACMP_BODY.pack(controller, talker, listener, talker_uid, listener_uid,
                           bytes(dest_mac), connection_count, sequence_id, flags,
                           vlan_id, b"\0\0"))


def unpack_acmp(pdu):
    subtype, mt, status, cdl, sid = unpack_header(pdu)
    f = ACMP_BODY.unpack_from(pdu, 12)
    d = {"message_type": mt, "status": status, "stream_id": sid}
    d.update(zip(ACMP_FIELDS, f[:10]))
    return d


def acmp_args(d):
    """The keyword arguments of pack_acmp from an unpacked ACMP dict."""
    return {k: d[k] for k in ("status", "stream_id") + ACMP_FIELDS}


# --------------------------------------------------------------- frames

def eth_frame(dst, src, payload, ethertype=AVTP_ETHERTYPE):
    """An Ethernet frame, padded to the 60-byte minimum (without FCS)."""
    f = bytes(dst) + bytes(src) + struct.pack(">H", ethertype) + payload
    return f + b"\0" * max(0, 60 - len(f))


def mac_str(b):
    return ":".join(f"{x:02x}" for x in b)


def eui64_str(v):
    return f"{v:016x}"
