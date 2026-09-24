# Claude Code prompt: get the Genesys ZU-3EG to boot Linux from SD

**Context for you (Claude Code):** You're on the maintainer's Windows 11 machine in the FPGAmixer repo. Phase 4 is built — PS block design, XSA, system device tree, machine config, EDF/Yocto image, flashed SD card — but the board stays silent and the APU never leaves reset. Read these before touching anything:

- `docs/handoff_2026-09-24_phase4_sd_boot.md` — **read this first.** What's verified good, what's ruled out, the evidence, and the environment. Don't re-derive what's already in it.
- `docs/phase4_status_2026-09-22.md` — what was built and how.
- `docs/setup_edf_hyperv_vm.md` — the toolchain spec (§5–§9 matter here).

## Goal

Find out why FSBL doesn't run, fix it, and get to the **Phase 4 exit criteria**: a login prompt on the UART console with `eth0` up. Then run `ethtool -T eth0` and confirm hardware timestamping, which is the Phase 9 (AVB/gPTP) prerequisite the board was chosen for.

## Ground rules

- **Stop and ask when you start guessing rather than working from established facts.** This is the standing instruction for this project, and the previous session burned a lot of time ignoring it. If a hypothesis needs a source, find the source (AMD docs, driver source, the installed tools) or stop.
- **Don't re-verify section 2 of the handoff.** The card, partition table, `BOOT.BIN` structure, boot header checksum, boot mode and `BOOT.SCR` are all confirmed good. Re-checking them wastes a cycle.
- **`xsdb`'s `dow` is broken on this machine** (handoff §5). Bulk transfers land at the wrong address. Don't build anything that depends on it, and don't trust a test that uses repeating synthetic data.
- **Long builds run detached in tmux on the VM**, logging to `~/edf/logs/<step>.log`. Never run a multi-minute bitbake in the foreground of an SSH call.
- **The VM is often powered off.** `ssh edfvm` to check. Starting it needs Hyper-V Manager and an elevated shell, so ask the user.
- **The board's boot mode latches only at power-on.** After any jumper move, the user must power-cycle. Ask them; you can't do it.
- **Don't commit without showing the diff first.**

## Suggested order

### 1. Make FSBL talk

It's currently built silent, so we're blind. Find the EDF/meta-xilinx knob for FSBL debug output and rebuild `xilinx-bootbin` with it. Then reflash and capture the console.

**CHECKPOINT:** report what FSBL prints, or that it prints nothing at all — both are informative.

### 2. Bisect BOOT.BIN

Build it without the PL bitstream (drop `bitstream` from `BIF_PARTITION_ATTR`). The bitstream is a 5.5 MB partition and a plausible early-hang cause. If the board boots without it, that localises the fault.

**CHECKPOINT:** report whether it boots, and what changed in the partition headers.

### 3. Known-good reference, if still stuck

Digilent publish a Genesys ZU demo image. Booting theirs proves the board, card and reader are fine, and their FSBL/U-Boot could load *our* kernel to unblock Phase 4 while ours gets fixed. Ask the user before downloading anything.

### 4. Once it boots

- Confirm the login prompt and that `eth0` gets an address. That's Phase 4 done.
- `ethtool -T eth0` — expect `hardware-transmit`, `hardware-receive`, `hardware-raw-clock` and a PTP hardware clock index. If it reports software-only, dig in: the device tree was verified to carry `gem0` with `tsu_clk` at 250 MHz.
- Then `ptp4l` against the Pi 5 + I350 as a known-good gPTP peer.
- Watch for the two predicted board snags (spec §9): the DP83867 RGMII delay properties and SD `no-1-8-v`/`disable-wp`. Fixes belong in a `meta-fpgamixer` layer, not in the generated device tree.

## Useful facts

- UART capture: `powershell -ExecutionPolicy Bypass -File scripts\uart_log.ps1 -TimeoutSec 900`. Passive by default; `-WaitFor`/`-Send` types a line when a pattern appears. The console is the FTDI port that talks (COM4 here). **Only one process can hold a COM port** — kill stale watchers first.
- Reading board state over JTAG works and doesn't disturb a running board: `xsdb.bat` with `connect; targets`, and `mrd 0xFF5E0200` for the boot mode (`0x0` JTAG, `0xE` SD1-LS).
- `scripts/jtag_boot.tcl` holds a working PS bring-up sequence (security gates, PMU firmware, `psu_init` for DDR, bootloop, halt ordering). It's useful for probing even though the payload transfer is broken.
- Rebuild the project with `vivado -source scripts/create_project.tcl` (`current_phase "phase4"`).
- Staged artifacts live under `build/` (gitignored): `build/sd/` flashable image, `build/jtag/` boot components, `build/sdt/` device tree, `build/fpgamixer_phase4.xsa`.

## Out of scope

Phases 5+ (OSC control, persistence, DSP, USB, AVB streaming), the `meta-fpgamixer` layer beyond device-tree fixes needed to boot, and any RTL change to the verified Phase 3.5 datapath.

## Uncommitted work to be aware of

The branch `docs/phase3.5-verified` carries RTL, script and doc changes from the previous sessions (the PS instance in `phase3_top`, `create_project.tcl` phase4 mode, the JTAG scripts, and the Phase 3.5/4 docs). Check `git status` early and agree with the user on branch naming before committing.
