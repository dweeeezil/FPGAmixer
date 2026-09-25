# Phase 6 status: 2026-09-25 — parameter persistence

Phase 6's goal (roadmap §3): save on change, auto-load on boot, one parameter store used everywhere. Exit criterion: **a power cycle keeps the routing.**

Starting point (end of Phase 5): the OSC server already saved every change to a JSON file and pushed the saved levels to the FPGA at startup. What was missing: nothing started the server at boot, the save path wasn't safe against power loss or corruption, and every set did a synchronous file write.

## 1. Plan

| Piece | Where | Status |
|---|---|---|
| **P1** Harden the store | `tools/mixer_state.py` (new, split out of the server) | done, §2 |
| **P2** Server as a boot service | `meta-fpgamixer/recipes-apps/fpgamixer-osc` | built, §3; hardware test pending |
| **P3** Bench network config | `meta-fpgamixer/recipes-apps/fpgamixer-bench-network` (separate: bench-only) | built, §3; hardware test pending |
| **P4** One source of truth for board software | recipe packages the repo's `tools/`; `.gitattributes` keeps `tools/` LF; `scripts/sync_buildhost.sh` | done, §4 |

Findings from the Phase 5 image that shaped this (read from the rootfs tarball and manifest on the build VM):

- **Networking is `systemd-networkd`.** `/usr/lib/systemd/network/80-wired.network` runs DHCP on every Ethernet port (which is how the board got an address from the Mac in Phase 4). A lower-numbered `.network` file matching `end0` takes precedence.
- **Python:** `python3-core`, `-json`, `-mmap`, `-threading`, `-io`, `-logging` are all in the image already.
- **Filesystems:** root is ext4 (journaled, atomic rename). `/storage` is FAT, where rename atomicity and fsync semantics are weaker. **Decision: state lives on the root filesystem, `/var/lib/fpgamixer/mixer_state.json`.** (`/var/lib` isn't one of the volatile tmpfs paths.) Consequence: **reflashing the SD card resets the state**, like everything else on the card.

## 2. P1: the store, hardened

`MixerState` moved from `osc_mixer_server.py` into `tools/mixer_state.py`. The store's file format is a contract that outlives the interim server (`architecture_modules.md` §4.2), so it now lives in a module that knows nothing about OSC, sockets or hardware. The full rules are in its docstring. In short:

| Concern | Before | Now |
|---|---|---|
| Write frequency | a synchronous write on **every** set, on the network thread | **batched**: a change marks the store dirty; a saver thread writes 250 ms later. A 500-set burst → ≤ 3 writes (test). No network path waits for the SD card. |
| Power loss mid-write | `tmp` + rename, no `fsync`: a crash could leave an empty file | `tmp` → `fsync` → rename current to `.bak` → rename `tmp` to current → `fsync` the directory. At every instant one of current/`.bak` is complete and on disk. |
| Crash between the renames | n/a | loader uses `.bak`, then rewrites the current file from it |
| Corrupt file | "starting fresh", and the next save **overwrote** it | moved aside as `.corrupt-<time>`, byte for byte, never deleted; `.bak` used if good |
| Disk full / read-only | exception on the network thread | logged, stays dirty, retried on the next change; memory stays authoritative |
| Shutdown | pending state lost | SIGTERM (`systemctl stop`, shutdown) writes anything pending, then exits 0 |
| Loss window on a power cut | none (but slow and unsafe) | ≤ 250 ms of changes + one write |

**Tests:** `tools/test_mixer_state.py`, standard library `unittest`, 14 tests: tree rules, NaN never written, flat-format conversion, batching, `.bak` = previous state, corrupt → `.bak` fallback with evidence kept, missing main (the crash window), both files unusable, leftover `.tmp` ignored, failed save retried, memory-only mode, and **SIGTERM inside the batch window still saves** (starts the real server, sets a value, kills it). Windows: 13 pass, 1 skipped (POSIX signals). **Linux build VM: 14/14.**

### A race this exposed (fixed)

With sets no longer slowed by a synchronous write, `osc_mixer_test.py`'s `multi_client_broadcast_sync` started failing about 1 run in 6. The server added a client to the broadcast list only once that client's handler thread was running, so a change made by another client in that window never reached it. Two fixes, one per layer:

- **Server:** clients are registered in the accept loop, before their thread starts.
- **Test:** client B now does one `get` round trip before client A's change. `connect()` returning only means the kernel finished the handshake. A connection still in the listen backlog can't be reached by any server, so the test was asserting something no server can guarantee. A real controller syncs with gets on connect anyway.

After both: the test **40/40**, the full suite **19/20** (the known unframed-TCP case).

## 3. P2 + P3: the recipes

New in `yocto/meta-fpgamixer/`:

| File | What |
|---|---|
| `recipes-apps/fpgamixer-osc/fpgamixer-osc_1.0.bb` | installs `osc_mixer_server.py`, `mixer_state.py`, `mixer_hw.py` to `/usr/lib/fpgamixer/`, plus the unit; `RDEPENDS` = `python3-core python3-io python3-json python3-mmap` (mapped module by module from poky's `python3-manifest.json`) |
| `recipes-apps/fpgamixer-osc/files/fpgamixer-osc.service` | runs the server as root with `--hw --state-file /var/lib/fpgamixer/mixer_state.json`; `StateDirectory=fpgamixer` creates the directory; `Restart=on-failure`; SIGTERM + 10 s stop timeout (a save needs far less) |
| `recipes-apps/fpgamixer-bench-network/…` | `/etc/systemd/network/10-end0-bench.network`: `end0` = 10.0.0.2/24 **and** DHCP. It sorts before the stock `80-wired.network`, and networkd uses the first match. `RequiredForOnline=no`, so the bench link's never-answered DHCP can't stall `network-online.target` |
| `recipes-extended/images/edf-linux-disk-image.bbappend` | adds `fpgamixer-osc` to the image, and `fpgamixer-bench-network` only when `FPGAMIXER_BENCH = "1"` (the default in `layer.conf`). What the image contains is tracked in git, not in the VM's `local.conf` |

Build check on the VM (`bitbake fpgamixer-osc fpgamixer-bench-network`, all tasks succeeded). `oe-pkgdata-util list-pkg-files` shows exactly the three modules, the unit, a `98-fpgamixer-osc.preset` (enabled) and the `.network` file. `bitbake -e` shows both packages in the image's `IMAGE_INSTALL`.

**Boot-hang guard.** An auto-started service that reads a register window on a bitstream without that window hangs the interconnect during boot, and only a reflash recovers from that. `mixer_hw` therefore refuses to map `/dev/mem` unless the running device tree has a node `…@<window base>`. sdtgen emits `/axi/M_AXI_CTRL@80000000` (checked in the shipped `.dtb`), and the device tree and the bitstream come from the same XSA, so the node is present exactly when the window is. On refusal the service fails with a clear message and systemd's start limit stops the retries.

**Tests:** `tools/test_mixer_hw.py`, 11 tests: the device-tree guard (finds the node, exact suffix match, refuses before opening `/dev/mem`), plus registers against a fake 4 KB window file (ID/CONFIG, addressing `k = out·N_IN + in`, COMMIT, clamp/off, signed read-back, out-of-range), and the server backend seeding, restoring and pushing in one commit. Linux VM: `test_mixer_hw` + `test_mixer_state` **25/25**; Windows 17 + 8 skipped (Linux mmap flags / POSIX signals).

## 4. P4: one source of truth, and the VM layout

Before: the VM had a hand-copied `~/edf/2026.1/sources/meta-fpgamixer`, which had already drifted from the repo (a comment date in `system-user.dtsi`). Now:

- `scripts/sync_buildhost.sh [host]` (default `edfvm`) streams the repo's git-tracked `yocto/` and `tools/` to `~/edf/2026.1/sources/fpgamixer/`, replacing it in one go (no stale files). It writes `.synced-from` with the commit, plus `-dirty` if the working tree had uncommitted changes, and strips any CR.
- The recipe takes the Python from `tools/` through `FPGAMIXER_TOOLS := "${LAYERDIR}/../../tools"` (`layer.conf`), so the layer holds no copy of it.
- **One-time VM change (done 2026-09-25):** `bitbake-layers remove-layer ../sources/meta-fpgamixer`, then `add-layer ../sources/fpgamixer/yocto/meta-fpgamixer`. Backups: `conf/bblayers.conf.pre-phase6`, `sources/meta-fpgamixer.pre-phase6`.
- `.gitattributes`: `tools/**` and `yocto/**` are `eol=lf`.

**Workflow from now on:** edit in the repo → `scripts/sync_buildhost.sh` → `bitbake edf-linux-disk-image xilinx-bootbin` on the VM. The `sdtgen` → `gen-machine-conf` steps are only needed when the Vivado design changes.

## 5. Hardware test plan (Phase 6 exit criterion)

1. Flash, full power-off, boot. With no manual network commands, `ssh board` should work (10.0.0.2 comes up by itself).
2. `systemctl status fpgamixer-osc`: active; the journal shows "Pushed 16 inputMatrix level(s) to the PL".
3. From the Pi: the OSC suite, 18/19 as before.
4. Set a non-default route over OSC (JB_L → JC_L, JC_L's own input off) and check it by ear.
5. **Pull the power** (no shutdown). Boot. With nothing typed on the board, the route from step 4 must be back, by ear and in `mixer_hw.py dump`. That is the exit criterion.
6. `sudo systemctl stop fpgamixer-osc` right after a change: the journal says "state saved".
