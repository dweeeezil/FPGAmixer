# Claude Code prompt: finish Phase 4 networking and run the gPTP bench spike

**Context for you (Claude Code):** You're on the maintainer's Windows 11 machine in the FPGAmixer repo. As of 2026-09-24 the Genesys ZU-3EG boots Linux from SD to a login prompt. `end0` (GEM0) gets DHCP at 1 Gbps, and `ethtool -T end0` reports hardware TX/RX timestamping with PTP Hardware Clock 0. Read these before touching anything:

- `docs/phase4_status_2026-09-24.md`: **read this first.** What was fixed and how, the current VM `local.conf`, and the follow-up list (§5) this prompt picks up.
- `docs/setup_edf_hyperv_vm.md`: the toolchain spec (§5–§9).
- `docs/FPGAmixer_Architecture_Roadmap.md`: the gPTP risk item and next-steps item 4. That is why this spike exists: Phase 9 (AVB/Milan) depends on it.

## Goal

1. Close the two Phase 4 networking follow-ups that affect timing: **the DP83867 driver is not bound** (the PHY runs as "Generic PHY"), and **the MAC address is random every boot**.
2. Run the **gPTP bench spike**: `ptp4l` on the board's GEM0 against the Raspberry Pi 5 + Intel I350 as a known-good gPTP peer. Measure how good sync is, with the board as slave and as grandmaster, and write it up.

## Ground rules

- **Stop and ask when you start guessing rather than working from established facts.** This is the standing instruction for this project. If a hypothesis needs a source, find the source (AMD/TI/Digilent docs, driver source, the installed tools) or stop. The previous session's breakthroughs came from reading registers and source, not from trying things.
- **Don't re-verify what `phase4_status_2026-09-24.md` records as verified.** DDR geometry, the boot chain, SD, and `ethtool -T` are all done.
- **Long builds run detached in tmux on the VM** (session `edf`), logging to `~/edf/logs/<step>.log`. Never run a multi-minute bitbake in the foreground of an SSH call. The VM is often powered off: `ssh edfvm` to check, and ask the user to start it (Hyper-V Manager, elevated).
- **Fixes go in `yocto/meta-fpgamixer/` in this repo**, then copy to `~/edf/2026.1/sources/meta-fpgamixer` on the VM. Scope device-tree changes to Linux (`:linux` override; see the existing `device-tree.bbappend`). Never edit generated device trees or `~/edf/2026.1/sources/meta-xilinx`.
- **The board is the user's to power-cycle, cable and log into.** The `amd-edf` account has a password the user set; never type or store passwords. If you need shell access, ask the user to run commands and paste the output, or to install an SSH key for you.
- **Only one process can hold a COM port.** Stop `scripts/uart_log.ps1` before the user opens COM4 in their own terminal.
- **Don't commit without showing the diff first.** The user handles branches and PRs.

## Suggested order

### 1. Bind the DP83867 driver

The boot log shows `PHY [ff0b0000.ethernet-ffffffff:0f] driver [Generic PHY]` even though MDIO reads `phy_id 0x2000a231`. First establish why from the built kernel config (is `CONFIG_DP83867_PHY` set, built-in or module, and is the module in the image?), not by assumption. Then look at the generated `gem0` / PHY node in `~/edf/2026.1/build/conf/dts/genesys-zu3eg/cortexa53-linux.dts`: `phy-mode` is `rgmii-id`, but are there `ti,rx-internal-delay`, `ti,tx-internal-delay` or `ti,fifo-depth` properties? Take delay values from a source: Digilent's `Digilent/Genesys-ZU-OS` (branch `3eg/master`) and the board schematic or reference manual. Note that the dtsi fetched from that branch had only an `&sdhci1` node, so the PHY values may live elsewhere or not exist. Don't invent them.

**CHECKPOINT:** report what you found and what you propose (kernel config fragment and/or dtsi change) before building.

### 2. A stable MAC address

`macb ff0b0000.ethernet: invalid hw address, using random`. Find out from the Digilent reference manual/schematic where this board keeps its MAC, if anywhere (an EEPROM with an EUI-48, for example), and how U-Boot or Linux would read it. If there's no on-board MAC, propose a fixed locally administered address in the Linux device tree (`local-mac-address`) and let the user pick it.

**CHECKPOINT:** after a rebuild and reflash, the user confirms the same MAC and link across two boots, with the proper PHY driver bound.

### 3. Bench topology

gPTP (802.1AS) is point-to-point: a normal switch in the path breaks it. Agree the cabling with the user. Board ↔ Pi 5 I350 directly is the simple case. The board is currently cabled to a Mac through a Thunderbolt adapter for DHCP/internet, which is **not** a gPTP peer. Settle how the board gets an IP on the direct link (static addresses on both ends are fine; gPTP itself is layer 2).

### 4. ptp4l spike

- Use linuxptp's gPTP profile on both ends (`configs/gPTP.cfg` in linuxptp; check what the image installs and what the Pi has). Check the linuxptp versions on both sides.
- Run the board as **slave** to the I350, then as **grandmaster**. Record `ptp4l` offset and path delay over a sustained period, and what `phc2sys` does for system time.
- Check that hardware timestamping is really in use (`time_stamping hardware`, no fallback warnings), that the one-step/two-step mode matches the profile, and that `/dev/ptp0` is the PHC `ptp4l` uses.
- Watch for GEM/macb timestamping quirks in `dmesg` and `ptp4l` logs. Tie any explanation to driver source (`drivers/net/ethernet/cadence/macb_ptp.c`), not to forum folklore.

**CHECKPOINT:** a table of results (roles, duration, offset mean/RMS/max, path delay, anything anomalous). **Agree with the user what "good enough for Phase 9" means before calling it a pass**; don't invent a threshold.

### 5. Write-up

Add `docs/gptp_spike_<date>.md` with the method and results. Update the roadmap's gPTP risk item, next-steps items 3–4, and `README.md`'s "Current phase" paragraph, which still says Phase 4 is awaiting its first boot.

## Useful facts

- Console: COM4, 115200 8N1 (`scripts/uart_log.ps1 -TimeoutSec 900` for passive capture). Login `amd-edf`. The interface is `end0`, not `eth0` (systemd predictable naming).
- The image ships `linuxptp` and `ethtool` (`IMAGE_INSTALL:append` in `local.conf`). OpenSSH is running on the board.
- JTAG reads work and don't disturb a running board: `xsdb.bat` with `connect; targets`. PS DDR is now correct, so `dow` is trustworthy again.
- Rebuild chain after any Vivado/PS change: `vivado -mode batch -source <script>` (create_project + impl + `write_hw_platform -fixed -include_bit`) → `sdtgen` → `scp` to `~/edf/sdt` → `dos2unix` → `gen-machine-conf parse-sdt --hw-description ~/edf/sdt -c conf --machine-name genesys-zu3eg` → `bitbake edf-linux-disk-image xilinx-bootbin`. A layer-only change needs just the bitbake step. Flash the `.wic.xz` with Etcher; it already contains `BOOT.BIN`.
- The FSBL is built with `FSBL_DEBUG_INFO` (it narrates on the console). Leave it on unless the user says otherwise.

## Out of scope

The audio media clock (the +324 ppm MMCM and the steerable-clock vs ASRC decision in the roadmap): note anything the spike teaches about it, but don't change the clocking. Also out of scope: Phase 5+ (OSC control, persistence, DSP, USB, AVB streaming), SD UHS tap-delay tuning, SPD-based DDR, and any RTL change to the verified Phase 3.5 datapath.
