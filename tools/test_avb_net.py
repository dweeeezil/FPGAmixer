#!/usr/bin/env python3
"""
Unit tests for avb_net.py (Phase 9, P9.6): the numbers, the commands and the
ALSA text it derives from avb.conf. Nothing here touches the network or the
kernel, so it runs anywhere:

    python3 -m unittest -v test_avb_net          (from tools/)
"""

import os
import shutil
import tempfile
import unittest

import avb_net

REPO_CONF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "yocto",
                         "meta-fpgamixer", "recipes-apps", "fpgamixer-avb", "files",
                         "avb.conf")
PI_SID = "50:7C:6F:8E:40:5B:0000"   # the bench Pi's eth4 MAC + 0000 (avb.conf)


def write_conf(text):
    d = tempfile.mkdtemp(prefix="avbconf-")
    p = os.path.join(d, "avb.conf")
    with open(p, "w") as f:
        f.write(text)
    return d, p


def repo_conf_text(**repl):
    with open(REPO_CONF) as f:
        text = f.read()
    for old, new in repl.items():
        assert old in text, old
        text = text.replace(old, new)
    return text


class Config(unittest.TestCase):
    def load(self, **repl):
        d, p = write_conf(repo_conf_text(**repl))
        try:
            return avb_net.load_config(p)
        finally:
            shutil.rmtree(d)

    def test_repo_config_as_decided(self):
        c = self.load()
        self.assertEqual((c["parent"], c["vlan_id"], c["pcp"], c["tai_offset"]),
                         ("end0", 2, 3, 37))
        self.assertEqual((c["channels"], c["format"], c["rate"], c["frames_per_pdu"]),
                         (8, "S24_3BE", 48000, 6))
        self.assertEqual((c["mtt_us"], c["time_uncertainty_us"], c["ptime_tolerance_us"]),
                         (2000, 1000, 125))
        self.assertEqual(c["tx_addr"], "91:E0:F0:00:FE:00")
        self.assertEqual(c["rx_addr"], "91:E0:F0:00:FE:01")
        self.assertEqual(c["tx_streamid"], "00:18:3E:05:06:48:0000")

    def test_placeholder_stream_id_refused(self):
        with self.assertRaises(SystemExit) as cm:
            self.load(**{PI_SID: "PI_ETH4_MAC:0000"})
        self.assertIn("rx_streamid", str(cm.exception))

    def test_stream_id_without_unique_id_refused(self):
        with self.assertRaises(SystemExit):
            self.load(**{PI_SID: PI_SID[:-5]})

    def test_bad_addr_refused(self):
        with self.assertRaises(SystemExit):
            self.load(**{"addr = 91:E0:F0:00:FE:00": "addr = 91:E0:F0:00:FE"})

    def test_idleslope_below_stream_refused(self):
        with self.assertRaises(SystemExit) as cm:
            self.load(**{"idleslope_kbps = 20000": "idleslope_kbps = 16000"})
        self.assertIn("16512", str(cm.exception))      # S32_BE, the larger format

    def test_unknown_format_refused(self):
        with self.assertRaises(SystemExit):
            self.load(**{"format = S24_3BE": "format = S24_LE"})

    def test_bridge_geometry_as_decided(self):
        c = self.load()
        self.assertEqual((c["period_frames"], c["periods"], c["queue_periods"]), (96, 4, 2))
        self.assertEqual(avb_net.bridge_env(c),
                         "AVB_BRIDGE_ARGS=-p 96 -n 4 -q 2 -F S24_3BE -G S24_3BE\n")

    def test_bridge_period_not_multiple_of_pdu_refused(self):
        with self.assertRaises(SystemExit) as cm:
            self.load(**{"period_frames = 96": "period_frames = 100"})
        self.assertIn("frames_per_pdu", str(cm.exception))

    def test_bridge_limits_refused(self):
        for repl in ({"period_frames = 96": "period_frames = 1602"},   # > 1600
                     {"periods = 4": "periods = 7"},                    # link: 2..6
                     {"queue_periods = 2": "queue_periods = 4"},        # must be < periods
                     {"queue_periods = 2": "queue_periods = 0"}):
            with self.assertRaises(SystemExit, msg=repl):
                self.load(**repl)


class Numbers(unittest.TestCase):
    def setUp(self):
        d, p = write_conf(repo_conf_text())
        self.c = avb_net.load_config(p)
        shutil.rmtree(d)

    def test_stream_size_and_rate(self):
        # 8 ch x 3 B x 6 frames = 144 B payload; + 24 AVTP + 14 Eth + 4 VLAN + 4 FCS
        self.assertEqual(avb_net.pdu_payload_bytes(self.c), 144)
        self.assertEqual(avb_net.frame_bytes(self.c), 190)
        self.assertEqual(avb_net.pdus_per_second(self.c), 8000)
        # + 20 B preamble/gap = 210 B x 8000/s = 13.44 Mbit/s (status doc 6.12)
        self.assertEqual(avb_net.stream_wire_kbps(self.c), 13440)
        # S32_BE (Phase 10): 8 x 4 x 6 = 192 B payload, 238 B frames, 258 on the wire
        self.assertEqual(avb_net.frame_bytes(self.c, "S32_BE"), 238)
        self.assertEqual(avb_net.stream_wire_kbps(self.c, "S32_BE"), 16512)
        self.assertEqual(avb_net.max_wire_kbps(self.c), 16512)
        self.assertEqual(avb_net.avtpdu_bytes(self.c), 168)
        self.assertEqual(avb_net.avtpdu_bytes(self.c, "S32_BE"), 216)

    def test_cbs(self):
        idle, send, hi, lo = avb_net.cbs_params(self.c)
        self.assertEqual((idle, send), (20000, -980000))
        self.assertEqual(hi, 31)        # ceil(1522 x 20/1000) = ceil(30.44)
        self.assertEqual(lo, -234)      # floor(238 x -0.98) = floor(-233.24): the larger frame

    def test_mqprio_map_only_pcp(self):
        m = avb_net.mqprio_map(3)
        self.assertEqual(len(m), 16)
        self.assertEqual(m[3], 1)
        self.assertEqual(sum(m), 1)


