Alexander Kelly
18 Aug 2026 (revised 4 Oct 2026: amendments A–H folded in)

This is the one source of truth for the mixer's OSC protocol. The 4 Oct 2026 revision merges the amendments agreed for the StudioRunner controller (A: name and alias, B: config, C: metering, D: TCP framing, E: discovery, F: value encoding, G: error reply, H: ping) and the device rules decided with them. The change log is at the end.

## Command Structure

All OSC commands operate under a set/get structure. Set commands pass a value which is then echoed back to the controller to confirm. Get commands just retrieve a value, useful for synchronization.

Set commands can be sent by controllers to set mixer values, but are also sent by the mixer itself to all network controllers on a value change to ensure synchronization.

The mixer hardware should never need to send get commands. It is the overarching authority on any value conflict.

Set/Get commands follow the same naming convention:
```
	/<mixer name>/set/<zone>/<index>/<module>     <value>
	/<mixer name>/get/<zone>/<index>/<module>
```

Mixer name: Host device name (see *Mixer name and the `/mixer/` alias*)

Zone: Where the value exists:
- inputChannel
- busChannel
- outputChannel
- inputMatrix (input-> bus matrix)
- busMatrix (bus -> output matrix)
- system

Index: Which part of the corresponding zone you're referring to. This can be a channel index or a matrix crosspoint written as "rowIndex_columnIndex". See matrix controls below.

Module: The actual value you're setting/getting. Can be as simple as level, but can also refer to more complex DSP values such as "eq_band4_freq"

Value: In most cases is a float, but can also be used for config strings:
```
/mixer/set/system/deviceName     "FOHmixer"
/FOHmixer/set/inputChannel/0/level     -6.0
```

NOTE: changing settings like deviceName will require you to change your OSC address space to reflect the change. This may cause issues with device/controller sync if controllers don't know to start listening to the new address space they just assigned. (See *The `system` zone* for how a rename is confirmed.)

### Command kinds

The segment after the mixer name is the command kind:

| Kind | Direction | Form | Section |
|---|---|---|---|
| `set` | both | `/<name>/set/<zone>/<index>/<module> <value>` | above; *Set and get* |
| `get` | controller → mixer | `/<name>/get/<zone>/<index>/<module>` | *Set and get* |
| `meter` | both | `/<name>/meter/subscribe ...` (controller), `/<name>/meter/<zone> <blob>` (mixer) | *Metering* |
| `error` | mixer → controller | `/<name>/error <path> <reason>` | *Error reply* |
| `ping` / `pong` | controller → mixer / mixer → controller | `/<name>/ping <token>`, `/<name>/pong <token>` | *Ping* |

A message with any other kind is ignored.

### Transports

- **TCP** (two-way): every command. The mixer's replies, echoes and broadcasts go to TCP controllers. Framing: see *TCP framing*.
- **UDP control** (write-only): `set` only, one OSC message per datagram. Nothing is ever sent back over it: no reply, no error. An accepted UDP `set` is broadcast to the TCP controllers like any other.
- **UDP meters** (mixer → controller): see *Metering*.

The reference server listens on TCP 8000 and UDP 8001.

## Channel Control Examples

```
/<mixer name>/set/inputChannel/0/level     -6.0
/<mixer name>/set/inputChannel/10/compressor_threshold     -16.4
```

## Matrix Control Examples
```
/mixer/set/inputMatrix/5_8/level     -24.0
/mixer/set/inputMatrix/5_8/delay     2.39
```
Sets the level of input 5 going to bus 8 to -24db, and delays it by 2.39ms

## Mixer name and the `/mixer/` alias

- The mixer answers to its current name **and** to the reserved alias `mixer`: `/mixer/set/...` and `/FOHmixer/set/...` are the same request to a mixer named `FOHmixer`, on TCP and UDP. Messages under any other name are ignored.
- A mixer that has never been named is called `mixer` (the factory state). It answers to `/mixer/` only, and reports `mixer` as its `deviceName`.
- **Name rules:** letters, digits, `-`, `_` and `.`; 1 to 63 bytes (a Bonjour label); not `mixer`. Spaces and `/` would break addresses. A rename that breaks a rule is refused (see *The `system` zone*).
- Everything the mixer sends is addressed under its current name.
- Controllers don't require the first segment of an **incoming** message to match a known name: the TCP connection is the identity. For **outgoing** messages a controller uses the mixer's current name if it knows it, otherwise `/mixer/`. On a `system/deviceName` set (echo or broadcast) a controller switches its outgoing prefix to the new name.

## Values

