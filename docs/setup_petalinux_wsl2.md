# PetaLinux 2026.1 build host on Windows 11 (WSL2)

**Date:** 2026-09-21
**Replaces:** `setup_build_host_macmini.md` (Mac mini build host retired)
**Target:** Genesys ZU-3EG (`xczu3eg-sfvc784-1-e`), aarch64 / zynqMP
**Split:** Vivado 2026.1 stays on Windows. PetaLinux 2026.1 runs in WSL2. The XSA is the only thing that crosses between them.

---

## 0. Before you start

| Item | Why it matters |
|---|---|
| Vivado on Windows is **2026.1** | PetaLinux must match the Vivado version that produced the XSA exactly. |
| **8+ cores, 16 GB+ RAM** on the PC | AMD's stated minimum is 8 cores, 8 GB RAM, 100 GB free disk. With 8 GB, Yocto builds tend to OOM once Windows takes its share. |
| **~150 GB free on the drive holding WSL** | 100 GB for PetaLinux, plus headroom for the first build's downloads and sstate. |
| Windows 11 22H2 or later | Needed for mirrored networking (§2). |

**Support status:** AMD's 2026.1 supported hosts are Ubuntu 22.04.3–.5 / 24.04.3, OpenSUSE Leap 15.4, AlmaLinux 8.10/9.4, and Rocky 9.6. **WSL2 is not on that list.** In practice, PetaLinux runs under WSL2 Ubuntu without trouble as long as the rules in §3 are followed. If you run into something odd that you can't pin down, the officially supported fallback is the same Ubuntu 22.04 in a Hyper-V VM (you have Win11 Pro, so Hyper-V is available). Everything from §3 onward still applies in the VM.

**Ubuntu 22.04, not 24.04:** WSL's `Ubuntu-22.04` distro is 22.04.5, which is exactly on AMD's list. WSL's `Ubuntu-24.04` has probably moved past 24.04.3, and 24.04 also dropped `libtinfo5`, which older PetaLinux releases needed.

---

## 1. Install WSL2 + Ubuntu 22.04

Run in PowerShell as admin:

```powershell
wsl --install -d Ubuntu-22.04
# reboot if prompted, then launch "Ubuntu 22.04" from Start and create a normal (non-root) user
wsl --list --verbose        # confirm VERSION = 2
```

Optional: move the distro off C: if another drive has more space:

```powershell
wsl --shutdown
wsl --manage Ubuntu-22.04 --move D:\WSL\Ubuntu-22.04
```

## 2. Windows-side WSL config: `%UserProfile%\.wslconfig`

This file controls the VM itself. Memory and CPU limits go here, **not** in `/etc/wsl.conf` inside Linux, where they are ignored.

```ini
[wsl2]
memory=24GB          # ~75% of physical RAM; leave Windows 6-8 GB
processors=12        # all physical cores, or a couple fewer
swap=16GB            # Yocto peaks (linking, rootfs) can exceed RAM
networkingMode=mirrored   # WSL shares the PC's network stack; helps hw_server / tftp later
```

Then run `wsl --shutdown` and reopen Ubuntu.

Rule of thumb: Yocto wants about 2 GB RAM per parallel build thread. If builds get OOM-killed, lower the thread count (§6) before adding RAM.

## 3. Linux-side config: `/etc/wsl.conf`

```ini
[boot]
systemd=true

[interop]
appendWindowsPath=false   # keeps "C:\Program Files\..." (spaces!) out of $PATH; bitbake chokes on it
```

Then run `wsl --shutdown` from PowerShell and reopen.

**Rules that avoid nearly all WSL + Yocto problems:**

1. **All PetaLinux projects live in the Linux filesystem** (`~/…`), **never under `/mnt/c`**. `/mnt/c` is case-insensitive, doesn't handle permissions or symlinks the way Yocto expects, and is 10–50× slower. Only the XSA gets copied across.
2. Install and build as your normal user. PetaLinux refuses to install as root.
3. Don't source Vivado's `settings64.sh` in WSL. Vivado lives on Windows, which also takes care of the old "never mix Vivado and PetaLinux environments in one shell" rule.

## 4. Host packages

```bash
sudo dpkg-reconfigure dash          # answer "No" → /bin/sh becomes bash (required)
sudo dpkg --add-architecture i386
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  iproute2 gawk python3 python-is-python3 build-essential gcc gcc-multilib git make \
  net-tools libncurses5-dev zlib1g-dev zlib1g:i386 libssl-dev flex bison libselinux1 \
  gnupg wget diffstat chrpath socat xterm autoconf libtool tar unzip texinfo automake \
  screen pax gzip cpio python3-pip python3-pexpect python3-git python3-jinja2 \
  xz-utils debianutils iputils-ping libegl1-mesa libsdl1.2-dev pylint lz4 zstd file \
  locales libtinfo5 bc rsync
sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8
ls -l /bin/sh                       # must point to bash
```

This list is based on recent PetaLinux releases. **The 2026.1 release notes contain the official list**, and the installer checks for missing packages and names them. If it asks for something not listed here, install it and rerun.

## 5. Install PetaLinux 2026.1

