#!/usr/bin/env python3
"""
FPGAmixer AVB network setup (Phase 9, P9.6): the Linux half of the AVB front
door, network side. Run once at boot by fpgamixer-avb-net.service, after end0
exists and before ptp4l starts (so the root qdisc change doesn't disturb it).

From ONE config file (/etc/fpgamixer/avb.conf) it:

  1. sets the kernel's TAI offset (CLOCK_TAI - CLOCK_REALTIME), decision A3.
     The alsa-plugins AAF plugin hard-codes TAI = UTC + 37 s when it arms its
     timer, and phc2sys only sets the offset when the grandmaster announces
     it as valid and traceable, which a default ptp4l doesn't. With the
     offset left at 0 the plugin would arm its timer 37 s in the past.
     phc2sys still overrides this value if a grandmaster ever announces a
     different, traceable one (a leap second).
  2. creates the stream VLAN interface (end0.2, VLAN 2), mapping socket
     priority PCP -> VLAN PCP (egress-qos-map), decision A6. gPTP stays
     untagged on end0.
  3. shapes end0's transmit side, decision A2 (software: the ZynqMP GEM has no
     TC offload in macb, and 2 TX queues):
        root  mqprio  2 classes: socket priority PCP -> TC 1 -> TX queue 1
                      (the GEM serves the higher queue first); everything
                      else, gPTP included -> TC 0 -> queue 0
        TC 1  cbs     credit-based shaper, class A, idleslope from the config
                      (with headroom; refused if below the stream's own rate)
        under etf     releases each AAF PDU at its SO_TXTIME launch time
                      (CLOCK_TAI), which the plugin's talker relies on
  4. writes the AAF ALSA devices (avb_tx, avb_rx) to
     /etc/alsa/conf.d/50-fpgamixer-avb.conf, decision A7. Generated, not
     static: a static file including a missing one would break every ALSA
     program on the board (the USB bridge too); a generated file is simply
     absent until this has run.
  5. checks the bridge geometry ([bridge], P9.7) against the AAF plugin's and
     the link card's limits and writes it for fpgamixer-avb-bridge.service
     (/run/fpgamixer/avb-bridge.env), so the config has one parser.

    avb_net.py [--config FILE] [--dry-run]     # --dry-run: print, change nothing

Design and numbers: docs/phase9_status_2026-09-26.md sec. 6.12 in the repo.
"""

import argparse
import configparser
import ctypes
import ctypes.util
import json
import math
import os
import re
import subprocess
import sys

DEFAULT_CONFIG = "/etc/fpgamixer/avb.conf"
ALSA_OUT = "/etc/alsa/conf.d/50-fpgamixer-avb.conf"

# Bytes per sample for the formats the AAF plugin accepts.
SAMPLE_BYTES = {"S16_BE": 2, "S24_3BE": 3, "S32_BE": 4, "FLOAT_BE": 4}

AVTP_AAF_HEADER = 24        # IEEE 1722 AAF stream PDU header
ETH_HEADER = 14
VLAN_TAG = 4
FCS = 4
PREAMBLE_SFD_IPG = 8 + 12   # on the wire only
MAX_INTERFERING_FRAME = 1522   # a full-size tagged best-effort frame
LINK_PERIOD_FRAMES = (6, 1600)  # FPGAmixerLink2: 192..51200 B per period at 8 ch x 4 B
LINK_PERIODS = (2, 6)
BRIDGE_ENV = "/run/fpgamixer/avb-bridge.env"
# Phase 10: what the AVDECC entity (avb_entityd) may switch a stream to, per
# direction, at run time: AAF INT_24BIT, or INT_32BIT carrying 24 bits (Milan).
# The shaper is set once at boot, so it is sized for the larger of them.
AAF_FORMATS = ("S24_3BE", "S32_BE")
RUNTIME = "/run/fpgamixer/avb-stream.json"


# ------------------------------------------------------------------ config

