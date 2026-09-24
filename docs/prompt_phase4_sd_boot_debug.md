# Claude Code prompt: get the Genesys ZU-3EG to boot Linux from SD

**Context for you (Claude Code):** You're on the maintainer's Windows 11 machine in the FPGAmixer repo. Phase 4 is built — PS block design, XSA, system device tree, machine config, EDF/Yocto image, flashed SD card. FSBL boots from SD and **fails loading the PL bitstream** (`XFSBL_ERROR_BITSTREAM_LOAD_FAIL`, partition 4, error `0x37`), so ATF and U-Boot never run. Read these before touching anything:

- `docs/handoff_2026-09-24_phase4_sd_boot.md` — **read this first.** What's verified good, what's ruled out, the evidence, and the environment. Don't re-derive what's already in it.
- `docs/logs/fsbl-bitstream-fail_2026-09-24.log` — the captured console output of the failure.
- `docs/phase4_status_2026-09-22.md` — what was built and how.
- `docs/setup_edf_hyperv_vm.md` — the toolchain spec (§5–§9 matter here).

## Goal

Get past the bitstream failure and reach the **Phase 4 exit criteria**: a login prompt on the UART console with `eth0` up. Then run `ethtool -T eth0` and confirm hardware timestamping, which is the Phase 9 (AVB/gPTP) prerequisite the board was chosen for.

## Ground rules

- **Stop and ask when you start guessing rather than working from established facts.** This is the standing instruction for this project, and the previous session burned a lot of time ignoring it. If a hypothesis needs a source, find the source (AMD docs, driver source, the installed tools) or stop.
- **Don't re-verify section 2 of the handoff.** The card, partition table, `BOOT.BIN` structure, boot header checksum, boot mode and `BOOT.SCR` are all confirmed good. Re-checking them wastes a cycle.
- **`xsdb`'s `dow` is broken on this machine** (handoff §5). Bulk transfers land at the wrong address. Don't build anything that depends on it, and don't trust a test that uses repeating synthetic data.
- **Long builds run detached in tmux on the VM**, logging to `~/edf/logs/<step>.log`. Never run a multi-minute bitbake in the foreground of an SSH call.
- **The VM is often powered off.** `ssh edfvm` to check. Starting it needs Hyper-V Manager and an elevated shell, so ask the user.
- **The board's boot mode latches only at power-on.** After any jumper move, the user must power-cycle. Ask them; you can't do it.
- **Don't commit without showing the diff first.**

## Suggested order

### 1. Get past the bitstream failure

Rebuild `BOOT.BIN` without the PL partition: drop `bitstream` from `BIF_PARTITION_ATTR`
(currently `fsbl pmufw bitstream arm-trusted-firmware device-tree u-boot-xlnx
bootbin-version-header`). FSBL should then continue to ATF and U-Boot. Reflash and capture
the console. The PL can be loaded from Linux later via fpga_manager, which is where Phase 5
wants it anyway.

**CHECKPOINT:** report how far the boot gets, with the console log.

### 2. Reach the Phase 4 exit criteria

- Login prompt on the console, and `eth0` up with an address.
- `ethtool -T eth0` — expect `hardware-transmit`, `hardware-receive`, `hardware-raw-clock`
  and a PTP hardware clock index. If it reports software-only, dig in: the device tree was
  verified to carry `gem0` with `tsu_clk` at 250 MHz.
- `ptp4l` against the Pi 5 + I350 as a known-good gPTP peer.
- Watch for the two predicted board snags (spec §9): DP83867 RGMII delay properties, and SD
  `no-1-8-v`/`disable-wp`. Fixes belong in a `meta-fpgamixer` layer, not the generated DT.

**CHECKPOINT:** report boot success and the `ethtool -T` output.

### 3. Then fix the bitstream path properly

`0x37` is raised *after* "DMA transfer done" — the data moved, the PL did not come up. Note
the same bitstream programs fine over JTAG (Phase 3.5 was verified that way), so the design
is good and the fault is in the FSBL/bootgen path. Check from sources, not guesswork: which
bitstream file bootgen was handed, the partition attributes (`0x26`) against what FSBL
expects for a PL partition, and whether PS-PL isolation or PL power needs anything the board
preset did not configure.

### 4. Secondary, unexplained

For most of the previous session the board produced no console output at all after a
power-cycle, with the APU reading `APU Reset` over JTAG; FSBL output only appeared later,
after an `xsdb` probe. Don't assume a power-cycle alone always starts FSBL. If you see
silence, that is this open question rather than a new bug.

## Useful facts

- UART capture: `powershell -ExecutionPolicy Bypass -File scripts\uart_log.ps1 -TimeoutSec 900`. Passive by default; `-WaitFor`/`-Send` types a line when a pattern appears. The console is the FTDI port that talks (COM4 here). **Only one process can hold a COM port** — kill stale watchers first.
- Reading board state over JTAG works and doesn't disturb a running board: `xsdb.bat` with `connect; targets`, and `mrd 0xFF5E0200` for the boot mode (`0x0` JTAG, `0xE` SD1-LS).
- `scripts/jtag_boot.tcl` holds a working PS bring-up sequence (security gates, PMU firmware, `psu_init` for DDR, bootloop, halt ordering). It's useful for probing even though the payload transfer is broken.
- Rebuild the project with `vivado -source scripts/create_project.tcl` (`current_phase "phase4"`).
- Staged artifacts live under `build/` (gitignored): `build/sd/` flashable image, `build/jtag/` boot components, `build/sdt/` device tree, `build/fpgamixer_phase4.xsa`.

## Out of scope

Phases 5+ (OSC control, persistence, DSP, USB, AVB streaming), the `meta-fpgamixer` layer beyond device-tree fixes needed to boot, and any RTL change to the verified Phase 3.5 datapath.

## Repo state

All of the above is committed on the branch `docs/phase3.5-verified` (unpushed as of
2026-09-24). The branch name predates the Phase 4 work it now carries — agree a better name
with the user before pushing.
