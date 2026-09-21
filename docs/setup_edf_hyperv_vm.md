# EDF (Yocto) build host: Ubuntu 24.04 VM on Hyper-V

**Date:** 2026-09-21
**Supersedes:** `setup_petalinux_wsl2.md` and `setup_build_host_macmini.md`
**Target:** Genesys ZU-3EG (`xczu3eg-sfvc784-1-e`), aarch64 / ZynqMP
**Toolchain:** Vivado 2026.1 (Windows) → AMD EDF 26.06.1 (`rel-v2026.1` branch, Yocto Scarthgap 5.0.x) in an Ubuntu VM

```
 Windows 11 (host)                         Ubuntu 24.04 VM (Hyper-V)
 ───────────────────────                   ─────────────────────────────
 Vivado 2026.1                             EDF / Yocto
   └─ design → XSA ──► sdtgen ──► SDT dir ──► gen-machine-conf → machine .conf
                                             └─ bitbake → .wic + BOOT.BIN
 hw_server (JTAG), PuTTY (UART)   ◄──────────── SD card / network
```

Why a VM instead of WSL: EDF's release notes say plainly that Windows, including any Linux distribution running under WSL, is **not supported** as a build host. EDF's top-priority validated host is Ubuntu 24.04.3.

> **Validated on 2026-09-21:** Ubuntu Server **24.04.5** (kernel 6.8.0-139), 12 vCPU / 32 GB / 400 GB VHDX. EDF tag **`amd-edf-rel-v26.06.1`**. Smoke build `MACHINE=amd-cortexa53-mali-common bitbake edf-linux-disk-image` passed in **43 min 25 s** with 0 warnings, and 96% of the sstate came from AMD's mirror. The build tree was 61 GB afterwards (downloads 32 GB, sstate 6.5 GB, tmp 22 GB). The VM never swapped. Details: `buildhost_status_2026-09-21.md`.

---

## 1. Enable Hyper-V

In PowerShell (admin):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
# reboot
```

## 2. Create the VM

Get the **Ubuntu Server 24.04.x** ISO. The server edition is headless, which leaves more RAM for builds; you'll work over SSH. AMD validated 24.04.3 specifically, and older point-release ISOs are at `old-releases.ubuntu.com/releases/24.04.3/`. In practice, point releases differ only in their package snapshot. Yocto's sanity check keys on "ubuntu-24.04", so a newer 24.04.x is very unlikely to matter.

In Hyper-V Manager → New → Virtual Machine:

| Setting | Value | Why |
|---|---|---|
| Generation | **2** | UEFI |
| Memory | **32768 MB, Dynamic Memory OFF** | Leaves Windows plus Vivado about 16 GB. Dynamic memory and Yocto's memory spikes don't mix well. |
| Network | Default Switch | NAT is fine for downloads and SSH from Windows (see §9 for board networking) |
| Disk | New VHDX, **400 GB** (dynamically expanding) on your fastest SSD | A full EDF build from source (downloads + sstate + tmp) easily reaches 150–250 GB |

Before the first boot, open VM **Settings**:

- **Security → Secure Boot template: "Microsoft UEFI Certificate Authority"**. With the default "Microsoft Windows" template, the Ubuntu installer won't boot. You can also just turn Secure Boot off.
- **Processor:** set the vCPU count to your logical core count minus 2–4.
- **Checkpoints:** turn off **automatic checkpoints**. Otherwise every VM start creates a differencing disk, and with Yocto's churn that bloats quickly.

  ```powershell
  Set-VM -Name <vmname> -AutomaticCheckpointsEnabled $false
  ```

Install Ubuntu Server: use the entire disk, skip LVM or give the root LV the full disk, and **tick "Install OpenSSH server"**. Create a normal user; Yocto refuses to run as root.

After the install, from Windows Terminal:

```powershell
ssh <user>@<vm-ip>       # the VM prints its IP on the console after login (ip -4 addr)
```

VS Code's Remote-SSH extension also works well for editing recipes in the VM.

**Check that the whole disk is usable:** `df -h /`. If the Ubuntu installer's LVM default only allocated ~100 GB, extend it:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

## 3. Host packages

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y \
  build-essential chrpath cpio debianutils diffstat file gawk gcc git iputils-ping \
  libacl1 liblz4-tool locales python3 python3-git python3-jinja2 python3-pexpect \
  python3-pip python3-subunit socat texinfo unzip wget xz-utils zstd lz4 \
  curl bc rsync device-tree-compiler dos2unix tmux
sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8

# repo
mkdir -p ~/bin && curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo && chmod a+x ~/bin/repo
grep -q 'HOME/bin' ~/.bashrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

git config --global user.name  "<Your Name>"
git config --global user.email "<you@example.com>"
```

