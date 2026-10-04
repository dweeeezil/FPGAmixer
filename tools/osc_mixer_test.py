#!/usr/bin/env python3
"""
OSC bring-up / robustness test suite for the FPGA mixer's OSC control protocol.

Implements the OSC wire format directly (osc_codec.py, shared with the
server; no python-osc or other third-party dependency) so that:
  - it runs anywhere with a stock Python 3.8+ interpreter, and
  - the fault-injection tests can build deliberately malformed packets that a
    "correct" OSC library would refuse to construct in the first place.

PROTOCOL ASSUMPTIONS (per "FPGA Mixer OSC Standard.md", 18 Aug 2026):
  - Addresses/values follow: /<mixer>/<set|get>/<zone>/<index>/<module>  [value]
  - UDP is write-only, no reply expected ("stupid receive message, write
    value to memory" per the roadmap doc).
  - TCP is two-way: every 'set' is echoed back to confirm. The standard
    doesn't say how 'get' replies are addressed (with a 'set' prefix, since
    that's described as the sync/confirmation vehicle, or a 'get' prefix
    mirroring the request), so this suite accepts either and reports which
    one it sees (see get_reply_style_probe).
  - TCP framing (--tcp-framing, matching the server's): len32 (default),
    the standard's OSC 1.0 4-byte size prefix per packet, or none, the older
    unframed stream. The codec, the framers and TCPLink/UDPLink are the
    shared osc_codec.py, which must sit next to this file. Raw fault-
    injection bytes go through ctx.frame() / link.send_packet() so they are
    framed like everything else.
  - The system/deviceName example in the standard doc puts the new name in
    the <index> slot with an empty <module> ("/mixer/set/system/deviceName/
    <value>"), not in <module> as the rest of the doc's pattern would
    suggest. This suite mirrors that literally, as written.

Usage:
    python3 osc_mixer_test.py --host 192.168.1.50 --tcp-port 8000 --udp-port 8001

    python3 osc_mixer_test.py --host 192.168.1.50 --tcp-port 8000 --udp-port 8001 --list
    python3 osc_mixer_test.py --host 192.168.1.50 --tcp-port 8000 --udp-port 8001 --only fragmented churn

No dependencies beyond the standard library.
"""

import argparse
import statistics
import sys
import time
from dataclasses import dataclass

# The codec and the client links are shared with the server (osc_codec.py).
from osc_codec import (FRAMINGS, DEFAULT_FRAMING, OSCMalformed, TCPLink, UDPLink,
                       encode_message, encode_bundle, make_framer, osc_string)


# ---------------------------------------------------------------------------
# Test context and harness
# ---------------------------------------------------------------------------

@dataclass
class Context:
    host: str
    tcp_port: int
    udp_port: int
    mixer_name: str
    timeout: float
    epsilon: float
    inputs: int
    buses: int
    framing: str = DEFAULT_FRAMING

    def new_tcp(self, timeout=None) -> TCPLink:
        return TCPLink(self.host, self.tcp_port, timeout or self.timeout, self.framing).connect()

    def new_udp(self) -> UDPLink:
        return UDPLink(self.host, self.udp_port)

    def frame(self, packet: bytes) -> bytes:
        """The bytes that carry `packet` on TCP in this run's framing."""
        return make_framer(self.framing).frame(packet)

    def addr(self, kind, zone, index, module):
        return f"/{self.mixer_name}/{kind}/{zone}/{index}/{module}"


def split_address(ctx: Context, address: str):
    """('set'|'get'|'?', 'zone/index/module') for a reply address."""
    prefix = f"/{ctx.mixer_name}/"
    if not address.startswith(prefix):
        return "?", address
    rest = address[len(prefix):]
    kind, _, zim = rest.partition("/")
    return kind, zim


@dataclass
class TestResult:
    name: str
    passed: bool
    detail: str
    duration: float


