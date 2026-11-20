# Timecode: the controller's spec (2026-11-18)

**Who this is for:** whoever builds the timecode display into a controller (StudioRunner). It describes everything a controller sends and receives about timecode, and what the mixer guarantees. The normative summary is the *Timecode* section of `FPGA Mixer OSC Standard.md`; this document is the full version, with examples and a checklist.

**Background, not needed to implement:** `timecode_proposal_2026-11-18.md`. The mixer decodes LTC from one input port. The user picks the port, and the controller shows the time.

**Firmware state:** the contract below is fixed, but the firmware isn't built yet. Until it is, develop against `MockDevice` (§8).

---

## 1. Discovery

A mixer with timecode adds two things to the config reply (`/<name>/get/system/config`). Both are additive, and `schemaVersion` stays 1.

```json
{
  "capabilities": ["snapshots", "inserts", "timecode"],
  "system": {
    "timecodeSource": {
      "type": "enum",
      "options": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
      "optionLabels": ["Off", "Analog 1", "Analog 2", "Analog 3", "Analog 4",
                       "USB 1", "USB 2", "USB 3", "USB 4", "USB 5", "USB 6", "USB 7", "USB 8",
                       "AVB 1", "AVB 2", "AVB 3", "AVB 4", "AVB 5", "AVB 6", "AVB 7", "AVB 8"],
      "default": 0
    }
  },
  "values": { "system/timecodeSource": 5.0 }
}
```

**Show timecode UI only if the config's `system` block has `timecodeSource`.** Older firmware doesn't have it, and the controller then shows nothing. You can test either that key or the capability. The key is enough, and today's `DeviceConfig` already parses it.

`values` is sparse: an absent `system/timecodeSource` means its default, 0 (Off). Take the options and labels from the config. Don't hard-code the port list.

## 2. Choosing the source

An ordinary system setting, with the usual set, echo and get rules:

```
/<name>/set/system/timecodeSource     5.0        USB 1
/<name>/set/system/timecodeSource     0.0        Off
```

- Numbers travel as OSC float.
- Every accepted set is broadcast to all controllers, so two controllers stay in step.
- The mixer keeps the setting across a power cycle.
- Snapshots neither store nor recall it.
- The port doesn't need to be patched to a channel. Timecode is read from the port itself, so the user shouldn't route it into a mix.

## 3. Subscribing

Works like the meters. Send over TCP:

```
/<name>/timecode/subscribe     <port:int>
```

| Rule | Detail |
|---|---|
| `port` | the UDP port the controller listens on, 1–65535. **The meter listener's port is fine:** one socket can receive both |
| `0` | unsubscribes at once |
| Destination | the source IP of the TCP connection |
| Lease | 5 s after the last `subscribe`. **Re-send every 2 s while connected**, as for meters |
| New port | moves the stream |
| TCP closes | ends the subscription |
| Malformed | anything but one integer (`i`, or `f` with an integral value), or a port above 65535, gets an *Error reply* with the path `timecode/subscribe` |

A subscription is independent of the meter subscription. Subscribe whenever the mixer has the feature, including while the source is Off: the stream then says so, and the display is ready the moment the user picks a port.

## 4. The stream

Mixer to controller, UDP, one OSC message per datagram:

```
/<name>/timecode   <seq:i> <state:i> <hours:i> <minutes:i> <seconds:i> <frames:i> <fps:f> <dropFrame:i>
```

Example, 01:02:03;04 at 29.97 drop-frame:

```
/FOHmixer/timecode   1234  2  1  2  3  4  29.97  1
```

| Argument | Type | Meaning |
|---|---|---|
| `seq` | int | Per subscriber. Starts at 0, +1 per message, wraps from 2³¹−1 to 0 |
| `state` | int | See below |
| `hours` | int | 0–23 |
| `minutes` | int | 0–59 |
| `seconds` | int | 0–59 |
| `frames` | int | 0 to the rate's last frame |
| `fps` | float | Exactly one of 23.976, 24, 25, 29.97, 30. 0 only if no timecode has been decoded yet |
| `dropFrame` | int | 1 = drop-frame. Only ever 1 with `fps` 29.97 |

| `state` | Name | Time fields | Show |
|---|---|---|---|
| 0 | Off | all 0, `fps` 0 | nothing, or the picker alone |
| 1 | No timecode | the last decoded time, held; all 0 if there has never been one | the held time dimmed, or `--:--:--:--` if `fps` is 0 |
| 2 | Running | the last decoded frame | the time, normal |

**Timing:**
- While running: one message per decoded frame.
- Otherwise: two messages a second, so a lost datagram corrects itself.
- After timecode starts, `state` becomes 2 about half a second later, once the mixer has measured the rate. So in state 2, `fps` is always valid.
- After timecode stops, `state` becomes 1 within about 100 ms.

