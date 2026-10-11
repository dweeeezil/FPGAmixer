# Prompt: channel sources (assignable input sources and output destinations)

*Written 2026-10-08 at the end of the session that did Phase 11 (USB host mode, the Pmods removed) and Phase 14's snapshots, virtual groups and channel names. The opening prompt for a fresh session in the **FPGAmixer** repo. The StudioRunner app is next to it at `../StudioRunner-controller` (read it with `git show origin/main:<path>` after a `git fetch`; never edit it).*

---

You're working on FPGAmixer: a digital matrix mixer on a Genesys ZU-3EG, controlled over OSC by the StudioRunner macOS app (the user builds the app side). Today: 20 inputs → levels → input matrix → 20 buses → levels → bus matrix → 20 outputs → levels, peak meters on every channel, snapshots, virtual groups, all persistent.

**The feature (user, 2026-10-06):** "Having Analog, USB, and AVB is great, but I rarely need all at once, and finding the right channel is a pain. I'd like to be able to configure the mixer to N×Y×Z channels, with each channel being generic. I'd like to then be able to assign input channel sources and output channel destinations in the UI. For example, I could go in and assign inputs 1–5 to AVB 4–9, and then set output channels 1–3 to USB 1–3."

**The plan:** `docs/plans/plan_channel_sources_2026-10-06.md`. Read it, then the corrections below: it was written before Phase 11 and the rest of Phase 14.

## What changed since the plan

1. **The Pmods are gone** (Phase 11, decision P1; `docs/phase11_status_2026-09-30.md` §8). Today's physical ports (`fpgamixer_top`): **0–3 = link #3, the USB host interface** (a MOTU M2, 2 × 2: it uses 0–1, 2–3 are silent), 4–11 = USB device (link #1, the Mac), 12–19 = AVB (link #2). The frame strobe already comes from `audio_clocking` (done). The physical port list for the pickers: "MOTU 1–2" (or "USB host 1–4"), "USB 1–8", "AVB 1–8".
2. **`D_MAX`**: today D = 249 of D_MAX = 250. The bound came from the Pmods' `i2s_port`; since they went, only the `pcm_link`s consume the core's output, at the next strobe, so up to 255 is available (`pcm_matrix_pkg.sv` and `architecture_modules.md` §2.1 say so). Re-derive it if the patch needs the cycles.
3. **The control SmartConnect is at its 16-master limit** (Phase 11 H.3: M14 = formatter #3, M15 = link #3's status window). New register windows for the patch tables need either a second SmartConnect cascaded from one master, or the tables folded into an existing window's address range. **Decide this first**; it's the main BD question. The next free window address is **0x8000_D000**.
4. **Snapshots exist** (standard *Snapshots*; `docs/phase14_status_2026-10-08.md` §2–§4). The patch (`source`/`destination`) will be ordinary parameters, so snapshots carry it automatically. Still to decide here: **"recall safe"** for the patch (decision S8 deferred it). The **"config changed, fetch it again"** broadcast was deliberately deferred to this feature: runtime channel counts change the topology, which `set`s can't express. Design it here.
5. **Virtual groups exist** (`vgroup`, standard *Virtual groups*, §6): linking is opt-in per module (`linked: true`), so `source`/`destination` simply don't set it. **Matrix crosspoints never link** (the user's rule: grouped channels stay independently routable).
6. **Channel names are built but not shipped** (`name` on channel zones, §7): they go out with this feature's image. Don't build a separate image for them.
7. **The standard's enums are numbers only**: the pickers need labels. Add an optional `optionLabels` beside `options` (additive), as the plan says.

## How this user works (also in memory)

- **Proposal → decisions → small verified steps.** Write the proposal into a status doc (`docs/phase15_status_<date>.md`, or a new section of the Phase 14 one), list the decisions with a recommendation each, and let the user decide ("as recommended" is common). **For protocol changes: amend `docs/FPGA Mixer OSC Standard.md` first; the user builds the app side from it.** Don't edit the controller repo.
- **Modularity first**: the patch plugs into the front-door/core seam; update `architecture_modules.md` in the same change; status docs as you go.
- RTL: bit-exact against a model at random tables, timing to the cycle; XSim via `scripts/xsim_regress.ps1` (Defender sometimes blocks XSim: a "child exe not found" is a tool failure, so rerun it; never count it as a test verdict). **Mutation-test new tests**, running the unmutated baseline first in the temp copy.
- Build chain: `create_project.tcl` + `build.tcl` (detached; wait for `^RESULT: XSA`), `sdtgen` (Device Guard may block the first run: retry once), then the SDT to the VM, `gen-machine-conf`, and bitbake (the pattern is `~/edf/logs/p11h3-build.sh`). The `fpgamixer-osc` recipe **lists its files explicitly**: add any new Python module there.
- **The user runs every board and Mac command**; short numbered steps, one command per block, and what healthy output looks like. Bench checks are lean: by ear or by eye in the app.
- Edit/Write tools for repo files (heredocs mangle backslashes); verify edits; `git show --stat` after commits; the attribution trailer. `gh` isn't installed and the GitHub connector isn't authorized: push branches and give the user the compare link.

## State of the repo

- Branch **`phase14-vgroups`** (pushed) holds snapshots + groups + names on top of `main`; the user may have merged it. Start a new branch (e.g. `phase15-sources`) from whatever holds it.
- Last images: `build/sd/p14g2-vgroups-20261008.wic.xz` (groups, no names); bitstream `p11h3`.

Start by reading the plan, `architecture_modules.md` §1–§4, the standard, `fpgamixer_top.sv`'s channel map and the BD part of `create_project.tcl`; then write the proposal.
