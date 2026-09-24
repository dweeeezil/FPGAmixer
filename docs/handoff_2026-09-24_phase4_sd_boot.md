# Handoff: Phase 4 — the board does not boot from SD

**Date:** 2026-09-24
**Status:** everything up to and including a flashed SD card is **done and verified**. The board stays silent and the APU never leaves reset. Prime suspect is **our FSBL**, not the card.
**Read with:** `phase4_status_2026-09-22.md` (what was built), `setup_edf_hyperv_vm.md` (the toolchain spec).

---

## 1. Where the project is

Phase 3.5 (static matrix in silicon) is hardware-verified. Phase 4 is built end to end:

| Step | State |
|---|---|
| PS block design (board preset + GEM0 TSU) | done, scripted in `scripts/create_project.tcl` (`current_phase "phase4"`) |
| Bitstream | builds clean, WNS +2.591 ns, 0 critical warnings |
| XSA → `sdtgen` → SDT | done, TSU verified through to the device tree |
| `gen-machine-conf` → `genesys-zu3eg.conf` | done |
| `bitbake edf-linux-disk-image xilinx-bootbin` | done, 13 min |
| SD card flashed | done, verified byte-level |
| **Board boots** | **NO — this is the blocker** |

---

## 2. The blocker

Power on with the mode jumper on SD and the flashed card inserted:

- **Nothing on the UART console.** Not one byte, on either FTDI channel.
- **The APU never leaves reset.** Over JTAG all four A53s read `APU Reset`, steady across repeated samples (not a reset loop). The ROM is not starting FSBL.
- `BOOT_MODE_USER (0xFF5E0200) = 0xE` — SD1 level-shifted, which is the same mode in which Digilent's **pre-installed demo image booted fine on this board, in this slot, from this card**. So the hardware path works.

### Verified good — do not re-derive these

| Layer | Evidence |
|---|---|
| Card write | Etcher verified; layout matches the source `.wic` |
| Partition table | `msdos`; entry 1 type `0x0C` (FAT32 LBA), boot flag `0x80`, start LBA 8 |
| `BOOT.BIN` on FAT | real 8.3 short name `BOOT.BIN` (checked by parsing FAT directory entries, not just `ls`), 7,626,980 bytes, in the root |
| Boot header | `0x20 = AA995566`, `0x24 = XLNX`, FSBL exec address `0xFFFC0000` |
| Header checksum | computed `~sum(0x20..0x44)` **equals** the stored value — valid |
| `BOOT.BIN` partitions | FSBL → **A53-0** `0xFFFC0000`; PMU firmware → `0xFFDC0050`; PL bitstream (5.5 MB); ATF → `0xFFFEA000`; device tree; U-Boot. All present, sane addresses. |
| `BOOT.SCR` | loads `/boot/Image` from partition 3 via `ext4load`, boots with U-Boot's control FDT |
| Rootfs | `/boot/Image` exists in the rootfs tarball |
| Boot mode | `0xE`, confirmed live over JTAG |

### Ruled out by test

- **Card layout.** First build used the EFI/`gpt-hybrid` layout (systemd-boot). Rebuilt with the classic `msdos` layout; **same silence**. Both were flashed and verified.
- **`PMUFW len = 0` in the boot header.** Red herring — `BIF_PARTITION_ATTR` includes `pmufw`, which is a separate partition rather than appended to FSBL.
- **Missing `BOOT.BIN`.** The `.wic` already contains it; the spec's "copy BOOT.BIN by hand" step is **wrong for EDF 26.06.1**.
- **Reset loop.** APU state is steady.
- **UART capture.** `scripts/uart_log.ps1` demonstrably captured Digilent's demo boot earlier on COM4.

### The strongest lead

**Our FSBL does not run.** Two independent paths agree:

1. **SD boot:** ROM never brings the APU out of reset.
2. **JTAG:** loading `fsbl-genesys-zu3eg.elf` onto A53-0 and running it left DDR uninitialised (`"Blocked address 0x18000000. DDR controller is not initialized"`), with the PC stuck at `0xFFFC0C70` — just past the C-runtime stubs (`frame_dummy`), i.e. very early startup. By contrast `psu_init.tcl` from the SDT brings DDR up every time.

FSBL is built silently (no debug prints), so there is no direct evidence of how far it gets.

---

## 3. Next steps, in priority order

1. **Rebuild FSBL with debug prints.** Highest information per minute — currently we are blind. Look for the EDF/meta-xilinx knob for FSBL debug (`XFSBL_DEBUG_INFO` / `FSBL_DEBUG` style config) and get FSBL to narrate over `ttyPS0`.
2. **Build `BOOT.BIN` without the PL bitstream.** Drop `bitstream` from `BIF_PARTITION_ATTR`. Bitstream loading is a plausible early hang; if it boots without, that localises the fault.
3. **Boot a known-good reference.** Digilent publish a Genesys ZU demo image. Booting theirs proves board + card + reader, and their FSBL/U-Boot could then load *our* kernel to unblock Phase 4 while ours is fixed.
4. If FSBL is confirmed broken, check how `gen-machine-conf` configured the FSBL multiconfig (`tmp-genesys-zu3eg-cortexa53-fsbl`) — particularly whether the FSBL's processor/DDR settings match the XSA.

---

## 4. Environment and assets

**Build VM** — Ubuntu 24.04 on Hyper-V, reachable as `ssh edfvm` (key auth, passwordless sudo). EDF checkout `~/edf/2026.1`, build dir `~/edf/2026.1/build`. Outputs in `build/tmp/deploy/images/genesys-zu3eg/`. It is powered off between sessions; start it from Hyper-V Manager (needs an elevated shell).

