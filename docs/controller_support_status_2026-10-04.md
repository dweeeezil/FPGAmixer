# Controller support status: 2026-10-04 — the OSC server meets the StudioRunner contract (F1–F9)

**Branch:** `controller-support`, from `phase9/time-shared-core` at `368e236`. **Opening prompt:** `../StudioRunner-controller/docs/prompts/prompt_firmware_controller_support.md`.

**Status: steps 0–5 and 7 done** (standard approved; shared codec and TCP framing; alias and name rules; error reply and value rules; config reply and snapshot ordering; ping; Bonjour through systemd-resolved), verified on the PC. **Image with all of it: §5** (the Pi is gone, C9). Then the first Mac run, metering (step 6) and the step 8 checks.

---

## 1. The goal

The StudioRunner controller app (`../StudioRunner-controller`) speaks the OSC standard plus amendments A–H, agreed 2026-10-04, and was built against an in-process mock (`MockDevice.swift`). Today's server (`tools/osc_mixer_server.py`) predates the amendments: the app connects and stops at once with "firmware predates the config reply (F1)". This task makes the board's server meet the contract in `../StudioRunner-controller/docs/FIRMWARE_CONTRACT.md` (F1–F9; F4a is gateware and not part of it).

## 2. Decisions (user, 2026-10-04)

| # | Question | Decision |
|---|---|---|
| C1 | Framing transition | `--tcp-framing len32\|none`, default `len32`, advertised in Bonjour TXT `framing`. The repo's tools move to a shared codec and get the same flag. TouchDesigner / Ableton are not in use now, so they don't constrain it. |
| C2 | Paths the config doesn't advertise | **Refused** with an error reply (set and get). A zone becomes reachable when it has a backend (or a declared store-only description). Values for such paths already in old state files stay in the file, untouched and unreachable. |
| C3 | Meter source (F4) | Subscription, lease and UDP stream behind a `MeterSource` interface; tested with a synthetic source enabled only by a server flag. The real source waits for F4a and channel zones. |
| C4 | Bonjour (F5) | ~~`avahi-daemon` in the image~~. **Revised by the user 2026-10-04:** systemd-resolved, which the image already runs (missed when C4 was asked): its mDNS on (global drop-in + `MulticastDNS=yes` on `end0`), and the server writes `/etc/systemd/dnssd/studiorunner.dnssd`, restarting resolved when it changes. No Avahi (it would fight resolved for port 5353). |
| C9 | The bench without the Pi (user, 2026-10-04) | The Pi is gone; **only the Mac reaches the board**, on a direct cable. The next step is an image with everything so far, not a hand deploy. In it: steps 1–5, step 7 (Bonjour), and Mac access: IPv4 link-local + mDNS on `end0`, so the Mac reaches `amd-edf.local` with no IP settings. Metering (step 6) comes later as server files copied from the Mac. |
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

### Step 3: error reply and value rules (F8, F9) — done, PC only

**What.**

- **The parameter model** (`tools/mixer_params.py`, new): `ModuleSpec` (type, unit, min, max, default, options, group, read-only, and the value rule `apply`), `ZoneSpec` (shape and module list), `Model.resolve(tail)` (→ a parameter with a canonical path, or `Refused(path, reason)`). No sockets, no hardware.
- **Backends describe themselves** (`Backend.describe()`); `MatrixBackend` says: matrix `n_in × n_out`, module `level`, float dB, −90 to the gain ceiling (read from the window's CONFIG with `--hw`: Q2.16 → 6.0205 dB), default −90 (off), group `level`. `build_model` assembles the model from the backends plus `SYSTEM_SETTINGS` (`deviceName` string, default `mixer`; `sampleRate` enum `[48000]`, read-only). Step 4 builds the config JSON from the same model.
- **Only what the model names is accepted** (C2). Set and get of anything else is refused.
- **Error reply** `/<name>/error <path> <reason>`, to the TCP requester, for: unknown path (zone, index, module or setting; `get` no longer answers 0.0), `set` without a value, wrong kind (string for a number, blob, …), read-only setting, enum value outside `options`, invalid name (step 2). Over UDP: logged only.
- **Value rules** (D37): non-finite remapped (NaN, −inf → −99.9; +inf → +99.9), then clamped to the module's range; bool snapped (≥ 0.5 → 1); int rounded, halves away from zero (as the mock's Swift `rounded()`); enum checked against `options`; result rounded to float32, so stored, echoed and snapshot values agree (D30). Clamping is not an error: the echo carries the applied value.
- **Canonical paths:** `inputMatrix/01_002/level/` resolves to `inputMatrix/1_2/level`, which is what is stored, echoed and named in errors.
- **Startup:** stored crosspoint levels are brought inside the rules (an old −99.9 or −120 becomes −90, 50 becomes the ceiling; a non-number gets the reset routing) and logged.