class TestSuite:
    def __init__(self):
        self._tests = []  # (name, func, destructive)

    def register(self, name, destructive=False):
        def deco(fn):
            self._tests.append((name, fn, destructive))
            return fn
        return deco

    def all(self):
        return list(self._tests)

    def run(self, ctx: Context, only=None, include_destructive=False):
        results = []
        for name, fn, destructive in self._tests:
            if only and not any(o.lower() in name.lower() for o in only):
                continue
            if destructive and not include_destructive:
                print(f"[SKIP] {name} (destructive — pass --include-destructive to run)")
                continue
            t0 = time.monotonic()
            try:
                detail = fn(ctx) or ""
                passed = True
            except AssertionError as e:
                passed, detail = False, str(e)
            except Exception as e:
                passed, detail = False, f"{type(e).__name__}: {e}"
            dt = time.monotonic() - t0
            results.append(TestResult(name, passed, detail, dt))
            status = "PASS" if passed else "FAIL"
            line = f"[{status}] {name} ({dt * 1000:.0f} ms)"
            if detail:
                line += f" — {detail}"
            print(line)
        return results


suite = TestSuite()


# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------

@suite.register("tcp_connect")
def test_tcp_connect(ctx):
    link = ctx.new_tcp()
    link.close()
    return "connected and closed cleanly"


@suite.register("udp_socket_send")
def test_udp_socket_send(ctx):
    link = ctx.new_udp()
    try:
        link.send_message(ctx.addr("get", "inputChannel", 0, "level"))
    finally:
        link.close()
    return "sendto() did not raise (UDP is write-only, so this only checks the local socket)"


# ---------------------------------------------------------------------------
# Basic correctness
# ---------------------------------------------------------------------------

@suite.register("set_get_echo_input_channel_level")
def test_set_echo(ctx):
    link = ctx.new_tcp()
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        link.send_message(target, [-6.0])
        reply = link.read_message()
        assert reply.address == target, f"echoed address {reply.address!r} != sent {target!r}"
        assert len(reply.args) == 1, f"expected 1 arg back, got {reply.args!r}"
        got = reply.args[0]
        assert abs(got - (-6.0)) <= ctx.epsilon, (
            f"echoed value {got} differs from sent -6.0 by more than epsilon={ctx.epsilon} "
            f"(delta={got - (-6.0):.6f}) — if this is consistent, the firmware may be "
            f"quantizing to a fixed-point internal representation"
        )
    finally:
        link.close()
    return f"echoed {reply.address} {reply.args}"


@suite.register("get_reply_style_probe")
def test_get_reply_style(ctx):
    link = ctx.new_tcp()
    try:
        set_addr = ctx.addr("set", "inputChannel", 0, "level")
        link.send_message(set_addr, [-3.5])
        link.read_message()  # absorb the set's own echo

        link.send_message(ctx.addr("get", "inputChannel", 0, "level"))
        reply = link.read_message()
        kind, zim = split_address(ctx, reply.address)
        assert zim == "inputChannel/0/level", (
            f"reply address {reply.address!r} doesn't reference the request"
        )
        assert len(reply.args) == 1, f"expected a single value back, got {reply.args!r}"
    finally:
        link.close()
    return f"get-replies use the {kind!r} prefix ({reply.address} {reply.args})"


@suite.register("matrix_crosspoint_set_echo")
def test_matrix_crosspoint(ctx):
    link = ctx.new_tcp()
    try:
        idx = "0_0"
        level_addr = ctx.addr("set", "inputMatrix", idx, "level")
        link.send_message(level_addr, [-24.0])
        reply = link.read_message()
        assert reply.address == level_addr, f"got {reply.address!r}"
        assert abs(reply.args[0] - (-24.0)) <= ctx.epsilon, f"level echo off by {reply.args[0] + 24.0:.4f}"

        delay_addr = ctx.addr("set", "inputMatrix", idx, "delay")
        link.send_message(delay_addr, [2.39])
        reply = link.read_message()
        assert reply.address == delay_addr, f"got {reply.address!r}"
        assert abs(reply.args[0] - 2.39) <= ctx.epsilon, f"delay echo off by {reply.args[0] - 2.39:.4f}"
    finally:
        link.close()
    return f"crosspoint {idx}: level and delay both echoed correctly"


# ---------------------------------------------------------------------------
# Ordering / synchronization
# ---------------------------------------------------------------------------

