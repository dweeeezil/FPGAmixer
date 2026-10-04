#!/usr/bin/env python3
"""
The one OSC codec for the FPGA mixer's tools: the server
(osc_mixer_server.py), the test suite (osc_mixer_test.py), the console
(osc_console.py) and crosspoint_restore_test.py all use this module, so they
speak identically. Standard library only. Protocol: docs/FPGA Mixer OSC
Standard.md (sections "TCP framing" and "Transports").

LAYERS, bottom up:

  wire format   encode_message / decode_message: one OSC message.
                Argument types: f i s b T F N I h d (encode: float, int, str,
                bytes; bool encodes as i, as it always has). decode_message
                works on a growing stream buffer: OSCIncomplete means "read
                more", OSCMalformed means "more bytes can't fix this".
  packets       decode_packet: one complete OSC packet (a UDP datagram or one
                framed TCP packet) -> its messages. A packet is exactly one
                message or one bundle ('#bundle', nested bundles allowed);
                bundle messages come out in order and time tags are ignored
                (everything is applied at once). encode_bundle for tests.
  framing       a framer turns a TCP byte stream into packets and back:
                  len32  OSC 1.0 stream framing: a 4-byte big-endian size
                         before each packet. Bundles allowed. A packet that
                         doesn't decode is dropped on its own; the stream
                         stays in step. A size above MAX_PACKET means the
                         stream position is lost (FramingLost): reset the
                         connection. Zero-length packets are skipped.
                  none   unframed (older firmware): messages back to back,
                         self-delimiting by parsing, no bundles. A truncated
                         message corrupts the parse of what follows; a
                         malformed one clears the buffer.
                make_framer(name) -> framer with .push(bytes) -> [packets]
                and .frame(packet) -> bytes.
  client links  TCPLink / UDPLink: the controller side, for the tools.
"""

import socket
import struct
import time
from dataclasses import dataclass, field

FRAMINGS = ("len32", "none")
DEFAULT_FRAMING = "len32"

MAX_PACKET = 4 * 1024 * 1024    # room for a large config JSON (controller D22)
MAX_STRING_SCAN = MAX_PACKET    # a string with no NUL this long is garbage (the config
                                # reply is one long string, so this is the packet limit)

BUNDLE_TAG = b"#bundle\x00"


class OSCIncomplete(Exception):
    """Buffer doesn't yet hold a complete field. Caller should read more bytes."""


class OSCMalformed(Exception):
    """Buffer holds bytes that are not valid OSC. More bytes won't fix it."""


class FramingLost(Exception):
    """A len32 stream can't be resynchronised (impossible size): reset the connection."""


# ---------------------------------------------------------------------------
# Wire format: one message
# ---------------------------------------------------------------------------

@dataclass
class OSCMessage:
    address: str
    args: list = field(default_factory=list)

    def __repr__(self):
        return f"OSCMessage({self.address!r}, {self.args!r})"


def _pad4(b: bytes) -> bytes:
    return b + b"\x00" * ((-len(b)) % 4)


def osc_string(s: str) -> bytes:
    return _pad4(s.encode("utf-8") + b"\x00")


def osc_blob(b: bytes) -> bytes:
    return struct.pack(">i", len(b)) + _pad4(bytes(b))


