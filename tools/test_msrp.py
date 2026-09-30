#!/usr/bin/env python3
"""
Unit tests for msrp.py (Phase 10): encodings checked byte by byte against
802.1Q / mrpd's layout (written out here, independent of the encoder),
decode of multi-value vectors and LeaveAll, and the Declarer. Runs anywhere:

    python3 -m unittest -v test_msrp          (from tools/)
"""

import struct
import unittest

import msrp

SID = 0x00183E0506480000
DEST = bytes.fromhex("91e0f000fe00")


class Encoding(unittest.TestCase):
    def test_talker_value(self):
        v = msrp.talker_value(SID, DEST, 2, 168, 1, 3, 1, 500000)
        self.assertEqual(len(v), 25)
        self.assertEqual(v[:8], SID.to_bytes(8, "big"))
        self.assertEqual(v[8:14], DEST)
        self.assertEqual(struct.unpack_from(">HHH", v, 14), (2, 168, 1))
        self.assertEqual(v[20], 0x70)                  # priority 3 << 5 | rank 1 << 4
        self.assertEqual(struct.unpack_from(">I", v, 21)[0], 500000)

    def test_domain_message_bytes(self):
        pdu = msrp.encode_msrp([(msrp.DOMAIN, msrp.domain_value(6, 3, 2), msrp.JOININ, None)])
        want = (bytes([0]) +                            # ProtocolVersion
                bytes([4, 4]) + struct.pack(">H", 2 + 4 + 1 + 2) +   # type, len, list len
                struct.pack(">H", 1) + bytes([6, 3, 0, 2]) + bytes([36]) +  # 1 value, JoinIn
                b"\0\0" +                               # EndMark (vectors)
                b"\0\0")                                # EndMark (messages)
        self.assertEqual(pdu, want)

    def test_listener_four_packed(self):
        pdu = msrp.encode_msrp([(msrp.LISTENER, SID.to_bytes(8, "big"), msrp.JOININ, msrp.READY)])
        # ver, type 3, len 8, list len, header, value 8, 3pack, 4pack, endmark, endmark
        self.assertEqual(pdu[1:3], bytes([3, 8]))
        self.assertEqual(struct.unpack_from(">H", pdu, 3)[0], 2 + 8 + 1 + 1 + 2)
        self.assertEqual(pdu[5:7], b"\x00\x01")
        self.assertEqual(pdu[15], 36)                   # JoinIn
        self.assertEqual(pdu[16], 2 * 64)               # Ready in the first slot

    def test_mvrp(self):
        pdu = msrp.encode_mvrp([2])
        self.assertEqual(pdu, bytes([0, 1, 2]) + struct.pack(">HH", 1, 2) + bytes([36]) +
                         b"\0\0\0\0")

    def test_roundtrip(self):
        t = msrp.talker_value(SID, DEST, 2, 216, 1, 3, 1, 125000)
        pdu = msrp.encode_msrp([
            (msrp.DOMAIN, msrp.domain_value(), msrp.JOININ, None),
            (msrp.TALKER_ADVERTISE, t, msrp.JOININ, None),
            (msrp.LISTENER, (SID + 5).to_bytes(8, "big"), msrp.LV, msrp.READY),
        ])
        got = msrp.decode(pdu)
        self.assertEqual([(a, v, e, f) for a, lva, v, e, f in got], [
            (msrp.TALKER_ADVERTISE, t, msrp.JOININ, None),
            (msrp.LISTENER, (SID + 5).to_bytes(8, "big"), msrp.LV, msrp.READY),
            (msrp.DOMAIN, msrp.domain_value(), msrp.JOININ, None),
        ])
        self.assertFalse(any(lva for _, lva, *_ in got))
        self.assertEqual(msrp.parse_talker(t)["max_frame"], 216)

    def test_decode_multi_value_vector_and_leave_all(self):
        # 4 listener values in one vector: events JoinIn, In, Mt, Lv;
        # four-packed Ready, AskingFailed, Ready, Ignore; LeaveAll set
        first = SID.to_bytes(8, "big")
        vec = (struct.pack(">H", msrp.LVA | 4) + first +
               bytes([(1 * 6 + 2) * 6 + 4, 5 * 36]) +          # 3-packed: 1,2,4 | 5,0,0
               bytes([2 * 64 + 1 * 16 + 2 * 4 + 0]))          # 4-packed
        body = vec + b"\0\0"
        pdu = bytes([0, 3, 8]) + struct.pack(">H", len(body)) + body + b"\0\0"
        got = msrp.decode(pdu)
        self.assertEqual(len(got), 4)
        self.assertTrue(all(g[1] for g in got))                  # LeaveAll
        self.assertEqual([int.from_bytes(g[2], "big") - SID for g in got], [0, 1, 2, 3])
        self.assertEqual([g[3] for g in got], [msrp.JOININ, msrp.IN, msrp.MT, msrp.LV])
        self.assertEqual([g[4] for g in got], [msrp.READY, msrp.ASKING_FAILED, msrp.READY,
                                               msrp.IGNORE])

    def test_talker_values_increment_mac_too(self):
        t = msrp.talker_value(SID, DEST, 2, 168)
        self.assertEqual(msrp._increment(t, msrp.TALKER_ADVERTISE, 2)[8:14],
                         bytes.fromhex("91e0f000fe02"))


