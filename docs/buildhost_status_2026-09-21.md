# EDF build host status: 2026-09-21

Phase 4 prep. The Hyper-V build VM is set up and has proven it can build a ZynqMP EDF image. The download and sstate caches are warm. Setup spec: `setup_edf_hyperv_vm.md`.

## Done

| Item | Result |
|---|---|
| Host | Ubuntu Server 24.04.5 LTS (kernel 6.8.0-139), 12 vCPU, 32 GB RAM (dynamic memory off), 7 GB swap, 392 GB root filesystem with no LVM |
| Host packages (spec §3) | All present. `/bin/sh` is dash, which Scarthgap accepts. The `en_US.UTF-8` locale is present. `repo` 2.65 is installed. |
| AppArmor userns | Already `0`, via `/etc/sysctl.d/60-yocto-userns.conf` |
| sudo | Passwordless for `user`, via `/etc/sudoers.d/90-user-nopasswd` |
| EDF checkout | `~/edf/2026.1`, 18 layers, clean |
| Pinned manifest | `~/edf/manifest-pinned.xml`, copied to [`edf/manifest-amd-edf-rel-v26.06.1.xml`](edf/manifest-amd-edf-rel-v26.06.1.xml). Recreate the exact checkout with `repo init -u https://github.com/Xilinx/yocto-manifests.git -b rel-v2026.1 -m default-edf.xml`, then `repo sync -m <absolute path to this file>` (`-m` makes the sync use this manifest temporarily). All layers are at tag **`amd-edf-rel-v26.06.1`**. The manifest repo is at `amd-edf-rel-v26.06.1-1-gec6578c`, which tracks the branch. |
| `sdtgen` (Windows) | Present at `C:\AMDDesignTools\2026.1\Vivado\bin\sdtgen.bat`. It runs and asks for `-xsa`. Spec §5 Option A is viable, so no Vivado install is needed in the VM. |

## Smoke build

`MACHINE=amd-cortexa53-mali-common bitbake edf-linux-disk-image`

- **Machine choice:** EDF's machine headers describe `amd-cortexa53-mali-common` as the shared-rootfs machine for Cortex-A53 parts with a Mali-400 (ZynqMP EG/EV). The ZU3EG is an EG part. `amd-cortexa53-common` is for CG/DR parts.
- **`local.conf` additions:** `BB_NUMBER_THREADS = "12"`, `PARALLEL_MAKE = "-j 12"` (min(12 vCPU, 32 GB / 2.5)), and `INHERIT += "rm_work"`.
- **Result: passed.** 13549 tasks ran with 0 warnings and 0 errors. The first attempt succeeded, and no host-side fixes were needed.
- **Wall clock:** 43 min 25 s (22:42 → 23:26).
- **Sstate:** 6238 of the 6459 wanted objects came from AMD's mirror (96% match). The EDF `local.conf` template configures that mirror by default.
- **Disk:** `downloads` 32 GB, `sstate-cache` 6.5 GB, `tmp` 22 GB (with `rm_work`). 301 GB remain free on the root filesystem.
- **Memory:** peak swap use was about 0.5 MB, which is effectively none. At least 15 GB of RAM (free + cache) stayed available throughout. 12 threads leave headroom, so it's reasonable to try more when source-heavy custom-machine builds start.
- **Outputs:** `tmp/deploy/images/amd-cortexa53-mali-common/` holds the rootfs `.wic` (5.6 GB, 291 MB as `.wic.xz`) and the `.tar.gz`. This common machine isn't bootable on its own because it has no BOOT.BIN or board device tree.

## Remaining before the first Genesys ZU build

1. **Phase 4 PS block design in Vivado.** Add the Zynq UltraScale+ MPSoC IP and run **Apply Board Preset**, which brings in the Genesys ZU board files: DDR4, UART, SD, GEM0/RGMII and USB. Spec §8 has the details.
2. **Export the XSA:** `write_hw_platform -fixed -include_bit`.
3. **Run `sdtgen`** on Windows, then `scp` the SDT directory to `~/edf/sdt`. Spec §5 has the steps.
4. **Generate the machine config:** `gen-machine-conf parse-sdt --hw-description ~/edf/sdt -c conf -l conf/local.conf --machine-name genesys-zu3eg`.
5. **Build:** `bitbake edf-linux-disk-image` and `bitbake xilinx-bootbin`, then boot from SD. Spec §7 covers the SD card and §9 lists the board snags to expect.
