# Prompt: Phase 9, P9.5 onwards (link #2, then AVB streaming)

*Written 2026-09-27 at the end of the session that did P9.A–P9.4, as the opening prompt for a fresh session.*

---

You're continuing the FPGAmixer project: a network/USB/analog digital matrix mixer on a Digilent Genesys ZU-3EG (Zynq UltraScale+ XCZU3EG). Phases 0–6 and 8 are done. **Phase 9 (AVB network audio) is well under way on branch `phase9/time-shared-core`** (not merged; the user opens PRs):

- **P9.A:** the core is time-shared (`mixer_core` = pack→stream → `pcm_matrix` on DSP lanes → stream→pack); 12 × 12 runs on **1 DSP48E2** (was 144); coefficients in RAM (`coef_bank_ram`) swapped at the frame strobe.
- **P9.1:** gPTP runs at boot (`fpgamixer-gptp`: ptp4l + phc2sys on `end0`, role by BMCA, `priority1 250`): follows the Pi at 2–3 ns RMS, takes over as grandmaster when the Pi goes away.
- **P9.3:** a meter measures `mclk` against the 1PPS from the GEM TSU counter (bit 45, inverted).
- **P9.4:** the MMCM runs 25 × 58/118 (+11 ppm nominal) and **`mclk` is locked to gPTP** by stepping the MMCM's fine phase shift from a rate that the Linux loop `fpgamixer-mediaclock` sets once per second. Locked in 5 s, phase ±1 cycle (81 ns) after warm-up, holdover through a reference step with no audible glitch.

**Next is P9.5: a second PS↔PL link and a 20 × 20 core.** It's planned and decided (L1–L5); build it, then continue with P9.6–P9.8.

## Read first, in this order

1. `docs/architecture_modules.md`: **the rules.** Module kinds, the PCM contract (§2) and the **PCM stream contract** inside the core (§2.1), the coefficient contract (§3, now a read port), the **three window types** and the address map (§4.1), the file map (§1.1).
2. **`docs/phase9_status_2026-09-26.md`**: everything done in Phase 9, with measurements and findings, section by section. Key parts: **§6.8 (the P9.5 plan and its decisions)**, §6.3–§6.7 (the meter, the retune, the steering, the loop), §6.1 (gPTP service), §8/§8.1 (AVB decisions), §9 (open verification items), §10 (the log).
3. `docs/phase8_status_2026-09-25.md`: how link #1, the ALSA card, the USB bridge and the bench tests were built. P9.5 repeats that link.
4. `docs/gptp_spike_2026-09-24.md`: gPTP on this board.
5. Your memory directory (`MEMORY.md` index): user preferences, bench facts, lessons.

## How this user works (non-negotiable)

- **Modularity first.** Front doors only convert to/from the PCM contract; the core never sees a foreign clock; the control plane is generic transport plus a small per-block binding. Say which seam a change plugs into; if none fits, propose the seam first. Keep `architecture_modules.md` current in the same change.
- **Proposal → decisions → small verified steps.** Each step committed on its own, with the status doc updated as it lands (what, why, how verified, open items; decisions with reasons). Report what was **measured**, and say what wasn't.
- **The user runs all board, Pi and Mac commands.** Give short numbered steps, one command per code block, and say which terminal each goes in. Read results from the Terminal panel yourself (`list_terminal_tabs` first: the tab IDs change).
- **Verify every edit before building, committing or claiming it.** Use the Edit/Write tools, not heredoc scripts: the Bash tool drops backslash line continuations in heredocs (it happened again this phase, in `sim.mk`). Grep for the change; `git show --stat` after committing. When adding a status-doc log entry, anchor on the **end** of the previous entry: an anchor phrase inside a line once split an entry in two.
- Commit on the branch with the attribution trailer. Don't switch the user's checkout.

## Bench and tooling facts (updated this phase)

