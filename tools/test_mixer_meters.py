#!/usr/bin/env python3
"""
Unit tests for mixer_meters.py (Phase 13): the scale, the blob, and MeterHub's
subscription rules, driven with a scripted source, a fake clock and captured
datagrams (no sockets, no sleeps). Runs anywhere.

    python3 -m unittest -v test_mixer_meters        (from tools/)
"""

import struct
import unittest

import mixer_meters as mm
from osc_codec import decode_packet


class Scale(unittest.TestCase):
    def test_centibels(self):
        self.assertEqual(mm.centibels(0), mm.SILENCE)
        self.assertEqual(mm.centibels(-5), mm.SILENCE)
        self.assertEqual(mm.centibels((1 << 23) - 1), 0)                 # full scale reads 0.00
        self.assertEqual(mm.centibels(1 << 22), -602)                    # half: -6.02 dBFS
        self.assertEqual(mm.centibels(1), -13847)                        # 1 LSB: -138.47 dBFS
        self.assertEqual(mm.centibels(1 << 30), 4214)                    # +42.14 dBFS fits
        self.assertEqual(mm.centibels(1 << 200), 32767)                  # clamped, never wraps

    def test_blob_is_big_endian_seq_then_int16s(self):
        b = mm.meter_blob(0x1_0000_0002, [0, 1 << 22, (1 << 23) - 1])     # seq wraps at 2^32
        self.assertEqual(b, struct.pack(">Ihhh", 2, -32768, -602, 0))

    def test_zones_from_mask(self):
        have = {"inputChannel": 4, "outputChannel": 4}
        self.assertEqual(mm.zones_from_mask(0b111, have), ["inputChannel", "outputChannel"])
        self.assertEqual(mm.zones_from_mask(0b010, have), [])            # busChannel: not here
        self.assertEqual(mm.zones_from_mask(0b1000 | 0b1, have), ["inputChannel"])   # unknown bits


class Synthetic(unittest.TestCase):
    def test_follows_level(self):
        levels = {("inputChannel", 0): 0.0, ("inputChannel", 1): -90.0, ("inputChannel", 2): 6.0}
        s = mm.SyntheticMeterSource({"inputChannel": 3}, lambda z, c: levels.get((z, c)))
        p = s.sample()["inputChannel"]
        self.assertEqual(mm.centibels(p[0]), -1200)                      # BASE_DB
        self.assertEqual(p[1], 0)                                        # off: silence
        self.assertEqual(mm.centibels(p[2]), -1200 - 600 + 600)          # ch 2: -6 base, +6 level


class FakeSource(mm.MeterSource):
    """Scripted samples: each sample() pops the next {zone: peaks}; when the
    script runs out, every channel reads `quiet`."""

    def __init__(self, sizes, quiet=10):
        self.sizes, self.quiet, self.script, self.calls = sizes, quiet, [], 0

    def zones(self):
        return dict(self.sizes)

    def sample(self):
        self.calls += 1
        s = {z: [self.quiet] * n for z, n in self.sizes.items()}
        if self.script:
            s.update(self.script.pop(0))
        return s


