# Prompt: PS ↔ PL audio link, first use USB audio (Phase 8, pulled ahead of Phase 7)

*Written 2026-09-25 at the end of the Phase 5/6 session, as the opening prompt for a fresh session.*

---

You're continuing the FPGAmixer project: a network/USB/analog digital matrix mixer on a Digilent Genesys ZU-3EG (Zynq UltraScale+ XCZU3EG). Phases 0–6 are done and verified on hardware. Next is the **PS ↔ PL audio link**, whose first user is **USB audio**. It was pulled ahead of Phase 7 (DSP) because the user wants multichannel audio for testing: the Pmod I2S2 bench only has mono cables, so only two left channels can be driven or heard.

## Read first, in this order

1. `docs/architecture_modules.md`: **the rules.** Module kinds (front door / PCM core / control plane / platform), the PCM contract (§2), the coefficient contract (§3), register windows and the address map (§4), the file map (§1.1), and §6 "How upcoming work plugs in", including *why there is no quick USB path*.
2. `docs/FPGAmixer_Architecture_Roadmap.md`: Decision 3 (USB: host mode vs device mode), the Phase 8/9/11 rows, and the **+324 ppm audio-clock** risk item.
3. `docs/phase5_status_2026-09-25.md` and `docs/phase6_status_2026-09-25.md`: current state, how everything was verified, and the bench procedures.
4. Your memory directory (`MEMORY.md` index): user preferences and bench facts.

## How this user works (non-negotiable)

- **Modularity is the overriding design value.** Front doors only convert to and from the PCM contract; the core never sees a foreign clock; the control plane is generic transport plus a small per-block binding. No shortcut that wires a new source straight into the matrix "just for testing". Before adding anything, say which seam it plugs into; if none fits, propose the seam first. Keep `architecture_modules.md` current in the same change.
- **Document as you go:** a `docs/phase8_status_<date>.md` updated as each step lands (what, why, how verified, open items). Record decisions with their reasons.
- **The user runs all board, Pi and VM-console commands themselves.** Give short numbered steps, one command per code block, and say which terminal each goes in (PowerShell / board / Pi / VM). Read the results from the Terminal panel yourself (`read_terminal`) instead of asking for pastes. The terminal panel renders line edits garbled, so don't "correct" what the user typed based on it.
- Commit in logical, separately verified steps on a branch (not `main`), with the attribution trailer. The user opens PRs themselves.

## Bench and tooling facts

- SSH aliases in Windows `~/.ssh/config`: `ssh board` (10.0.0.2 via ProxyJump through the Pi), `ssh pi` (akPi5.local), `ssh edfvm` (build VM, key auth; you can use it non-interactively). The board and the Pi need passwords, so the user runs those.
- The board boots with the OSC server as a service (`fpgamixer-osc`, state in `/var/lib/fpgamixer/`) and `end0` = 10.0.0.2 automatically. After flashing, the board needs a **full power-off**, not a reboot: the DP83867 PHY can otherwise come up with no link. After a reflash, the user must `ssh-keygen -R 10.0.0.2`.
- Build chain: Vivado batch on Windows (`C:\AMDDesignTools\2026.1\Vivado\bin`) → `write_hw_platform -fixed -include_bit` → `sdtgen.bat` (**forward-slash paths**; backslashes are eaten by Tcl) → copy `build/sdt` to the VM `~/edf/sdt` + `dos2unix` → `gen-machine-conf parse-sdt --hw-description ~/edf/sdt -c conf --machine-name genesys-zu3eg` → `bitbake edf-linux-disk-image xilinx-bootbin`. For layer/tools-only changes: `scripts/sync_buildhost.sh`, then bitbake. The VM's layer is `~/edf/2026.1/sources/fpgamixer/yocto/meta-fpgamixer`, synced from the repo, never edited in place.
- Build from the repo checkout: Vivado fails past 248-character paths (a scratch-directory worktree broke the PS IP synthesis).
- Simulation: no Icarus on this Windows host; XSim works (`xvlog -sv -d SIM_ODDR …`, `xelab`, `xsim -R`). `scripts/sim.mk` is the Icarus path, kept in step.
- Tool quirk seen repeatedly: backslash sequences inside Bash-tool heredocs get mangled (`\` + newline became a literal `\n`). Write files with the Write/Edit tools.
- The board has no RTC or NTP: the clock starts at 2025-05-29 every boot.
- Test assets: `tools/osc_mixer_test.py` (expect 18/19 on hardware; the known failure is unframed TCP), `tools/test_mixer_state.py` and `tools/test_mixer_hw.py` (25/25 on Linux), and all RTL TBs (see `sim.mk`).

## The task

**Step 1 is a design proposal, not code.** Write it into `docs/phase8_status_<date>.md` (or an ADR) and get the user's decision on the open questions before building anything. Research the current AMD/Linux facts; don't answer from memory.

Questions the proposal must settle:

1. **USB role.** The roadmap's Decision 3 recommends host mode (a class-compliant interface plugged into the board, `snd-usb-audio`) first. The user's stated goal is to route audio *from their Mac* over USB for testing, which is **device mode**: the board appears as a UAC2 soundcard (`f_uac2` gadget on the DWC3 controller, via the Type-C DRD port). Confirm which one they want. Then check what the device tree and kernel config need: DWC3 `dr_mode`, `CONFIG_USB_CONFIGFS_F_UAC2`, and whether the Genesys ZU Type-C port actually works as a device with the current PS configuration. The Digilent preset enables USB0/USB1.
2. **The PS ↔ PL audio link: architecture options.** Compare at least:
   - (a) AMD's **Audio Formatter** IP (AXI DMA for audio, with the Linux ASoC `xlnx_formatter_pcm` driver) presenting an AXI-Stream audio interface to the PL. This would give the PS a real ALSA card backed by the PL. Check licensing and availability in 2026.1, and the driver's state in the EDF kernel.
   - (b) AXI DMA or AXI-Stream FIFO plus a custom driver or userspace (UIO / u-dma-buf).
   - (c) anything better found in research.
   The PL side must end at the **PCM contract on `mclk`**. The link is a *front door*, and it's shared with Phase 9 AVB, so it must not be USB-specific.
3. **Clock-domain bridging.** The USB host's clock, the board's `mclk` (+324 ppm, 12.2919 MHz) and later the network media clock are all independent. Options: a UAC2 feedback endpoint steered by the elastic-buffer fill level; ALSA-side adaptive resampling (e.g. `alsaloop`); ASRC in the PL. Say where the bridging lives: it belongs inside the front door (§2 rule 1), never in the core.
4. **Channel counts and the core.** The matrix is 4×4 today, with the channel map in `fpgamixer_top`. Adding USB channels changes `N_IN`/`N_OUT` (the matrix supports non-square since D3), the channel map, the OSC matrix indices, and the state seeding (`MatrixBackend.seed_and_push`: diagonal 0 dB, rest off). Propose the new map and how existing saved state migrates.
5. **Control and status plane.** The link needs status (buffer fill, under/overruns, rate). `axil_coef_window` is coefficient-oriented (shadow bank + commit). Decide whether status gets a new generic window type (RO counters) or fits the existing one, and keep the header convention (ID/CONFIG at 0x000/0x004).
6. **Verification plan.** Simulation for the PL side; on hardware, multichannel audio from the Mac through the matrix to the Pmods, **plus the Phase 6 follow-up: repeat the power-cycle restore test with real multichannel audio on every crosspoint.**

Then implement in small, separately verified, committed steps, updating the status doc and `architecture_modules.md` as you go.