**Rules for the receiver:**
- UDP can reorder. Drop a message whose `seq` is older than the newest seen, allowing for the wrap, and restart when a new subscription begins.
- Ignore a message without exactly these eight arguments.
- If no message arrives for 2 s, treat the display as state 1.
- Reverse play and fast shuttle aren't decoded in this version. They show as state 1.

## 5. Display format

| Rate | Format | Label |
|---|---|---|
| Non-drop | `01:02:03:04` | `23.98`, `24`, `25`, `29.97`, `30` |
| Drop-frame | `01:02:03;04`: a semicolon before the frames | `29.97 DF` |

Use a monospaced face, so the digits don't shift as they count.

## 6. The frame offset

The frame offset is **the controller's own display preference**. The mixer has no offset setting and always reports the frame it decoded.

**Why it's useful.** An LTC frame can only be decoded once it has fully arrived, so the reported frame is already at least one frame old. The input path, the network and the screen add more. The real amount depends on the setup, so it is best set by comparing against the source.

**The arithmetic.** Adding to the frame field alone gives wrong times at each rollover, and drop-frame skips labels. Convert to a frame count, add the offset, and convert back:

```
nominal = 24 if fps is 23.976 or 24; 25 if fps is 25; 30 if fps is 29.97 or 30

label -> count
    n = (hours * 3600 + minutes * 60 + seconds) * nominal + frames
    if dropFrame:
        totalMinutes = 60 * hours + minutes
        n -= 2 * (totalMinutes - totalMinutes / 10)          // integer division

add the offset, wrapped into one day (the result must be 0 ..< dayLength)
    dayLength = dropFrame ? 2_589_408 : 86_400 * nominal
    n = ((n + offset) % dayLength + dayLength) % dayLength

count -> label
    if dropFrame:
        d = n / 17_982                                       // integer division
        r = n % 17_982
        n += 18 * d
        if r >= 2: n += 2 * ((r - 2) / 1_798)
    frames  = n % nominal
    seconds = (n / nominal) % 60
    minutes = (n / (nominal * 60)) % 60
    hours   = (n / (nominal * 3600)) % 24
```

Apply the offset in states 1 and 2, so the display doesn't jump when timecode stops. Skip it when `fps` is 0.

**Test vectors.** The conversion above was checked over every label of a full day at 24, 25, 30 and 29.97 drop-frame.

| Rate | Time | Offset | Result |
|---|---|---|---|
| 30 | 01:00:00:00 | +2 | 01:00:00:02 |
| 30 | 01:00:00:00 | −1 | 00:59:59:29 |
| 30 | 23:59:59:29 | +1 | 00:00:00:00 |
| 30 | 00:00:00:00 | −1 | 23:59:59:29 |
| 25 | 00:00:00:24 | +1 | 00:00:01:00 |
| 24 | 00:00:00:23 | +1 | 00:00:01:00 |
| 29.97 DF | 00:00:59;29 | +1 | 00:01:00;02 |
| 29.97 DF | 00:01:00;02 | −1 | 00:00:59;29 |
| 29.97 DF | 00:09:59;29 | +1 | 00:10:00;00 |
| 29.97 DF | 23:59:59;29 | +1 | 00:00:00;00 |
| 29.97 DF | 00:00:00;00 | −1 | 23:59:59;29 |

## 7. What it doesn't do

- Nothing in the mixer follows the timecode. It is a display.
- It doesn't carry user bits or frame-accurate sync to other equipment.

## 8. Testing without the board

**In `MockDevice`:** add `system/timecodeSource`, the subscribe handling and a generator, so demo mode shows a running clock.

**On the reference server (arrives with the firmware's server step):**

```bash
python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --timecode-source synthetic
```

Each source then behaves differently, so every display state can be reached from the picker:

| Source | Behaviour |
|---|---|
| Off | state 0 |
| Analog 1 | 30 fps, from 01:00:00:00 |
| Analog 2 | 29.97 drop-frame, from 00:59:50;00, so it crosses a dropped minute |
| Analog 3 | 25 fps |
| Analog 4 | 23.976 fps |
| USB 1 | state 1, never any timecode |
| USB 2 | runs for 5 s, stops for 3 s, repeats |
| Every other port | 24 fps |

## 9. Checklist

- [ ] No timecode UI on a mixer without `system/timecodeSource` (older firmware).
- [ ] The picker's options and labels come from the config.
- [ ] A change from another controller moves the picker (the broadcast).
- [ ] Subscribe on connect, renew every 2 s, and subscribe again after a reconnect.
- [ ] States 0, 1 and 2 each display as in §4.
- [ ] Out-of-order datagrams are dropped, and silence for 2 s reads as state 1.
- [ ] Drop-frame shows the semicolon and the `29.97 DF` label.
- [ ] The offset passes every vector in §6.
- [ ] The readout's width doesn't change while it counts.