def read_osc_string(data: bytes, offset: int):
    if offset > len(data):
        raise OSCIncomplete()
    idx = data.find(b"\x00", offset)
    if idx == -1:
        if len(data) - offset > MAX_STRING_SCAN:
            raise OSCMalformed(f"no NUL terminator within {MAX_STRING_SCAN} bytes of offset {offset}")
        raise OSCIncomplete()
    length = idx - offset + 1
    total = ((length + 3) // 4) * 4
    if offset + total > len(data):
        raise OSCIncomplete()
    s = data[offset:idx].decode("utf-8", errors="replace")
    return s, offset + total


def read_osc_blob(data: bytes, offset: int):
    if offset + 4 > len(data):
        raise OSCIncomplete()
    (size,) = struct.unpack_from(">i", data, offset)
    if size < 0 or size > MAX_PACKET:
        raise OSCMalformed(f"blob size {size} out of range")
    end = offset + 4 + size
    total = offset + 4 + size + ((-size) % 4)
    if total > len(data):
        raise OSCIncomplete()
    return bytes(data[offset + 4:end]), total


def encode_message(address: str, args=()) -> bytes:
    """A spec-correct OSC message. For malformed/fault-injection packets,
    build the bytes directly instead."""
    type_tags = ","
    arg_bytes = b""
    for a in args:
        if isinstance(a, bool):
            type_tags += "i"
            arg_bytes += struct.pack(">i", int(a))
        elif isinstance(a, float):
            type_tags += "f"
            arg_bytes += struct.pack(">f", a)
        elif isinstance(a, int):
            type_tags += "i"
            arg_bytes += struct.pack(">i", a)
        elif isinstance(a, str):
            type_tags += "s"
            arg_bytes += osc_string(a)
        elif isinstance(a, (bytes, bytearray)):
            type_tags += "b"
            arg_bytes += osc_blob(a)
        else:
            raise TypeError(f"unsupported OSC arg type: {type(a)!r}")
    return osc_string(address) + osc_string(type_tags) + arg_bytes


_FIXED = {"i": (">i", 4), "f": (">f", 4), "h": (">q", 8), "d": (">d", 8)}
_NO_DATA = {"T": True, "F": False, "N": None, "I": float("inf")}


def decode_message(data: bytes, offset: int = 0):
    """Decode one OSC message starting at `offset`. Returns (message, length_consumed)."""
    start = offset
    address, offset = read_osc_string(data, offset)
    if not address.startswith("/"):
        if address == "#bundle":
            raise OSCMalformed("a bundle where a message was expected (unframed TCP can't carry bundles)")
        raise OSCMalformed(f"address does not start with '/': {address!r}")
    type_tag_str, offset = read_osc_string(data, offset)
    if not type_tag_str.startswith(","):
        raise OSCMalformed(f"type-tag string does not start with ',': {type_tag_str!r}")
    args = []
    for tag in type_tag_str[1:]:
        if tag in _FIXED:
            fmt, size = _FIXED[tag]
            if offset + size > len(data):
                raise OSCIncomplete()
            (val,) = struct.unpack_from(fmt, data, offset)
            args.append(val)
            offset += size
        elif tag == "s":
            s, offset = read_osc_string(data, offset)
            args.append(s)
        elif tag == "b":
            b, offset = read_osc_blob(data, offset)
            args.append(b)
        elif tag in _NO_DATA:
            args.append(_NO_DATA[tag])
        else:
            raise OSCMalformed(f"unsupported type tag {tag!r} in {type_tag_str!r}")
    return OSCMessage(address, args), offset - start


# ---------------------------------------------------------------------------
# Packets: a message or a bundle
# ---------------------------------------------------------------------------

def encode_bundle(elements, timetag=1) -> bytes:
    """elements: encoded messages or bundles (bytes). timetag 1 = immediately."""
    out = BUNDLE_TAG + struct.pack(">Q", timetag)
    for e in elements:
        out += struct.pack(">i", len(e)) + e
    return out


def decode_packet(data: bytes, depth: int = 0) -> list:
    """All messages in one complete packet, in order. Raises OSCMalformed if
    the packet isn't exactly one message or one bundle."""
    if depth > 8:
        raise OSCMalformed("bundles nested too deep")
    data = bytes(data)
    if data.startswith(BUNDLE_TAG):
        if len(data) < 16:
            raise OSCMalformed("bundle shorter than its header")
        messages, offset = [], 16
        while offset < len(data):
            if offset + 4 > len(data):
                raise OSCMalformed("bundle element size cut short")
            (size,) = struct.unpack_from(">i", data, offset)
            offset += 4
            if size <= 0 or size % 4 or offset + size > len(data):
                raise OSCMalformed(f"bundle element size {size} doesn't fit")
            messages += decode_packet(data[offset:offset + size], depth + 1)
            offset += size
        return messages
    try:
        msg, consumed = decode_message(data)
    except OSCIncomplete:
        raise OSCMalformed("packet ends inside a message (truncated)")
    if consumed != len(data):
        raise OSCMalformed(f"{len(data) - consumed} byte(s) after the message "
                           f"(a packet holds one message or one bundle)")
    return [msg]


# ---------------------------------------------------------------------------
# TCP stream framing
# ---------------------------------------------------------------------------

class Len32Framer:
    """OSC 1.0 stream framing. push() returns complete packets (bytes); it
    never decodes them, so a bad packet is the caller's to drop."""

    name = "len32"

    def __init__(self):
        self.buffer = b""

    @staticmethod
    def frame(packet: bytes) -> bytes:
        return struct.pack(">I", len(packet)) + packet

    def push(self, chunk: bytes) -> list:
        self.buffer += chunk
        packets = []
        while len(self.buffer) >= 4:
            (size,) = struct.unpack_from(">I", self.buffer, 0)
            if size > MAX_PACKET:
                self.buffer = b""
                raise FramingLost(f"packet size {size} exceeds {MAX_PACKET}; stream position lost")
            if len(self.buffer) < 4 + size:
                break
            packet = self.buffer[4:4 + size]
            self.buffer = self.buffer[4 + size:]
            if size:
                packets.append(packet)
        return packets


class UnframedFramer:
    """Messages back to back. push() returns one packet per complete message.
    A malformed message clears the buffer and raises OSCMalformed; the
    packets completed before it in the same chunk are on the exception's
    .packets, so the caller can still handle them."""

    name = "none"

    def __init__(self):
        self.buffer = b""

    @staticmethod
    def frame(packet: bytes) -> bytes:
        return packet

    def push(self, chunk: bytes) -> list:
        self.buffer += chunk
        packets = []
        while self.buffer:
            try:
                _, consumed = decode_message(self.buffer)
            except OSCIncomplete:
                break
            except OSCMalformed as e:
                self.buffer = b""
                e.packets = packets
                raise
            packets.append(self.buffer[:consumed])
            self.buffer = self.buffer[consumed:]
        return packets


def make_framer(name: str):
    if name == "len32":
        return Len32Framer()
    if name == "none":
        return UnframedFramer()
    raise ValueError(f"unknown TCP framing {name!r} (one of {', '.join(FRAMINGS)})")


# ---------------------------------------------------------------------------
# Client links (controller side, for the tools)
# ---------------------------------------------------------------------------

class TCPLink:
    """A controller's TCP connection. read_message() returns one message at a
    time, whatever the framing; a bundle's messages come out one by one."""

    def __init__(self, host, port, timeout=2.0, framing=DEFAULT_FRAMING):
        self.host, self.port, self.timeout = host, port, timeout
        self.framing = framing
        self.framer = make_framer(framing)
        self.pending = []           # decoded messages not yet returned
        self.sock = None

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)
        return self

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    @property
    def buffer(self):
        return self.framer.buffer

    def frame(self, packet: bytes) -> bytes:
        """The bytes that carry `packet` in this link's framing."""
        return self.framer.frame(packet)

    def send_raw(self, data: bytes):
        """Bytes exactly as given: no framing (for fault injection)."""
        self.sock.sendall(data)

    def send_packet(self, packet: bytes):
        self.sock.sendall(self.frame(packet))

    def send_message(self, address, args=()):
        self.send_packet(encode_message(address, args))

    def _fill(self, timeout):
        self.sock.settimeout(max(timeout, 0.001))
        chunk = self.sock.recv(4096)
        if chunk == b"":
            raise ConnectionResetError("peer closed the connection")
        error = None
        try:
            packets = self.framer.push(chunk)
        except OSCMalformed as e:
            packets, error = e.packets, e
        for packet in packets:            # good messages are kept; the first bad one is raised
            try:
                self.pending += decode_packet(packet)
            except OSCMalformed as e:
                error = error or e
        if error is not None:
            raise error

    def read_message(self, timeout=None) -> OSCMessage:
        """Block until one message is available, or raise TimeoutError /
        OSCMalformed / FramingLost."""
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while not self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"no complete OSC message within timeout "
                    f"({len(self.buffer)} bytes buffered: {self.buffer[:64]!r})")
            self._fill(remaining)
        return self.pending.pop(0)

    def drain(self, duration=0.3):
        """Best-effort: absorb and discard whatever arrives for `duration`
        seconds, and reset the framer. Clears stray replies between tests."""
        deadline = time.monotonic() + duration
        self.sock.settimeout(0.05)
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
            except socket.timeout:
                continue
            except OSError:
                break
        self.framer = make_framer(self.framing)
        self.pending = []


class UDPLink:
    """Write-only: one packet per datagram, never framed."""

    def __init__(self, host, port):
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send_message(self, address, args=()):
        self.sock.sendto(encode_message(address, args), self.addr)

    def send_raw(self, data: bytes):
        self.sock.sendto(data, self.addr)

    send_packet = send_raw      # a datagram is one packet

    def close(self):
        self.sock.close()
