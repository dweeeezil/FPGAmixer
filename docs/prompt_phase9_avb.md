# Prompt: network audio / AVB (Phase 9)

*Written 2026-09-26 at the end of the Phase 8 session, as the opening prompt for a fresh session.*

---

You're continuing the FPGAmixer project: a network/USB/analog digital matrix mixer on a Digilent Genesys ZU-3EG (Zynq UltraScale+ XCZU3EG). Phases 0–6 and **Phase 8 (PS↔PL audio link + USB device mode)** are done and verified on hardware. The Mac sees the board as one 8 × 8 USB soundcard, audio runs through a 12 × 12 matrix, and the routing survives a power cut. **Next is Phase 9: AVB network audio, starting with a refactor of the core to time-shared multipliers.** DSP (Phase 7) comes after AVB by the user's choice (their DSP module library plan makes it large).

## Read first, in this order

1. `docs/architecture_modules.md`: **the rules.** Module kinds (front door / PCM core / control plane / platform), the PCM contract (§2), the coefficient contract (§3), register windows and the address map (§4), the file map (§1.1), §6 "How upcoming work plugs in".
2. **`docs/phase9_status_2026-09-26.md`: the Phase 9 design proposal.** Checked facts, the media-clock options, **§5: the time-shared core, which is done first**, proposed steps P9.A1–A6 then P9.0–P9.8, and **the decisions in §8, which you get from the user before building the AVB part.**
3. `docs/phase8_status_2026-09-25.md`: how the link, the ALSA card, the USB bridge and the bench tests were built and verified. Phase 9 reuses all of it. Note the open items at its end.
4. `docs/gptp_spike_2026-09-24.md`: gPTP on this board (the three fixes it needed, the Pi 5 + I350 peer, configs).
5. `docs/FPGAmixer_Architecture_Roadmap.md`: Decisions 1–2 and the +324 ppm audio-clock risk item.
6. Your memory directory (`MEMORY.md` index): user preferences, bench facts, lessons.

## How this user works (non-negotiable)

- **Modularity is the overriding design value.** Front doors only convert to and from the PCM contract; the core never sees a foreign clock; the control plane is generic transport plus a small per-block binding. No shortcut that wires a new source straight into the matrix. Before adding anything, say which seam it plugs into; if none fits, propose the seam first. Keep `architecture_modules.md` current in the same change.
- **Workflow: proposal → decisions → small verified steps.** Each step gets committed on its own, with the status doc (`docs/phase9_status_2026-09-26.md`) updated as it lands: what, why, how verified, open items. Record decisions with their reasons. Report what was *measured*, and say what wasn't.
- **The user runs all board, Pi and Mac commands themselves.** Give short numbered steps, one command per code block, and say which terminal each goes in (PowerShell / board / Pi / Mac). Read results from the Terminal panel yourself (`read_terminal`; the tab IDs change, so list the tabs first). The panel renders line edits garbled; don't "correct" what the user typed from it.
- **Verify every edit before building, committing or claiming it.** Use the Edit/Write tools, not heredoc scripts: the Bash tool mangles backslashes in heredocs, and an edit made that way was once silently lost and then reported as done. Grep for the change, and check `git show --stat` after committing.
- Commit on a branch (not `main`), with the attribution trailer. The user opens PRs themselves. Don't switch the user's checkout; if they're on another branch, ask.

## Bench and tooling facts