def load_config(path):
    cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    if not cp.read(path):
        raise SystemExit(f"avb_net: no config at {path}")
    net, st, tx, rx, br = cp["net"], cp["stream"], cp["tx"], cp["rx"], cp["bridge"]
    cfg = {
        "parent": net.get("parent"),
        "vlan_id": net.getint("vlan_id"),
        "pcp": net.getint("pcp"),
        "tai_offset": net.getint("tai_offset"),
        "link_mbps": net.getint("link_mbps"),
        "idleslope_kbps": net.getint("idleslope_kbps"),
        "etf_delta_us": net.getint("etf_delta_us"),
        "channels": st.getint("channels"),
        "format": st.get("format"),
        "rate": st.getint("rate"),
        "frames_per_pdu": st.getint("frames_per_pdu"),
        "mtt_us": st.getint("mtt_us"),
        "time_uncertainty_us": st.getint("time_uncertainty_us"),
        "ptime_tolerance_us": st.getint("ptime_tolerance_us"),
        "tx_addr": tx.get("addr"),
        "tx_streamid": tx.get("streamid"),
        "rx_addr": rx.get("addr"),
        "rx_streamid": rx.get("streamid"),
        "period_frames": br.getint("period_frames"),
        "periods": br.getint("periods"),
        "queue_periods": br.getint("queue_periods"),
    }
    cfg["rx_format"] = cfg["tx_format"] = cfg["format"]
    check_config(cfg)
    return cfg


def sid_str(stream_id):
    """A 64-bit stream ID as the plugin's 'XX:XX:XX:XX:XX:XX:XXXX'."""
    b = stream_id.to_bytes(8, "big")
    return ":".join(f"{x:02X}" for x in b[:6]) + ":" + b[6:].hex().upper()


def apply_runtime(cfg, path=RUNTIME):
    """cfg with the AVDECC entity's run-time choices applied (Phase 10): the
    listener's binding (rx addr, stream ID, format) and the talker's format,
    from the JSON avb_entityd writes. No file: cfg unchanged."""
    try:
        with open(path) as f:
            rt = json.load(f)
    except FileNotFoundError:
        return cfg
    c = dict(cfg)
    rx = rt.get("rx") or {}
    for k_json, k_cfg in (("addr", "rx_addr"), ("streamid", "rx_streamid"),
                          ("format", "rx_format")):
        if rx.get(k_json):
            c[k_cfg] = rx[k_json]
    tx = rt.get("tx") or {}
    if tx.get("format"):
        c["tx_format"] = tx["format"]
    if tx.get("mtt_us"):
        c["mtt_us"] = int(tx["mtt_us"])
    check_config(c)
    return c


def write_runtime(rx=None, tx_format=None, tx_mtt_us=None, path=RUNTIME):
    """Record the entity's choices (see apply_runtime); None keeps a value."""
    try:
        with open(path) as f:
            rt = json.load(f)
    except FileNotFoundError:
        rt = {}
    if rx is not None:
        rt["rx"] = rx
    if tx_format is not None:
        rt.setdefault("tx", {})["format"] = tx_format
    if tx_mtt_us is not None:
        rt.setdefault("tx", {})["mtt_us"] = tx_mtt_us
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rt, f)
    os.replace(tmp, path)


_MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$")
_SID_RE = re.compile(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}:[0-9A-Fa-f]{4}$")