- **Kinds.** Each module has a type, published in the config (*Config*): `float`, `int`, `bool`, `enum` or `string`.
- **Encoding.** Numbers of every type (including `bool`, `int` and `enum`) travel as OSC float `f`. The mixer also accepts `i`, `T` and `F` for them. Strings travel as OSC string `s`.
- **The mixer applies, then echoes what it applied:**
  - numbers are clamped to the module's `min`/`max` (for `level`: ≤ −90 dB is −90, which means off; the ceiling is the hardware's, +6.02 dB for today's Q2.16 gains);
  - `bool` values snap to 0 or 1 (≥ 0.5 is 1); `int` values round to the nearest integer;
  - non-finite numbers are remapped before clamping: NaN and −inf to −99.9, +inf to +99.9;
  - an `enum` value must be one of the module's `options`; anything else is refused.

  Clamping and snapping are **not** errors: the echo carries the applied value, and a controller takes that value as the truth.
- A value of the wrong kind (a string for a number, a number for a string, or an OSC type other than `f i T F s`) is refused.

## Set and get

- Every accepted `set`, from any TCP controller or from UDP, is broadcast to **all** TCP controllers, including the sender. That broadcast is the echo: there is no separate confirmation.
- A refused `set` is neither applied, stored nor echoed. The sender gets an *Error reply* (TCP only).
- A `get` is answered with a `set` message carrying the current value, to the requesting controller only. Nothing is broadcast, since nothing changed.
- `set` and `get` only work on parameters the mixer has: the zones, indices and modules its config lists, plus the `system` settings. Anything else is refused with an *Error reply*.
- The mixer keeps every parameter across a power cycle.

## The `system` zone

`system` has no index: its addresses are `/<name>/<set|get>/system/<setting>`. A trailing slash is allowed and means the same (`system/deviceName/` is `system/deviceName`); controllers send it without one.

- **`deviceName`** (string): the mixer name. A rename is confirmed by a broadcast of the new name under the **old** name (the address the request arrived on); from then on, every message uses the new name. A refused rename (the name breaks a rule, or the value is not a string) is answered to the **sender only** with a `set` carrying the name that stands, followed by an *Error reply*; nobody else hears anything.
- **`config`**: not a setting but a request; see *Config*.
- Other settings the mixer has are listed in the config's `system` block. A setting marked `readOnly` refuses every `set` with an *Error reply*.

## Config

A controller learns everything about the mixer, including its topology, module metadata and current values, from one request:

```
/<name>/get/system/config
```

The reply goes to the requesting controller only, on the same TCP connection, as a `set` whose value is UTF-8 JSON in an OSC string (or an OSC blob):

```
/<name>/set/system/config     "<json>"
```

Shape:

```json
{
  "schemaVersion": 1,
  "deviceName": "FOHmixer",
  "firmware": "0.5.0",
  "sampleRate": 48000,
  "zones": {
    "inputChannel":  { "count": 8, "modules": ["level", "mute"] },
    "busChannel":    { "count": 8, "modules": ["level"] },
    "outputChannel": { "count": 8, "modules": ["level"] },
    "inputMatrix":   { "rows": 8, "cols": 8, "modules": ["level"] },
    "busMatrix":     { "rows": 8, "cols": 8, "modules": ["level"] }
  },
  "modules": {
    "level": { "type": "float", "unit": "dB", "min": -90, "max": 6.02, "default": 0, "group": "level" },
    "mute":  { "type": "bool", "default": 0, "group": "level" }
  },
  "system": {
    "deviceName": { "type": "string", "default": "mixer" },
    "sampleRate": { "type": "enum", "unit": "Hz", "options": [48000], "default": 48000, "readOnly": true }
  },
  "values": {
    "inputChannel/0/level": -6.0,
    "inputMatrix/5_8/level": -24.0,
    "system/deviceName": "FOHmixer"
  }
}
```

Rules:

- **`schemaVersion`** (required) is a breaking-change number. A controller refuses a newer version than it supports. Additive changes (new optional keys, new module types) don't bump it.
- **`zones`** (required): channel zones have `count`, matrix zones `rows` and `cols`, and every zone lists its `modules`. For a matrix, row = source, column = destination. A zone absent from `zones` does not exist on the mixer; a module absent from a zone's list is not implemented there. `system` is never listed here.
- **`modules`** (required) is metadata, keyed by module name: `type` (`float`, `int`, `bool`, `enum`, `string`), and optionally `unit`, `min`, `max`, `default`, `options` (for `enum`) and `group`. `group` is for UI clustering (`level`, `eq`, `dynamics`, `delay`, ...); grouping is never inferred from underscores in module names.
- **`system`**: the mixer's settings, keyed by setting name, with the same metadata fields as `modules` plus optional `readOnly`. Absent: the mixer has only `deviceName`.
- **`level`** has the mixer's real range: `min` −90 (off) and `max` the hardware ceiling.
- **`values`** keys are `<zone>/<index>/<module>`, the same as the address tail of a `set`, so applying the snapshot reuses the path for incoming sets. For `system` the key is `system/<setting>`. Values are **sparse**: an absent entry is its module's `default`. `system/deviceName` is always present.
- Numbers in `values` should be float32-representable: OSC carries float32, and controllers store values at that precision.
- `deviceName` (top level) is the current name, `firmware` a version string, `sampleRate` in Hz.
- Tolerance (controllers): unknown keys are ignored, unknown module types are shown as a plain number, missing optional fields get defaults. A missing or invalid required field (`schemaVersion`, `zones`, `modules`) fails the connection.