**`local.conf` additions on the VM** (backups: `local.conf.pre-machine`, `local.conf.efi-layout`):

```
MACHINE = "genesys-zu3eg"
SKIP_META_SECURITY_SANITY_CHECK = "1"
BB_NUMBER_THREADS = "12"
PARALLEL_MAKE = "-j 12"
INHERIT += "rm_work"
IMAGE_INSTALL:append = " linuxptp ethtool"
IMAGE_FSTYPES:pn-core-image-minimal = "cpio.gz"      # JTAG-boot ramdisk
IMAGE_FEATURES:append:pn-core-image-minimal = " debug-tweaks"
INITRAMFS_MAXSIZE = "524288"
MACHINE_FEATURES:remove = "efi"                       # classic SD layout
WKS_FILE = "xilinx-default-sd.wks"
```

**Windows host** — Vivado/Vitis 2026.1 at `C:\AMDDesignTools\2026.1`; `sdtgen` is at `Vivado\bin\sdtgen.bat`, and `xsdb`/`hw_server` are in the same directory. Board files (`gzu_3eg` 1.1) are installed but need `board.repoPaths` pointing at the XHub store — `create_project.tcl` handles it.

**Board** — Genesys ZU-3EG. Mode jumper: JTAG for `xsdb`, SD to boot. **Boot mode is latched only at power-on**, so always power-cycle after moving the jumper. Its FTDI bridge shows up as several COM ports; the console is the one that talks (COM4 on this machine). Channel A is JTAG.

**Scripts** (all work, all committed):
- `scripts/jtag_boot.tcl` — PS bring-up over JTAG: security gates (UG1137 `mwr 0xffca0038 0x1ff`), PMU firmware, `psu_init.tcl` for DDR, reset-vector bootloop, correct halt ordering. Every fix is commented with the symptom it cures.
- `scripts/uart_log.ps1` — passive UART capture, optional pattern-triggered send.
- `scripts/jtag_boot.ps1` — UART capture that also drives U-Boot. Only for the JTAG path.

**Staged artifacts** (gitignored, under `build/`): `build/sd/` has the flashable `.wic.xz` plus `BOOT-genesys-zu3eg.bin`; `build/jtag/` has kernel, dtb, 53 MB ramdisk, U-Boot, ATF, FSBL and PMU firmware; `build/sdt/` is the system device tree; `build/fpgamixer_phase4.xsa` is the hardware handoff.

---

## 5. Separate finding: `xsdb`'s `dow` is broken here

Worth recording because it cost a lot of time and will mislead anyone who tries JTAG boot again.

**`dow` mis-addresses bulk transfers.** Three 16 KB files downloaded to consecutive addresses in one session:

| Target | Expected | Got |
|---|---|---|
| `0x30000000` | `A1A1A1A1` | **`B2B2B2B2`** |
| `0x30004000` | `B2B2B2B2` | `B2B2B2B2` |
| `0x30008000` | `C3C3C3C3` | `C3C3C3C3` |

The first transfer's data never lands. Within a single large file the same thing happens: downloading the DTB put the bytes **from file offset 0x4000 (exactly 16 KB)** at the base address. So transfers move in 16 KB chunks and the destination address does not advance.

Consequences: U-Boot faulted on its first instruction (memory at `0x8000000` was never U-Boot), and the kernel read as NOPs instead of its `MZ` header.

**Ruled out:** cable and USB port (new cable, direct motherboard port), JTAG clock (15 MHz vs 5 MHz), DDR (`mwr` is correct at 1/4/256-word *and* byte granularity), DDR ECC (disabled), cache coherency (core and DAP reads agree), file integrity (md5 matches the VM), `dow` syntax, and access protection (`configparams force-mem-accesses 1`).

**Trap for the unwary:** synthetic test files with a repeating pattern (e.g. bytes 0..255) appear to download correctly, because a misplaced chunk looks identical. Always test with real payloads or non-repeating data.

`mwr` is correct and could be used to load payloads, but at roughly 10–20 minutes for 86 MB it is only worth it as a one-off.

---

## 6. Documentation corrections found along the way

Already applied to `setup_edf_hyperv_vm.md` except where noted:

- Ethernet is **GEM0 / ENET0**, MIO 26–37, MDIO on MIO 76–77 — **not GEM3**.
- The board preset leaves the **GEM TSU disabled**; we enable it (IOPLL / 250 MHz). Without it the macb driver silently falls back to `pclk`'s rate, giving a PTP clock that runs at the wrong speed instead of failing visibly.
- `sdtgen` lives in `Vivado\bin`, not `Vitis\bin`.
- `sdtgen` on Windows emits CRLF; run `dos2unix` on `*.dts*` every time.
- `gen-machine-conf` has **no `-l` option** (use `-c <config_dir>`) and **does not edit `local.conf`** — it only prints what to add.
- The image warning "not supported on genesys-zu3eg" is advisory, from `amd-edf-check-image.bbclass`.
- **Not yet applied:** §7's "copy BOOT.BIN onto the FAT partition by hand" is wrong for EDF 26.06.1 — the `.wic` already contains it, byte-identical.
- **Not yet applied:** the PS must be instantiated *inside* `phase3_top` (under `` `ifdef INCLUDE_PS ``), never in a wrapper above it. The XDC names ODDR instances by absolute path, so extra hierarchy silently drops 25 constraints and implementation fails in IO clock placement.