def check_config(cfg):
    # The plugin's listener drops PDUs with another stream ID without a word
    # (a debug print only), so a wrong or placeholder ID must stop here.
    for k in ("tx_addr", "rx_addr"):
        if not _MAC_RE.match(cfg[k] or ""):
            raise SystemExit(f"avb_net: {k} {cfg[k]!r} is not a MAC address")
    for k in ("tx_streamid", "rx_streamid"):
        if not _SID_RE.match(cfg[k] or ""):
            raise SystemExit(f"avb_net: {k} {cfg[k]!r} is not MAC:XXXX")
    for k in ("format", "rx_format", "tx_format"):
        if cfg[k] not in AAF_FORMATS:
            raise SystemExit(f"avb_net: {k} {cfg[k]}: the AAF streams take "
                             f"{', '.join(AAF_FORMATS)}")
    if not 1 <= cfg["mtt_us"] <= 1_000_000:
        raise SystemExit(f"avb_net: mtt_us {cfg['mtt_us']}: 1..1000000")
    if not 1 <= cfg["pcp"] <= 7:
        raise SystemExit("avb_net: pcp must be 1..7 (0 is best effort)")
    if not 1 <= cfg["vlan_id"] <= 4094:
        raise SystemExit("avb_net: vlan_id must be 1..4094")
    need = max_wire_kbps(cfg)
    if cfg["idleslope_kbps"] < need:
        raise SystemExit(f"avb_net: idleslope {cfg['idleslope_kbps']} kbit/s is below the "
                         f"stream's own {need} kbit/s on the wire (its largest format)")
    if cfg["idleslope_kbps"] >= cfg["link_mbps"] * 1000:
        raise SystemExit("avb_net: idleslope must be below the link rate")
    # [bridge]: the AAF plugin needs a period that is a multiple of
    # frames_per_pdu; the link card (Phase 8 sec. 17) takes 192..51200 bytes
    # per period (8 ch x 4 B: 6..1600 frames) and 2..6 periods.
    p = cfg["period_frames"]
    if p % cfg["frames_per_pdu"] or not LINK_PERIOD_FRAMES[0] <= p <= LINK_PERIOD_FRAMES[1]:
        raise SystemExit(f"avb_net: period_frames {p}: a multiple of frames_per_pdu "
                         f"({cfg['frames_per_pdu']}) within {LINK_PERIOD_FRAMES[0]}.."
                         f"{LINK_PERIOD_FRAMES[1]}")
    if not LINK_PERIODS[0] <= cfg["periods"] <= LINK_PERIODS[1]:
        raise SystemExit(f"avb_net: periods {cfg['periods']}: the link card takes "
                         f"{LINK_PERIODS[0]}..{LINK_PERIODS[1]}")
    if not 1 <= cfg["queue_periods"] < cfg["periods"]:
        raise SystemExit("avb_net: queue_periods must be at least 1 and below periods")


# ----------------------------------------------------------------- numbers

def pdu_payload_bytes(cfg, fmt=None):
    return cfg["channels"] * SAMPLE_BYTES[fmt or cfg["format"]] * cfg["frames_per_pdu"]


def avtpdu_bytes(cfg, fmt=None):
    """The AVTPDU (AAF header + payload): MSRP's MaxFrameSize."""
    return AVTP_AAF_HEADER + pdu_payload_bytes(cfg, fmt)


def frame_bytes(cfg, fmt=None):
    """One AAF PDU as an Ethernet frame (VLAN tag and FCS, no preamble/gap)."""
    return ETH_HEADER + VLAN_TAG + AVTP_AAF_HEADER + pdu_payload_bytes(cfg, fmt) + FCS


def pdus_per_second(cfg):
    return cfg["rate"] / cfg["frames_per_pdu"]


def stream_wire_kbps(cfg, fmt=None):
    """The stream's rate on the wire (preamble and gap included), kbit/s,
    rounded up."""
    bits = (frame_bytes(cfg, fmt) + PREAMBLE_SFD_IPG) * 8 * pdus_per_second(cfg)
    return math.ceil(bits / 1000)


def max_wire_kbps(cfg):
    return max(stream_wire_kbps(cfg, f) for f in AAF_FORMATS)


def cbs_params(cfg):
    """(idleslope, sendslope, hicredit, locredit) for tc cbs, per
    tc-cbs(8) / 802.1Q: kbit/s for the slopes, bytes for the credits.
    hicredit: the credit built up while one maximum interfering frame is sent;
    locredit: the credit spent by one maximum frame of this class."""
    port = cfg["link_mbps"] * 1000
    idle = cfg["idleslope_kbps"]
    send = idle - port
    hi = math.ceil(MAX_INTERFERING_FRAME * idle / port)
    lo = math.floor(max(frame_bytes(cfg, f) for f in AAF_FORMATS) * send / port)
    return idle, send, hi, lo


def mqprio_map(pcp):
    """Socket priority 0..15 -> traffic class: only the stream's PCP -> TC 1."""
    return [1 if p == pcp else 0 for p in range(16)]


def vlan_name(cfg):
    return f"{cfg['parent']}.{cfg['vlan_id']}"


# ---------------------------------------------------------------- commands

