# Prompt: USB host mode (a USB audio interface plugged into the board)

*Written 2026-09-30 at the end of the session that did P9.5–P9.7 and Phase 10 (the board as an AVB device for a Mac), as the opening prompt for a fresh session.*

---

You're continuing the FPGAmixer project: a network/USB/analog digital matrix mixer on a Digilent Genesys ZU-3EG (Zynq UltraScale+ XCZU3EG). Work is on branch **`phase9/time-shared-core`** (not merged; the user opens PRs). Where things stand:

- **Core:** time-shared `pcm_matrix`, **20 × 20** on 2 DSP48E2 lanes (D = 227 `mclk` cycles of 256 per frame). Channel map `{link2, link, jc, jb}`: in/out 0–1 JB, 2–3 JC, 4–11 link #1, 12–19 link #2.
- **Front doors, all working on the bench:**
  - Pmods JB/JC (I2S2);
  - **USB device mode** on the Type-C port: link #1 (`FPGAmixerLink`), UAC2 gadget + `fpgamixer-usb-bridge`, which steers the host's clock through the feedback endpoint. The host sees **"StudioRunner USB"**. Works on the Mac and, since 2026-09-30, on **Windows** (in-box UAC2 driver).
  - **AVB:** link #2 (`FPGAmixerLink2`) + `fpgamixer-avb-bridge` (AAF, 8 ch each way) + our own AVDECC entity. The Mac sees **"StudioRunner AVB"**; audio heard both ways.
- **Clocks:** `mclk` is locked to gPTP (`fpgamixer-mediaclock`); ptp4l + phc2sys (`step_threshold 1.0`); no ETF, no timesyncd (Phase 10 findings).
- **Current image:** `build/sd/p10e-names-20260930.wic.xz`.

## The goal (the user's words, 2026-09-30)

"My goal is to plug my USB interface into the board, and be able to access it from either my mac or PC through the board."