@suite.register("rapid_pipelined_sets_order_preserved")
def test_pipelined_order(ctx):
    """Fire N sets back-to-back without waiting for replies (pipelining),
    then read N replies. This is deliberately the scenario most likely to
    expose TCP message-boundary bugs: the OS will very likely coalesce these
    small writes into one or two recv()s on the device side."""
    n = 20
    link = ctx.new_tcp()
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        values = [round(-40.0 + i * 2.0, 2) for i in range(n)]
        for v in values:
            link.send_message(target, [v])
        got = []
        for _ in range(n):
            reply = link.read_message(timeout=5.0)
            got.append(reply.args[0] if reply.args else None)
        assert len(got) == n, f"expected {n} replies, got {len(got)}"
        mismatches = [(i, values[i], got[i]) for i in range(n)
                      if got[i] is None or abs(got[i] - values[i]) > ctx.epsilon]
        assert not mismatches, f"{len(mismatches)}/{n} replies out of order or wrong: {mismatches[:5]}"
    finally:
        link.close()
    return f"{n} pipelined sets echoed back in order"


@suite.register("multi_client_broadcast_sync")
def test_multi_client_broadcast(ctx):
    """Per the standard: 'sent by the mixer itself to all network controllers
    on a value change to ensure synchronization.' This checks a second, idle
    TCP client actually sees that broadcast."""
    a = ctx.new_tcp()
    b = ctx.new_tcp()
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        # B's connect() returning only means the kernel finished the TCP
        # handshake; the server may not have accepted it yet, and no server can
        # broadcast to a connection still in its listen backlog. One round trip
        # on B (a get, as a controller does to sync on connect) proves the
        # server has B before A's change -- without it this test is racy.
        b.send_message(ctx.addr("get", "inputChannel", 0, "level"), [])
        b.read_message()
        a.send_message(target, [-9.0])
        reply_a = a.read_message()
        assert reply_a.address == target, f"client A's own echo malformed: {reply_a}"

        try:
            reply_b = b.read_message(timeout=2.0)
        except TimeoutError:
            raise AssertionError(
                "client B (a second, idle TCP connection) never received a "
                "broadcast of client A's change — multi-controller sync isn't "
                "reaching other clients"
            )
        assert reply_b.address == target, f"client B got {reply_b.address!r}, expected {target!r}"
    finally:
        a.close()
        b.close()
    return "second client received the broadcasted change"


@suite.register("udp_set_then_tcp_get_consistency")
def test_udp_then_tcp_get(ctx):
    value = -17.25
    udp = ctx.new_udp()
    try:
        udp.send_message(ctx.addr("set", "inputChannel", 1, "level"), [value])
        time.sleep(0.2)  # UDP set is fire-and-forget; give it time to land
    finally:
        udp.close()

    # The TCP connection is opened AFTER the UDP set, deliberately — if it
    # were already connected, the mixer's own broadcast of the UDP-triggered
    # change would land in its buffer as an extra, unsolicited message ahead
    # of the get reply we're about to request, and read_message() would
    # return that instead.
    tcp = ctx.new_tcp()
    try:
        tcp.send_message(ctx.addr("get", "inputChannel", 1, "level"))
        reply = tcp.read_message()
        assert reply.args and abs(reply.args[0] - value) <= ctx.epsilon, (
            f"TCP get after UDP set returned {reply.args!r}, expected ~{value}"
        )
    finally:
        tcp.close()
    return "value set over UDP was visible via a TCP get"


@suite.register("interleaved_set_then_get_race")
def test_set_then_get_race(ctx):
    link = ctx.new_tcp()
    try:
        zim = "inputChannel/2/level"
        target_set = ctx.addr("set", "inputChannel", 2, "level")
        value = -1.0
        # Send set and get back to back, no wait in between — checks whether
        # the get reflects the just-sent value rather than a stale one.
        link.send_message(target_set, [value])
        link.send_message(ctx.addr("get", "inputChannel", 2, "level"))
        replies = [link.read_message(), link.read_message()]
        set_echo = next((r for r in replies if r.address == target_set), None)
        assert set_echo is not None, f"missing set-echo among replies: {replies}"
        get_reply = next((r for r in replies if r is not set_echo), None)
        get_kind, get_zim = split_address(ctx, get_reply.address)
        assert get_zim == zim, f"get reply address {get_reply.address!r} doesn't reference {zim}"
        get_val = get_reply.args[0] if get_reply.args else None
        assert get_val is not None and abs(get_val - value) <= ctx.epsilon, (
            f"get returned {get_val}, expected the just-set value {value} "
            f"(if this fails, the get raced ahead of the set being committed)"
        )
    finally:
        link.close()
    return f"get immediately after set reflected the new value (reply used {get_kind!r} prefix)"