def net_commands(cfg):
    """The ip/tc commands, in order. Re-runnable: the root qdisc is deleted
    first (qdisc_del, its failure ignored when there is none), because
    mqprio can't be changed in place ('tc qdisc replace' on an existing
    mqprio fails: "Change operation not supported", found on the Phase 10
    bench); the VLAN add is skipped by the caller when the interface exists."""
    dev, vl = cfg["parent"], vlan_name(cfg)
    idle, send, hi, lo = cbs_params(cfg)
    return {
        "qdisc_del": ["tc", "qdisc", "del", "dev", dev, "root"],
        "link_up": ["ip", "link", "set", "dev", dev, "up"],
        "vlan_add": ["ip", "link", "add", "link", dev, "name", vl, "type", "vlan",
                     "id", str(cfg["vlan_id"]),
                     "egress-qos-map", f"{cfg['pcp']}:{cfg['pcp']}"],
        "vlan_up": ["ip", "link", "set", "dev", vl, "up"],
        "qdiscs": [
            ["tc", "qdisc", "replace", "dev", dev, "root", "handle", "100:", "mqprio",
             "num_tc", "2", "map", *map(str, mqprio_map(cfg["pcp"])),
             "queues", "1@0", "1@1", "hw", "0"],
            # mqprio's children are per TX queue: class 100:2 = queue 1 = TC 1
            ["tc", "qdisc", "replace", "dev", dev, "parent", "100:2", "handle", "200:",
             "cbs", "idleslope", str(idle), "sendslope", str(send),
             "hicredit", str(hi), "locredit", str(lo), "offload", "0"],
            ["tc", "qdisc", "replace", "dev", dev, "parent", "200:1", "etf",
             "clockid", "CLOCK_TAI", "delta", str(cfg["etf_delta_us"] * 1000)],
        ],
    }


def alsa_conf(cfg):
    """The AAF PCM devices, in alsa-lib's configuration syntax. S32_BE is
    AAF INT_32BIT with bit_depth 24 (the plugin's bit_depth key, our patch)."""
    common = (f"    ifname \"{vlan_name(cfg)}\"\n"
              f"    frames_per_pdu {cfg['frames_per_pdu']}\n")

    def dev(name, addr, sid, fmt, extra):
        depth = "    bit_depth 24\n" if fmt == "S32_BE" else ""
        return (f"pcm.{name} {{\n    type aaf\n{common}"
                f"    addr \"{addr}\"\n    streamid \"{sid}\"\n{depth}{extra}}}\n")

    return ("# Generated by avb_net.py (fpgamixer-avb-net.service at boot; avb_entityd\n"
            "# when a controller binds a stream) from /etc/fpgamixer/avb.conf and\n"
            f"# {RUNTIME}. Edits here are lost: change avb.conf.\n"
            f"# Streams: {cfg['channels']} ch {cfg['rate']} Hz, {cfg['frames_per_pdu']} "
            f"frames/PDU; avb_tx {cfg['tx_format']}, avb_rx {cfg['rx_format']}. The\n"
            "# application must use exactly these, and a period that is a multiple of\n"
            "# frames_per_pdu.\n"
            + dev("avb_tx", cfg["tx_addr"], cfg["tx_streamid"], cfg["tx_format"],
                  f"    prio {cfg['pcp']}\n    mtt {cfg['mtt_us']}\n"
                  f"    time_uncertainty {cfg['time_uncertainty_us']}\n")
            + dev("avb_rx", cfg["rx_addr"], cfg["rx_streamid"], cfg["rx_format"],
                  f"    ptime_tolerance {cfg['ptime_tolerance_us']}\n"))


def bridge_env(cfg):
    """The EnvironmentFile line for fpgamixer-avb-bridge.service."""
    return (f"AVB_BRIDGE_ARGS=-p {cfg['period_frames']} -n {cfg['periods']} "
            f"-q {cfg['queue_periods']} -F {cfg['rx_format']} -G {cfg['tx_format']}\n")