**Reading to confirm with the user in the proposal (don't assume):** the interface's inputs and outputs become channels of the mixer core, a third front door. The Mac or PC then reaches them through the existing front doors (USB device mode or AVB), routed by the matrix. That fits the architecture: no pass-through of the interface's USB to the host, which USB can't do anyway, since the board is a host on one port and a device on the other. Ask the user which interface it is: channel counts, rates, class-compliant UAC2 or not.

## What's already decided or known about host mode

- `docs/phase8_status_2026-09-25.md` **§9.1–9.2**: host mode was decided in Phase 8 (user decision 1: "device mode, and also host mode") and scoped as step **P8.8**, never scheduled until now.
  - **USB1** (MIO 64–75) → the USB2513B hub → **2 × Type-A** + the Mini PCIe slot. It's a separate controller from USB0 (Type-C, device mode), so both work **at the same time**, with no role switching. `&dwc3_1 { dr_mode = "host"; }` is already in `system-user.dtsi`.
  - `CONFIG_SND_USB_AUDIO=y` was noted as already in the kernel: **re-check** on the current image.
  - **Clocking is the main difference from device mode:** a USB interface runs on its own clock and the board can't steer it, so the host-mode bridge has to **resample** (or servo a resampler) between the interface's card and the link's card (`mclk` time). Phase 8 §9.2 and its table of options (alsaloop `-S`, our own) are the starting point. `bridge_core` (shared by the USB and AVB bridges) has a pluggable `bridge_servo`; a resampling servo would plug in there.
  - **Core size:** a third 8-channel link makes the core 28 × 28. The time-shared core scales by lanes (`matrix_lanes(N, N)`): check the DSP and cycle budget (256 cycles per frame) and the address map. The P9.5 link #2 work (§6.8–6.11 of the Phase 9 status doc) is the template for adding a link: `pcm_link` instance, formatter, card name in the DT, stat window.
- **Modularity (non-negotiable):** the host-mode front door converts to and from the PCM contract and does nothing else. The core never sees the interface's clock.

## Read first, in this order

1. `docs/architecture_modules.md`: the rules (module kinds, the PCM contract §2 / §2.1, the coefficient contract §3, windows and the address map §4.1, the file map §1.1).
2. `docs/phase8_status_2026-09-25.md`: link #1, the ALSA card, the USB bridge; **§9.1–9.2 for host mode**.
3. `docs/phase9_status_2026-09-26.md`: §6.8–6.11 (adding link #2 and growing the core), §6.15–6.16 (`bridge_core`).
4. `docs/phase10_status_2026-09-29.md`: the most recent work and its bench lessons (§11–§14).
5. Your memory directory (`MEMORY.md`).

## How this user works (non-negotiable)

- **Proposal → user decisions → small verified steps**, each committed on its own, with the status doc updated in the same step (what, why, how verified, open items). Report what was **measured**, and say what wasn't. Start a new status doc for this phase.
- **Modularity first.** Say which seam a change plugs into; if none fits, propose the seam first. Keep `architecture_modules.md` current.
- **The user runs all board, Mac and PC commands.** Give short numbered steps, one command per code block, and say where each goes.
- **Diagnose from evidence** (logs, captures, source) **before suggesting resets or restarts**. The user called out guessing in Phase 10.
- **Lean bench verification:** the minimum check that proves the point; by-ear tests for content; board Python is minimal (no extra modules).
- **Verify every edit** with the Edit/Write tools, not heredoc or Python rewrite scripts. Python's text mode on Windows writes CRLF; if a script did edit a file, restore LF. Grep for the change; `git show --stat` after committing.
- Commit on the branch with the attribution trailer. Don't switch the user's checkout. Never put `sudo` in background jobs.

## Bench and tooling facts (as of 2026-09-30)

- **Board access:** the Pi is disconnected. The board is on the Mac's OWC Thunderbolt Ethernet adapter (en15, 10.0.0.1), and reached with `ssh amd-edf@10.0.0.2` **from the Mac's Terminal**; the user pastes the output. If the Mac's adapter loses its IP: `sudo networksetup -setmanual "Thunderbolt Ethernet Slot 0" 10.0.0.1 255.255.255.0`.
- **Audio:** mono cables on the Pmods, so **only JB-L (out 0) and JC-L (out 2) are heard**. Routing to the Pmods (not saved across reboots): `sudo python3 /usr/lib/fpgamixer/mixer_hw.py set <out> <in> 0`, e.g. link #1 in 4 → out 0, AVB in 12 → out 0, 13 → out 2.
- **Services:** `fpgamixer-osc`, `-usb-gadget`, `-usb-bridge`, `-ptp4l`, `-phc2sys`, `-mediaclock`, `-avb-net`, `-avb-bridge`, `-avb-entity`. `pmc` needs `-f /etc/fpgamixer/gptp.cfg`.
- **Yocto-only changes:** `scripts/sync_buildhost.sh`, then on the VM a detached copy of `~/edf/logs/p10e-build.sh` (`sed s/p10e/<tag>/`), launched with `nohup setsid … &`. Then check the rootfs contents you changed, and copy the `.wic.xz` to `build/sd/<name>.wic.xz` with its MD5 checked on both ends. **FPGA changes** (a third link): the full chain in `docs/prompt_phase9_p95.md` ("Build chain"): Vivado project + build, sdtgen, copy to the VM `~/edf/sdt`, `gen-machine-conf`; check that `psu_init` is unchanged and the DTB nodes are right.
- **The build VM (`ssh edfvm`) is sometimes stopped by the user** to free memory. If SSH times out, say so and ask.

## Open items carried over (not this phase's job unless the user says so)

- The Mac connecting two talker streams to our single listener; the Mac's periodic AVB asserts.
- P9.7 checks (60-min log, round trip) and the P9.8 soak.
- Re-running `fpgamixer-avb-net` by hand while ptp4l runs disturbs gPTP (restart ptp4l after it).
