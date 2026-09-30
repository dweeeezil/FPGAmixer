#!/usr/bin/env python3
"""
Unit tests for the AVDECC entity (Phase 10): PDU and descriptor layouts
against jdksavdecc-c's offsets (written out here as numbers, independent of
the packing code), and the entity's behaviour driven as a controller would.
Runs anywhere:

    python3 -m unittest -v test_avdecc          (from tools/)
"""

import struct
import unittest

import avdecc_model as M
import avdecc_pdu as P
from avdecc_entity import Entity, STREAM_INFO_FLAGS, CONNECT_TX_TIMEOUT_S

MAC = bytes.fromhex("00183e050648")
EID = 0x00183EFFFE050648
MODEL_ID = 0x00183E0000000001
TX_SID = 0x00183E0506480000
TX_DEST = bytes.fromhex("91e0f000fe00")
CTRL = 0x1122334455667788
CTRL_B = 0x99AABBCCDDEEFF00
CTRL_MAC = bytes.fromhex("0a0b0c0d0e0f")
MAC_TALKER = 0x8C85900000000001        # a pretend Mac talker entity


class Harness:
    def __init__(self):
        self.sent = []
        self.bound = []
        self.formats = []
        self.m = M.Model(EID, MODEL_ID, MAC, entity_name="FPGAmixer")
        self.e = Entity(self.m, tx_stream_id=TX_SID, tx_dest_mac=TX_DEST, vlan_id=2,
                        send=lambda dst, pdu: self.sent.append((bytes(dst), pdu)),
                        on_listener=self.bound.append,
                        on_format=lambda d, f: self.formats.append((d, f)),
                        log=lambda s: None)

    def aem(self, cmd, payload, controller=CTRL, seq=7, now=0.0):
        pdu = P.pack_aem(P.AECP_AEM_COMMAND, 0, EID, controller, seq, P.CMD[cmd], payload)
        self.sent.clear()
        self.e.handle(CTRL_MAC, pdu, now)
        assert len(self.sent) == 1, self.sent
        dst, rpdu = self.sent[0]
        assert dst == CTRL_MAC
        return P.unpack_aecp(rpdu)

    def acmp(self, name, now=0.0, **kw):
        self.e.handle(CTRL_MAC, P.pack_acmp(P.ACMP[name], **kw), now)

    def acmp_sent(self):
        return [P.unpack_acmp(p) for d, p in self.sent if p[0] == P.SUBTYPE_ACMP]


class Layouts(unittest.TestCase):
    def test_header(self):
        h = P.pack_header(P.SUBTYPE_AECP, 1, 3, 40, 0x0102030405060708)
        self.assertEqual(h, bytes([0xFB, 0x01, (3 << 3) | 0, 40]) + bytes(range(1, 9)))
        self.assertEqual(P.unpack_header(h), (0xFB, 1, 3, 40, 0x0102030405060708))

    def test_adp(self):
        pdu = P.pack_adp(0, 10, EID, MODEL_ID, 0x508, 1, 0x4001, 1, 0x4001, 0,
                         0x01020304, 0x1111222233334444, 5)
        self.assertEqual(len(pdu), 12 + 56)                 # ADPDU_LEN
        self.assertEqual(pdu[0], 0xFA)
        self.assertEqual(pdu[2] >> 3, 10)                   # valid_time
        self.assertEqual(struct.unpack_from(">H", pdu, 2)[0] & 0x7FF, 56)
        self.assertEqual(struct.unpack_from(">Q", pdu, 4)[0], EID)
        self.assertEqual(struct.unpack_from(">Q", pdu, 12)[0], MODEL_ID)   # +0
        self.assertEqual(struct.unpack_from(">I", pdu, 20)[0], 0x508)      # +8 caps
        self.assertEqual(struct.unpack_from(">H", pdu, 26)[0], 0x4001)     # +14 talker caps
        self.assertEqual(struct.unpack_from(">I", pdu, 36)[0], 0x01020304) # +24 available_index
        self.assertEqual(struct.unpack_from(">Q", pdu, 40)[0], 0x1111222233334444)  # +28 gm
        self.assertEqual(pdu[48], 5)                                        # +36 domain

    def test_acmp(self):
        pdu = P.pack_acmp(6, status=0, stream_id=0xAABB, controller=1, talker=2, listener=3,
                          talker_uid=4, listener_uid=5, dest_mac=bytes(range(10, 16)),
                          connection_count=6, sequence_id=7, flags=8, vlan_id=9)
        self.assertEqual(len(pdu), 12 + 44)                 # ACMPDU_LEN
        self.assertEqual(pdu[1] & 0x0F, 6)
        self.assertEqual(pdu[40:46], bytes(range(10, 16)))  # +28 dest MAC
        self.assertEqual(struct.unpack_from(">HHHH", pdu, 46), (6, 7, 8, 9))  # +34..+40
        d = P.unpack_acmp(pdu)
        self.assertEqual((d["controller"], d["talker"], d["listener"], d["talker_uid"],
                          d["listener_uid"]), (1, 2, 3, 4, 5))

    def test_aem_command_type_offset(self):
        pdu = P.pack_aem(0, 0, EID, CTRL, 0x1234, 0x0004, b"\x00" * 8)
        self.assertEqual(struct.unpack_from(">QHH", pdu, 12), (CTRL, 0x1234, 0x0004))
        self.assertEqual(struct.unpack_from(">H", pdu, 2)[0] & 0x7FF, 12 + 8)