### Connect ordering

No revision counters: TCP ordering is the mechanism.

1. The controller opens TCP and starts reading.
2. The controller sends `get/system/config`.
3. Any `set` that arrives before the config reply is older than the snapshot; the controller discards it.
4. The controller applies the config reply (topology and `values`).
5. Everything after it is processed normally.

This requires the mixer to serialize the snapshot into the **same TCP stream** as its broadcast `set`s: no broadcast may be sent between reading the state for the snapshot and sending it.

## Error reply

The mixer answers a refused request with

```
/<name>/error     <path:string> <reason:string>
```

to the requesting TCP controller only. `path` is the request's address tail after the command, without a trailing slash (`inputChannel/99/level`, `system/deviceName`, `meter/subscribe`). `reason` is human-readable, for logs and the UI; controllers don't parse it.

Refused requests:

- a `get` or `set` of a path the mixer doesn't have (unknown zone, index out of range, module not implemented there, unknown setting);
- a `set` without a value, or with a value of the wrong kind;
- a `set` of a `readOnly` setting;
- an `enum` value outside its `options`;
- an invalid `deviceName` (after the current-name reply, see *The `system` zone*);
- a malformed `meter/subscribe` (see *Metering*).

Clamping is never an error. UDP requests never get an error reply. A message under an unknown name, or with an unknown command kind, is ignored without one.

## Metering

Meters stream over UDP, mixer → controller, separate from TCP control. The controller chooses the UDP port it listens on.

**Subscribe** (controller → mixer, TCP):

```
/<name>/meter/subscribe     <port:int> <rateHz:int> <zoneMask:int>
```

- `zoneMask`: bit 0 `inputChannel`, bit 1 `busChannel`, bit 2 `outputChannel`. Bits for zones the mixer doesn't have are ignored.
- The mixer streams to the **source IP of the TCP connection**, at `port`.
- `rateHz` is clamped to 1–120. Controllers default to 30.
- **Lease:** a subscription expires 5 s after the last `subscribe`. Controllers re-send every 2 s while connected. `zoneMask` 0 unsubscribes at once. Closing the TCP connection ends the subscription.
- Re-subscribing with a new port moves the stream; with the same port it renews the lease and updates the rate and zones.
- A `subscribe` that isn't three integers (`i`, or `f` with an integral value), or whose port is 0 or above 65535, is refused with an *Error reply*.

**Stream** (mixer → controller, UDP), one message per subscribed zone per tick:

```
/<name>/meter/<zone>     <blob>
```

- Blob, big-endian: `uint32 sequence`, then `N × int16` peaks in units of 0.01 dBFS; `-32768` is silence / no signal. `N` is the zone's channel `count` from the config.
- `sequence` is per zone per subscriber: it starts at 0 when the subscription starts, increments by 1 per message and wraps at 2³². A message that is dropped still uses its number, so gaps are visible.
- The peak is the highest since the previous message for that zone (nothing between two ticks is lost).
- Tap point: post-DSP of that zone. Reserved for later: `meter/<zone>_pre`.

## Ping

Optional: a mixer may not implement it, and controllers then fall back to TCP state and meter sequence gaps.

- Controller → mixer: `/<name>/ping <token:int>`.
- Mixer → that controller: `/<name>/pong <token:int>`, with the same token.

## TCP framing

- **OSC 1.0 stream framing:** each packet is preceded by its size as a 4-byte big-endian integer. Packets may be messages or bundles (`#bundle`); the messages of a bundle are handled in order.
- **Unframed** (older firmware): OSC messages back to back, self-delimiting by parsing, no bundles. A truncated message corrupts the parse of what follows. Controllers keep supporting it for older images.
- A mixer serves one framing per port and advertises it (Bonjour TXT `framing`, below). The reference server has `--tcp-framing len32|none`, default `len32`.

## Discovery

- Bonjour service type `_studiorunner._tcp`, port = the OSC TCP port, instance name = the mixer name.
- TXT: `name` (current mixer name), `v` (protocol/schema version, today `1`), `framing` (`len32` or `none`).
- The mixer updates the advertisement when it is renamed.

## Change log

- **18 Aug 2026:** first version (set/get, zones, matrix and channel examples, `deviceName`).
- **4 Oct 2026:** amendments A–H folded in (from the StudioRunner controller's `OSC_Amendments_Proposed.md`, agreed 4 Oct 2026), with the device rules decided alongside them (controller `DECISIONS.md` D33, D37, D38, D39, D50) and in the firmware session: `mixer` is the factory name; the error `path` has no trailing slash; UDP never replies; a malformed `meter/subscribe` gets an error. The `deviceName` example lost its trailing slash (both forms are accepted).
