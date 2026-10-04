#!/usr/bin/env python3
"""
Unit tests for osc_codec.py: wire format, packets and bundles, both TCP
framings, and the client link. Standard library only.

    python3 -m unittest -v test_osc_codec        (from tools/)
"""

import socket
import struct
import unittest

import osc_codec
from osc_codec import (FramingLost, Len32Framer, OSCIncomplete, OSCMalformed, TCPLink,
                       UnframedFramer, decode_message, decode_packet, encode_bundle,
                       encode_message, make_framer, osc_string)

SET = "/mixer/set/inputMatrix/0_1/level"


class WireFormat(unittest.TestCase):
    def test_round_trip_every_encodable_type(self):
        args = [-6.0, 7, "FOHmixer", b"\x00\x01\x02", b"", "é"]
        msg, used = decode_message(encode_message(SET, args))
        self.assertEqual(msg.address, SET)
        self.assertEqual(msg.args, args)
        self.assertEqual(used, len(encode_message(SET, args)))

    def test_every_field_is_4_byte_aligned(self):
        for args in ([], [1.0], ["a"], ["abcd"], [b"x"], [b"wxyz"]):
            self.assertEqual(len(encode_message("/a", args)) % 4, 0, args)

    def test_decodes_tags_controllers_send(self):
        """T F N I h d have no encoder here but must decode (controller D21)."""
        data = (osc_string("/x") + osc_string(",TFNIhdi") + struct.pack(">q", -2)
                + struct.pack(">d", 0.5) + struct.pack(">i", 3))
        msg, used = decode_message(data)
        self.assertEqual(msg.args, [True, False, None, float("inf"), -2, 0.5, 3])
        self.assertEqual(used, len(data))

    def test_every_truncation_is_incomplete_not_malformed(self):
        full = encode_message(SET, [-6.0, "name", b"blob!"])
        for cut in range(len(full)):
            with self.assertRaises(OSCIncomplete, msg=f"cut at {cut}"):
                decode_message(full[:cut])

    def test_malformed(self):
        for data in (osc_string("noslash") + osc_string(","),
                     osc_string("/x") + osc_string("f"),
                     osc_string("/x") + osc_string(",z") + b"\0\0\0\0",
                     osc_string("/x") + osc_string(",b") + struct.pack(">i", -1),
                     b"/" + b"a" * 2000):
            with self.assertRaises(OSCMalformed, msg=repr(data[:24])):
                decode_message(data)

    def test_bundle_where_a_message_is_expected(self):
        with self.assertRaisesRegex(OSCMalformed, "bundle"):
            decode_message(encode_bundle([encode_message("/a")]))


class Packets(unittest.TestCase):
    def test_message_packet(self):
        self.assertEqual([m.args for m in decode_packet(encode_message(SET, [1.0]))], [[1.0]])

    def test_bundle_in_order_with_nesting(self):
        inner = encode_bundle([encode_message("/b", [2]), encode_message("/c", [3])])
        packet = encode_bundle([encode_message("/a", [1]), inner, encode_message("/d", [4])])
        self.assertEqual([m.address for m in decode_packet(packet)], ["/a", "/b", "/c", "/d"])

    def test_empty_bundle(self):
        self.assertEqual(decode_packet(encode_bundle([])), [])

    def test_truncated_message_packet_is_malformed(self):
        with self.assertRaisesRegex(OSCMalformed, "truncated"):
            decode_packet(osc_string(SET) + osc_string(",f") + b"\0\0")

    def test_trailing_bytes_are_malformed(self):
        """A packet is one message or one bundle, never two messages."""
        with self.assertRaisesRegex(OSCMalformed, "after the message"):
            decode_packet(encode_message("/a", [1]) + encode_message("/b", [2]))

    def test_bad_bundle_element_sizes(self):
        good = encode_message("/a", [1])
        head = osc_codec.BUNDLE_TAG + struct.pack(">Q", 1)
        for packet, reason in (
                (head[:12], "header"),                                         # header cut short
                (head + struct.pack(">i", len(good) + 4) + good, "size"),      # size past the end
                (head + struct.pack(">i", 0), "size 0"),                        # empty element
                (head + struct.pack(">i", 6) + good[:6], "size 6"),            # not a multiple of 4
                (head + b"\0\0", "cut short")):                                 # size cut short
            with self.assertRaisesRegex(OSCMalformed, reason, msg=repr(packet)):
                decode_packet(packet)

    def test_bad_message_inside_a_bundle_drops_the_bundle(self):
        bad = osc_string("/x") + osc_string(",z") + b"\0\0\0\0"
        with self.assertRaises(OSCMalformed):
            decode_packet(encode_bundle([encode_message("/a", [1]), bad]))

    def test_nesting_limit(self):
        packet = encode_message("/a")
        for _ in range(12):
            packet = encode_bundle([packet])
        with self.assertRaisesRegex(OSCMalformed, "deep"):
            decode_packet(packet)