class Hub(unittest.TestCase):
    SIZES = {"inputChannel": 3, "busChannel": 2, "outputChannel": 3}

    def setUp(self):
        self.now = 100.0
        self.sent = []
        self.src = FakeSource(self.SIZES)
        self.hub = mm.MeterHub(self.src, lambda pkt, addr: self.sent.append((pkt, addr)),
                               lambda: "FOH", clock=lambda: self.now)

    def advance(self, dt, period=None):
        """Run the sampler for dt seconds at its own period (or `period`)."""
        end = self.now + dt
        while self.now < end - 1e-9:
            self.hub.tick()
            self.now += period or self.hub.period() or 0.01

    def msgs(self, port=None, zone=None):
        out = []
        for pkt, addr in self.sent:
            m = decode_packet(pkt)[0]
            z = m.address.rsplit("/", 1)[1]
            seq = struct.unpack(">I", m.args[0][:4])[0]
            peaks = list(struct.unpack(f">{(len(m.args[0]) - 4) // 2}h", m.args[0][4:]))
            if (port is None or addr[1] == port) and (zone is None or z == zone):
                out.append((m.address, addr, seq, peaks))
        return out

    def test_nothing_sampled_without_subscribers(self):
        self.advance(1.0, period=0.01)
        self.assertEqual((self.src.calls, self.sent), (0, []))

    def test_messages_address_rate_and_per_zone_sequences(self):
        self.hub.subscribe("A", "10.0.0.9", 9000, 30, ["inputChannel", "outputChannel"])
        self.advance(1.0)
        ins = self.msgs(zone="inputChannel")
        outs = self.msgs(zone="outputChannel")
        self.assertEqual(ins[0][:2], ("/FOH/meter/inputChannel", ("10.0.0.9", 9000)))
        self.assertTrue(29 <= len(ins) <= 31, len(ins))
        self.assertEqual([m[2] for m in ins], list(range(len(ins))))     # 0, 1, 2, ...
        self.assertEqual([m[2] for m in outs], list(range(len(outs))))   # its own sequence
        self.assertEqual(len(ins[0][3]), 3)                              # N = the zone's count
        self.assertEqual(self.msgs(zone="busChannel"), [])

    def test_blobs_follow_the_channel_counts(self):
        """Phase 15: after set_visible each blob carries the zone's first
        `count` channels; zones not named keep all; more than the source
        has is capped."""
        self.hub.subscribe("A", "10.0.0.9", 9000, 30, ["inputChannel", "busChannel", "outputChannel"])
        self.advance(0.1)
        self.hub.set_visible({"inputChannel": 1, "outputChannel": 9})
        self.sent.clear()
        self.advance(0.1)
        self.assertEqual({len(m[3]) for m in self.msgs(zone="inputChannel")}, {1})
        self.assertEqual({len(m[3]) for m in self.msgs(zone="busChannel")}, {2})
        self.assertEqual({len(m[3]) for m in self.msgs(zone="outputChannel")}, {3})

    def test_a_transient_reaches_every_subscriber_exactly_once(self):
        """Two subscribers at different rates; one source sample carries a
        spike: each sees it in exactly one message, none loses it."""
        self.hub.subscribe("A", "10.0.0.9", 9000, 30, ["busChannel"])
        self.hub.subscribe("B", "10.0.0.8", 9100, 7, ["busChannel"])
        self.advance(0.5)
        self.src.script.append({"busChannel": [10, 5_000_000]})
        self.advance(1.0)
        for port in (9000, 9100):
            spikes = [m for m in self.msgs(port=port, zone="busChannel")
                      if m[3][1] == mm.centibels(5_000_000)]
            self.assertEqual(len(spikes), 1, port)
        self.assertGreater(len(self.msgs(port=9000)), 2 * len(self.msgs(port=9100)))

    def test_sampler_runs_at_the_highest_rate(self):
        self.hub.subscribe("A", "h", 1, 10, ["inputChannel"])
        self.hub.subscribe("B", "h", 2, 50, ["inputChannel"])
        self.assertAlmostEqual(self.hub.period(), 1 / 50)

    def test_lease_expires_after_5_s_and_a_renewal_extends_it(self):
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])
        self.advance(4.0)
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])         # renew at t = 4
        self.advance(4.5)                                                # t = 8.5: still alive
        self.assertEqual(self.hub.active(), 1)
        self.advance(1.0)                                                # t = 9.5 > 4 + 5
        self.assertEqual(self.hub.active(), 0)
        n = len(self.sent)
        self.advance(1.0, period=0.1)
        self.assertEqual(len(self.sent), n)                              # nothing after expiry

    def test_move_port_keeps_sequences_and_new_zone_starts_at_0(self):
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])
        self.advance(0.5)
        last = self.msgs(port=9000, zone="inputChannel")[-1][2]
        self.hub.subscribe("A", "h", 9500, 10, ["inputChannel", "busChannel"])
        self.advance(0.5)
        moved = self.msgs(port=9500, zone="inputChannel")
        self.assertEqual(moved[0][2], last + 1)                          # continues
        self.assertEqual(self.msgs(port=9500, zone="busChannel")[0][2], 0)
        n = len(self.msgs(port=9000))
        self.advance(0.5)
        self.assertEqual(len(self.msgs(port=9000)), n)                   # the old port is quiet

    def test_empty_zones_unsubscribes_and_drop_ends_it(self):
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])
        self.hub.subscribe("B", "h", 9001, 10, ["inputChannel"])
        self.hub.subscribe("A", "h", 9000, 10, [])
        self.hub.drop("B")
        self.assertEqual(self.hub.active(), 0)

    def test_maxima_restart_after_each_message(self):
        self.hub.subscribe("A", "h", 9000, 10, ["outputChannel"])
        self.src.script.append({"outputChannel": [1 << 22, 10, 10]})
        self.advance(0.35, period=0.1)                                   # 4 ticks, 4 messages
        ch0 = [m[3][0] for m in self.msgs(zone="outputChannel")]
        self.assertEqual(ch0[0], -602)
        self.assertTrue(all(v == mm.centibels(10) for v in ch0[1:]), ch0)

    def test_name_is_read_at_send_time(self):
        current = ["FOH"]
        self.hub.name = lambda: current[0]
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])
        self.hub.tick()
        current[0] = "Stage"                                             # a rename
        self.now += 0.2
        self.hub.tick()
        self.assertEqual([m[0] for m in self.msgs()], ["/FOH/meter/inputChannel", "/Stage/meter/inputChannel"])

    def test_a_failing_send_doesnt_stop_the_others(self):
        def send(pkt, addr):
            if addr[1] == 9000:
                raise OSError("unreachable")
            self.sent.append((pkt, addr))
        self.hub.send = send
        self.hub.subscribe("A", "h", 9000, 10, ["inputChannel"])
        self.hub.subscribe("B", "h", 9001, 10, ["inputChannel"])
        self.hub.tick()
        self.assertEqual(len(self.msgs(port=9001)), 1)


if __name__ == "__main__":
    unittest.main()