class Declarer(unittest.TestCase):
    def setUp(self):
        self.d = msrp.Declarer(log=lambda s: None)

    def test_declares_and_withdraws(self):
        t = msrp.talker_value(SID, DEST, 2, 168)
        self.d.set_talker(t)
        self.d.set_listener(0xAAAA)
        self.assertTrue(self.d.due(0.0))
        got = {(a, v): e for a, lva, v, e, f in msrp.decode(self.d.msrp_pdu(0.0))}
        self.assertEqual(got[(msrp.TALKER_ADVERTISE, t)], msrp.JOININ)
        self.assertEqual(got[(msrp.LISTENER, (0xAAAA).to_bytes(8, "big"))], msrp.JOININ)
        self.assertIn((msrp.DOMAIN, msrp.domain_value()), got)
        self.assertFalse(self.d.due(0.5))
        self.assertTrue(self.d.due(1.0))
        self.d.set_listener(0xBBBB)                               # rebind: old one leaves
        self.assertTrue(self.d.due(0.5))
        got = {(a, v): e for a, lva, v, e, f in msrp.decode(self.d.msrp_pdu(0.5))}
        self.assertEqual(got[(msrp.LISTENER, (0xAAAA).to_bytes(8, "big"))], msrp.LV)
        self.assertEqual(got[(msrp.LISTENER, (0xBBBB).to_bytes(8, "big"))], msrp.JOININ)
        got = {(a, v) for a, lva, v, e, f in msrp.decode(self.d.msrp_pdu(1.5))}
        self.assertNotIn((msrp.LISTENER, (0xAAAA).to_bytes(8, "big")), got)   # Lv sent once

    def test_registers_peer_and_leave_all(self):
        peer_t = msrp.talker_value(0x8C85900000010000, bytes.fromhex("91e0f0001234"), 2, 216,
                                   latency_ns=320000)
        pdu = msrp.encode_msrp([(msrp.TALKER_ADVERTISE, peer_t, msrp.JOININ, None),
                                (msrp.LISTENER, SID.to_bytes(8, "big"), msrp.JOININ, msrp.READY)])
        self.d.next_tx = 99.0
        self.assertFalse(self.d.handle_msrp(pdu, 10.0))
        self.assertEqual(self.d.talker_latency(0x8C85900000010000), 320000)
        self.assertEqual(self.d.reg_listeners[SID][0], msrp.READY)
        self.assertFalse(self.d.due(10.0))
        la = msrp.encode_msrp([(msrp.DOMAIN, msrp.domain_value(), msrp.JOININ, None)],
                              leave_all=True)
        self.assertTrue(self.d.handle_msrp(la, 11.0))
        self.assertTrue(self.d.due(11.0))                          # re-declare at once
        lv = msrp.encode_msrp([(msrp.TALKER_ADVERTISE, peer_t, msrp.LV, None)])
        self.d.handle_msrp(lv, 12.0)
        self.assertIsNone(self.d.talker_latency(0x8C85900000010000))
        self.d.expire(10.0 + msrp.Declarer.EXPIRE_S + 1)
        self.assertNotIn(SID, self.d.reg_listeners)


if __name__ == "__main__":
    unittest.main()