class Len32(unittest.TestCase):
    def packets(self, n=3):
        return [encode_message(f"/m{i}", [float(i)]) for i in range(n)]

    def test_frame_is_a_big_endian_size_prefix(self):
        p = encode_message("/a")
        self.assertEqual(Len32Framer.frame(p), struct.pack(">I", len(p)) + p)

    def test_any_split_of_the_stream(self):
        packets = self.packets()
        stream = b"".join(Len32Framer.frame(p) for p in packets)
        for cut in range(len(stream) + 1):
            f = Len32Framer()
            got = f.push(stream[:cut]) + f.push(stream[cut:])
            self.assertEqual(got, packets, f"cut at {cut}")
            self.assertEqual(f.buffer, b"")

    def test_byte_at_a_time(self):
        packets = self.packets()
        f, got = Len32Framer(), []
        for b in b"".join(Len32Framer.frame(p) for p in packets):
            got += f.push(bytes([b]))
        self.assertEqual(got, packets)

    def test_zero_length_packets_are_skipped(self):
        p = encode_message("/a")
        f = Len32Framer()
        self.assertEqual(f.push(Len32Framer.frame(b"") + Len32Framer.frame(p)), [p])

    def test_does_not_decode(self):
        """A bad packet comes out whole; dropping it is the caller's job, and
        the next packet is still found (the stream stays in step)."""
        bad, good = b"\x01\x02\x03\x04garbage!", encode_message("/a")
        f = Len32Framer()
        self.assertEqual(f.push(Len32Framer.frame(bad) + Len32Framer.frame(good)), [bad, good])

    def test_oversized_loses_the_stream(self):
        f = Len32Framer()
        with self.assertRaises(FramingLost):
            f.push(struct.pack(">I", osc_codec.MAX_PACKET + 1) + b"abcd")
        self.assertEqual(f.buffer, b"")

    def test_max_packet_is_allowed(self):
        f = Len32Framer()
        self.assertEqual(f.push(struct.pack(">I", osc_codec.MAX_PACKET)), [])   # waits, no error


class Unframed(unittest.TestCase):
    def test_messages_back_to_back_any_split(self):
        msgs = [encode_message("/a", [1.0]), encode_message("/bb", ["x"]), encode_message("/c")]
        stream = b"".join(msgs)
        for cut in range(len(stream) + 1):
            f = UnframedFramer()
            self.assertEqual(f.push(stream[:cut]) + f.push(stream[cut:]), msgs, f"cut at {cut}")

    def test_frame_is_identity(self):
        self.assertEqual(UnframedFramer.frame(b"abcd"), b"abcd")

    def test_malformed_clears_and_keeps_earlier_packets(self):
        good = encode_message("/a", [1])
        bad = osc_string("/x") + osc_string(",z") + b"\0\0\0\0"
        f = UnframedFramer()
        with self.assertRaises(OSCMalformed) as cm:
            f.push(good + bad + good)
        self.assertEqual(cm.exception.packets, [good])
        self.assertEqual(f.buffer, b"")
        self.assertEqual(f.push(good), [good])       # recovers on the next message

    def test_bundle_is_malformed(self):
        with self.assertRaises(OSCMalformed):
            UnframedFramer().push(encode_bundle([encode_message("/a")]))


class Factory(unittest.TestCase):
    def test_names(self):
        self.assertIsInstance(make_framer("len32"), Len32Framer)
        self.assertIsInstance(make_framer("none"), UnframedFramer)
        self.assertEqual(osc_codec.DEFAULT_FRAMING, "len32")
        with self.assertRaises(ValueError):
            make_framer("slip")


class Link(unittest.TestCase):
    """TCPLink against the far end of a socket pair."""

    def link(self, framing):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        link = TCPLink("unused", 0, timeout=1.0, framing=framing)
        link.sock = a
        return link, b

    def test_len32_bundle_comes_out_message_by_message(self):
        link, peer = self.link("len32")
        peer.sendall(Len32Framer.frame(encode_bundle([encode_message("/a", [1]), encode_message("/b", [2])])))
        self.assertEqual([link.read_message().address, link.read_message().address], ["/a", "/b"])

    def test_send_message_is_framed(self):
        link, peer = self.link("len32")
        link.send_message("/a", [1.0])
        peer.settimeout(1)
        data = peer.recv(100)
        self.assertEqual(data, Len32Framer.frame(encode_message("/a", [1.0])))

    def test_unframed_keeps_good_messages_before_a_bad_one(self):
        link, peer = self.link("none")
        bad = osc_string("/x") + osc_string(",z") + b"\0\0\0\0"
        peer.sendall(encode_message("/a", [1]) + bad)
        with self.assertRaises(OSCMalformed):
            link.read_message()
        self.assertEqual(link.read_message().address, "/a")

    def test_len32_bad_packet_is_reported_and_the_next_kept(self):
        link, peer = self.link("len32")
        bad = osc_string("/x") + osc_string(",f") + b"\0\0"
        peer.sendall(Len32Framer.frame(bad) + Len32Framer.frame(encode_message("/a", [1])))
        with self.assertRaises(OSCMalformed):
            link.read_message()
        self.assertEqual(link.read_message().address, "/a")

    def test_drain_resets_a_half_read_packet(self):
        link, peer = self.link("len32")
        peer.sendall(Len32Framer.frame(encode_message("/stale"))[:7])
        link._fill(0.5)
        link.drain(0.05)
        peer.sendall(Len32Framer.frame(encode_message("/a")))
        self.assertEqual(link.read_message().address, "/a")

    def test_timeout(self):
        link, _ = self.link("len32")
        with self.assertRaises(TimeoutError):
            link.read_message(timeout=0.05)


if __name__ == "__main__":
    unittest.main()