**Seam.** `Backend.describe()` is the new seam: a block's software side now carries its own description, so adding a block adds its parameters, validation and (step 4) config in one place. `Backend.apply(index, module, value)` only drives hardware: it gets a canonical index and an already-accepted value.

**State file:** format unchanged (§4.2). Values for paths the model doesn't name (old `inputChannel/0/level`, `inputMatrix/0_0/delay`) stay in the file, untouched and unreachable; tested.

**Behaviour changes a user could notice:** `level` below −90 now echoes −90 (it used to echo the value sent, e.g. −120, while applying off); `inputChannel`, `delay` and other paths with no hardware are refused instead of stored; `get` of anything unknown is an error, not 0.0.

**Tools:** `osc_mixer_test.py` no longer uses `inputChannel`. Its tests change only "scratch" crosspoints, input 0–6 → output `--scratch-output` (default 19, an AVB output nothing listens to on the bench), so a run on the board doesn't touch what is heard. `matrix_crosspoint_set_echo` now expects the `delay` to be refused; `invalid_matrix_index_handling` expects an error reply. `set_get_echo_input_channel_level` is now `set_get_echo_level`.

**Verified (PC), measured:**

- `test_mixer_params.py` (new): 18 tests, the value rules per type, defaults, resolution and its refusal paths, the model's consistency checks.
- `test_osc_mixer_server.py`: 40 tests (17 new): error replies for set and get of six kinds of unknown path, wrong kind, missing value, read-only, clamping with the applied value echoed, canonical paths in echo, get and state file, UDP refusals only logged, the reset routing, an old state file (values brought inside the rules, unadvertised values kept), a conflicting state file, and in-process tests of `MatrixBackend` against a fake hardware window (write order out/in, the startup bank, the ceiling from the window geometry).
- Mutation test: 22 planted bugs in `mixer_params.py`, 16 in the server's set/get/startup code. **A runner bug first made every model mutant look killed**: two test modules were passed as one argument, so every run failed on import. Found from the identical error counts, fixed, checked with a no-op mutation (survives), and all re-run. Real result: 2 model survivors (a redundant bool clamp, now deleted; a module checked against all zones' modules instead of its own zone's, now tested) and 5 server survivors (state stored under the raw path, the backend call, the reset routing, the state-conflict refusal: now tested; a read-only branch equivalent to the default, now deleted). All killed after the fixes. Steps 1–2 ran one test module per mutation run, so the bug didn't affect them.
- `osc_mixer_test.py` against a local server named `FOH`: 22/22, including the destructive rename.

### Step 4: config reply and snapshot ordering (F1, F3) — done, PC only

**What.**

