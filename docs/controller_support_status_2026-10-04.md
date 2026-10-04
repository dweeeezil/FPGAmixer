# Controller support status: 2026-10-04 — the OSC server meets the StudioRunner contract (F1–F9)

**Branch:** `controller-support`, from `phase9/time-shared-core` at `368e236`. **Opening prompt:** `../StudioRunner-controller/docs/prompts/prompt_firmware_controller_support.md`.

**Status: steps 0–2 done** (standard approved; shared codec and TCP framing; alias and name rules), verified on the PC, not yet on the board. Next: step 3 (error reply and value rules).

---

## 1. The goal

The StudioRunner controller app (`../StudioRunner-controller`) speaks the OSC standard plus amendments A–H, agreed 2026-10-04, and was built against an in-process mock (`MockDevice.swift`). Today's server (`tools/osc_mixer_server.py`) predates the amendments: the app connects and stops at once with "firmware predates the config reply (F1)". This task makes the board's server meet the contract in `../StudioRunner-controller/docs/FIRMWARE_CONTRACT.md` (F1–F9; F4a is gateware and not part of it).

## 2. Decisions (user, 2026-10-04)

| # | Question | Decision |
|---|---|---|
| C1 | Framing transition | `--tcp-framing len32\|none`, default `len32`, advertised in Bonjour TXT `framing`. The repo's tools move to a shared codec and get the same flag. TouchDesigner / Ableton are not in use now, so they don't constrain it. |
| C2 | Paths the config doesn't advertise | **Refused** with an error reply (set and get). A zone becomes reachable when it has a backend (or a declared store-only description). Values for such paths already in old state files stay in the file, untouched and unreachable. |
| C3 | Meter source (F4) | Subscription, lease and UDP stream behind a `MeterSource` interface; tested with a synthetic source enabled only by a server flag. The real source waits for F4a and channel zones. |
| C4 | Bonjour (F5) | `avahi-daemon` in the image; the server writes `/etc/avahi/services/studiorunner.service` and rewrites it on rename. Bench check with `avahi-browse` on the Pi; Mac discovery later, when the Mac is on the board's segment. |
| C5 | Base branch | `phase9/time-shared-core`: what the board runs (20 × 20 core). The server reads the matrix size from the PL, so the code doesn't depend on it. |
| C6 | The name `mixer` | The factory (unnamed) state: reported as `deviceName` `mixer`, answers to `/mixer/` only. Renaming **to** `mixer` is refused. A stored name that breaks today's rules loads as it is but can't be set again. (Today's board service starts with the default `--mixer-name mixer`.) |
| C7 | Refusals over UDP | Logged only. UDP control stays write-only: nothing is ever sent back over it. |
| C8 | Error `path` | Normalised: the request's tail without a trailing slash, as the mock sends it and as the app keys pending edits. |

## 3. Plan

Each step: build, test, commit, this doc updated. Board, Pi and Mac commands are run by the user.

| Step | What | Contract | Seam |
|---|---|---|---|
| 0 | Merge amendments A–H into `docs/FPGA Mixer OSC Standard.md`; user reviews before any code | — | the standard |
| 1 | `tools/osc_codec.py`: one codec, both framings, bundle decoding; server and all repo tools on it; `--tcp-framing` | F6 | transport, below the protocol layer |
| 2 | `/mixer/` alias and name rules | F2, F9 | address parsing (one place, TCP and UDP) |
| 3 | Error reply; value rules (clamp, snap, refuse) from module metadata | F8, F9 | the `apply_set` / `handle_get` path; backends describe modules |
| 4 | Backends describe their zones; the server builds the config JSON; reply under the broadcast lock | F1, F3 | `Backend.describe()`, `ClientRegistry` |
| 5 | Ping | F7 | protocol layer |
| 6 | Metering behind `MeterSource` | F4, F9 | new `MeterSource` seam |
| 7 | Bonjour via Avahi | F5 | image (`meta-fpgamixer`) + a small advertiser |
| 8 | `osc_mixer_test.py` covers F1–F9; board run; power cycle; app connects; F1–F9 status for the controller repo | all | — |

The persisted state format (`architecture_modules.md` §4.2) does not change; old state files must keep loading.

## 4. Steps

### Step 0: the merged standard (approved 2026-10-04)

**What.** `docs/FPGA Mixer OSC Standard.md` rewritten as the single source of truth: the original text kept, amendments A–H folded in as sections (command kinds, transports, name and alias, values, set/get, `system`, config and connect ordering, error reply, metering, ping, framing, discovery), and the decisions above (C6–C8) written in. A change log at the end.

**Points beyond the amendments and the mock**, written into the draft for the user to accept or strike:

- A malformed `meter/subscribe` gets an error reply (path `meter/subscribe`). The mock ignores it silently; amendment G doesn't list it.
- `meter/subscribe` accepts `f` arguments with integral values as well as `i` (D6 says ints travel as floats). The mock accepts only `i`.
- Closing the TCP connection ends a meter subscription (the mock does this; the prose didn't say).
- The meter peak is "the highest since the previous message": what F4a delivers. Until F4a exists no real meter source does.
- The unnamed state is `mixer` (C6). Amendment B's example already had `"default": "mixer"`.
- The standard's own `deviceName` example lost its trailing slash; both forms stay accepted.

**Approved by the user as drafted, 2026-10-04** (all six points kept). The user re-copies the standard into `../StudioRunner-controller/docs/protocol/OSC_Standard.md` and retires `OSC_Amendments_Proposed.md` (DECISIONS D52).

### Step 1: shared codec and TCP framing (F6) — done, PC only

**What.** `tools/osc_codec.py` is the one codec: messages (encode `f i s b`, decode `f i s b T F N I h d`), packets (a message or a bundle, nested, messages in order, time tags ignored), the two TCP framers behind one interface (`push(bytes) → [packets]`, `frame(packet) → bytes`), and the client links (`TCPLink`, `UDPLink`) the tools share. The server, `osc_mixer_test.py`, `osc_console.py` and `crosspoint_restore_test.py set` use it; their four copies of the codec are gone. Every tool has `--tcp-framing len32|none`, default `len32`.

**Seam.** Transport, below the protocol layer: the server's protocol code only ever sees messages, and `ClientRegistry` frames every TCP send (`architecture_modules.md` §4.2, first bullet). The image recipe `fpgamixer-osc` installs `osc_codec.py` next to the server.

**Behaviour, per framing:**

| Input | `len32` | `none` (as before) |
|---|---|---|
| a packet that doesn't decode (truncated, bad type tag, bad bundle) | that packet is dropped and logged; the stream stays in step | truncated: corrupts what follows; malformed: buffer cleared |
| a bundle | its messages run in order; a bad message drops the whole bundle | not possible |
| an impossible size (> 4 MB) | the connection is closed (stream position lost); others unaffected | — |
| an unframed controller on a `len32` port | `/mix` reads as an ~800 MB size: closed at once, never misparsed | — |

UDP (either framing): one packet per datagram, so bundles work. **Changed:** two messages concatenated in one datagram are no longer half-applied (the first one used to be); the datagram isn't a valid packet and is dropped and logged.

**Verified (PC, Windows, Python 3.14), measured:**

- `test_osc_codec.py`: 32 tests (every truncation point, every split of a framed stream, bundles, bad sizes, the client link over a socket pair). Mutation-tested: 14 planted bugs, all caught; the two that survived the first run (a client silently dropping a bad packet; bundle element sizes checked only indirectly) got tests.
- `test_osc_mixer_server.py` (new): the real server as a subprocess, 13 tests over its sockets in both framings and UDP. Mutation-tested: 9 planted bugs in the server's framing code, all caught.
- `osc_mixer_test.py` against a local server: **len32 22/22** (21, then the destructive rename on its own), including `truncated_argument_then_recovery`, which never passed before, plus two new bundle tests. **none 21/22**: the truncated test fails by design, as it always has.
- `crosspoint_restore_test.py set`: 400/400 crosspoints echoed as sent (len32). `osc_console.py`: sends and receives over len32.
- `test_mixer_state.py`'s SIGTERM test now sends a framed message; it is skipped on Windows, so **not run**. `test_mixer_hw.py` shows 7 errors on Windows with or without this change (`os.O_SYNC`, `/dev/mem`).

**Not verified:** anything on the board. The board's image still runs the unframed server; the board check is part of step 8 (deploy, `osc_mixer_test.py` from the Pi with `--tcp-framing len32`).

### Step 2: the `/mixer/` alias and the name rules (F2, F9) — done, PC only

**What.**

- The server answers to its current name **and** `/mixer/`, on TCP and UDP; any other root is ignored. Replies, echoes and broadcasts always use the current name.
- Name rules (`name_problem`, D33): letters, digits, `-`, `_`, `.`; 1–63 bytes; not `mixer`.
- An accepted rename is broadcast under the old name, then the new name applies; the old name is ignored, and the alias keeps working.
- A refused rename (rule broken, or a non-string value) answers the **sender only**: `set system/deviceName <name that stands>`, then `/<name>/error system/deviceName <reason>` (D38, amendment G). Nobody else hears anything. Over UDP it's only logged (C7).
- `mixer` stays a valid *current* name: a fresh board is `mixer` (C6). A stored name that breaks the rules (e.g. `FOH mixer` from before) loads as it is.

**Seam.** The protocol layer's entry: one address parser for both transports, and one `handle_set` path for TCP and UDP (UDP used to have its own copy of the set logic). `send_error` is the error reply in its minimal form; step 3 uses it for every refusal.

**Changed on the wire:** the rename confirmation's address is now `.../set/system/deviceName`, without the trailing slash the old server added. Requests may still carry one. The app accepts both (controller D34).

**Standard:** one wording fix (change log updated). It said a rename is confirmed under "the address the request arrived on"; it is the old *name*, also when the request came through `/mixer/`. The mock, the app and this server all do that.

**Tools:** `osc_mixer_test.py`'s destructive rename test now reports "not run" for a mixer named `mixer` (it couldn't rename it back), and its cleanup checks that the revert was accepted instead of trusting any reply. `osc_console.py`'s help no longer suggests a name with a space.

**Verified (PC), measured:**

- `test_osc_mixer_server.py`: 23 tests (10 new): alias and name on TCP and UDP, other roots silent, rename confirmed under the old name and seen by a second client, the new name and the alias answering afterwards, 63 bytes allowed, eight refused values (each: current name + error to the sender, silence for a second client, name unchanged), UDP refusal only logged, the factory name, a stored invalid name, the rename persisted.
- Mutation test: 15 planted bugs; 13 caught at once. Of the two survivors, one (no explicit empty-name check) is caught by the character rule anyway, so the test now pins its message as well and catches it; the other (a no-op reply function for UDP) behaves exactly like `None` and can't be observed.
- `osc_mixer_test.py` against a local server named `FOH`: 22/22, including the destructive rename.

## 5. Open items

- The board image needs the meter/Bonjour modules added to the `fpgamixer-osc` recipe (`osc_codec.py` is in since step 1), and `avahi-daemon` in the image (step 7).
- `osc_mixer_test.py` still exercises `inputChannel`, which step 3 refuses (C2). Its tests move to advertised paths in step 3 and gain F1–F9 coverage in step 8.
- **The board's current name.** The service starts with `--mixer-name mixer`; if the board's state file still has `mixer`, it is the factory name (fine). Renaming it is the user's call; the app works either way through the alias.
- `MockProfile.hardwareToday` is 12 × 12 (Phase 8); the board on this branch is 20 × 20. The config JSON follows the PL's CONFIG register, so a comparison with the mock is by shape, not size.
