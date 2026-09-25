# Phase 4 status: 2026-09-24 — boots from SD, exit criteria met

The Genesys ZU-3EG boots Linux from SD to a login prompt, with `end0` (the GEM0 interface) routable and hardware timestamping available. This supersedes `handoff_2026-09-24_phase4_sd_boot.md`, whose diagnosis was wrong at several points (see §4).

## 1. Result

| Check | Result |
|---|---|
| FSBL → PMUFW → **PL bitstream** → ATF → U-Boot → Linux 6.18.10 | all load from SD; FSBL logs "PL Configuration done successfully" |
| Login prompt on `ttyPS0` | `amd-edf login:` (EDF user `amd-edf`, empty password that must be changed at first login) |
| `eth0` (renamed `end0` by systemd) | routable, DHCP `192.168.2.7` from a Mac with internet sharing, 1 Gbps full duplex |
| `ethtool -T end0` | `hardware-transmit`, `hardware-receive`, `hardware-raw-clock`, **PTP Hardware Clock: 0**, TX modes `off/on/onestep-sync`, RX filters `none/all` |
| PHY | MDIO reads `phy_id 0x2000a231` (TI DP83867) at address 0xf |

## 2. Root causes, in the order they bit

Each fix exposed the next fault. All four were needed.

### 2.1 Dynamic DDR config: FSBL fails in stage 1, looking like a ROM failure

Digilent's preset sets `PSU_DYNAMIC_DDR_CONFIG_EN = 1`. That defines `XPAR_DYNAMIC_DDR_ENABLED`, so `psu_init()` skips the static DDR init and FSBL calls `XFsbl_DdrInit()`, which reads the SODIMM's SPD. `XFsbl_IicReadSpdEeprom()` (embeddedsw `xfsbl_ddr_init.c`) is written for the ZCU102/106: it first selects channel `0x08` on a TCA9548 mux at I2C address `0x75`. The Genesys ZU wires the SPD **directly** to I2C1 on MIO 8/9 (reference manual §3.1), with no mux, so the read fails.

FSBL then returns `XFSBL_FAILURE` from stage 1, and in SD boot mode `XFsbl_ErrorLockDown()` calls `XFsbl_FallBack()`: multiboot + 1 and a soft reset. The ROM then searches `BOOT0001.BIN`…`BOOT8191.BIN`, finds none, and logs `CSU_BR_ERROR = 0x4B` with the APU back in reset. From outside, it looks exactly like "the ROM never started FSBL".

How to tell the difference: read these over JTAG, which doesn't disturb the board:

| Register | Silent-boot value | Meaning |
|---|---|---|
| `PMU_GLOBAL.CSU_BR_ERROR` `0xFFD80528` | `0x80004B00` | ROM error `0x4B` |
| `CSU_MULTI_BOOT` `0xFFCA0010` | `0x1FFF` | every multiboot slot tried |
| `PMU_GLOBAL.PERS_GLOB_GEN_STORAGE4` `0xFFD80060` | `0x3FFFFFFF` | **FSBL's** error register: `XFSBL_FAILURE` + stage-1 offset `0x0`. An FSBL code, not an unwritten default. |
| `CRL_APB.RESET_REASON` `0xFF5E0220` | `0x21` | bit 5 = **SOFT** reset after POR, i.e. FSBL's fallback |

A branch-to-self `BOOT.BIN` (bootgen, `b .` at `0xFFFC0000`) booted cleanly (`CSU_BR_ERROR = 0`, PC at `0xFFFC0000`). That separated the ROM/SD path from the FSBL payload.

**Fix:** `CONFIG.PSU_DYNAMIC_DDR_CONFIG_EN {0}` in `scripts/create_project.tcl`.

### 2.2 Wrong SODIMM geometry: DDR address bit 14 aliases

With static DDR init, FSBL got through stage 1 and failed on the bitstream (`0x4037` = stage 3 + `XFSBL_ERROR_BITSTREAM_LOAD_FAIL`: PL_DONE never set). FSBL stages the bitstream in DDR at `0x100000` and DMAs it to PCAP from there. The same `.bit` programmed fine over JTAG (DONE = 1, EOS = 1, no IDCODE or CRC error).

An address-bit test over JTAG (`mwr`/`mrd`, one write to `base`, one to `base ^ (1<<b)`, read back `base`) showed **`0x30000000` and `0x30004000` alias**, and no other bit does. The preset describes **x8** devices (4 Gb, 2 bank-group bits). In the resulting address map `ADDRMAP8.BG_B1 = 0x8` + internal base 3 = HIF bit 11 = **byte-address bit 14**. The fitted module is a **Kingston CBD26D4S9S1KC-4** (4 GB, 1Rx16, four 512M x16 = 8 Gb devices), and x16 DDR4 has only one bank-group pin. BG1 drives nothing, so every bulk write into DDR folded onto itself in 16 KB steps.

**Fix:** `DRAM_WIDTH 16 Bits`, `DEVICE_CAPACITY 8192 MBits`, `BG_ADDR_COUNT 1`, `ROW_ADDR_COUNT 16`. Vivado does not re-derive the counts, but flags them (PSU-2, PSU-3), so all four are set explicitly. Verified before building: 0 aliasing failures across bits 2–30 in both `0x0…` and `0x8_0000_0000…`, and a 33 MB kernel `Image` via `dow` matches the file at every sampled offset.

**The SODIMM is user-replaceable.** A different module needs different values, or a working SPD path (see §5).

### 2.3 SD card read-only in Linux

