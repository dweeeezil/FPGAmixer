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

**Image `p10b` built 2026-09-30** from `df7460e`: 15,069 tasks, all succeeded; linuxptp's `do_patch` log shows the new patch applied; the rootfs's `avdecc_pdu.py` has the transit-time commands. **`build/sd/p10b-ptpfix-20260930.wic.xz`** (MD5 `910bcc26…`, same on both ends).

## 11. Second Mac bench (image `p10b`): gPTP fixed; the bridge never ran

- **gPTP: fixed.** `UNCALIBRATED to SLAVE on MASTER_CLOCK_SELECTED` 24 s after boot, then **rms 4–10 ns, max 10–27 ns**, path delay 244 ns, frequency +0.76 … +0.89 ppm (the crystals). No "bad message".
- The Mac again: formats S32_BE both ways, our talker connected to its listener (Listener Ready), its talker to our listener (Talker Advertise, 234 B), **SET_MAX_TRANSIT_TIME on our output = 12,836 ns** (the same number as its MSRP accumulated latency), START_STREAMING. No AAF from the Mac (0 packets); link #2 received nothing; macOS apps hung or crashed on the device.
- **Cause found: `fpgamixer-avb-bridge` has never run.** It exits at start-up with `B core->net: poll descriptors: Invalid argument`; systemd had restarted it 120 times. The board sent no stream (0 outgoing AAF packets), so the Mac's AVB device, waiting on our stream, never started (the likely reason for the hangs). **Bug in bridge_core (P9.7a):** it asked each PCM for "up to MAX_PFD" poll descriptors; the AAF plugin (ioplug) refuses any `space` other than its exact count (`aaf_poll_descriptors`: `space != FD_COUNT_* → -EINVAL`), a line read in P9.7 and not applied. Not caught because the P9.7 bench was skipped and the VM test exercised the entity, not the bridge with the plugin. **Fixed:** exact counts from `snd_pcm_poll_descriptors_count()`, checked against MAX_PFD. Hardware PCMs (the USB bridge) were unaffected by the old call.
- macOS log: repeated internal asserts in its AVB configuration process (`_controllerTerminated == NO`, `interface.aecp != nil`) every 100 s, in step with its REGISTER_UNSOLICITED_NOTIFICATION renewals. Unclear whether related; to revisit once streams flow.
- `link2 5` read frames_tx 51,390/s (not ~48,000) while the bridge was restart-looping: to re-check with a running bridge.
- **Tried: the bridge against the real AAF plugin off-hardware.** The image's own binaries (bridge, alsa-lib, the patched plugin) under Yocto's `qemu-aarch64` on the VM, two bridges on a veth pair with VLAN 2, ALSA `null` as link #2, real-time priority dropped (`setpriv`), the VM's TAI offset set to 37 for the run and restored. Result: **not possible under qemu-user:** it doesn't translate the plugin's `SO_TXTIME` and `PACKET_ADD_MEMBERSHIP` socket options ("Failed to configure txtime", "Failed to add multicast address", `ENOPROTOOPT`), so the plugin can't open its sockets there. (Also learned: alsa-lib's `conf.d` scan isn't redirected into the qemu prefix; `ALSA_CONFIG_PATH` works around it.) A native x86 build would need ALSA/libavtp dev packages on the VM; not done. **The fix is therefore verified by the plugin's source and the bench only.**
- **Image `p10c` built 2026-09-30** from `abe146f`: 15,069 tasks, all succeeded; the rootfs's bridge has the new code. **`build/sd/p10c-bridgefix-20260930.wic.xz`** (MD5 `443ace66…`).

## 12. Third Mac bench (image `p10c`): the bridge runs