`~/.bashrc` only adds `~/bin` to `PATH` in interactive shells. For one-shot commands over SSH (`ssh edfvm '...'`), call `~/bin/repo` or prepend `PATH=$HOME/bin:$PATH`.

This is the standard Yocto Scarthgap package list for Ubuntu. EDF's release notes say a validated host doesn't guarantee that the default packages are enough. If bitbake's sanity check names something missing, install it and rerun.

**Ubuntu 24.04 + AppArmor:** 24.04 restricts unprivileged user namespaces, and bitbake uses them to sandbox tasks. If a build fails with namespace or permission errors in the first few tasks, run:

```bash
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-yocto-userns.conf
sudo sysctl --system
```

**Use `tmux` for builds**, so an SSH drop doesn't kill a two-hour bitbake.

## 4. Fetch EDF

```bash
mkdir -p ~/edf/2026.1 && cd ~/edf/2026.1
repo init -u https://github.com/Xilinx/yocto-manifests.git -b rel-v2026.1 -m default-edf.xml
repo sync -j8
```

The current release on that branch is tagged `amd-edf-rel-v26.06.1`. The manifest repo itself sits one commit past that tag (`amd-edf-rel-v26.06.1-1-gec6578c`, "move to branch HEAD"). That commit makes every layer track the `rel-v2026.1` branch instead of the tag, so a later `repo sync` can move past 26.06.1. Pin what you actually built:

```bash
repo manifest -r -o ~/edf/manifest-pinned.xml
```

Note the tag in the commit message when this matters.

## 5. XSA → System Device Tree (SDT)

EDF doesn't take the XSA directly. `sdtgen` converts it into a System Device Tree directory first. `sdtgen` ships with the Vivado install: on this machine it's **`C:\AMDDesignTools\2026.1\Vivado\bin\sdtgen.bat`** (verified 2026-09-21). It isn't in `Vitis\bin`, and the install root is `C:\AMDDesignTools`, not `C:\AMD` or `C:\Xilinx`.

**Option A (preferred, no second Vivado install): run `sdtgen` on Windows.** It isn't on the plain Windows `PATH`. Run it from a Vivado command prompt or Tcl console, or call it by full path:

```
C:\AMDDesignTools\2026.1\Vivado\bin\sdtgen.bat -xsa <repo>\<path>\<name>.xsa -dir <repo>\build\sdt
```

Then copy the `sdt` directory into the VM:

```powershell
scp -r <repo>\build\sdt <user>@<vm-ip>:~/edf/sdt       # <repo> = your FPGAmixer checkout
```

If the device-tree compiler later complains about stray `\r` characters, run `find ~/edf/sdt -type f -name '*.dts*' -exec dos2unix {} +`.

**Option B: install Vivado 2026.1 in the VM** (ZynqMP device support only) and run `sdtgen` there. It costs tens of GB of disk and gives you a second install to keep in sync. Use it only if Option A isn't available on Windows.

Add the SDT output directory to `.gitignore`. Like the Vivado project, it's generated from sources.

## 6. Machine config + first build

```bash
cd ~/edf/2026.1
source edf-init-build-env          # creates ./build, generates local.conf + bblayers.conf, cd's into build/
                                   # source it from bash; its header says it isn't dash-safe with arguments

gen-machine-conf parse-sdt --hw-description ~/edf/sdt \
  -c conf -l conf/local.conf --machine-name genesys-zu3eg
```

This writes `conf/machine/genesys-zu3eg.conf` and wires it into `local.conf`. Check that `MACHINE = "genesys-zu3eg"` appears in `conf/local.conf`.

Also add to `conf/local.conf`:

```
BB_NUMBER_THREADS = "12"   # ≈ RAM_GB / 2.5 is safe; raise it if the VM never swaps
PARALLEL_MAKE     = "-j 12"
INHERIT += "rm_work"       # deletes per-recipe work dirs after they build; saves ~100 GB
```

Build, inside tmux:

```bash
bitbake edf-linux-disk-image
bitbake xilinx-bootbin      # BOOT.BIN (FSBL + PMUFW + ATF + U-Boot + your bitstream)
```