class Descriptors(unittest.TestCase):
    def setUp(self):
        self.m = M.Model(EID, MODEL_ID, MAC, entity_name="FPGAmixer", firmware="p10")

    def test_entity(self):
        d = self.m.descriptor(M.ENTITY, 0)
        self.assertEqual(len(d), 312)                                   # ..._ENTITY_LEN
        self.assertEqual(struct.unpack_from(">Q", d, 4)[0], EID)
        self.assertEqual(struct.unpack_from(">Q", d, 12)[0], MODEL_ID)
        self.assertEqual(struct.unpack_from(">HH", d, 24), (1, 0x4001))
        self.assertEqual(d[48:57], b"FPGAmixer")
        self.assertEqual(struct.unpack_from(">HH", d, 112), (0, 1))     # vendor, model strings
        self.assertEqual(d[116:119], b"p10")
        self.assertEqual(struct.unpack_from(">HH", d, 308), (1, 0))

    def test_configuration(self):
        d = self.m.descriptor(M.CONFIGURATION, 0)
        n, off = struct.unpack_from(">HH", d, 70)
        self.assertEqual(off, 74)
        self.assertEqual(len(d), 74 + 4 * n)
        counts = dict(struct.unpack_from(">HH", d, 74 + 4 * i) for i in range(n))
        self.assertEqual(counts[M.STREAM_INPUT], 1)
        self.assertEqual(counts[M.CLOCK_DOMAIN], 1)
        for t, c in counts.items():                                    # every one readable
            for i in range(c):
                self.assertIsNotNone(self.m.descriptor(t, i), (t, i))

    def test_audio_unit(self):
        d = self.m.descriptor(M.AUDIO_UNIT, 0)
        self.assertEqual(struct.unpack_from(">HHHH", d, 72), (1, 0, 1, 0))  # stream in/out ports
        self.assertEqual(struct.unpack_from(">I", d, 136)[0], 48000)
        self.assertEqual(struct.unpack_from(">HH", d, 140), (144, 1))
        self.assertEqual(struct.unpack_from(">I", d, 144)[0], 48000)

    def test_stream_formats(self):
        self.assertEqual(M.aaf_format("S24_3BE"), 0x0205031802006000)
        self.assertEqual(M.aaf_format("S32_BE"), 0x0205021802006000)
        self.assertEqual(M.decode_aaf_format(0x0205021802006000), ("S32_BE", 8, 5, 6))
        self.assertIsNone(M.decode_aaf_format(0x0205022002006000))       # depth 32: not ours
        self.assertIsNone(M.decode_aaf_format(0x00A0020840000800))       # 61883-6

    def test_stream(self):
        for t in (M.STREAM_INPUT, M.STREAM_OUTPUT):
            d = self.m.descriptor(t, 0)
            self.assertEqual(struct.unpack_from(">H", d, 72)[0] & M.STREAM_FLAG_CLASS_A, 2)
            cur = struct.unpack_from(">Q", d, 74)[0]
            off, n = struct.unpack_from(">HH", d, 82)
            self.assertEqual(n, 2)
            fmts = [struct.unpack_from(">Q", d, off + 8 * i)[0] for i in range(n)]
            self.assertEqual(fmts, [M.aaf_format("S24_3BE"), M.aaf_format("S32_BE")])
            self.assertIn(cur, fmts)
            self.assertEqual(len(d), off + 8 * n)
            self.assertEqual(struct.unpack_from(">I", d, 128)[0], 8_000_000)  # buffer_length

    def test_avb_interface(self):
        d = self.m.descriptor(M.AVB_INTERFACE, 0)
        self.assertEqual(len(d), 98)
        self.assertEqual(d[70:76], MAC)
        self.assertEqual(d[78:86], bytes.fromhex("00183efffe050648"))
        self.assertEqual(d[86], 250)                                     # priority1

    def test_small_descriptors(self):
        self.assertEqual(len(self.m.descriptor(M.CLOCK_SOURCE, 0)), 86)
        self.assertEqual(len(self.m.descriptor(M.LOCALE, 0)), 72)
        self.assertEqual(len(self.m.descriptor(M.STRINGS, 0)), 452)
        self.assertEqual(len(self.m.descriptor(M.STREAM_PORT_INPUT, 0)), 20)
        self.assertEqual(len(self.m.descriptor(M.AUDIO_CLUSTER, 15)), 87)
        self.assertIsNone(self.m.descriptor(M.AUDIO_CLUSTER, 16))
        cd = self.m.descriptor(M.CLOCK_DOMAIN, 0)
        self.assertEqual(struct.unpack_from(">HHHH", cd, 70), (0, 76, 1, 0))
        sp = self.m.descriptor(M.STREAM_PORT_OUTPUT, 0)
        self.assertEqual(struct.unpack_from(">HHHH", sp, 12), (8, 8, 1, 1))  # clusters, maps
        am = self.m.descriptor(M.AUDIO_MAP, 0)
        self.assertEqual(struct.unpack_from(">HH", am, 4), (8, 8))
        self.assertEqual(struct.unpack_from(">HHHH", am, 8 + 8 * 3), (0, 3, 3, 0))