class Commands(unittest.TestCase):
    def setUp(self):
        d, p = write_conf(repo_conf_text())
        self.c = avb_net.load_config(p)
        shutil.rmtree(d)
        self.cmds = avb_net.net_commands(self.c)

    def test_vlan(self):
        v = self.cmds["vlan_add"]
        self.assertEqual(v[:7], ["ip", "link", "add", "link", "end0", "name", "end0.2"])
        self.assertEqual(v[v.index("id") + 1], "2")
        self.assertEqual(v[v.index("egress-qos-map") + 1], "3:3")

    def test_qdisc_chain(self):
        self.assertEqual(self.cmds["qdisc_del"], ["tc", "qdisc", "del", "dev", "end0", "root"])
        mq, cbs = self.cmds["qdiscs"]       # no ETF (Phase 10, status doc sec. 14)
        self.assertEqual(mq[mq.index("root") + 2], "100:")
        self.assertIn("mqprio", mq)
        self.assertEqual(mq[mq.index("map") + 1: mq.index("map") + 17],
                         ["0", "0", "0", "1"] + ["0"] * 12)
        self.assertEqual(mq[mq.index("queues") + 1: mq.index("queues") + 3], ["1@0", "1@1"])
        self.assertEqual(mq[mq.index("hw") + 1], "0")
        # CBS on TC 1's queue (class 100:2)
        self.assertEqual(cbs[cbs.index("parent") + 1], "100:2")
        self.assertEqual(cbs[cbs.index("idleslope") + 1], "20000")
        self.assertEqual(cbs[cbs.index("offload") + 1], "0")

    def test_alsa_conf(self):
        t = avb_net.alsa_conf(self.c)
        tx = t[t.index("pcm.avb_tx"):t.index("pcm.avb_rx")]
        rx = t[t.index("pcm.avb_rx"):]
        for block in (tx, rx):
            self.assertIn("type aaf", block)
            self.assertIn('ifname "end0.2"', block)
            self.assertIn("frames_per_pdu 6", block)
        self.assertIn('addr "91:E0:F0:00:FE:00"', tx)
        self.assertIn('streamid "00:18:3E:05:06:48:0000"', tx)
        self.assertIn("prio 3", tx)
        self.assertIn("mtt 2000", tx)
        self.assertIn("time_uncertainty 1000", tx)
        self.assertIn('addr "91:E0:F0:00:FE:01"', rx)
        self.assertIn(f'streamid "{PI_SID}"', rx)
        self.assertIn("ptime_tolerance 125", rx)
        self.assertNotIn("prio", rx)
        self.assertEqual(t.count("{"), t.count("}"))


class Runtime(unittest.TestCase):
    """Phase 10: the AVDECC entity's choices, through the runtime JSON."""

    def setUp(self):
        d, p = write_conf(repo_conf_text())
        self.c = avb_net.load_config(p)
        shutil.rmtree(d)
        self.d = tempfile.mkdtemp(prefix="avbrt-")
        self.rt = os.path.join(self.d, "avb-stream.json")

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_no_file_no_change(self):
        self.assertEqual(avb_net.apply_runtime(self.c, self.rt), self.c)

    def test_binding_and_formats_applied(self):
        sid = avb_net.sid_str(0x0A0B0C0D0E0F0001)
        self.assertEqual(sid, "0A:0B:0C:0D:0E:0F:0001")
        avb_net.write_runtime(rx={"addr": "91:E0:F0:00:12:34", "streamid": sid,
                                  "format": "S32_BE"}, path=self.rt)
        avb_net.write_runtime(tx_format="S32_BE", path=self.rt)      # keeps rx
        c = avb_net.apply_runtime(self.c, self.rt)
        self.assertEqual((c["rx_addr"], c["rx_streamid"], c["rx_format"], c["tx_format"]),
                         ("91:E0:F0:00:12:34", sid, "S32_BE", "S32_BE"))
        t = avb_net.alsa_conf(c)
        tx = t[t.index("pcm.avb_tx"):t.index("pcm.avb_rx")]
        rx = t[t.index("pcm.avb_rx"):]
        self.assertIn("bit_depth 24", tx)
        self.assertIn("bit_depth 24", rx)
        self.assertIn(f'streamid "{sid}"', rx)
        self.assertEqual(avb_net.bridge_env(c),
                         "AVB_BRIDGE_ARGS=-p 96 -n 4 -q 2 -F S32_BE -G S32_BE\n")

    def test_mtt_override(self):
        avb_net.write_runtime(tx_mtt_us=1500, path=self.rt)
        c = avb_net.apply_runtime(self.c, self.rt)
        self.assertEqual(c["mtt_us"], 1500)
        self.assertIn("mtt 1500", avb_net.alsa_conf(c))

    def test_s24_has_no_bit_depth(self):
        self.assertNotIn("bit_depth", avb_net.alsa_conf(self.c))

    def test_bad_runtime_refused(self):
        avb_net.write_runtime(rx={"streamid": "not-an-id"}, path=self.rt)
        with self.assertRaises(SystemExit):
            avb_net.apply_runtime(self.c, self.rt)


if __name__ == "__main__":
    unittest.main()
