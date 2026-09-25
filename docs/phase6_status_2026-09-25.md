# Phase 6 status: 2026-09-25 — parameter persistence

Phase 6's goal (roadmap §3): save on change, auto-load on boot, one parameter store used everywhere. Exit criterion: **a power cycle keeps the routing.**

Starting point (end of Phase 5): the OSC server already saved every change to a JSON file and pushed the saved levels to the FPGA at startup. What was missing: nothing started the server at boot, the save path wasn't safe against power loss or corruption, and every set did a synchronous file write.

## 1. Plan

| Piece | Where | Status |
|---|---|---|
| **P1** Harden the store | `tools/mixer_state.py` (new, split out of the server) | done, §2 |
| **P2** Server as a boot service | `meta-fpgamixer/recipes-apps/fpgamixer-osc` | |
| **P3** Bench network config | `meta-fpgamixer/recipes-apps/fpgamixer-bench-network` (separate: bench-only) | |
| **P4** One source of truth for board software | recipe packages the repo's `tools/`; `.gitattributes` keeps `tools/` LF | `.gitattributes` done |

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
