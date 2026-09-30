# Phase 10 status: 2026-09-29 — the board as an AVB device (AVDECC + MSRP)

**Branch:** `phase9/time-shared-core` (continued). **Started from:** P9.7a (the AVB bridge) built as image `p97-bridge-20260928`, **not yet benched**.

## 1. The decision, and how this phase was run

The user, 2026-09-29: *"I want you to write the rest of the code required to make the board AVB compliant … I should be able to plug my mac (with the owc thunderbolt ethernet adapter) into the board and have it show up as an AVB device. From there we can debug and run tests."* They called it "a bit of a reckless call … I'm okay with the potential consequences".

So, unlike Phases 5–9, **there was no proposal-and-decisions round**: the design choices below were made by Claude under that go-ahead and are **recorded here for review**, each with its reason. The code was still built in verified steps (unit tests, mutants, a Linux integration test), but **nothing here has met a Mac yet**. The P9.7 bench (the AVB bridge by ear) was also skipped; the first bench of this phase covers both.

Answers the user gave on the three open questions: (1) the adapter is advertised as AVB ready; (2) stream format: "whichever works best"; (3) existing implementations: "research this".

## 2. Facts checked (2026-09-29)

| Fact | Source | Consequence |
|---|---|---|
| **OWC Thunderbolt 4 10G Ethernet adapter** (Marvell AQC113) is advertised **"AVB ready"**, with the note "Requires AVB compatible switch/router" | owc.com product page (quoted) | The Mac side is plausible. **A direct cable Mac ↔ board is not promised**: that's the first bench question. macOS only runs AVB on some Ethernet chipsets (USB adapters never; Sonnet sells a Broadcom-based "Thunderbolt AVB adapter") |
| macOS supports **AAF** streams ("Milan AAF stream formats") though it isn't fully Milan compliant; older macOS/AVB devices used AM824 (IEC 61883-6) | RME manuals/forum, MOTU forum, DirectOut note (web search) | AAF first: our data path already speaks it. AM824 isn't supported; if the Mac insists on it, that's the next piece of work |
| A Mac lists AVB devices through **AVDECC** (IEEE 1722.1: ADP discovery, AECP/AEM entity model, ACMP connections), and AVB talkers normally wait for an **MSRP** Listener Ready | 1722.1 / 802.1Q; macOS Network Device Browser | We need an AVDECC entity and an MSRP participant, not just streams |
| **No maintained Linux AVDECC *end-station* library to reuse as is:** L-Acoustics `la_avdecc` (C++17, Milan 1.3) is controller-centric (its README describes the controller side; entity-side support couldn't be confirmed); OpenAvnu's `avtp_pipeline` has a full end station but depends on its own stack (endpoint, mrpd, igb shaper); ATDECCSwift is Swift | GitHub pages, OpenAvnu source | **Our own entity, in Python** (like the OSC server: control plane, millisecond timing), with the byte layouts taken from reference code, not memory |
| Byte layouts: **jdksavdecc-c** headers (ADP, ACMP, AECP/AEM commands, descriptors, flags); **OpenAvnu mrpd** (MSRP/MVRP encodings); **OpenAvnu avtp_pipeline** (the AAF stream-format packing) | cloned on the VM, read | Every offset used is quoted in the code's comments and checked in the tests |
| Milan's base audio format is **AAF INT_32BIT with bit_depth 24** (`0x0205021802006000` for 8 ch, 48 kHz, 6 samples); the alsa-plugins AAF plugin always sends and requires bit_depth = the sample format's width (32 for S32_BE) | avtp_pipeline's own AAF default (`format 2, bit_depth 32`), plugin source | A small **plugin patch** (optional `bit_depth`), and S32_BE in the bridge, so we can offer the Milan format as well as INT_24BIT |

## 3. What was built

```
  Mac (controller, talker, listener) ── end0 ──┬── AVDECC (ADP/AECP/ACMP, untagged) ── avb_entityd ──┐
                                               ├── MSRP / MVRP ─────────────────────── avb_entityd   │ binds, formats
                                               ├── gPTP ─────────────────────────────── ptp4l         ▼
                                               └── AAF streams on VLAN 2 ── avb_rx/avb_tx ── fpgamixer-avb-bridge ── link #2 ── core 12-19
```

| Piece | What |
|---|---|
| `tools/avdecc_pdu.py` (new) | ADP, AECP (AEM) and ACMP pack/unpack; constants; the 60-byte-padded Ethernet frame |
| `tools/avdecc_model.py` (new) | the entity model: ENTITY, CONFIGURATION, AUDIO_UNIT (48 kHz), STREAM_INPUT/OUTPUT (8 ch AAF, formats INT_24BIT and INT_32BIT/24), AVB_INTERFACE, CLOCK_SOURCE (internal), CLOCK_DOMAIN, LOCALE + STRINGS, STREAM_PORT_INPUT/OUTPUT, 16 AUDIO_CLUSTERs, 2 AUDIO_MAPs; the AAF stream-format encoder/decoder |
| `tools/avdecc_entity.py` (new) | the protocol state machine, no I/O: ADP (advertise every 5 s, valid 20 s, on DISCOVER, on a grandmaster change, DEPARTING on stop); AEM responder (ACQUIRE/LOCK, READ_DESCRIPTOR, GET/SET_STREAM_FORMAT, GET_STREAM_INFO, GET/SET_NAME, GET/SET_SAMPLING_RATE, GET/SET_CLOCK_SOURCE, START/STOP_STREAMING, (DE)REGISTER_UNSOLICITED_NOTIFICATION, GET_AVB_INFO, GET_AS_PATH, GET_COUNTERS, GET_AUDIO_MAP; anything else NOT_IMPLEMENTED, non-AEM AECP (e.g. Milan's vendor-unique GET_MILAN_INFO) NOT_IMPLEMENTED); ACMP listener (CONNECT_RX → CONNECT_TX to the talker with one retry after 2 s → bind → reply; DISCONNECT_RX; GET_RX_STATE) and talker (CONNECT_TX, DISCONNECT_TX, GET_TX_STATE, GET_TX_CONNECTION); unsolicited GET_STREAM_INFO on (dis)connect |
| `tools/msrp.py` (new) | MSRP/MVRP encode/decode (multi-value vectors, three- and four-packed events, LeaveAll) and a simplified declarer: Domain (class A, prio 3, VID 2), our Talker Advertise, a Listener Ready for the bound stream, MVRP VLAN 2; JoinIn every second and at once on a change or a peer's LeaveAll; Lv on withdrawal; the peer's registrations with ages |
| `tools/avb_entityd.py` (new) + `fpgamixer-avb-entity.service` | the daemon: raw sockets on end0 (AVTP with a **BPF filter** so the 8000/s AAF frames never reach Python; MSRP; MVRP), a pmc thread for gPTP (grandmaster, asCapable, peer delay, path), and on a binding or format change: the runtime JSON → ALSA devices + bridge arguments re-rendered (`avb_net`) → `systemctl restart fpgamixer-avb-bridge` |
| `tools/avdecc_probe.py` (new) | a minimal controller (discover, enumerate the model, connect/disconnect, rx state): the test driver, and a bench tool if a controller misbehaves |
| `tools/avb_net.py` | formats per direction (`rx_format`, `tx_format`), `bit_depth 24` for S32_BE, the runtime override file `/run/fpgamixer/avb-stream.json` (`apply_runtime` / `write_runtime`), `write_stream_files`, the bridge's `-F`/`-G`; the CBS reservation sized for the **larger** format |
| `avb.conf` | `[entity] name`; **`idleslope_kbps` 16000 → 20000**: S32_BE needs 16,512 kbit/s on the wire and the shaper is set once at boot (P9.6's A2 value was sized for S24_3BE only) |
| `recipes-multimedia/alsa/files/0001-aaf-optional-bit_depth.patch` (new) | the plugin's optional `bit_depth` key (tx field and rx check); default unchanged. The same AAF source as 1.2.12 (P9.6), so it applies to the Pi's build too |
| `bridge_convert.h`, `bridge_core.c`, `fpgamixer-avb-bridge.c` | S32_BE (24 bits left-justified, the low byte zero; arithmetic shift in); the AVB bridge's `-F`/`-G` per-direction formats |
| `fpgamixer-avb_1.0.bb` | installs the new modules and the entity unit (enabled); RDEPENDS python3-io/-json/-math/-threading and linuxptp (pmc) |

**Identity:** entity ID = end0's MAC as EUI-64 (`00:18:3E:FF:FE:05:06:48`), model ID = the MAC's OUI + `0x01` (a bench value, not a registered model), name from `avb.conf`. Our talker stream ID and destination MAC stay the static ones in `avb.conf [tx]` (no MAAP yet).

## 4. Checks (no hardware yet)

- **Unit tests, 67/67** on this PC: `test_avdecc` 22 (PDU layouts and every descriptor's offsets against jdksavdecc's numbers written out independently of the packing code; the behaviour driven as a controller: discover, enumerate, acquire vs a second controller, lock expiry, formats including a refused AM824 one, NOT_IMPLEMENTED paths, the listener connect with the talker exchange and unsolicited notification, the 2 × 2 s talker timeout, the talker side), `test_msrp` 9 (encodings byte by byte, a four-value vector with LeaveAll, increments, the declarer), `test_avb_net` 19 (+4 for the runtime file and the formats), plus `test_aaf_check`, `test_mediaclock`.
- **Mutants, all caught**, baseline passing in the same setup: ACMP field order, the stream format's bit-depth position, the CONNECT_RX reply's sequence ID, the MRP three-packing, the ADP available index; `test_bridge_convert` (C, VM): S32_BE layouts and round trips PASS, a logical-shift (sign-losing) mutant caught.
- **Integration on Linux (VM, real raw sockets):** a Linux bridge with three veth ports: two `avb_entityd` instances (A, B) and `avdecc_probe`. The probe **discovered both**, **enumerated A's whole model (30 descriptors, all answered)** plus stream info / AVB info / sampling rate, **connected B's talker to A's listener** (A ran the CONNECT_TX exchange with B, bound B's stream `563626ef224b0000`, replied status 0, rewrote its ALSA device and bridge arguments for that stream and asked systemd to restart the bridge), read A's rx state, and **disconnected** (A back on the static stream).

**Image built 2026-09-29** from the clean commit `db1a736`: 15,069 tasks, all succeeded. Checked: the alsa-plugins build applied `0001-aaf-optional-bit_depth.patch` and the deployed plugin contains the `bit_depth` key; `/usr/lib/fpgamixer` has `avb_entityd.py`, `avdecc_{pdu,model,entity,probe}.py`, `msrp.py`; `fpgamixer-avb-{net,bridge,entity}.service` enabled; the bridge binary knows S32_BE. **`build/sd/p10-avdecc-20260929.wic.xz`** (MD5 `4a4b5c2a…`, same on both ends).

## 5. Not verified, and the known risks (for the bench)

1. **Whether the Mac talks AVB over this adapter on a direct cable** at all (OWC: "requires AVB compatible switch/router"). If Network Device Browser says "AVB is not enabled" on that interface, nothing on the board can fix it.
2. **gPTP with the Mac:** linuxptp's gPTP profile vs macOS's; `neighborPropDelayThresh` (800 ns in `gPTP.cfg`) vs a Thunderbolt adapter's path delay: asCapable false would stop sync. First check: `pmc … PORT_DATA_SET` / `PORT_DATA_SET_NP`.
3. **What macOS reads and sends:** it may need commands we answer NOT_IMPLEMENTED (e.g. Milan's GET_MILAN_INFO, GET_DYNAMIC_INFO), a CONTROL descriptor for identify, or other descriptors. `avb_entityd` logs every non-read command and every non-success status; `avdecc_probe` can replay.
4. **Stream format:** if the Mac only offers AM824 (61883-6), the SET_STREAM_FORMAT is refused (logged) and nothing connects: AM824 support would be the next piece.
5. **MSRP:** the simplified declarer (no full applicant/registrar state machines) may not satisfy a strict peer; the Mac's Talker/Listener declarations are logged as they register.
6. **Media clock and presentation time:** the AAF plugin presents at a constant offset (P9.7 V4); a Mac talker's stream is clocked from gPTP like ours, so rates should match; drift would show as bridge coarse fixes.
7. **The P9.7 bridge itself hasn't been heard yet.**

## 6. Bench plan (short)

1. Flash the image; the Pi's cable moves to the Mac (the board has one port).
2. Board: `journalctl -u fpgamixer-avb-entity -f` (entity available; gPTP state; every AECP command the Mac sends).
3. Mac: System Settings → Network: the OWC adapter up (a link-local address is fine); Audio MIDI Setup → Window → Show Network Device Browser: the adapter's AVB enabled; **FPGAmixer listed?**
4. Tick it: the Mac acquires, reads the model, sets formats, connects streams. Watch the entity log, then `mixer_hw.py link2 10` and the bridge log; by ear: route AVB in 1 → JB_L, and Mac output → the new device.

## 8. First Mac bench (2026-09-30 UTC, image `p10-avdecc-20260929`, Mac + OWC TB4 10G adapter, direct cable)

**What worked** (entity journal):
- **macOS found the entity and drove it:** controllers from the Mac (`5ce91e726af90000`, later `5de91e726af90006`, `0023a40d5494…`) registered for notifications, **acquired**, **locked**, and **set both stream formats to `0x0205021802006000` (AAF INT_32BIT, 24-bit: Milan's base format)**, the path the plugin patch added. The bridge restarted on S32_BE.
- **ACMP both ways:** the Mac connected its talker stream `0023a40d54940000` (dest `91:e0:f0:00:08:e8`, VLAN 2) to our listener (CONNECT_TX exchange with the Mac's talker, status 0), and connected our talker to its listener; START_STREAMING on both.
- **MSRP both ways:** the Mac's **Talker Advertise registered** (234-byte MaxFrameSize: 8 ch × 32-bit × 6 + AAF header + Ethernet/VLAN header, i.e. the Mac counts the header) and **the Mac declared Listener Ready for our talker stream**.
- gPTP: **the Mac is grandmaster** (`7a9d6b.b90e.020002`: priority1 250 like ours, clockAccuracy 0x21 better than our 0xFE), link `asCapable 1`, peer delay 250 ns.

**What didn't:** macOS played nothing ("audio engine is off" in Ableton); `link2 5`: frames_rx 36/s, starved ~48,000/s; a 5 s capture showed **only gPTP frames from the Mac, no AAF**; the Mac later withdrew its Talker Advertises.

**Findings:**
1. **ptp4l rejects every Sync/Follow_Up from the Mac: "bad message" every 125 ms**, so the board stays **UNCALIBRATED** and never follows the Mac's time. From linuxptp 4.4's `msg.c`/`tlv.c`: `-EBADMSG` comes from a TLV with an odd length or one longer than what's left, an 802.1 organization TLV of the wrong size, or a total length that doesn't match `messageLength`. The Mac's Follow_Up is **96 bytes** (a plain gPTP one is 76: 44 + the 32-byte Follow_Up information TLV), so it carries 20 more bytes of TLV. Raw bytes requested to pin it down. Also noted: the Mac's gPTP time is ~320,617 s (not TAI/UTC), so once the board follows it, `phc2sys` will set the board's system clock to early 1970 (harmless for audio; the known "no plausibility guard" item).
2. **macOS sends AEM `0x004C` / `0x004D` right after connecting: SET/GET_MAX_TRANSIT_TIME** (1722.1-2021; codes and 12-byte payloads read in la_avdecc's `protocolDefines.cpp` / `protocolAemPayloadSizes.hpp`). We answered NOT_IMPLEMENTED. **Implemented now** (§9).
3. The Mac connected **two** of its talker streams (unique IDs 0 and 1) to our single listener, one after the other; our listener rebinds each time. Not fixed yet; to see what the Mac expects (possibly a 16-channel Mac device split in two streams).
4. Several Mac controller processes: the first one's acquisition (it re-registers every 100 s, so it's alive) makes later ones get ENTITY_ACQUIRED (status 4); they then LOCK instead. Correct per 1722.1; left as is.

## 9. Fix 1: SET/GET_MAX_TRANSIT_TIME

`avdecc_pdu.CMD` gains `GET_DYNAMIC_INFO` 0x004B (still NOT_IMPLEMENTED), `SET_MAX_TRANSIT_TIME` 0x004C, `GET_MAX_TRANSIT_TIME` 0x004D. The entity keeps a max transit time per stream (default the configured `mtt`, 2 ms); a SET on the **output** stream becomes our talker's AAF `mtt` (runtime file `tx.mtt_us` → `avb_net` → the ALSA device → bridge restart); on the input it is stored and reported. Tests: `test_avdecc` +1 (get default, set → callback, get back, input stored only, wrong descriptor), `test_avb_net` +1 (the override reaches the ALSA text): **69/69**.

## 10. Fix 2: ptp4l rejected every Follow_Up from macOS

**Raw Follow_Up** (captured on the board, `tcpdump -xx`): `messageLength` = **96** (`0x0060`); after the 44-byte header + body come the **802.1AS Follow_Up information TLV** (type 3, length 28, org `00:80:C2` subtype 1) and a **16-byte Apple organization TLV** (org `00:0D:93` subtype 4), which make exactly 96; **then 54 more bytes: a further Apple TLV (length 50, subtype 2) outside the message**, 150 bytes of PTP in the frame.

**Cause:** linuxptp 4.4 `msg_post_recv()` parses TLVs over everything received (`suffix_post_recv(m, cnt - pdulen)`) and then requires header + TLVs == `messageLength`: 150 ≠ 96 → `-EBADMSG` → "bad message" on every Follow_Up → no two-step Sync ever completes → UNCALIBRATED.

**Fix:** `recipes-connectivity/linuxptp/files/0001-msg-ignore-octets-after-messageLength.patch` (+ bbappend): after the header is parsed, `cnt` is cut to `messageLength`; octets beyond a message's own length aren't part of it, like Ethernet padding. Generated against the build's linuxptp 4.4 source with an exact-anchor script.

**Proof on the captured bytes (VM):** linuxptp 4.4 built natively twice, a harness feeding the 150 captured bytes to `msg_post_recv()`: **unpatched `-74` (EBADMSG), patched `0` (accepted)**, sequence 16051 and correction 150,463 ns as decoded by tcpdump.

**Consequence to expect:** once the board follows the Mac, its PHC carries the Mac's gPTP time (~320,977 s, not TAI), so `phc2sys` sets the board's system clock to early January 1970 (the Mac's Announce doesn't flag its UTC offset as valid). Harmless for audio (the AAF plugin uses CLOCK_TAI = CLOCK_REALTIME + 37 s consistently, and the media-clock loop goes through HOLDOVER on the PHC step and re-locks); journal dates will look odd.

## 7. Log

- **2026-09-29:** user go-ahead for "the rest of the code" to make the board show up as an AVB device on a Mac. Research (§2), then built (§3): the AAF plugin's `bit_depth` patch, S32_BE in the bridge, `avdecc_pdu` / `avdecc_model` / `avdecc_entity` / `msrp` / `avb_entityd` / `avdecc_probe`, runtime stream binding in `avb_net`, the entity service. Checks (§4): 67/67 unit tests, 6 mutants caught, the veth integration test with two entities and a probe controller PASS. Not on hardware yet; risks in §5.