- **Audio bench:** Pmod I2S2s on JB/JC with **mono cables: only the left channels are heard** (core out 0 = JB_L, out 2 = JC_L). The Mac (Ableton) plays/records over USB. **Reflashing resets the saved routing** to identity (no USB → Pmod routes): re-route before listening (`mixer_hw.py set 0 4 0`, `set 2 5 0` in the registers, or over OSC to save it).
- **Network:** Pi 5 + Intel I350, `eth4` ↔ board `end0`, 10.0.0.x; `ssh board` goes through the Pi. After flashing: a **full power-off**, then `ssh-keygen -R 10.0.0.2`.
- **gPTP bench recipe:** the Pi is grandmaster: `sudo phc_ctl eth4 freq 0 set adj 37` (**after every Pi reboot**, or the board's `phc2sys` sets the board's clock to 1970), then `sudo ptp4l -f /usr/share/doc/linuxptp/configs/gPTP.cfg -i eth4 -m` in a terminal that **stays open** (closing it kills ptp4l). **Never steer the Pi's PHC with phc2sys:** its PCIe read is bimodal and yanks the grandmaster by ±10 µs. Board: `sudo pmc -u -b 0 -f /etc/fpgamixer/gptp.cfg "GET PORT_DATA_SET"`.
- **Board services:** `fpgamixer-osc`, `fpgamixer-usb-gadget`, `fpgamixer-usb-bridge`, `fpgamixer-ptp4l`, `fpgamixer-phc2sys`, and `fpgamixer-mediaclock`. The last is **installed but not enabled in the current image** (`p94b-steer-20260927`): start it by hand there (`sudo systemctl start fpgamixer-mediaclock`). The recipe is already switched to **enabled**, so the next image starts it at boot. Tools in `/usr/lib/fpgamixer/`: `mixer_hw.py` (`info`, `dump`, `set`, `link [s]`, `mclk [s]`, `steer [ppm]`), `mediaclock.py`; `crosspoint_restore_test.py` must be copied by hand (`scp tools/crosspoint_restore_test.py board:` and `pi:`).
- **Build chain:** `vivado -mode batch -source scripts/create_project.tcl` (**`current_phase = phase9`**) then `vivado -mode batch -source scripts/build.tcl -tclargs <tag>`, launched detached (`Start-Process cmd /c "... && ..."`). **Wait on the final `^RESULT: XSA` line of the build log**: the log also collects the child runs' output, and "Exiting Vivado" there matches too early. Then `sdtgen.bat -xsa build/fpgamixer_<tag>.xsa -dir build/sdt` (move the old `build/sdt` aside first), copy to the VM `~/edf/sdt` (old one aside) + `dos2unix`, `scripts/sync_buildhost.sh`, then on the VM a detached script: `gen-machine-conf parse-sdt --hw-description ~/edf/sdt -c conf --machine-name genesys-zu3eg` + `bitbake edf-linux-disk-image xilinx-bootbin` (the pattern is in `~/edf/logs/p9a6-build.sh`; copy it with `sed s/p9a6/<tag>/`). Check each image: the deployed bitstream MD5, the rootfs contents you changed, the DTB nodes; copy it to `build/sd/<name>.wic.xz`.
- **The build VM (`ssh edfvm`) is sometimes stopped by the user for memory.** If SSH times out, say so and ask; don't poll for ages.
- **Every SDT so far has had `psu_init.tcl/.c` identical to Phase 8's.** Check that each time; a change there means a PS setting moved.
- **Simulation:** `scripts/xsim_regress.ps1` runs **every TB** with XSim, each in a fresh directory (a reused `build/xsim_top` once made xvlog hang): currently **15/15**. `scripts/sim.mk` (Icarus) is kept in step but has **never run on this PC** (no Icarus installed). Mutation-test every new TB (mutated copies compiled from the scratchpad; for Python, `PYTHONDONTWRITEBYTECODE=1` and a fresh directory per mutant, or a cached `.pyc` gives wrong results).
- **Python tests:** `tools/test_mediaclock.py` runs anywhere; `test_mixer_hw.py` / `test_mixer_state.py` need Linux (mmap flags): run them on the VM (`scp tools/*.py edfvm:/tmp/x/`): currently **44/44**.
- **Vivado Clocking Wizard trap:** the MMCM dividers are forced in **override mode**; there, dynamic phase shift only appears if `MMCM_CLKOUT0_USE_FINE_PS` is forced too (`create_project.tcl` checks and stops otherwise). Don't touch `clk_wiz_audio` without keeping that.
- **AMD docs:** docs.amd.com was partly down this phase; a local UG1085 v2.5 is at `%TEMP%\ug1085.pdf` / `.txt`. The built-in browser pane can read docs.amd.com pages when the fetch tool can't.

## State at hand-off

- Branch `phase9/time-shared-core`, last commit the P9.5 decisions + this prompt. The board runs image **`build/sd/p94b-steer-20260927.wic.xz`** (bitstream `p94b`).
- Address map: 0x8000_0000 matrix, 0x8000_1000 link #1 status, 0x8000_2000 media-clock meter (RO), 0x8000_3000 media-clock steering (RW); 0x8010_0000 formatter #1 (driver-owned). P9.5 adds 0x8000_4000 and 0x8011_0000.
- **Open items** (none blocks P9.5): the USB bridge's direction B swings at start-up and its coarse fix spins while the Mac is idle (Phase 8 bridge); `phc2sys` follows a bogus grandmaster time with no plausibility guard; the media-clock loop could wait for steady intervals before acquiring after a step; the Icarus path is unrun; a multi-hop gPTP soak needs a switch (the user suggests the I350 as a software stand-in; the Mac as an AVB peer probably needs AVDECC = Phase 10, unverified).

## The task

1. **Implement P9.5 exactly as planned in the status doc §6.8, with decisions L1–L5 (all "yes"):** link #2 = a second Audio Formatter + `pcm_link` + `pcm_link_stat_regs` (no new RTL); the card driver takes its name from a DT property (default unchanged: `FPGAmixerLink`; link #2 `FPGAmixerLink2`); formatter #2 at 0x8011_0000, link #2 status at 0x8000_4000 (reservations → 0x8000_5000); core **20 × 20** with channel map `{link2, link, jc, jb}` and the new crosspoints seeded as identity; the `phase9` variant grows. Also: the tools at 20 × 20 (restore test 400 levels, simulator default, `mixer_hw` window `linkstat2`), the stale "12.2919 MHz" comment in `system-user.dtsi`. Verify as §6.8 lists: regression, Vivado (2 DSP), SDT (`psu_init` identical), image, bench (two cards, link #2 to the Pmods by ear, link #1/USB unchanged, the loop still locked, restore test at 400 across a power pull).
2. **Then P9.6** (status doc §6 table and §9): kernel fragment for `NET_SCH_CBS/ETF/TAPRIO`, alsa-plugins `aaf` + libavtp, mqprio/CBS on GEM0 (class A), static stream IDs/MACs; re-check the §9 items it depends on (the AAF plugin's timing model and whether it needs `CLOCK_REALTIME` on the PHC, as `phc2sys` provides; the Pi's CBS/ETF and whether Debian ships the AAF plugin). Propose first, get decisions, then build.
3. P9.7 (the AVB bridge: AAF ALSA devices ↔ link #2) and P9.8 (soak) after that, same way.

**Not in this phase, but recorded:** the OSC alias / parameter-linking feature (`docs/proposal_osc_aliases.md`); keep it in mind when touching the OSC server or the state format.
