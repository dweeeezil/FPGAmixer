# Plan: virtual groups (stereo / surround linking)

**Written:** 2026-10-06 17:40 PDT (2026-10-07 00:40 UTC), at the end of Phase 13, on branch `phase13-metering` (commit `d3c1587`).
**Status:** plan only, nothing built. Order agreed in principle: **snapshots → virtual groups → channel sources**, after Phase 11 (USB host mode), which the user put first on 2026-10-06.
**Companions:** `plan_snapshots_2026-10-06.md`, `plan_channel_sources_2026-10-06.md`; session prompt `docs/prompt_phase14_qol.md`.

---

## The request (user, 2026-10-06)

> "I've been thinking about how I want to handle stereo/surround linking. I like having mono channels because it makes it very clear where everything is going, but I don't want to have to individually change every parameter when working in stereo or surround. I'd like to implement a virtual group system. In the UI, a user should be able to assign any channel to a group, and then when any parameter is changed on any channel in a given group, that change is reflected across all channels in that group. This could technically be done only in the UI, but then changes wouldn't persist across sessions."

## Shape (recommended; to be decided in a proposal)

- **In the server, not the UI** (the user's own reason, plus): persistent, the same for every controller, and in snapshots for free.
- **A module `group`** (int, 0 = none, 1..G) on each channel zone (`inputChannel`, `busChannel`, `outputChannel`). Groups are **per zone**: an input group and a bus group are different things. G = the zone's channel count is enough.
- **On a set of a linked module on a grouped channel,** the server applies the change to every member under the ordering lock (`ClientRegistry.lock`) and echoes each member's applied value. The app's D44 (matching echoes to edits) already accepts device-originated sets for other parameters.
- **Hardware:** one write per member, one COMMIT per window (the window's shadow/commit already makes a multi-channel change land on one frame).

## Decisions for the proposal

1. **Which modules link:** `level`, `mute`, later EQ / dynamics; **never** `group`, `name`, `source` / `destination` (channel sources), meters.
2. **Absolute or relative level linking:** relative (offsets kept, like DAW fader groups) suits trims; absolute suits matched stereo pairs. Clamping at +6.02 and "off" at −90 make relative links lossy at the ends (a member at −90 can't keep an offset). Decide the rule, or a per-group mode.
3. **Matrix crosspoints:** a stereo input group (1, 2) sent to a stereo bus group (3, 4): changing 1→3 should change 2→4, not 2→3. Pair members **by order** when both sides are groups of the same size; apply across one side when only that side is grouped; decide what happens when the sizes differ (e.g. stereo into a 5.1 bus group).
4. **Joining a group:** the new member takes the group's values, or keeps its own (relative offsets)?
5. **Group names / colours:** later, unless wanted now (would be system-level metadata, not per channel).

## Seams

Control plane only: a linking step in `apply_set` (`osc_mixer_server.py`) driven by the model's description of which modules link (a `ModuleSpec` flag, so new modules opt in by metadata rather than by special cases); the backends unchanged. Protocol: `group` is an ordinary module (needs no standard change beyond listing it, possibly a `linked: true` metadata hint for the app). No gateware.

## Tests to plan

Absolute and relative links at the ends (clamp, off); matrix pairing for equal and unequal group sizes; ungrouped channels untouched; every member echoed to every controller; snapshots carry groups; a group change during a drag (D44's pending logic on the app side). Mutation-tested.

## App work (controller repo, handoff)

Assigning a channel to a group (a strip control, or the group as a picker); showing group membership (colour, badge); D44's pending state for echoes of members the user didn't touch.