class Behaviour(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.h.e.start(0.0)

    def test_advertise_and_discover(self):
        adps = [P.unpack_adp(p) for d, p in self.h.sent if p[0] == P.SUBTYPE_ADP]
        self.assertEqual(len(adps), 1)
        self.assertEqual(self.h.sent[0][0], P.ADP_ACMP_MAC)
        a = adps[0]
        self.assertEqual((a["entity_id"], a["model_id"], a["available_index"]), (EID, MODEL_ID, 0))
        self.assertEqual(a["talker_sources"], 1)
        self.h.sent.clear()
        disc = P.pack_adp(P.ADP_ENTITY_DISCOVER, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        self.h.e.handle(CTRL_MAC, disc, 1.0)
        self.assertEqual(P.unpack_adp(self.h.sent[0][1])["available_index"], 1)
        self.h.sent.clear()
        self.h.e.tick(1.5)
        self.assertEqual(self.h.sent, [])                      # not due yet
        self.h.e.tick(6.1)
        self.assertEqual(len(self.h.sent), 1)                  # re-advertised

    def test_gm_change_readvertises(self):
        self.h.sent.clear()
        self.h.e.set_gptp(0x507C6FFFFE8E405B)
        self.assertEqual(P.unpack_adp(self.h.sent[0][1])["gm_id"], 0x507C6FFFFE8E405B)

    def test_read_descriptor(self):
        r = self.h.aem("READ_DESCRIPTOR", struct.pack(">HHHH", 0, 0, M.ENTITY, 0))
        self.assertEqual((r["message_type"], r["status"], r["sequence_id"]), (1, 0, 7))
        self.assertEqual(len(r["payload"]), 4 + 312)
        self.assertEqual(struct.unpack_from(">Q", r["payload"], 4 + 4)[0], EID)
        r = self.h.aem("READ_DESCRIPTOR", struct.pack(">HHHH", 0, 0, M.STREAM_INPUT, 5))
        self.assertEqual(r["status"], P.AEM_NO_SUCH_DESCRIPTOR)

    def test_not_implemented(self):
        r = self.h.aem("GET_AUDIO_MAP", struct.pack(">HHHH", 0x99, 0, 0, 0))   # bad type
        self.assertEqual(r["status"], P.AEM_NO_SUCH_DESCRIPTOR)
        pdu = P.pack_aem(0, 0, EID, CTRL, 3, 0x0030, b"\x01\x02")           # REMOVE_VIDEO_MAPPINGS
        self.h.sent.clear()
        self.h.e.handle(CTRL_MAC, pdu, 0.0)
        r = P.unpack_aecp(self.h.sent[0][1])
        self.assertEqual((r["status"], r["command_type"], r["payload"]),
                         (P.AEM_NOT_IMPLEMENTED, 0x0030, b"\x01\x02"))
        # a vendor-unique command (e.g. Milan MVU): NOT_IMPLEMENTED, type + 1
        vu = P.pack_aecp_other(6, 0, EID, CTRL, 9, bytes.fromhex("001bc50ac100") + b"\0\0")
        self.h.sent.clear()
        self.h.e.handle(CTRL_MAC, vu, 0.0)
        r = P.unpack_aecp(self.h.sent[0][1])
        self.assertEqual((r["message_type"], r["status"], r["sequence_id"]), (7, 1, 9))
        # a command for another entity: ignored
        self.h.sent.clear()
        self.h.e.handle(CTRL_MAC, P.pack_aem(0, 0, EID + 1, CTRL, 3, 4, b"\0" * 8), 0.0)
        self.assertEqual(self.h.sent, [])

    def test_acquire_guards_set_stream_format(self):
        s32 = M.aaf_format("S32_BE")
        r = self.h.aem("ACQUIRE_ENTITY", struct.pack(">IQHH", 0, 0, M.ENTITY, 0))
        self.assertEqual(r["status"], 0)
        self.assertEqual(struct.unpack_from(">Q", r["payload"], 4)[0], CTRL)
        r = self.h.aem("SET_STREAM_FORMAT", struct.pack(">HHQ", M.STREAM_INPUT, 0, s32),
                       controller=CTRL_B)
        self.assertEqual(r["status"], P.AEM_ENTITY_ACQUIRED)
        self.assertEqual(self.h.formats, [])
        r = self.h.aem("SET_STREAM_FORMAT", struct.pack(">HHQ", M.STREAM_INPUT, 0, s32))
        self.assertEqual(r["status"], 0)
        self.assertEqual(self.h.formats, [(M.STREAM_INPUT, "S32_BE")])
        r = self.h.aem("GET_STREAM_FORMAT", struct.pack(">HH", M.STREAM_INPUT, 0))
        self.assertEqual(struct.unpack_from(">Q", r["payload"], 4)[0], s32)
        r = self.h.aem("SET_STREAM_FORMAT", struct.pack(">HHQ", M.STREAM_INPUT, 0,
                                                        0x00A0020840000800))
        self.assertEqual(r["status"], P.AEM_NOT_SUPPORTED)
        r = self.h.aem("ACQUIRE_ENTITY", struct.pack(">IQHH", P.ACQUIRE_FLAG_RELEASE, 0,
                                                     M.ENTITY, 0), controller=CTRL_B)
        self.assertEqual(r["status"], P.AEM_ENTITY_ACQUIRED)
        r = self.h.aem("ACQUIRE_ENTITY", struct.pack(">IQHH", P.ACQUIRE_FLAG_RELEASE, 0,
                                                     M.ENTITY, 0))
        self.assertEqual(r["status"], 0)

    def test_lock_expires(self):
        r = self.h.aem("LOCK_ENTITY", struct.pack(">IQHH", 0, 0, M.ENTITY, 0), now=0.0)
        self.assertEqual(r["status"], 0)
        name = struct.pack(">HHHH", M.ENTITY, 0, 0, 0) + M.s64("Stage")
        r = self.h.aem("SET_NAME", name, controller=CTRL_B, now=10.0)
        self.assertEqual(r["status"], P.AEM_ENTITY_LOCKED)
        r = self.h.aem("SET_NAME", name, controller=CTRL_B, now=61.0)
        self.assertEqual(r["status"], 0)
        r = self.h.aem("GET_NAME", struct.pack(">HHHH", M.ENTITY, 0, 0, 0))
        self.assertEqual(r["payload"][8:13], b"Stage")

    def test_misc_getters(self):
        r = self.h.aem("GET_SAMPLING_RATE", struct.pack(">HH", M.AUDIO_UNIT, 0))
        self.assertEqual(struct.unpack_from(">I", r["payload"], 4)[0], 48000)
        r = self.h.aem("GET_AVB_INFO", struct.pack(">HH", M.AVB_INTERFACE, 0))
        self.assertEqual(len(r["payload"]), 4 + 16 + 4)
        self.assertEqual(struct.unpack_from(">BBH", r["payload"], 20), (6, 3, 2))
        r = self.h.aem("GET_COUNTERS", struct.pack(">HH", M.AVB_INTERFACE, 0))
        self.assertEqual(len(r["payload"]), 4 + 4 + 128)
        r = self.h.aem("GET_AUDIO_MAP", struct.pack(">HHHH", M.STREAM_PORT_INPUT, 0, 0, 0))
        self.assertEqual(struct.unpack_from(">HHHH", r["payload"], 4), (0, 1, 8, 0))
        r = self.h.aem("GET_AS_PATH", struct.pack(">HH", 0, 0))
        self.assertEqual(struct.unpack_from(">H", r["payload"], 2)[0], 1)

    def test_listener_connect(self):
        h = self.h
        h.aem("REGISTER_UNSOLICITED_NOTIFICATION", b"")
        h.sent.clear()
        h.acmp("CONNECT_RX_COMMAND", controller=CTRL, talker=MAC_TALKER, listener=EID,
               sequence_id=0x55)
        tx = h.acmp_sent()
        self.assertEqual(len(tx), 1)
        self.assertEqual(tx[0]["message_type"], P.ACMP["CONNECT_TX_COMMAND"])
        self.assertEqual((tx[0]["talker"], tx[0]["listener"], tx[0]["controller"]),
                         (MAC_TALKER, EID, CTRL))
        our_seq = tx[0]["sequence_id"]
        h.sent.clear()
        mac_dest = bytes.fromhex("91e0f0001234")
        h.acmp("CONNECT_TX_RESPONSE", stream_id=0x8C8590000001ABCD, controller=CTRL,
               talker=MAC_TALKER, listener=EID, dest_mac=mac_dest, connection_count=1,
               sequence_id=our_seq, vlan_id=2)
        self.assertEqual(h.bound[-1]["stream_id"], 0x8C8590000001ABCD)
        self.assertEqual(h.bound[-1]["dest_mac"], mac_dest)
        rx = h.acmp_sent()
        self.assertEqual(rx[0]["message_type"], P.ACMP["CONNECT_RX_RESPONSE"])
        self.assertEqual((rx[0]["status"], rx[0]["sequence_id"], rx[0]["stream_id"]),
                         (0, 0x55, 0x8C8590000001ABCD))
        # an unsolicited GET_STREAM_INFO went to the registered controller
        uns = [P.unpack_aecp(p) for d, p in h.sent if p[0] == P.SUBTYPE_AECP]
        self.assertTrue(uns and uns[0]["unsolicited"] and uns[0]["command_type"] == 0x000F)
        r = h.aem("GET_STREAM_INFO", struct.pack(">HH", M.STREAM_INPUT, 0))
        flags = struct.unpack_from(">I", r["payload"], 4)[0]
        self.assertTrue(flags & STREAM_INFO_FLAGS["CONNECTED"])
        self.assertEqual(struct.unpack_from(">Q", r["payload"], 16)[0], 0x8C8590000001ABCD)
        self.assertEqual(r["payload"][28:34], mac_dest)           # 4+4+8+8+4
        # get rx state, then disconnect
        h.sent.clear()
        h.acmp("GET_RX_STATE_COMMAND", listener=EID, controller=CTRL, sequence_id=3)
        st = h.acmp_sent()[0]
        self.assertEqual((st["connection_count"], st["talker"]), (1, MAC_TALKER))
        h.sent.clear()
        h.acmp("DISCONNECT_RX_COMMAND", listener=EID, talker=MAC_TALKER, controller=CTRL,
               sequence_id=4)
        self.assertIsNone(h.bound[-1])
        names = [P.ACMP_NAME[a["message_type"]] for a in h.acmp_sent()]
        self.assertIn("DISCONNECT_TX_COMMAND", names)
        self.assertIn("DISCONNECT_RX_RESPONSE", names)

    def test_listener_talker_timeout(self):
        h = self.h
        h.sent.clear()
        h.acmp("CONNECT_RX_COMMAND", controller=CTRL, talker=MAC_TALKER, listener=EID,
               sequence_id=0x66, now=0.0)
        h.sent.clear()
        h.e.tick(CONNECT_TX_TIMEOUT_S + 0.1)
        self.assertEqual([P.ACMP_NAME[a["message_type"]] for a in h.acmp_sent()],
                         ["CONNECT_TX_COMMAND"])                  # retried once
        h.sent.clear()
        h.e.tick(2 * CONNECT_TX_TIMEOUT_S + 0.3)
        a = h.acmp_sent()
        self.assertEqual(P.ACMP_NAME[a[0]["message_type"]], "CONNECT_RX_RESPONSE")
        self.assertEqual((a[0]["status"], a[0]["sequence_id"]), (P.ACMP_LISTENER_TALKER_TIMEOUT, 0x66))
        self.assertEqual(h.bound, [])

    def test_talker_connect(self):
        h = self.h
        h.sent.clear()
        h.acmp("CONNECT_TX_COMMAND", controller=CTRL, talker=EID, listener=MAC_TALKER,
               sequence_id=0x10)
        r = h.acmp_sent()[0]
        self.assertEqual(P.ACMP_NAME[r["message_type"]], "CONNECT_TX_RESPONSE")
        self.assertEqual((r["status"], r["stream_id"], r["dest_mac"], r["connection_count"],
                          r["vlan_id"], r["sequence_id"]),
                         (0, TX_SID, TX_DEST, 1, 2, 0x10))
        h.sent.clear()
        h.acmp("GET_TX_CONNECTION_COMMAND", talker=EID, controller=CTRL, connection_count=0)
        self.assertEqual(h.acmp_sent()[0]["listener"], MAC_TALKER)
        h.sent.clear()
        h.acmp("GET_TX_CONNECTION_COMMAND", talker=EID, controller=CTRL, connection_count=1)
        self.assertEqual(h.acmp_sent()[0]["status"], P.ACMP_NO_SUCH_CONNECTION)
        h.sent.clear()
        h.acmp("DISCONNECT_TX_COMMAND", controller=CTRL, talker=EID, listener=MAC_TALKER)
        self.assertEqual(h.acmp_sent()[0]["connection_count"], 0)
        h.sent.clear()
        h.acmp("CONNECT_TX_COMMAND", talker=EID, talker_uid=3)
        self.assertEqual(h.acmp_sent()[0]["status"], P.ACMP_TALKER_UNKNOWN_ID)

    def test_other_entities_acmp_ignored(self):
        h = self.h
        h.sent.clear()
        h.acmp("CONNECT_RX_COMMAND", controller=CTRL, talker=EID, listener=MAC_TALKER)
        h.acmp("CONNECT_TX_RESPONSE", listener=MAC_TALKER, sequence_id=1)
        self.assertEqual(h.sent, [])


if __name__ == "__main__":
    unittest.main()
