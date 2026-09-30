#!/usr/bin/env python3
"""
The FPGAmixer's AVDECC entity model (IEEE 1722.1 AEM): the descriptors a
controller (e.g. macOS's Network Device Browser) reads to learn what the
board is. No I/O; avdecc_entity.py serves them.

One configuration:

    ENTITY 0
    CONFIGURATION 0
      AUDIO_UNIT 0            48 kHz, 1 stream input port, 1 stream output port
        STREAM_PORT_INPUT 0   8 AUDIO_CLUSTERs (0-7), AUDIO_MAP 0
        STREAM_PORT_OUTPUT 0  8 AUDIO_CLUSTERs (8-15), AUDIO_MAP 1
      STREAM_INPUT 0          "AVB in": 8 ch AAF, 48 kHz  -> core inputs 12-19
      STREAM_OUTPUT 0         "AVB out": 8 ch AAF, 48 kHz <- core outputs 12-19
      AVB_INTERFACE 0         end0
      CLOCK_SOURCE 0          internal (mclk, locked to gPTP)
      CLOCK_DOMAIN 0
      LOCALE 0 -> STRINGS 0

Byte layouts: jdksavdecc-c include/jdksavdecc_aem_descriptor.h (offsets in
the comments); the STREAM descriptor also carries 1722.1-2013's
redundant_offset / number_of_redundant_streams before the formats, and says
where the formats are (formats_offset), so a parser of either revision
finds them.

AAF stream formats (1722.1 7.3.2.1.3; the packing checked against OpenAvnu's
avtp_pipeline openavb_descriptor_stream_io.c): byte 0 = v(1) | subtype(7) =
0x02, byte 1 = ut(1) | reserved(3) | nsr(4), byte 2 = format, byte 3 =
bit_depth, then channels_per_frame (10 bits), samples_per_frame (10 bits),
reserved (12 bits).

Phase 10, docs/phase10_status_2026-09-29.md.
"""

import struct

# descriptor types (jdksavdecc_aem_descriptor.h)
ENTITY = 0x0000
CONFIGURATION = 0x0001
AUDIO_UNIT = 0x0002
STREAM_INPUT = 0x0005
STREAM_OUTPUT = 0x0006
AVB_INTERFACE = 0x0009
CLOCK_SOURCE = 0x000A
LOCALE = 0x000C
STRINGS = 0x000D
STREAM_PORT_INPUT = 0x000E
STREAM_PORT_OUTPUT = 0x000F
AUDIO_CLUSTER = 0x0014
AUDIO_MAP = 0x0017
CLOCK_DOMAIN = 0x0024

NO_STRING = 0xFFFF                 # localized string reference: none

STREAM_FLAG_CLOCK_SYNC_SOURCE = 0x0001
STREAM_FLAG_CLASS_A = 0x0002
AVB_INTERFACE_FLAGS = 0x0001 | 0x0002 | 0x0004   # GM supported, gPTP, SRP
CLOCK_SOURCE_TYPE_INTERNAL = 0x0000
AUDIO_CLUSTER_FORMAT_MBLA = 0x40

# AAF
AAF_SUBTYPE = 0x02
AAF_NSR_48KHZ = 0x05
AAF_FORMAT_INT_32BIT = 0x02
AAF_FORMAT_INT_24BIT = 0x03
ALSA_TO_AAF = {"S24_3BE": (AAF_FORMAT_INT_24BIT, 24), "S32_BE": (AAF_FORMAT_INT_32BIT, 24)}


def aaf_format(alsa_fmt, channels=8, nsr=AAF_NSR_48KHZ, samples_per_frame=6):
    """The 64-bit AEM stream format for one of our AAF sample formats.
    S32_BE is sent as INT_32BIT with bit_depth 24 (Milan's base format)."""
    fmt, depth = ALSA_TO_AAF[alsa_fmt]
    return ((AAF_SUBTYPE << 56) | ((nsr & 0x0F) << 48) | (fmt << 40) | (depth << 32) |
            ((channels & 0x3FF) << 22) | ((samples_per_frame & 0x3FF) << 12))


def decode_aaf_format(v):
    """(alsa_fmt, channels, nsr, samples_per_frame) or None if not one of ours."""
    if (v >> 56) & 0x7F != AAF_SUBTYPE or v >> 63:
        return None
    nsr = (v >> 48) & 0x0F
    fmt = (v >> 40) & 0xFF
    depth = (v >> 32) & 0xFF
    ch = (v >> 22) & 0x3FF
    spf = (v >> 12) & 0x3FF
    for name, (f, d) in ALSA_TO_AAF.items():
        if (f, d) == (fmt, depth):
            return name, ch, nsr, spf
    return None


def s64(s):
    b = s.encode("utf-8")[:64]
    return b + b"\0" * (64 - len(b))


def sampling_rate(hz, pull=0):
    return ((pull & 0x7) << 29) | (hz & 0x1FFFFFFF)