The EDF `local.conf` template already points `SOURCE_MIRROR_URL` and `SSTATE_MIRRORS` at `edf.amd.com/sswreleases/amd-edf/26.06/`. Most tasks therefore restore from AMD's prebuilt sstate instead of compiling. The stock-machine smoke build pulled 96% of its tasks from the mirror and finished in about 45 min, with about 32 GB of downloads. A custom machine like `genesys-zu3eg` will match less of the mirror, because its kernel, device tree and boot firmware are machine-specific, but the shared rootfs packages still restore from it. Rebuilds are much faster after that.

**Host validation without an XSA:** build a stock common machine first, e.g. `MACHINE=amd-cortexa53-mali-common bitbake edf-linux-disk-image`. Choose `amd-cortexa53-mali-common` for EG/EV parts, which have the Mali-400, and `amd-cortexa53-common` for CG/DR parts. These common machines produce a shared rootfs `.wic` only. They aren't bootable on their own because they have no BOOT.BIN or board device tree.

Outputs are in `build/tmp/deploy/images/genesys-zu3eg/` (roughly: a `.wic` image, `BOOT.BIN`, the kernel, and the dtb).

## 7. SD card

1. Copy the `.wic` image to Windows (`scp <user>@<vm-ip>:~/edf/2026.1/build/tmp/deploy/images/genesys-zu3eg/*.wic .`) and write it with balenaEtcher or Rufus.
2. **On ZynqMP, copy `BOOT.BIN` onto the FAT boot partition by hand.** Unlike Versal, the ZynqMP `.wic` doesn't include it.
3. Set the Genesys ZU boot-mode switch to SD. Connect PuTTY or Tera Term to the board's FTDI COM port at 115200 8N1.

**Phase 4 exit:** the U-Boot → kernel → login prompt appears on the UART console, `eth0` gets an address, and the Mac can `ping` and `ssh` into the board.

## 8. Vivado-side prerequisite (differs from the Arty Stage A spec)

On ZynqMP, the PS block has to be the **Zynq UltraScale+ MPSoC** IP with **Apply Board Preset** from the Digilent Genesys ZU board files. The board preset provides the board-specific **DDR4** settings, plus UART, SD, GEM3/RGMII, and USB. The Arty-era approach of turning off every PS interface doesn't carry over: without DDR, UART, and SD configured, there's nothing to boot into. Export as before with `write_hw_platform -fixed -include_bit`.

## 9. Board-specific snags to expect (no Digilent EDF BSP exists)

These are possibilities based on how Digilent ZynqMP boards usually behave, not confirmed failures. Build plain first and patch only what breaks.

- **Ethernet PHY (TI DP83867CR):** the generated device tree may not set the PHY address or the RGMII delay properties (`ti,rx-internal-delay`, `ti,tx-internal-delay`, `ti,fifo-depth`). Symptom: `eth0` shows up but gets no link or no traffic.
- **SD card:** the SDHCI node may need `no-1-8-v` and/or `disable-wp`. Symptom: the rootfs never mounts.
- **Where fixes go:** create your own layer (`bitbake-layers create-layer ../sources/meta-fpgamixer` then `bitbake-layers add-layer ../sources/meta-fpgamixer`). It's the equivalent of PetaLinux's `meta-user` and is where the OSC server, parameter store, and PTP config will live later. Device-tree fixes go in as a `system-user.dtsi` via `EXTRA_DT_INCLUDE_FILES`, scoped to the Linux domain so they don't leak into the FSBL/PMUFW device trees. Alternatively, pass the dtsi to `sdtgen -user_dts`. Digilent's archived Genesys-ZU-OS repo has a PetaLinux-era `system-user.dtsi` worth borrowing PHY values from.
- **Version the layer:** `meta-fpgamixer` should go into git, either in the FPGAmixer repo or a sibling repo. The `~/edf/2026.1` checkout itself is disposable.

## 10. Later: networking and JTAG from the VM

- **Default Switch (NAT)** is enough for Phase 4 because the board sits on your LAN and the Mac talks to it directly. If you later want TFTP or NFS boot from the VM, add an **External** virtual switch bound to your Ethernet NIC so the VM gets its own LAN IP.
- **JTAG:** the USB cable belongs to Windows. Run `hw_server` from the Windows Vivado install and connect from the VM over TCP (`<windows-ip>:3121`). The VM never needs the USB device.