- **The bridge starts** (both directions S32_BE, period 96, 4 periods). The first run had direction B (link #2 → Mac) logging "Failed to send AAF PDU" constantly, with ~4,300 coarse fixes per 10 s.
- **Change on the board:** `time_uncertainty_us` 125 → **1000** (the talker's launch-time margin ahead of ETF; changed with sed in `/etc/fpgamixer/avb.conf` on the board, not yet in the repo). After the restart: ETF **sent 23,418 packets, dropped 0**, no send failures; B 47,602 frames/s, xruns 0/14, 495 coarse fixes in the first 10 s (start-up included; to re-check once settled).
- **Bug found on the way: `avb_net` couldn't be re-run.** `tc qdisc replace … root mqprio` fails on an existing mqprio ("Change operation not supported"), so `systemctl restart fpgamixer-avb-net` failed and took the bridge with it. Worked around on the bench with `tc qdisc del dev end0 root`. **Fixed:** `avb_net` now deletes the root qdisc first (the error is ignored when there isn't one, as at boot), then builds mqprio/CBS/ETF. Unit test updated.
- Direction A (Mac → link #2) hasn't run yet in this boot: it needs the Mac's stream connected and playing.

## 13. The board's clocks ran away (found on the third bench)

- **Symptom:** after the manual qdisc delete and service restarts, FPGAmixer vanished from the Mac's Network Device Browser. The Mac's log: `Didn't add entity … because link … is not ASCapable`. The Mac sent only Pdelay (no Announce), so the board became grandmaster; clocksyncd's port for the board: `Port Role: Disabled`, `Minimum Raw Delay 4294967295`: it had never accepted a single delay measurement, though it counted every response as received. Resetting the cable and ptp4l didn't help.
- **Diagnosis from a hex capture of the Pdelay exchange:** the board's responses were well formed (sequence ids, requesting port identity, t3−t2 86 µs), but the rates were impossible: the board's PHC saw the Mac's 0.9007 s request spacing (board system clock) as 0.9367 s, and the Mac saw the board's 1.0000 s spacing as 1.1111 s. The Mac drops a neighbour whose rate ratio is that far out.
- **Cause:** the system clock's `tick` was **9000** (the kernel's −10% limit) and the PHC's frequency adjustment **±64,000,000 ppb** (the GEM's limit), phc2sys swinging between them with offsets of hundreds of ms. phc2sys (and ptp4l) step only on the first update and slew everything after, at the maximum rate; the grandmaster's time jumped as roles changed (the Mac's gPTP time is ~2,660 s since its boot, the board's wall clock 2026), so the slew never ended. Also explains link #2's 51,390 frames/s (48,000 × 1.07: mclk follows the PHC) and the bridge's coarse fixes and send failures.
- **Bench recovery:** stop phc2sys and ptp4l; `adjtimex` tick 10000, freq 0; `phc_ctl end0 freq 0`; start ptp4l (SLAVE to the Mac in 4 s), then phc2sys. **FPGAmixer reappeared.**
- **Fixed in the repo:** `step_threshold 1.0` in `fpgamixer-gptp.cfg` (read by both ptp4l and phc2sys): any offset over 1 s is stepped, not slewed. A step is a glitch in the media clock; a slew at the limit was a 6–10% rate error for good.
- Not yet on an image. Until then, after any grandmaster change on the bench, check `phc_ctl end0 freq` and the tick.
- **Follow-up on the bench (board clock now on the Mac's timescale, 1970):** the phc2sys already running (reset tick, `step_threshold` appended to the board's `/etc/fpgamixer/gptp.cfg`) never stepped: every sample `clockcheck: clock jumped forward…`, servo reset (`s0`), offset stuck at 56.7 years. `systemctl stop systemd-timesyncd` (no log entries this boot) + `restart fpgamixer-phc2sys`: stepped at once, then **±70 ns, +1.4 ppm**. Which of the two cleared it is **not established**; timesyncd doesn't belong on this board either way (to decide: remove it from the image).
- **ETF wedged by the backward step:** after the step every AAF PDU failed ("Failed to send AAF PDU", ~485 playback xruns/s, ETF `dropped` rising at the same rate). ETF rejects a packet whose txtime is before the last dequeued one (`is_packet_valid`: `txtime < q->last`); `q->last` was a 2026 time. **Fixed on the bench** by deleting and re-adding only the ETF leaf (`parent 200:1`, the stream's queue; ptp4l untouched). **Open, needs a decision:** any backward step (grandmaster change) wedges ETF again: rebuild the leaf on a step, or drop ETF (CBS already shapes; ETF also caused the launch-time failures in §12).
- **Result, 2026-09-30 01:11 (board clock):** both directions running: **B core→net 48,000 frames/s, xruns 0/0, no coarse fixes; A net→core 48,000 frames/s, xruns 2/3 at start-up only, queue −8 frames.** The Mac's stream arrived after unticking/re-ticking FPGAmixer in the Network Device Browser.

## 14. First audio, and the decisions after it (2026-09-30)

- **Heard by ear:** Mac audio → AVB → link #2 → JB-L / JC-L. Both directions streaming (§13's last point).
- **Decisions (user, 2026-09-30):**
  1. **ETF dropped.** `avb_net` now installs mqprio + CBS only. ETF's `txtime < q->last` rule wedged the stream after any backward clock step (a grandmaster change), and its launch-time drops caused §12's send failures. The plugin's timer paces the PDUs; CBS shapes them; the SO_TXTIME the plugin still attaches is ignored. `etf_delta_us` removed from `avb.conf`; `CONFIG_NET_SCH_ETF` stays built in, unused (no kernel rebuild). Unit tests updated.
  2. **systemd-timesyncd removed** (`recipes-core/systemd/systemd_%.bbappend`, `PACKAGECONFIG:remove = "timesyncd"`): the board's time is gPTP's; a second time service can only fight phc2sys.
  3. **`time_uncertainty_us` 125 → 1000** in the repo's `avb.conf`, as benched.
- Also in the next image: `step_threshold 1.0` (§13), `avb_net` re-runnable (§12).
- **Known, not fixed:** re-running `fpgamixer-avb-net` while ptp4l runs deletes the root qdisc under it (a TX queue reset). At boot it runs before ptp4l, so only a manual restart is affected; restart ptp4l after it.
- **Next:** build image `p10d`, boot it clean with the Mac attached, and check without manual steps: SLAVE, FPGAmixer in the browser, audio both ways. Then the Mac's two-streams-to-one-listener question, the P9.7 checks (60-min log, round trip) and the P9.8 soak.

## 7. Log

- **2026-09-29:** user go-ahead for "the rest of the code" to make the board show up as an AVB device on a Mac. Research (§2), then built (§3): the AAF plugin's `bit_depth` patch, S32_BE in the bridge, `avdecc_pdu` / `avdecc_model` / `avdecc_entity` / `msrp` / `avb_entityd` / `avdecc_probe`, runtime stream binding in `avb_net`, the entity service. Checks (§4): 67/67 unit tests, 6 mutants caught, the veth integration test with two entities and a probe controller PASS. Not on hardware yet; risks in §5.
