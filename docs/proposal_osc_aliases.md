# Proposal: OSC aliases and linked parameters

*Requested by the user 2026-09-26; not scheduled ("it doesn't need to happen now"). Written so it isn't lost and so later OSC/state changes don't paint it into a corner. Decisions are in §4.*

## 1. The request

> If I send `/mixer/set/inputChannel/0/level/alias "channel one"`, I should then be able to call `/mixer/set/channel_one/` and pass a float to set the level of inputChannel 0. Also, if multiple parameters have the same alias, they should act as if they're linked. This would be especially useful for stereo pairing channels.

So: **(a)** a name for a parameter, usable as an address of its own, and **(b)** parameters sharing a name form a **link group**: setting the name (or, see §4, any member) sets them all.

## 2. Where it lives (modularity)

A **generic layer in the OSC server**, between address parsing and the zone → backend table (`architecture_modules.md` §4.2). Backends, register windows and the PL don't change, and it works for every zone, including ones added later (DSP modules). The final server (the Python one is interim) should carry the same layer. The OSC standard (`FPGA Mixer OSC Standard.md`, the user's document) needs a section for it; that's the user's to write, or they can ask for a draft.

## 3. Things the design has to handle

1. **The state-tree rule.** `inputChannel/0/level` is a leaf (a value). `…/level/alias` would make it a branch, which the stored tree forbids (`architecture_modules.md` §4.2: "a value can't sit where the tree has a branch"). So `/…/<module>/alias` should be an **OSC command form** the server recognises, not a tree path, and aliases are **stored in a zone of their own**, e.g.
   ```json
   "alias": { "channel_one": ["inputChannel/0/level", "inputChannel/1/level"] }
   ```
   A new top-level zone doesn't change the file format, so old state files keep loading.
2. **Name → address.** `"channel one"` → `channel_one`: trim, spaces → `_`. Also: allowed characters, case (keep or fold), and refusal of names that clash with zones (`system`, `inputChannel`, …) or with `set`/`get`. `/mixer/set/channel_one` should work with and without the trailing slash (as `deviceName` does).
3. **Echoes.** A set through the alias echoes the alias address **and** every member's own address, so controllers bound to either view stay in sync. The same applies when a member is set directly.
4. **One frame for a linked group.** A stereo pair's crosspoints must change on the **same audio frame**, which is what the coefficient contract's COMMIT gives, if the server writes all members and then commits once. Today `MatrixBackend.apply` commits per set, so backends need a batch path (apply several, commit once).
5. **Joining a group with a different value.** When a parameter takes an existing alias, does it snap to the group's current value (echoed), or keep its own until the next set?
6. **Removal and queries.** `…/alias ""` removes a membership; `/mixer/get/…/level/alias` returns the name; `/mixer/get/channel_one` returns the group value.
7. **Persistence.** Aliases are saved with the state and restored at boot, like everything else.
8. **Stereo is more than equal values.** Linked levels want the same value, but a stereo pair's **pans** want mirrored values, and "relative" links (keep offsets) are common on consoles. v1 can be absolute (same value), with room left for a per-group mode later.

## 4. Decisions needed (when it's scheduled)

| # | Question | Recommendation |
|---|---|---|
| 1 | Is the link **symmetric**: does setting a member directly (`/inputChannel/0/level`) move the others too? | **Yes.** "Act as if they're linked" means any member drives the group. |
| 2 | Parameter-level aliases only (as requested), or also **channel-level** (`/mixer/set/inputChannel/0/alias "vox"` → `/mixer/set/vox/level`, `/mixer/set/vox/eq_band1_gain`, …, and two channels with the same channel alias linked in every module)? | **Both, eventually:** channel-level is what stereo pairing usually wants; parameter-level is the building block. |
| 3 | Joining a group: snap to the group's value? | **Yes, snap and echo**, so a group is never inconsistent. |
| 4 | Name rules: case-sensitive? Which characters? | Case-preserving, case-insensitive matching; `[A-Za-z0-9_-]` after spaces → `_`. |
| 5 | Link modes beyond absolute (mirrored for pan, relative)? | **Later:** absolute only in v1, but store a `mode` per group so adding modes doesn't change the format. |
| 6 | May a parameter be in more than one group? | **No** (one alias per parameter); it keeps the semantics obvious. |
