# Claude Code prompt: finish EDF build-host setup (Phase 4 prep)

**Context for you (Claude Code):** You're running on the maintainer's Windows 11 machine in the FPGAmixer repo. The EDF/Yocto build host is a Hyper-V Ubuntu Server 24.04 VM that you reach over SSH. Read these before doing anything:

- `docs/setup_edf_hyperv_vm.md`: the setup spec. Sections 1–3 (Hyper-V, VM, host packages) are reported done. Section 4 (Fetch EDF) is next.
- `buildhost.local.md`: VM address and credentials. **It's gitignored. Never commit it, never copy its contents into a tracked file or commit message, and never echo the password in output.**
- `docs/FPGAmixer_Architecture_Roadmap.md`: the phase context. We're finishing Phase 3.5 and preparing Phase 4 (Linux on the ZU-3EG PS).

## Goal

Get the VM to the point where it has **proven it can build a ZynqMP EDF image**, and has warm download and sstate caches. The real Genesys ZU-3EG image comes later, once the Phase 4 PS block design and XSA exist. Stop and report at each **CHECKPOINT**.

## Ground rules

- Every VM command runs through `ssh user@<host> '<cmd>'`. If key auth isn't set up yet, stop and ask the user to run the key-setup step in "Before you start" below. Don't try to script password entry.
- For `sudo`, pass the password from `buildhost.local.md` via `sudo -S`, without it showing in your printed output. Alternatively, ask the user whether they want passwordless sudo for `user` on this VM and set that up once.
- **Long jobs (`repo sync`, `bitbake`) run detached in tmux** (`tmux new -d -s edf '…  2>&1 | tee ~/edf/logs/<step>.log'`). Poll the log periodically. Never run a multi-hour build in the foreground of an SSH call.
- Don't source any Vivado/Vitis `settings64.sh` in the VM. Vivado lives on Windows only.
- If the spec turns out to be wrong for EDF 26.06.1 / `rel-v2026.1` (a command, flag, or package name), trust what the tools actually say, then **fix `docs/setup_edf_hyperv_vm.md`** to match and note the correction in your report. Don't guess. If something is ambiguous, stop and ask.
- Don't commit anything without showing the user the diff first.

## Steps

### 1. Verify the prerequisites the spec says are done

Run over SSH and report:

- `lsb_release -a`, `nproc`, `free -g`, `df -h /`. The root filesystem should have **at least 300 GB free**. If the LVM default left it at about 100 GB, apply the `lvextend` + `resize2fs` fix from spec §2 and confirm.
- `/bin/sh` points to bash or dash (Yocto Scarthgap is fine with dash; only note it).
- The locale `en_US.UTF-8` exists (`locale -a`).
- `repo --version` and `git config --global user.name/user.email` are set.
- Every package from spec §3 is installed (`dpkg -s` loop). Install any that are missing.
- Check `sysctl kernel.apparmor_restrict_unprivileged_userns`. Don't change it yet. Only change it (spec §3) if bitbake fails on namespaces in step 4.

**CHECKPOINT 1:** report the host facts, what was missing, and what you fixed.

### 2. Fetch EDF (spec §4)

```
mkdir -p ~/edf/2026.1 ~/edf/logs && cd ~/edf/2026.1
repo init -u https://github.com/Xilinx/yocto-manifests.git -b rel-v2026.1 -m default-edf.xml
repo sync -j8        # in tmux
```

Then record the resolved manifest (`repo manifest -r -o ~/edf/manifest-pinned.xml`) and the release tag if one is identifiable (expected: `amd-edf-rel-v26.06.1`). Check that `edf-init-build-env` exists in the checkout.

### 3. Check `sdtgen` on the Windows side (spec §5)

Find out whether the Windows Vivado/Vitis 2026.1 install ships `sdtgen`. Search the AMD install tree, e.g. `where /R C:\AMD sdtgen*` and `where /R C:\Xilinx sdtgen*`, whichever root exists. Report the path, or report that it doesn't exist. **Don't install anything in the VM to work around a missing `sdtgen`.** That decision (spec §5 Option B) belongs to the user.

**CHECKPOINT 2:** report the repo sync result, the pinned tag, and the `sdtgen` status.

### 4. Smoke build with a stock ZynqMP machine (host validation + cache warm-up)

There's no Genesys ZU XSA yet, so prove the toolchain with a stock AMD machine:

```
cd ~/edf/2026.1 && source edf-init-build-env
ls ../sources/meta-amd-adaptive-socs/meta-amd-adaptive-socs-bsp/conf/machine/   # confirm the path; it may differ
```

- Choose the generic **Cortex-A53 ZynqMP** machine that fits an **EG** part (the ZU3EG has a Mali-400 GPU). Candidates are `amd-cortexa53-common` and `amd-cortexa53-mali-common`. Read the machine `.conf` headers and state which you picked and why. If it's unclear, pick `amd-cortexa53-common` and say so.
- In `conf/local.conf`: `BB_NUMBER_THREADS` and `PARALLEL_MAKE` sized as `min(nproc, RAM_GB/2.5)`, plus `INHERIT += "rm_work"`. Show the diff.
- Build, in tmux: `MACHINE=<chosen> bitbake edf-linux-disk-image`.
- If it fails, diagnose from the log (`bitbake` error + the failing task's `log.do_*`). Fix host-side causes (missing packages, the AppArmor userns setting, disk space, OOM → lower the thread count). Don't patch recipes. If the failure isn't host-side, stop and report it.

**CHECKPOINT 3:** report build success or failure, wall-clock time, the size of `~/edf/2026.1/build` (downloads/sstate/tmp), and peak memory if observed (was the VM swapping?).

### 5. Record the results

- Update `docs/setup_edf_hyperv_vm.md` with any corrections found, and add a short "Validated on" note: date, EDF tag, Ubuntu point release, smoke-build machine, and build time.
- Add a short `docs/buildhost_status_<date>.md`: what's done, the pinned manifest tag, the `sdtgen` status, and what remains before the first Genesys ZU build. What remains: the Phase 4 PS block design with **Apply Board Preset** (Zynq UltraScale+ MPSoC IP) → XSA → `sdtgen` → `gen-machine-conf --machine-name genesys-zu3eg` → `edf-linux-disk-image` + `xilinx-bootbin`.
- Confirm `git status` doesn't show `buildhost.local.md` or `build/`.
- Show the user the diff and let them decide whether to commit.

## Out of scope for this task

The Vivado PS block design, generating the XSA, building for the Genesys ZU, creating the `meta-fpgamixer` layer, device-tree patches, and anything on the board itself.

---

## Before you start (user, one-time, manual)

Claude Code can't type an SSH password, so set up key auth first. In PowerShell:

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\edf_vm -N '""'
type $env:USERPROFILE\.ssh\edf_vm.pub | ssh user@<vm-ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Then add this to `%USERPROFILE%\.ssh\config`:

```
Host edfvm
    HostName <vm-hostname>.mshome.net     # or the 172.x IP; the IP changes when Windows reboots
    User user
    IdentityFile ~/.ssh/edf_vm
```

Test with `ssh edfvm hostname`, and put `edfvm` as the Host in `buildhost.local.md`.