- `get system/config` (alias or name, trailing slash or not) → `set system/config "<json>"`, an OSC string, to the requester only. `set system/config` is refused (it isn't a setting); over UDP nothing happens.
- The JSON is built by `Model.config` (`mixer_params.py`) from the backends' descriptions and the state: `schemaVersion` 1, `deviceName`, `firmware`, `sampleRate` 48000, `zones`, `modules`, `system`, `values`. Metadata objects carry only the fields that are set, `default` always, `readOnly` only when true. `values` is sparse (non-defaults) plus `system/deviceName` always; read-only settings are never listed.
- What the board will send (20 × 20 core, fresh state): `zones` = `inputMatrix` 20 × 20 `["level"]`; `modules.level` = float, dB, −90 … 6.0205, default −90, group `level`; `system` = `deviceName` (string, default `mixer`) and `sampleRate` (enum `[48000]`, Hz, read-only); `values` = the 20 unity diagonal crosspoints and `system/deviceName`. 1,033 bytes (measured with the simulated 20 × 20 backend).
- **`firmware`** is the commit: on the board, `VERSION` next to the server, which the `fpgamixer-osc` recipe now installs from the `.synced-from` that `scripts/sync_buildhost.sh` writes (`<commit>` or `<commit>-dirty`; the recipe re-runs when it changes); in a checkout, `git describe --always --dirty`; else `dev`.
- **Ordering (F3).** `ClientRegistry.lock` (now re-entrant) is held while a change is applied, stored and echoed, while any packet is sent, and while the snapshot is read and sent. Besides F3 this fixes two races the old server had: two changes to one parameter could echo in the reverse of their store order (controllers ending on a value the mixer doesn't have), and a get reply and a broadcast could write into one socket at the same time.
- **The price, bounded.** A controller that stops reading now holds everyone up for at most 5 s (`SEND_TIMEOUT`, the socket timeout); then it is dropped and its connection shut down, so it reconnects and resyncs. The reader thread's old 120 s timeout is gone (it never reaped anything: a recv timeout just looped).
- **Codec:** the unframed string limit went from 1 kB to the packet limit (4 MB): the config reply is one long string, which an unframed reader used to reject as "no NUL within 1024 bytes".

**Seam.** `Model.config` is generic: a new block's zone, modules and values appear in the reply through its `describe()`, with nothing to add to the server. The ordering guarantees are written into `ClientRegistry`'s docstring and §4.2 as the contract; the lock is the Python server's way of meeting them.

**App compatibility, without a Mac.** The app's `DeviceConfig.swift` was ported rule by rule into the test (`app_config_problems`: every throw and every warning); the server's reply produces none. Its shape is compared with `MockProfile.hardwareToday` (the same keys; `level` identical except `max`, 6.0205 vs the profile's 6.02; unity diagonal in `values`). **Not yet checked in the app itself**: that is the user's run in step 8 (or earlier, on request).

**Verified (PC), measured:**

- `test_mixer_params.py`: 23 tests (5 new: shape, sparse values, read-only exclusion, every parameter once, strict JSON).
- `test_osc_mixer_server.py`: 53 tests (13 new): the reply through every address form, to the requester only; app rules; mock shape; values following sets and a rename; refusals; the reply over unframed TCP; **F3 end to end** (a writer sets one crosspoint up to 9,000 times as fast as it can while 15 controllers connect in turn: no set after a snapshot is older than it, and snapshot + later sets end on the mixer's value); **F3 deterministic** in-process (the snapshot slowed after reading the state: a concurrent set waits and its echo follows the snapshot); store-order echoes; two-thread sends never interleave (both orders); a stalled controller dropped and its connection closed; the reply's firmware; the firmware sources.
- `test_osc_codec.py`: 33 (a 50 kB string waits for its NUL).
- All 123 unit tests, three runs in a row on the final code: no flakes. `osc_mixer_test.py` against a local server: 22/22.
- Mutation test: 10 server mutants, 10 config-builder mutants, 1 codec mutant. **Two false kills found and fixed in the method:** the runner's temp folder isn't a git checkout, so two new tests that assumed one failed for every mutant. The tests now check git only in a checkout, and the runner runs the unmutated baseline first and stops if it fails. Re-run with the baseline check: the config builder 10/10; the server 5/10 at first. Survivors: the lock in `apply_set` (the test slowed the backend, before the store, not the store-to-echo window), `send` without the lock (no test of interleaved writes), `broadcast` without its own lock (only one order tested), no shutdown on drop (only the client list checked), `firmware` hard-coded (equal to `dev` in the temp folder). Each got a test; all 21 killed after.

**Not verified:** the recipe change (the `VERSION` install and `file-checksums`) has not been built; the app hasn't decoded a real reply.

### Step 5: ping (F7) — done, PC only

**What.** `/<root>/ping <int>` → `/<name>/pong <int>`, the same token as an OSC int, to the sender only, through the alias or the name. Anything else (no token, a float, a string, an OSC true, two tokens, `/ping/x`) is ignored and logged, as the mock does; a ping is optional, so it gets no error reply. Over UDP nothing (write-only).

**Seam.** The protocol layer's command dispatch (`handle_tcp_message`), beside `set` and `get`.

**Verified (PC):** 3 new server tests (tokens 0, ±2³¹ edges, both roots; the reply is an OSC `i`; the ignored forms, then still answering). Mutation test: 6 planted bugs, 6 caught, with the runner's baseline check (which, on the first try, correctly refused to report while a test of mine was wrong: Python's `True` encodes as an OSC int, so that case was a valid ping; it now sends a real OSC `T`).

**What the app sends that the board now handles** (controller DECISIONS): `get system/config` through `/mixer/` (D2, D60), a ping every 2 s (D58), crosspoint sets as floats (D6). No `meter/subscribe`: the config advertises no channel zones, and the app subscribes only to those (D55). So the app can run against the board before steps 6–7.

### Step 7: Bonjour through systemd-resolved (F5, C4 revised) — done, PC only

**What.** `tools/osc_discovery.py` (new): an advertiser the server calls at startup and after every accepted rename (outside the ordering lock). `DnssdAdvertiser` writes `/etc/systemd/dnssd/studiorunner.dnssd` atomically (`Name=<mixer name>`, `Type=_studiorunner._tcp`, `Port=<TCP port>`, `TxtText=name=<mixer name> v=1 framing=<len32|none>`) and, only if the contents changed, restarts systemd-resolved in a background thread; a failure is logged, never fatal. A stored name from before the rules (a space, `%`) is escaped (`%%` in `Name=`, one quoted TXT word). `NoAdvertiser` for everything else. Server option `--advertise none|dnssd` (default none), `--dnssd-file`, `--dnssd-reload`; the board's unit passes `--advertise dnssd`.

**Image side.** `fpgamixer-osc` installs `/etc/systemd/resolved.conf.d/fpgamixer-mdns.conf` (`MulticastDNS=yes`: Yocto builds systemd with `-Ddefault-mdns=no`, checked on the VM) and creates `/etc/systemd/dnssd/`. `10-end0-bench.network` adds `MulticastDNS=yes` (per link; systemd 255's man page: "Defaults to false") and `LinkLocalAddressing=yes` (IPv4 link-local "when DHCPv4 autoconfiguration has been unsuccessful for some time", i.e. on a Mac cable with no DHCP server; the same man page, read from the image's systemd-stable revision `70500d3`).

**Seam.** Discovery is its own module behind `advertise(name)`; the server knows nothing about resolved. Avahi, or the final server's own mechanism, would be another advertiser.

**Verified (PC):** `test_osc_discovery.py` (new, 10 tests: the file's lines, port and framing from the server, a reload only when the contents change, escaping, a reload that can't start or exits non-zero is logged, an unwritable path is logged, no reload command); 2 server tests (advertised at startup and after a rename, not after a refused one; off by default). Mutation test: 13 planted bugs (12 in the module, 1 in the server's call), all caught after one survivor (a non-zero exit wasn't tested) got its test. **Not verified:** resolved actually publishing, and the Mac seeing it. That is the board's first boot.

## 5. The image without the Pi (C9)

**Content:** this branch at the build commit: Phases 9–10 (as `p10e`), Phase 11 (docs only, nothing built), and controller support steps 1–5 and 7, plus Mac access (link-local, mDNS). No hardware change, so no new SDT or bitstream (`p95`, as `p10e`).

**Image `ctl1` built 2026-10-04** from the clean commit `12c8f9f` (synced, `.synced-from` = `12c8f9f`): `bitbake edf-linux-disk-image xilinx-bootbin`, 15,069 tasks, all succeeded, 23 warnings (the usual; none from fpgamixer recipes). No `gen-machine-conf` (no hardware change). **`build/sd/ctl1-controller-20261004.wic.xz`** (108 MB, MD5 `f8f37f53…`, same on both ends).

**Checked in the rootfs tarball:** `/usr/lib/fpgamixer/` has `osc_mixer_server.py`, `osc_codec.py`, `osc_discovery.py`, `mixer_params.py`, `mixer_state.py`, `mixer_hw.py` and `VERSION` = `12c8f9f` (so the recipe's `.synced-from` install works); the unit runs `--hw --advertise dnssd`; `/etc/systemd/resolved.conf.d/fpgamixer-mdns.conf` (`MulticastDNS=yes`) and `/etc/systemd/dnssd/`; `10-end0-bench.network` with `LinkLocalAddressing=yes` and `MulticastDNS=yes`.

**Checked under the board's Python version:** all 138 tests on the VM (Python 3.12.3, Linux; the board has 3.12.12), including the SIGTERM test that Windows skips. It failed once: the test still set `inputChannel/5/level`, refused since step 3 (I had updated its framing in step 1, not its path, and it had never run). Fixed to `inputMatrix/0_1/level`; 138/138. A test-only change, not in the image.

**Not verified:** anything on the board (first boot below).

## 6. Open items

- The board image needs the meter/Bonjour modules added to the `fpgamixer-osc` recipe (`osc_codec.py` is in since step 1), and `avahi-daemon` in the image (step 7).
- `osc_mixer_test.py` gains F1–F9 coverage in step 8. It needs a matrix with at least 20 outputs for its default scratch output (pass `--scratch-output` otherwise).
- The step 4 recipe change (`VERSION` from `.synced-from`, `do_install[file-checksums]`) is unbuilt; check it in the first image build (step 8): `cat /usr/lib/fpgamixer/VERSION` on the board.
- `sampleRate` is reported as 48000 (nominal). The core actually runs ~+324 ppm fast unless disciplined (roadmap §4); the setting is the nominal rate, which is what the app shows.
- **The board's current name.** The service starts with `--mixer-name mixer`; if the board's state file still has `mixer`, it is the factory name (fine). Renaming it is the user's call; the app works either way through the alias.
- `MockProfile.hardwareToday` is 12 × 12 (Phase 8); the board on this branch is 20 × 20. The config JSON follows the PL's CONFIG register, so a comparison with the mock is by shape, not size.