`mmcblk0: ... (ro)`. The generated node has `xlnx,has-wp = <0>` but no generic `disable-wp`, so the MMC core trusted the controller's WP bit. The FAT mounts `/efi` and `/storage` failed, and systemd went to emergency mode (root is locked there, so no shell).

**Fix:** `disable-wp` in `yocto/meta-fpgamixer/.../system-user.dtsi`.

### 2.4 Writes time out in UHS-I SDR104

Next boot: `mmc0: new UHS-I speed SDR104 SDHC card`, reads fine, then `mmc0: error -110 writing Cache Flush bit` and write I/O errors. The root filesystem was remounted read-only and emergency mode again.

**Fix (for now):** `no-1-8-v`, which keeps the card at 3.3 V high speed (`mmc0: new high speed SDHC card`). Writes are clean.

Digilent's own PetaLinux dtsi (`Digilent/Genesys-ZU-OS`, branch `3eg/master`) keeps UHS and sets `xlnx,itap-delay-*` values instead, with the comment that SDR104 tuning "fails on some cards if not set". The current `sdhci-of-arasan` driver reads only the generic `clk-phase-*` properties (in degrees), so those tap values would need converting before they could be used.

## 3. Changes

| Where | What |
|---|---|
| `scripts/create_project.tcl` | dynamic DDR off; x16 / 8 Gb / BG 1 / row 16; logs the geometry |
| `yocto/meta-fpgamixer/` (new) | layer.conf (`scarthgap`), `device-tree.bbappend` (`EXTRA_DT_INCLUDE_FILES:append:linux`), `system-user.dtsi` (`&sdhci1 { disable-wp; no-1-8-v; }`) |
| VM `conf/bblayers.conf` | `bitbake-layers add-layer ../sources/meta-fpgamixer` (copied from the repo; `dos2unix` after copying) |
| VM `conf/local.conf` | see below |

`device-tree` is also built in the FSBL and PMU multiconfigs, so the `:linux` override matters: `bitbake -e device-tree` shows `EXTRA_DT_INCLUDE_FILES=" system-user.dtsi"`, while `mc:genesys-zu3eg-cortexa53-fsbl:device-tree` shows it empty.

`local.conf` additions now (backups: `.pre-fsbldebug`, `.pre-edf-default-layout`, and earlier ones):

```
MACHINE = "genesys-zu3eg"
SKIP_META_SECURITY_SANITY_CHECK = "1"
IMAGE_INSTALL:append = " linuxptp linuxptp-configs ethtool"   # -configs added for the gPTP spike (gPTP.cfg)
IMAGE_FSTYPES:pn-core-image-minimal = "cpio.gz"
IMAGE_FEATURES:append:pn-core-image-minimal = " debug-tweaks"
INITRAMFS_MAXSIZE = "524288"
CFLAGS:append:pn-fsbl-firmware = " -DFSBL_DEBUG_INFO"   # FSBL narrates on ttyPS0; kept on for now
MACHINE_FEATURES:remove = "efi"                         # EDF msdos layout: edf-disk-single-rootfs.wks
```

(plus the thread/`rm_work` settings from the build-host setup).

**The `WKS_FILE = "xilinx-default-sd.wks"` line was removed because it never had any effect.** `image_types_wic.bbclass` searches `WKS_FILES`, which `edf-disk-image.inc` sets. With `efi` removed EDF uses `edf-disk-single-rootfs.wks`: msdos, `esp` 1 G vfat (BOOT.BIN, boot.scr, kernel), `storage` 2 G vfat, ext4 root. The rootfs mounts `/efi` and `/storage` by label, so the other layouts don't fit it.

## 4. Corrections to the earlier handoff

- **"`xsdb`'s `dow` is broken"** was wrong. The 16 KB signature (`0x30000000` receiving the `0x30004000` file's data) was the DDR bit-14 aliasing in §2.2. `dow` is fine with the corrected DDR config. The earlier `mwr` checks never wrote two addresses 16 KB apart, so they could not catch it.
- **The JTAG "FSBL doesn't run" evidence** was taken with that same aliased DDR, and doesn't hold.
- **"The ROM never starts FSBL / APU never leaves reset"**: FSBL ran and fell back each time (§2.1).
- **The card layout** (EFI vs msdos) was never the cause.

## 5. Follow-ups (not blocking Phase 4)

1. ~~**DP83867 driver not bound.**~~ Fixed 2026-09-24. The generated DT had no PHY node, so `dp83867_of_init()` returned `-ENODEV`. There's now a PHY node with Digilent's delays (`gptp_spike_2026-09-24.md` §2.1).
2. ~~**No MAC address.**~~ Fixed 2026-09-24. The factory MAC is at QSPI `0x1FFF000`; `local-mac-address` hard-codes this board's copy (§2.2 there). Reading it from flash in Linux is still open.
3. **SD at 3.3 V HS.** Enough for boot and config. If UHS is ever wanted, convert Digilent's tap delays to `clk-phase-*`.
4. **SPD-based DDR** would make the design follow SODIMM swaps. It needs FSBL's SPD reader patched for a mux-less bus. Only worth it if modules get swapped.
5. ~~**`ptp4l` against the Pi 5 + I350.**~~ Done 2026-09-24, PASS, after an FPGA fix to the GEM TSU increment control (`gptp_spike_2026-09-24.md`).
6. Remove `FSBL_DEBUG_INFO` once the boot path has been stable for a while.
7. U-Boot prints "No ethernet found" and a generic "Xilinx ZynqMP" model. That's harmless for SD boot; revisit if network boot is ever wanted.