class Model:
    """Everything a descriptor needs, and descriptor(type, index) -> bytes."""

    CHANNELS = 8

    def __init__(self, entity_id, model_id, mac, *, entity_name="FPGAmixer",
                 firmware="", serial="", formats=("S24_3BE", "S32_BE"),
                 gptp=None):
        self.entity_id = entity_id
        self.model_id = model_id
        self.mac = bytes(mac)
        self.entity_name = entity_name
        self.group_name = ""
        self.firmware = firmware
        self.serial = serial
        self.formats = [aaf_format(f, self.CHANNELS) for f in formats]
        self.current_format = {STREAM_INPUT: self.formats[0], STREAM_OUTPUT: self.formats[0]}
        self.names = {}                  # (type, index) -> object_name override
        # gPTP parameters for the AVB_INTERFACE descriptor (fpgamixer-gptp's
        # gptp.cfg: linuxptp's gPTP.cfg with priority1 250)
        self.gptp = {"clock_identity": self.mac[:3] + b"\xff\xfe" + self.mac[3:],
                     "priority1": 250, "clock_class": 248, "variance": 0x436A,
                     "accuracy": 0xFE, "priority2": 248, "domain": 0,
                     "log_sync": -3, "log_announce": 0, "log_pdelay": 0}
        if gptp:
            self.gptp.update(gptp)
        self.available_index = 0

    # ----- names
    def object_name(self, dtype, index, default):
        return self.names.get((dtype, index), default)

    # ----- descriptors
    def entity(self):
        from avdecc_pdu import (CAP_AEM_SUPPORTED, CAP_CLASS_A_SUPPORTED, CAP_GPTP_SUPPORTED,
                                TALKER_IMPLEMENTED, TALKER_AUDIO_SOURCE,
                                LISTENER_IMPLEMENTED, LISTENER_AUDIO_SINK)
        caps = CAP_AEM_SUPPORTED | CAP_CLASS_A_SUPPORTED | CAP_GPTP_SUPPORTED
        # offsets 0 type, 2 index, 4 entity_id, 12 model_id, 20 caps,
        # 24 talker_stream_sources, 26 talker_caps, 28 listener_sinks,
        # 30 listener_caps, 32 controller_caps, 36 available_index,
        # 40 association_id, 48 entity_name, 112 vendor_name_string,
        # 114 model_name_string, 116 firmware_version, 180 group_name,
        # 244 serial_number, 308 configurations_count, 310 current_configuration
        return struct.pack(">HHQQIHHHHIIQ64sHH64s64s64sHH",
                           ENTITY, 0, self.entity_id, self.model_id, caps,
                           1, TALKER_IMPLEMENTED | TALKER_AUDIO_SOURCE,
                           1, LISTENER_IMPLEMENTED | LISTENER_AUDIO_SINK,
                           0, self.available_index, 0,
                           s64(self.entity_name), 0, 1, s64(self.firmware),
                           s64(self.group_name), s64(self.serial), 1, 0)

    TOP_LEVEL = ((AUDIO_UNIT, 1), (STREAM_INPUT, 1), (STREAM_OUTPUT, 1),
                 (AVB_INTERFACE, 1), (CLOCK_SOURCE, 1), (LOCALE, 1), (CLOCK_DOMAIN, 1))

    def configuration(self):
        counts = b"".join(struct.pack(">HH", t, n) for t, n in self.TOP_LEVEL)
        return (struct.pack(">HH64sHHH", CONFIGURATION, 0,
                            s64(self.object_name(CONFIGURATION, 0, "Default")),
                            NO_STRING, len(self.TOP_LEVEL), 74) + counts)

    def audio_unit(self):
        # 72.. 16 (number, base) pairs: stream in/out ports, external in/out,
        # internal in/out, controls, signal selectors, mixers, matrices,
        # splitters, combiners, demultiplexers, multiplexers, transcoders,
        # control blocks; 136 current_sampling_rate, 140 sampling_rates_offset,
        # 142 sampling_rates_count, 144 rates
        pairs = [(1, 0), (1, 0)] + [(0, 0)] * 14
        return (struct.pack(">HH64sHH", AUDIO_UNIT, 0,
                            s64(self.object_name(AUDIO_UNIT, 0, self.entity_name)), NO_STRING, 0) +
                b"".join(struct.pack(">HH", n, b) for n, b in pairs) +
                struct.pack(">IHHI", sampling_rate(48000), 144, 1, sampling_rate(48000)))

    def stream(self, dtype, index):
        name = "AVB in (core 12-19)" if dtype == STREAM_INPUT else "AVB out (core 12-19)"
        formats = b"".join(struct.pack(">Q", f) for f in self.formats)
        formats_offset = 136
        # 70 clock_domain_index, 72 stream_flags, 74 current_format, 82
        # formats_offset, 84 number_of_formats, 86..125 backup talkers (3 x
        # entity id + unique id) and backedup talker, 126 avb_interface_index,
        # 128 buffer_length (ns); 132 redundant_offset, 134 number_of_redundant
        # _streams (1722.1-2013); formats at formats_offset
        head = struct.pack(">HH64sHHHQHH", dtype, index,
                           s64(self.object_name(dtype, index, name)), NO_STRING, 0,
                           STREAM_FLAG_CLASS_A, self.current_format[dtype],
                           formats_offset, len(self.formats))
        head += b"\0" * (126 - len(head))           # backup / backedup talkers: none
        head += struct.pack(">HIHH", 0, 8_000_000,
                            formats_offset + 8 * len(self.formats), 0)
        assert len(head) == formats_offset
        return head + formats

    def avb_interface(self):
        g = self.gptp
        return struct.pack(">HH64sH6sH8sBBHBBBbbbH",
                           AVB_INTERFACE, 0, s64(self.object_name(AVB_INTERFACE, 0, "end0")),
                           NO_STRING, self.mac, AVB_INTERFACE_FLAGS, bytes(g["clock_identity"]),
                           g["priority1"], g["clock_class"], g["variance"], g["accuracy"],
                           g["priority2"], g["domain"], g["log_sync"], g["log_announce"],
                           g["log_pdelay"], 1)

    def clock_source(self):
        # 70 flags, 72 type, 74 identifier (8), 82 location_type, 84 location_index
        return struct.pack(">HH64sHHHQHH", CLOCK_SOURCE, 0,
                           s64(self.object_name(CLOCK_SOURCE, 0, "Internal (gPTP)")),
                           NO_STRING, 0, CLOCK_SOURCE_TYPE_INTERNAL, self.entity_id,
                           CLOCK_SOURCE, 0)

    def clock_domain(self):
        return struct.pack(">HH64sHHHHH", CLOCK_DOMAIN, 0,
                           s64(self.object_name(CLOCK_DOMAIN, 0, "Media clock")),
                           NO_STRING, 0, 76, 1, 0)

    def locale(self):
        return struct.pack(">HH64sHH", LOCALE, 0, s64("en-US"), 1, 0)

    def strings(self):
        # vendor and model name strings (the entity descriptor points at 0, 1)
        s = ["StudioRunner", self.entity_name, "", "", "", "", ""]
        return struct.pack(">HH", STRINGS, 0) + b"".join(s64(x) for x in s)

    def stream_port(self, dtype):
        base = 0 if dtype == STREAM_PORT_INPUT else self.CHANNELS
        amap = 0 if dtype == STREAM_PORT_INPUT else 1
        return struct.pack(">HHHHHHHHHH", dtype, 0, 0, 0, 0, 0,
                           self.CHANNELS, base, 1, amap)

    def audio_cluster(self, index):
        if index < self.CHANNELS:
            name = f"AVB in {index + 1}"
        else:
            name = f"AVB out {index - self.CHANNELS + 1}"
        # 70 signal_type, 72 signal_index, 74 signal_output, 76 path_latency,
        # 80 block_latency, 84 channel_count, 86 format
        return struct.pack(">HH64sHHHHIIHB", AUDIO_CLUSTER, index,
                           s64(self.object_name(AUDIO_CLUSTER, index, name)), NO_STRING,
                           0xFFFF, 0, 0, 0, 0, 1, AUDIO_CLUSTER_FORMAT_MBLA)

    def audio_map(self, index):
        maps = b"".join(struct.pack(">HHHH", 0, ch, ch, 0) for ch in range(self.CHANNELS))
        return struct.pack(">HHHH", AUDIO_MAP, index, 8, self.CHANNELS) + maps

    def mappings(self):
        """The audio map's mappings, as GET_AUDIO_MAP returns them."""
        return self.audio_map(0)[8:]

    def descriptor(self, dtype, index):
        """bytes, or None if there is no such descriptor."""
        one = {ENTITY: self.entity, CONFIGURATION: self.configuration,
               AUDIO_UNIT: self.audio_unit, AVB_INTERFACE: self.avb_interface,
               CLOCK_SOURCE: self.clock_source, CLOCK_DOMAIN: self.clock_domain,
               LOCALE: self.locale, STRINGS: self.strings}
        if dtype in one:
            return one[dtype]() if index == 0 else None
        if dtype in (STREAM_INPUT, STREAM_OUTPUT):
            return self.stream(dtype, index) if index == 0 else None
        if dtype in (STREAM_PORT_INPUT, STREAM_PORT_OUTPUT):
            return self.stream_port(dtype) if index == 0 else None
        if dtype == AUDIO_CLUSTER:
            return self.audio_cluster(index) if 0 <= index < 2 * self.CHANNELS else None
        if dtype == AUDIO_MAP:
            return self.audio_map(index) if index in (0, 1) else None
        return None