def write_stream_files(cfg, dry=False):
    """Steps 4 and 5: the ALSA devices and the bridge's arguments. Also what
    avb_entityd calls after a binding or format change (then it restarts the
    bridge)."""
    text = alsa_conf(cfg)
    env = bridge_env(cfg)
    if dry:
        print(f"  (would write {ALSA_OUT}:)\n" + text)
        print(f"  (would write {BRIDGE_ENV}: {env.strip()})")
        return
    for path, content in ((ALSA_OUT, text), (BRIDGE_ENV, env)):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(content)
        os.replace(tmp, path)
    print(f"avb_net: wrote {ALSA_OUT} (avb_tx {cfg['tx_format']}, avb_rx {cfg['rx_format']} "
          f"from {cfg['rx_streamid']} on {vlan_name(cfg)}) and {BRIDGE_ENV} ({env.strip()})",
          flush=True)


# --------------------------------------------------------------- TAI offset

class _Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class _Timex(ctypes.Structure):
    """struct timex (include/uapi/linux/timex.h); ctypes lays out the padding."""
    _fields_ = [("modes", ctypes.c_uint), ("offset", ctypes.c_long),
                ("freq", ctypes.c_long), ("maxerror", ctypes.c_long),
                ("esterror", ctypes.c_long), ("status", ctypes.c_int),
                ("constant", ctypes.c_long), ("precision", ctypes.c_long),
                ("tolerance", ctypes.c_long), ("time", _Timeval),
                ("tick", ctypes.c_long), ("ppsfreq", ctypes.c_long),
                ("jitter", ctypes.c_long), ("shift", ctypes.c_int),
                ("stabil", ctypes.c_long), ("jitcnt", ctypes.c_long),
                ("calcnt", ctypes.c_long), ("errcnt", ctypes.c_long),
                ("stbcnt", ctypes.c_long), ("tai", ctypes.c_int),
                ("_pad", ctypes.c_int * 11)]


ADJ_TAI = 0x0080


def _adjtimex(tx):
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    if libc.adjtimex(ctypes.byref(tx)) < 0:
        raise OSError(ctypes.get_errno(), "adjtimex failed")
    return tx


def get_tai_offset():
    return _adjtimex(_Timex(modes=0)).tai


def set_tai_offset(seconds):
    _adjtimex(_Timex(modes=ADJ_TAI, constant=seconds))
    return get_tai_offset()


# -------------------------------------------------------------------- main

def _run(argv, dry, check=True):
    print("  " + " ".join(argv), flush=True)
    if not dry:
        subprocess.run(argv, check=check)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    cfg = load_config(a.config)
    dry = a.dry_run

    idle, send, hi, lo = cbs_params(cfg)
    print(f"avb_net: stream {cfg['channels']} ch {cfg['format']} @ {cfg['rate']} Hz, "
          f"{cfg['frames_per_pdu']} frames/PDU: {frame_bytes(cfg)} B frames, "
          f"{pdus_per_second(cfg):.0f} PDU/s, {stream_wire_kbps(cfg)} kbit/s on the wire "
          f"({max_wire_kbps(cfg)} in its largest format); "
          f"CBS idleslope {idle} sendslope {send} hicredit {hi} locredit {lo}", flush=True)

    # 1. TAI offset
    if dry:
        print(f"  (would set the kernel TAI offset to {cfg['tai_offset']} s)")
    else:
        before = get_tai_offset()
        after = set_tai_offset(cfg["tai_offset"]) if before != cfg["tai_offset"] else before
        print(f"avb_net: kernel TAI offset {before} -> {after} s", flush=True)
        if after != cfg["tai_offset"]:
            raise SystemExit("avb_net: the kernel didn't take the TAI offset")

    # 2. VLAN, 3. qdiscs
    cmds = net_commands(cfg)
    _run(cmds["link_up"], dry)
    if os.path.exists(f"/sys/class/net/{vlan_name(cfg)}") and not dry:
        print(f"  ({vlan_name(cfg)} exists)")
    else:
        _run(cmds["vlan_add"], dry)
    _run(cmds["vlan_up"], dry)
    _run(cmds["qdisc_del"], dry, check=False)      # none at boot: fails, fine
    for c in cmds["qdiscs"]:
        _run(c, dry)

    # 4. ALSA devices, 5. the bridge's geometry and formats (P9.7, Phase 10)
    write_stream_files(apply_runtime(cfg), dry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