Download `petalinux-v2026.1-*-installer.run` from the AMD downloads page (AMD account required). Copy it into WSL; don't run it from `/mnt/c`.

```bash
mkdir -p ~/petalinux/2026.1 ~/xsa ~/plnx
cp /mnt/c/Users/<you>/Downloads/petalinux-v2026.1-*-installer.run ~/
chmod +x ~/petalinux-v2026.1-*-installer.run
~/petalinux-v2026.1-*-installer.run --dir ~/petalinux/2026.1 --platform "aarch64"
```

`--platform "aarch64"` installs only the zynqMP toolchain and skips arm and microblaze, which saves a lot of space. If this release rejects the flag, check `--help`.

Set up an alias instead of auto-sourcing, so it's clear which shell has the environment loaded:

```bash
echo 'alias plnx="source ~/petalinux/2026.1/settings.sh"' >> ~/.bashrc
source ~/.bashrc
plnx && petalinux-util --help >/dev/null && echo OK
```

## 6. Smoke test: project from the XSA

**Vivado-side prerequisite (not covered by the Arty Stage A spec):** on ZynqMP, the PS block has to be the *Zynq UltraScale+ MPSoC* IP with **Apply Board Preset** from the Digilent Genesys ZU board files. The board preset carries the board-specific **DDR4** settings, plus UART, SD, GEM0/RGMII, and USB. The Arty-era approach of turning off every PS interface doesn't carry over: without DDR, UART, and SD configured, there's nothing to boot into. Export with `write_hw_platform -fixed -include_bit` as before.

```bash
cp /mnt/c/Users/<you>/Documents/FPGAmixer/<path-to>.xsa ~/xsa/
plnx
cd ~/plnx
petalinux-create project --template zynqMP --name fpgamixer-os   # 2024.1+ syntax (older: -t project)
cd fpgamixer-os
petalinux-config --get-hw-description ~/xsa/<name>.xsa
```

In the menuconfig that opens:

- **Yocto Settings → Parallel thread execution:** set `BB_NUMBER_THREADS` and `PARALLEL_MAKE` to about RAM(GB)/2 if you have less than 2 GB per core.
- **Subsystem AUTO Hardware Settings → Serial Settings:** make sure the console points at the PS UART wired to the Genesys ZU's USB-UART. I haven't confirmed whether that's UART0 or UART1; check the Digilent reference manual or the board preset.
- Leave everything else at defaults for the first build.

```bash
petalinux-build                       # first build: roughly 1-2+ hours, several GB of downloads
petalinux-package boot --u-boot --fpga images/linux/system.bit --force
#   (older syntax: petalinux-package --boot ...)
```

The artifacts end up in `images/linux/`: `BOOT.BIN`, `image.ub`, `boot.scr`.

## 7. Getting it onto the board

**SD boot (recommended with WSL):** copy `BOOT.BIN`, `image.ub`, and `boot.scr` to a FAT32 SD card from Windows. They're reachable in Explorer at `\\wsl$\Ubuntu-22.04\home\<you>\plnx\fpgamixer-os\images\linux`. Set the Genesys ZU boot-mode switch to SD. Alternatively, run `petalinux-package wic` and write the `.wic` image with balenaEtcher or Rufus.

**UART console:** use PuTTY or Tera Term on Windows at 115200 8N1 on the board's FTDI COM port. WSL can't see USB devices without `usbipd-win`, and it doesn't need to here.

**JTAG boot (optional, later):** the USB-JTAG cable is only visible to Windows. Run `hw_server` from the Windows Vivado install. With mirrored networking, PetaLinux in WSL reaches it at `localhost:3121` via `petalinux-boot jtag … --hw_server-url TCP:localhost:3121`. Check `petalinux-boot jtag --help` for 2026.1's exact flags.

**Phase 4 exit check:** the U-Boot → kernel → login prompt appears on UART, and after `ip addr` shows an address on `eth0`, the board answers `ping` and `ssh` from the Mac.

---

## Likely snags specific to this board (no Digilent 2026.1 BSP)

Digilent's Genesys ZU PetaLinux BSPs target much older releases, so we're building from the XSA with the generic zynqMP template. Things that may need a `system-user.dtsi` patch in `project-spec/meta-user/recipes-bsp/device-tree/files/`:

- **Ethernet PHY (TI DP83867CR):** the auto-generated device tree may not set the PHY address or the RGMII internal-delay properties (`ti,rx-internal-delay`, `ti,tx-internal-delay`, `ti,fifo-depth`). Symptoms: `eth0` exists but gets no link or no traffic. Digilent's old Genesys-ZU-OS repo has a `system-user.dtsi` worth borrowing values from.
- **SD card:** some Digilent ZynqMP boards need `no-1-8-v` and/or `disable-wp` on the SDHCI node. Symptom: rootfs mount fails or the card isn't detected.

These are possibilities based on how these boards usually behave, not confirmed failures. Try the plain build first and only patch what actually breaks.

## Longer-term note

PetaLinux is on AMD's retirement path, with the Yocto-based EDF as its successor. The existing plan is to revisit that at the Phase 6/7 boundary. EDF is also Yocto on a Linux host, so this WSL2 setup (§1–4) carries over.