- **Audio bench:** Pmod I2S2s on JB/JC with **mono cables: only the left channels can be heard** (core out 0 = JB_L, out 2 = JC_L; never route test audio to JC_R). The Mac (Ableton) is the multichannel source/sink over USB. The repo's scripts are not on the Mac; audio checks there are by ear/spectrogram, or WAVs copied to the PC.
- **Network:** Pi 5 (`ssh pi`, akPi5.local) with an Intel I350; `eth4` ↔ board `end0` at 10.0.0.x. The board comes up as 10.0.0.2 by itself; `ssh board` goes through the Pi. After flashing, the board needs a **full power-off** (the DP83867 otherwise may come up with no link), and the user runs `ssh-keygen -R 10.0.0.2`. The bench image gives `amd-edf` a fixed password (the user knows it) with no forced change.
- **Board services at boot:** `fpgamixer-osc` (OSC server, state in `/var/lib/fpgamixer/`), `fpgamixer-usb-gadget` (UAC2; forces the Type-C chip to UFP; `single_clock`), `fpgamixer-usb-bridge` (gadget ↔ link, steers the Mac to `mclk`). Tools: `/usr/lib/fpgamixer/mixer_hw.py` (`info`, `dump`, `link [s]`), `tools/crosspoint_restore_test.py`, `tools/osc_console.py` (on the Pi).
- **Build chain:** `vivado -mode batch -source scripts/create_project.tcl` (`current_phase = phase8`), then `vivado -mode batch -source scripts/build.tcl -tclargs <tag>` (runs + reports + XSA; the post-route methodology gate must pass). Launch long Vivado runs detached (PowerShell `Start-Process`); tool calls time out at 10 min. Then `sdtgen.bat -xsa <xsa> -dir build/sdt` (**forward slashes**) → copy to the VM `~/edf/sdt` + `dos2unix` → `gen-machine-conf parse-sdt --hw-description ~/edf/sdt -c conf --machine-name genesys-zu3eg` → `bitbake edf-linux-disk-image xilinx-bootbin`, run detached on the VM (`setsid nohup … &`). Layer or tools changes only: `git add` (the sync ships **tracked** files), `scripts/sync_buildhost.sh`, then bitbake. `ssh edfvm` works non-interactively.
- **VM pitfalls:** check the **board** kernel under `tmp/work/genesys_zu3eg-amd-linux/`, not the stale generic `amd_cortexa53_mali_common` tree. `rm_work` deletes compile logs; use `bitbake -c compile -f <recipe>` to read warnings. A carried kernel patch lives in `meta-fpgamixer/recipes-kernel/linux-xlnx/` (the `f_uac2` single-clock patch; re-check it on kernel updates).
- **Simulation:** XSim on Windows (`xvlog -sv`, `xelab`, `xsim -R`, in `build/xsim_*`); `scripts/sim.mk` is the Icarus path, kept in step. Mutation-test new TBs (plant a bug, see them fail).
- Build from the repo checkout (Vivado fails past 248-character paths). The board has no RTC: its clock starts at 2025-05-29 every boot.

## State at hand-off

- Branch `phase8/ps-pl-audio-link` holds all of Phase 8 and is **not yet merged**; `main` has one extra commit (the S4 test WAVs). Start Phase 9 on a new branch from `main` once the user has merged Phase 8; ask if it isn't merged yet.
- **Not yet on hardware:** the USB bridge's coarse queue correction + servo hold (in the source, built with 0 warnings). It goes into the next image; check the bridge log at start-up (direction B used to overshoot to +650 ppm for ~50 s).

## The task

**First, the time-shared core (proposal §5, steps P9.A1–A6), decided by the user on 2026-09-26: "it's better to get it done now".** Today's `pcm_matrix` spends one DSP48E2 per crosspoint for one multiply per 256-cycle frame; AVB's 20 × 20 won't fit, and Phase 7's DSP module library will be built on whatever core interface exists. Stay at `mclk` (no faster core clock: it would have to follow the Phase 9 media-clock steering).

1. **P9.A1: write the core design proposal into the status doc and get the user's decisions**: the time-shared stream contract inside the core (sample format, channel order, framing/valid, back-pressure or not, latency), packed ↔ stream converters at the core boundary, and coefficients in RAM with a bank swap that keeps the coefficient contract ("the whole bank changes on one frame") and the register window unchanged. Research before proposing (DSP48E2 cascade/pipelining, BRAM ports, how the scheduler handles N_IN × N_OUT not divisible by the frame).
2. Implement P9.A2–A6 in small, separately verified, committed steps: bit-exact against the existing matrix TBs and reference model, mutation-tested, Vivado (DSP count, CDC report, methodology gate), then the Phase 8 bench tests (USB ↔ matrix ↔ Pmods; `crosspoint_restore_test.py` with a power pull).

**Then AVB:**

3. **Get the user's decisions on `phase9_status_2026-09-26.md` §8** (media clock, gPTP role, streams/channels, peers, channel map; #4 is already decided). Re-check anything in the proposal you'll depend on; it was written from the build tree, but verify, don't trust.
4. Implement P9.0/P9.1 and P9.3 onward in the same way, updating the status doc and `architecture_modules.md` as you go. The verification items in §9 are resolved inside the step that needs them, and the result is written down.

**Not in this phase, but recorded:** the user wants an OSC alias / parameter-linking feature (`docs/proposal_osc_aliases.md`). Don't build it unless asked; keep it in mind when touching the OSC server or the state format.
