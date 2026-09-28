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

    avb_net.py [--config FILE] [--dry-run]     # --dry-run: print, change nothing

Design and numbers: docs/phase9_status_2026-09-26.md sec. 6.12 in the repo.
"""

import argparse
import configparser
import ctypes
import ctypes.util
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


# ------------------------------------------------------------------ config

def load_config(path):
    cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    if not cp.read(path):
        raise SystemExit(f"avb_net: no config at {path}")
    net, st, tx, rx = cp["net"], cp["stream"], cp["tx"], cp["rx"]
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
    }
    check_config(cfg)
    return cfg


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
    if cfg["format"] not in SAMPLE_BYTES:
        raise SystemExit(f"avb_net: format {cfg['format']}: the AAF plugin takes "
                         f"{', '.join(SAMPLE_BYTES)}")
    if not 1 <= cfg["pcp"] <= 7:
        raise SystemExit("avb_net: pcp must be 1..7 (0 is best effort)")
    if not 1 <= cfg["vlan_id"] <= 4094:
        raise SystemExit("avb_net: vlan_id must be 1..4094")
    need = stream_wire_kbps(cfg)
    if cfg["idleslope_kbps"] < need:
        raise SystemExit(f"avb_net: idleslope {cfg['idleslope_kbps']} kbit/s is below the "
                         f"stream's own {need} kbit/s on the wire")
    if cfg["idleslope_kbps"] >= cfg["link_mbps"] * 1000:
        raise SystemExit("avb_net: idleslope must be below the link rate")


# ----------------------------------------------------------------- numbers

def pdu_payload_bytes(cfg):
    return cfg["channels"] * SAMPLE_BYTES[cfg["format"]] * cfg["frames_per_pdu"]


def frame_bytes(cfg):
    """One AAF PDU as an Ethernet frame (VLAN tag and FCS, no preamble/gap)."""
    return ETH_HEADER + VLAN_TAG + AVTP_AAF_HEADER + pdu_payload_bytes(cfg) + FCS


def pdus_per_second(cfg):
    return cfg["rate"] / cfg["frames_per_pdu"]


def stream_wire_kbps(cfg):
    """The stream's rate on the wire (preamble and gap included), kbit/s,
    rounded up."""
    bits = (frame_bytes(cfg) + PREAMBLE_SFD_IPG) * 8 * pdus_per_second(cfg)
    return math.ceil(bits / 1000)


def cbs_params(cfg):
    """(idleslope, sendslope, hicredit, locredit) for tc cbs, per
    tc-cbs(8) / 802.1Q: kbit/s for the slopes, bytes for the credits.
    hicredit: the credit built up while one maximum interfering frame is sent;
    locredit: the credit spent by one maximum frame of this class."""
    port = cfg["link_mbps"] * 1000
    idle = cfg["idleslope_kbps"]
    send = idle - port
    hi = math.ceil(MAX_INTERFERING_FRAME * idle / port)
    lo = math.floor(frame_bytes(cfg) * send / port)
    return idle, send, hi, lo


def mqprio_map(pcp):
    """Socket priority 0..15 -> traffic class: only the stream's PCP -> TC 1."""
    return [1 if p == pcp else 0 for p in range(16)]


def vlan_name(cfg):
    return f"{cfg['parent']}.{cfg['vlan_id']}"


# ---------------------------------------------------------------- commands

def net_commands(cfg):
    """The ip/tc commands, in order. Each is idempotent: 'replace' for qdiscs,
    and the VLAN add is skipped by the caller when the interface exists."""
    dev, vl = cfg["parent"], vlan_name(cfg)
    idle, send, hi, lo = cbs_params(cfg)
    return {
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
    """The AAF PCM devices, in alsa-lib's configuration syntax."""
    common = (f"    ifname \"{vlan_name(cfg)}\"\n"
              f"    frames_per_pdu {cfg['frames_per_pdu']}\n")

    def dev(name, addr, sid, extra):
        return (f"pcm.{name} {{\n    type aaf\n{common}"
                f"    addr \"{addr}\"\n    streamid \"{sid}\"\n{extra}}}\n")

    return ("# Generated at boot by avb_net.py (fpgamixer-avb-net.service) from\n"
            "# /etc/fpgamixer/avb.conf. Edits here are lost: change avb.conf.\n"
            f"# Stream: {cfg['channels']} ch {cfg['format']} {cfg['rate']} Hz, "
            f"{cfg['frames_per_pdu']} frames/PDU; the application must use exactly this\n"
            "# format, and a period that is a multiple of frames_per_pdu.\n"
            + dev("avb_tx", cfg["tx_addr"], cfg["tx_streamid"],
                  f"    prio {cfg['pcp']}\n    mtt {cfg['mtt_us']}\n"
                  f"    time_uncertainty {cfg['time_uncertainty_us']}\n")
            + dev("avb_rx", cfg["rx_addr"], cfg["rx_streamid"],
                  f"    ptime_tolerance {cfg['ptime_tolerance_us']}\n"))


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

def _run(argv, dry):
    print("  " + " ".join(argv), flush=True)
    if not dry:
        subprocess.run(argv, check=True)


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
          f"{pdus_per_second(cfg):.0f} PDU/s, {stream_wire_kbps(cfg)} kbit/s on the wire; "
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
    for c in cmds["qdiscs"]:
        _run(c, dry)

    # 4. ALSA devices
    text = alsa_conf(cfg)
    if dry:
        print(f"  (would write {ALSA_OUT}:)\n" + text)
    else:
        os.makedirs(os.path.dirname(ALSA_OUT), exist_ok=True)
        tmp = ALSA_OUT + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, ALSA_OUT)
        print(f"avb_net: wrote {ALSA_OUT} (avb_tx, avb_rx on {vlan_name(cfg)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
