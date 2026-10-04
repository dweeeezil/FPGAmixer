# Controller support status: 2026-10-04 — the OSC server meets the StudioRunner contract (F1–F9)

**Branch:** `controller-support`, from `phase9/time-shared-core` at `368e236`. **Opening prompt:** `../StudioRunner-controller/docs/prompts/prompt_firmware_controller_support.md`.

**Status: step 0 drafted (merged OSC standard), waiting for the user's review.** No code changed yet.

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

### Step 0: the merged standard (drafted, awaiting review)

**What.** `docs/FPGA Mixer OSC Standard.md` rewritten as the single source of truth: the original text kept, amendments A–H folded in as sections (command kinds, transports, name and alias, values, set/get, `system`, config and connect ordering, error reply, metering, ping, framing, discovery), and the decisions above (C6–C8) written in. A change log at the end.

**Points beyond the amendments and the mock**, written into the draft for the user to accept or strike:

- A malformed `meter/subscribe` gets an error reply (path `meter/subscribe`). The mock ignores it silently; amendment G doesn't list it.
- `meter/subscribe` accepts `f` arguments with integral values as well as `i` (D6 says ints travel as floats). The mock accepts only `i`.
- Closing the TCP connection ends a meter subscription (the mock does this; the prose didn't say).
- The meter peak is "the highest since the previous message": what F4a delivers. Until F4a exists no real meter source does.
- The unnamed state is `mixer` (C6). Amendment B's example already had `"default": "mixer"`.
- The standard's own `deviceName` example lost its trailing slash; both forms stay accepted.

**After approval:** the user re-copies the standard into `../StudioRunner-controller/docs/protocol/OSC_Standard.md` and retires `OSC_Amendments_Proposed.md` (DECISIONS D52).

## 5. Open items

- The board image needs `osc_codec.py` (and the meter/Bonjour modules) added to the `fpgamixer-osc` recipe's `SRC_URI`, and `avahi-daemon` to the image (step 7).
- `MockProfile.hardwareToday` is 12 × 12 (Phase 8); the board on this branch is 20 × 20. The config JSON follows the PL's CONFIG register, so a comparison with the mock is by shape, not size.
