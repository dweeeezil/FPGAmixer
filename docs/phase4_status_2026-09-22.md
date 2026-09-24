# Phase 4 status: 2026-09-22

Everything from the Vivado PS block design through to a bootable EDF/Yocto image builds clean. What remains is hardware: write the SD card, boot it, confirm a UART login with `eth0` up, and check `ethtool -T eth0`.

Specs: `setup_edf_hyperv_vm.md` (toolchain), `buildhost_status_2026-09-21.md` (build VM).

## The pipeline, as run

| Step | Result |
|---|---|
| Board files | `digilentinc.com:xilinx_board_store:gzu_3eg` **1.1** (board rev D.0) installed from XHub. `get_board_parts` stays empty until `board.repoPaths` points at the store's `boards/` dir — `create_project.tcl` now sets it. |
| PS block design | One cell (`zynq_ultra_ps_e` 3.5) with Apply Board Preset, plus GEM0 TSU. Scripted in `scripts/create_project.tcl` (`current_phase "phase4"`). |
| Build | Synthesis + implementation + bitstream, **0 critical warnings**. WNS **+2.591 ns**, WHS +0.034 ns (Phase 3.5 was +2.421 / +0.034, so the PS costs the audio path nothing). Methodology: the same 6 × TIMING-18 and 1 × CLKC-56 advisories as before. |
| XSA | `build/fpgamixer_phase4.xsa`, 750 KB, via `write_hw_platform -fixed -include_bit`. Contains the bitstream, `psu_init.*`, and `ps_sys.hwh`. |
| `sdtgen` | `C:\AMDDesignTools\2026.1\Vivado\bin\sdtgen.bat` → `build/sdt/` (13 files). Writes **CRLF**, so `dos2unix` on `*.dts*` before use. |
| `gen-machine-conf parse-sdt` | → `conf/machine/genesys-zu3eg.conf`, `SERIAL_CONSOLES ?= "115200;ttyPS0"`. |
| `bitbake edf-linux-disk-image xilinx-bootbin` | **15,526 tasks, all succeeded, 13 min.** 71% sstate match, 86% already current. |

## PS configuration (from Digilent's preset unless noted)

| | |
|---|---|
| DDR4 | 64-bit, DDR4-1866L, CL12, 930 MHz |
| UART0 | MIO 18–19 → `ttyPS0` at 115200 |
| SD1 | MIO 39–51, card detect enabled |
| USB0 / USB1 | both enabled (MIO 52–63, 64–75) |
| Ethernet | **ENET0 / GEM0**, MIO 26–37, MDIO on MIO 76–77 |
| **GEM0 TSU** | **enabled by us** — IOPLL / 250 MHz, divisors 6/1 |
| AXI | `M_AXI_HPM0_LPD` + `S_AXI_HPC0_FPD` enabled, clocked from `pl_clk0` (100 MHz), unused until Phase 5 |

## The TSU chain, verified at every step

The board was chosen for hardware PTP, so each link was checked rather than assumed:

1. **Vivado:** `PSU__ENET0__TSU__ENABLE = 1`, `GEM_TSU_REF_CTRL = IOPLL / 250.000000 MHz`.
2. **XSA:** the same values inside `ps_sys.hwh`.
3. **SDT:** `pcw.dtsi` → `&gem0 { xlnx,enet-tsu-clk-freq-hz = <250000000>; status = "okay"; phy-mode = "rgmii-id"; }`.
4. **Device tree clocks:** `gem0`'s clocks include `GEM_TSU`, named `tsu_clk` — the exact name `gem_get_tsu_rate()` looks up.
5. **Deployed dtb:** `cortexa53-linux.dtb` has `gem0` `status = "okay"` with `tsu_clk` in `clock-names`.

**Why this mattered:** the preset ships with the TSU off. `macb_main.c: gem_get_tsu_rate()` silently falls back to `pclk`'s rate when `tsu_clk` is absent, and `macb_ptp.c: gem_ptp_init_timer()` derives the PTP timer increment from it. The failure mode would have been a PTP clock running at the wrong rate — `ptp4l` never converging, with nothing on the Linux side pointing at the cause. 250 MHz divides 1e9 exactly: a 4 ns increment, no sub-ns remainder.

## Decisions worth remembering

- **The PS is instantiated inside `phase3_top`**, under `` `ifdef INCLUDE_PS ``, not in a wrapper above it. A `phase4_top` wrapper was tried and reverted: `constraints/phase3_genesys_zu.xdc` names ODDR instances by absolute path (`u_fwd_*/u_oddr/C`), so the extra hierarchy level dropped 25 constraints — reported only as XDC critical warnings — and implementation then failed with "IO Clock Placer failed". The define keeps Phase 1–3 projects and the Icarus sim free of any reference to the BD wrapper.
- **The BD wrapper has no ports.** On ZynqMP the PS's DDR and MIO never reach the fabric, unlike Zynq-7000's FIXED_IO, so there is nothing to wire and no constraints to add.
- **`edf-linux-disk-image` warns that it "is not supported on genesys-zu3eg".** Advisory only, from `amd-edf-check-image.bbclass`, whose comment says it warns when building an image "intended for a 'common' build". Any custom board machine trips it.
- **`linuxptp` and `ethtool` are in the image** (`IMAGE_INSTALL:append`), so the Phase 9 prerequisite can be checked on the first boot.

## Build outputs

`~/edf/2026.1/build/tmp/deploy/images/genesys-zu3eg/`

| File | Size |
|---|---|
| `BOOT-genesys-zu3eg.bin` (FSBL + PMUFW + ATF + U-Boot + bitstream) | 7.3 MB |
| `edf-linux-disk-image-genesys-zu3eg.rootfs.wic` | 4.3 GB |
| `devicetree/cortexa53-linux.dtb` | — |
| `boot.scr`, `download-genesys-zu3eg.bit` | — |

## Next

1. Write the `.wic` to the SD card, then copy `BOOT-genesys-zu3eg.bin` onto the FAT boot partition **as `BOOT.BIN`** — the ZynqMP `.wic` does not contain it.
2. Boot mode switch to SD, UART at 115200 8N1. **Phase 4 exit:** login prompt, `eth0` up.
3. `ethtool -T eth0` — expect `hardware-transmit`, `hardware-receive`, `hardware-raw-clock` and a PTP clock index.
4. `ptp4l` against the Pi 5 + I350 as a known-good gPTP peer.
5. Watch for the board snags in `setup_edf_hyperv_vm.md` §9: the DP83867 RGMII delay properties and SD `no-1-8-v`/`disable-wp`. Fixes belong in a `meta-fpgamixer` layer, not in the generated device tree.