# ---------------------------------------------------------------------------
# Fault injection / desync stress
# ---------------------------------------------------------------------------

@suite.register("concatenated_messages_single_write")
def test_concatenated_single_write(ctx):
    link = ctx.new_tcp()
    try:
        a1 = ctx.addr("set", "inputChannel", 0, "level")
        blob = link.frame(encode_message(a1, [-10.0])) + link.frame(encode_message(a1, [-20.0]))
        link.send_raw(blob)  # one sendall() -> likely one TCP segment on the wire
        r1 = link.read_message(timeout=3.0)
        r2 = link.read_message(timeout=3.0)
        assert r1.address == a1 and abs(r1.args[0] - (-10.0)) <= ctx.epsilon, f"first reply wrong: {r1}"
        assert r2.address == a1 and abs(r2.args[0] - (-20.0)) <= ctx.epsilon, f"second reply wrong: {r2}"
    finally:
        link.close()
    return "two messages sent in a single write() both parsed and echoed correctly, in order"


@suite.register("fragmented_message_delayed_writes")
def test_fragmented_message(ctx):
    """Split one message at a few different byte offsets and dribble it out
    over multiple delayed writes, to check the receiver waits for the rest
    rather than acting on a partial packet."""
    target = ctx.addr("set", "inputChannel", 0, "level")
    full = ctx.frame(encode_message(target, [-5.5]))   # len32: split points 1 and 4 are in the size
    split_points = sorted(set([1, 4, len(full) // 2, len(full) - 1]))
    failures = []
    for split_at in split_points:
        link = ctx.new_tcp()
        try:
            link.send_raw(full[:split_at])
            time.sleep(0.2)
            link.send_raw(full[split_at:])
            reply = link.read_message(timeout=3.0)
            if not (reply.address == target and abs(reply.args[0] - (-5.5)) <= ctx.epsilon):
                failures.append((split_at, "wrong reply", str(reply)))
        except (TimeoutError, OSCMalformed, OSError) as e:
            failures.append((split_at, type(e).__name__, str(e)))
        finally:
            link.close()
    assert not failures, f"{len(failures)}/{len(split_points)} split points failed: {failures}"
    return f"message correctly reassembled across {len(split_points)} different split points"


@suite.register("byte_at_a_time_extreme_fragmentation")
def test_byte_at_a_time(ctx):
    target = ctx.addr("set", "inputChannel", 0, "level")
    full = ctx.frame(encode_message(target, [-1.5]))
    link = ctx.new_tcp()
    try:
        for b in full:
            link.send_raw(bytes([b]))
            time.sleep(0.01)
        reply = link.read_message(timeout=5.0)
        assert reply.address == target and abs(reply.args[0] - (-1.5)) <= ctx.epsilon, f"got {reply}"
    finally:
        link.close()
    return f"reassembled correctly from {len(full)} single-byte writes"


@suite.register("malformed_type_tag_then_recovery")
def test_malformed_type_tag_recovery(ctx):
    link = ctx.new_tcp()
    try:
        bad_addr = ctx.addr("set", "inputChannel", 0, "level")
        # 'z' isn't a type tag this standard uses.
        bad_packet = osc_string(bad_addr) + osc_string(",z") + b"\x00\x00\x00\x00"
        link.send_packet(bad_packet)
        time.sleep(0.2)
        link.drain(0.3)  # discard whatever (if anything) the device said about the bad packet

        good = ctx.addr("set", "inputChannel", 0, "level")
        link.send_message(good, [-2.0])
        reply = link.read_message(timeout=3.0)
        assert reply.address == good and abs(reply.args[0] - (-2.0)) <= ctx.epsilon, (
            f"connection did not cleanly recover after a bad type tag — got {reply}"
        )
    finally:
        link.close()
    return "connection recovered and processed a valid message after a bad type tag"


@suite.register("truncated_argument_then_recovery")
def test_truncated_arg_recovery(ctx):
    link = ctx.new_tcp()
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        # Header claims a float follows, but only 2 of 4 bytes are ever sent.
        # len32: the size prefix delimits the bad packet, so the device drops
        # it and stays in step. none: the device can't tell where it ends, so
        # this fails by design (the reason for framing).
        truncated = osc_string(target) + osc_string(",f") + b"\x00\x00"
        link.send_packet(truncated)
        time.sleep(0.3)
        link.drain(0.3)

        good = ctx.addr("set", "inputChannel", 0, "level")
        link.send_message(good, [-8.25])
        try:
            reply = link.read_message(timeout=3.0)
        except TimeoutError:
            raise AssertionError(
                "no reply after a truncated argument — the device may be stuck "
                "waiting for the 2 bytes that will never arrive"
            )
        assert reply.address == good and abs(reply.args[0] - (-8.25)) <= ctx.epsilon, (
            f"got {reply} — the truncated bytes were likely misread as part of "
            f"the following valid message"
        )
    finally:
        link.close()
    return "connection recovered after a truncated float argument"


@suite.register("out_of_range_numeric_values")
def test_out_of_range_values(ctx):
    link = ctx.new_tcp()
    observations = []
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        cases = [("NaN", float("nan")), ("+inf", float("inf")),
                 ("-inf", float("-inf")), ("huge", 1e30)]
        for label, value in cases:
            link.send_message(target, [value])
            try:
                reply = link.read_message(timeout=2.0)
                observations.append(f"{label}: echoed {reply.args}")
            except TimeoutError:
                observations.append(f"{label}: no reply within 2s")
                link.drain(0.2)

        link.send_message(target, [0.0])
        reply = link.read_message(timeout=3.0)
        assert abs(reply.args[0] - 0.0) <= ctx.epsilon, (
            f"connection didn't recover cleanly after extreme values: got {reply}"
        )
    finally:
        link.close()
    return "; ".join(observations) + " — recovered afterward"


@suite.register("invalid_matrix_index_handling")
def test_invalid_matrix_index(ctx):
    link = ctx.new_tcp()
    try:
        bogus_idx = f"{ctx.inputs + 500}_{ctx.buses + 500}"
        link.send_message(ctx.addr("set", "inputMatrix", bogus_idx, "level"), [-6.0])
        try:
            reply = link.read_message(timeout=2.0)
            observation = f"out-of-range index got a reply: {reply}"
        except TimeoutError:
            observation = "out-of-range index: no reply within 2s (silently ignored)"
            link.drain(0.2)

        good_idx = "0_0"
        link.send_message(ctx.addr("set", "inputMatrix", good_idx, "level"), [-3.0])
        reply = link.read_message(timeout=3.0)
        assert abs(reply.args[0] - (-3.0)) <= ctx.epsilon, f"didn't recover: {reply}"
    finally:
        link.close()
    return observation + "; recovered on a valid crosspoint afterward"


@suite.register("connection_churn_then_recovery")
def test_connection_churn(ctx):
    n = 20
    for _ in range(n):
        link = TCPLink(ctx.host, ctx.tcp_port, timeout=1.0)
        link.connect()
        link.close()
    fresh = ctx.new_tcp()
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        fresh.send_message(target, [-4.0])
        reply = fresh.read_message(timeout=3.0)
        assert abs(reply.args[0] - (-4.0)) <= ctx.epsilon, f"got {reply}"
    finally:
        fresh.close()
    return f"{n} rapid connect/disconnect cycles, then a fresh connection still worked"


@suite.register("udp_double_message_single_packet")
def test_udp_double_message(ctx):
    """Two OSC messages concatenated into ONE UDP datagram. Not a valid OSC
    packet (a packet is one message or one bundle; see udp_bundle_...), so
    this is informational: it reports what happened. Since the shared codec
    (osc_codec.py) the reference server drops the whole datagram; before it,
    it applied the first message."""
    udp = ctx.new_udp()
    try:
        addr1 = ctx.addr("set", "inputChannel", 3, "level")
        addr2 = ctx.addr("set", "inputChannel", 4, "level")
        blob = encode_message(addr1, [-11.0]) + encode_message(addr2, [-22.0])
        udp.send_raw(blob)
        time.sleep(0.3)
    finally:
        udp.close()

    # Opened AFTER the UDP send: an already-connected TCP client would catch
    # the mixer's broadcast of whichever part of the datagram it accepted,
    # as an extra message ahead of the two get replies below, throwing off
    # the 1-request/1-reply pairing this test relies on.
    tcp = ctx.new_tcp()
    try:
        tcp.send_message(ctx.addr("get", "inputChannel", 3, "level"))
        r1 = tcp.read_message()
        tcp.send_message(ctx.addr("get", "inputChannel", 4, "level"))
        r2 = tcp.read_message()
        v1 = r1.args[0] if r1.args else None
        v2 = r2.args[0] if r2.args else None
        first_ok = v1 is not None and abs(v1 - (-11.0)) <= ctx.epsilon
        second_ok = v2 is not None and abs(v2 - (-22.0)) <= ctx.epsilon
        return (f"first message landed: {first_ok} (value={v1}); "
                f"second message landed: {second_ok} (value={v2})")
    finally:
        tcp.close()


@suite.register("tcp_bundle_messages_in_order")
def test_tcp_bundle(ctx):
    """A bundle of two sets in one framed packet: both applied, echoed in
    order. Unframed TCP can't carry bundles, so this only runs with len32."""
    if ctx.framing != "len32":
        return f"not applicable with --tcp-framing {ctx.framing} (no bundles)"
    link = ctx.new_tcp()
    try:
        a = ctx.addr("set", "inputChannel", 5, "level")
        b = ctx.addr("set", "inputChannel", 6, "level")
        link.send_packet(encode_bundle([encode_message(a, [-13.0]), encode_message(b, [-14.0])]))
        r1 = link.read_message(timeout=3.0)
        r2 = link.read_message(timeout=3.0)
        assert r1.address == a and abs(r1.args[0] + 13.0) <= ctx.epsilon, f"first echo wrong: {r1}"
        assert r2.address == b and abs(r2.args[0] + 14.0) <= ctx.epsilon, f"second echo wrong: {r2}"
    finally:
        link.close()
    return "both messages of a bundle applied and echoed in order"


@suite.register("udp_bundle_single_datagram")
def test_udp_bundle(ctx):
    udp = ctx.new_udp()
    try:
        a = ctx.addr("set", "inputChannel", 3, "level")
        b = ctx.addr("set", "inputChannel", 4, "level")
        udp.send_raw(encode_bundle([encode_message(a, [-15.0]), encode_message(b, [-16.0])]))
        time.sleep(0.3)
    finally:
        udp.close()
    tcp = ctx.new_tcp()     # opened after the send, as in udp_double_message_single_packet
    try:
        got = []
        for ch in (3, 4):
            tcp.send_message(ctx.addr("get", "inputChannel", ch, "level"))
            got.append(tcp.read_message().args[0])
        assert abs(got[0] + 15.0) <= ctx.epsilon and abs(got[1] + 16.0) <= ctx.epsilon, (
            f"bundle over UDP not applied: got {got}, expected [-15.0, -16.0]")
    finally:
        tcp.close()
    return "both messages of a UDP bundle applied"


# ---------------------------------------------------------------------------
# Informational
# ---------------------------------------------------------------------------

@suite.register("roundtrip_latency_profile")
def test_latency_profile(ctx):
    n = 30
    link = ctx.new_tcp()
    times = []
    try:
        target = ctx.addr("set", "inputChannel", 0, "level")
        for i in range(n):
            v = -30.0 + (i % 10)
            t0 = time.monotonic()
            link.send_message(target, [v])
            reply = link.read_message()
            times.append(time.monotonic() - t0)
            assert reply.address == target, f"unexpected reply during latency run: {reply}"
    finally:
        link.close()
    ms = [t * 1000 for t in times]
    return (f"n={n} round-trips — min={min(ms):.1f}ms mean={statistics.mean(ms):.1f}ms "
            f"max={max(ms):.1f}ms stdev={statistics.pstdev(ms):.1f}ms")


# ---------------------------------------------------------------------------
# Destructive (mutates persistent device config) — opt-in only
# ---------------------------------------------------------------------------

@suite.register("devicename_change_roundtrip", destructive=True)
def test_devicename_roundtrip(ctx):
    """The standard itself flags this as a footgun: changing system/deviceName
    changes the whole address space, and per the other project docs, control
    parameters persist across power loss. This always tries to put the name
    back in a finally block, even if an assertion above it fails — but if the
    device wedges mid-rename, you may need to recover it manually."""
    original = ctx.mixer_name
    temp_name = f"{original}_TEST"
    link = ctx.new_tcp()
    renamed = False
    try:
        print(f"    WARNING: renaming the device from {original!r} to {temp_name!r} "
              f"and back. This mutates persistent config.")
        rename_addr = f"/{original}/set/system/deviceName/"
        link.send_message(rename_addr, [temp_name])
        reply = link.read_message(timeout=3.0)
        renamed = True

        probe_new = f"/{temp_name}/set/inputChannel/0/level"
        link.send_message(probe_new, [-1.0])
        new_name_works = False
        try:
            r = link.read_message(timeout=2.0)
            new_name_works = (r.address == probe_new)
        except TimeoutError:
            pass

        probe_old = f"/{original}/set/inputChannel/0/level"
        link.send_message(probe_old, [-1.0])
        old_name_still_works = False
        try:
            r = link.read_message(timeout=2.0)
            old_name_still_works = (r.address == probe_old)
        except TimeoutError:
            pass

        return (f"rename ack: {reply.address} {reply.args}; new name active: "
                f"{new_name_works}; old name still active: {old_name_still_works}")
    finally:
        if renamed:
            reverted = False
            for root in (temp_name, original):
                try:
                    revert_link = ctx.new_tcp(timeout=2.0)
                    revert_link.send_message(f"/{root}/set/system/deviceName/", [original])
                    revert_link.read_message(timeout=2.0)
                    revert_link.close()
                    print(f"    reverted device name to {original!r} via root {root!r}")
                    reverted = True
                    break
                except Exception:
                    continue
            if not reverted:
                print(f"    *** COULD NOT CONFIRM DEVICE NAME WAS REVERTED TO "
                      f"{original!r} — CHECK THE DEVICE MANUALLY ***")
        link.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_arg_parser():
    p = argparse.ArgumentParser(description="Bring-up / robustness test suite for the FPGA mixer OSC protocol.")
    p.add_argument("--host", help="IP or hostname of the mixer")
    p.add_argument("--tcp-port", type=int, help="TCP OSC port")
    p.add_argument("--udp-port", type=int, help="UDP OSC port")
    p.add_argument("--mixer-name", default="mixer", help="mixer name in the OSC address root (default: mixer)")
    p.add_argument("--tcp-framing", choices=FRAMINGS, default=DEFAULT_FRAMING,
                   help="TCP framing the mixer uses: len32 (default) or none (older firmware)")
    p.add_argument("--timeout", type=float, default=2.0, help="default per-op timeout in seconds")
    p.add_argument("--epsilon", type=float, default=0.01, help="float round-trip tolerance")
    p.add_argument("--inputs", type=int, default=8, help="number of input channels, for picking safe test indices")
    p.add_argument("--buses", type=int, default=8, help="number of buses, for picking safe test indices")
    p.add_argument("--only", nargs="*", help="only run tests whose name contains any of these substrings")
    p.add_argument("--include-destructive", action="store_true",
                    help="also run tests that change persistent config (e.g. device name)")
    p.add_argument("--list", action="store_true", help="list test names and exit")
    return p


def main():
    parser = build_arg_parser()
    args = parser.parse_args()

    if args.list:
        for name, _, destructive in suite.all():
            print(name + ("  [destructive]" if destructive else ""))
        return 0

    if args.host is None or args.tcp_port is None or args.udp_port is None:
        parser.error("--host, --tcp-port and --udp-port are required unless --list is given")

    ctx = Context(host=args.host, tcp_port=args.tcp_port, udp_port=args.udp_port,
                  mixer_name=args.mixer_name, timeout=args.timeout, epsilon=args.epsilon,
                  inputs=args.inputs, buses=args.buses, framing=args.tcp_framing)

    print(f"Target: {ctx.host}  TCP:{ctx.tcp_port} ({ctx.framing})  UDP:{ctx.udp_port}  "
          f"mixer name: {ctx.mixer_name!r}\n")
    results = suite.run(ctx, only=args.only, include_destructive=args.include_destructive)

    passed = sum(1 for r in results if r.passed)
    failed = [r for r in results if not r.passed]
    print(f"\n{passed}/{len(results)} passed")
    if failed:
        print("\nFailures:")
        for r in failed:
            print(f"  - {r.name}: {r.detail}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
