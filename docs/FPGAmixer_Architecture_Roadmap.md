# FPGAmixer — architecture scoping & build roadmap

**Date:** September 15, 2026
**Hardware:** Genesys ZU-3EG (Zynq UltraScale+ MPSoC, XCZU3EG-SFVC784), 2× Pmod I2S2 AD/DA (removed in Phase 11, 2026-10-07: a MOTU M2 on the USB host port took their place), RPi5 + Intel I350-T4V2 (optional network endpoint)

> **Board migration note (Sept 2026):** the project has moved from the Arty
> Z7-20 (Zynq-7000) to the **Genesys ZU-3EG** (Zynq UltraScale+ MPSoC). The
> driving reason is network audio: the Zynq-7000's Ethernet MAC could not do
> usable IEEE-1588/PTP hardware timestamping (see Decision 2), which is the one
> capability AVB/gPTP hinges on. The UltraScale+ GEM fixes exactly that. Two
> earlier hardware dead-ends (no PS PTP, USB host-only) are resolved on this
> board, so Decisions 2 and 3 below have been re-opened in the project's
> favour. The Arty-era version of this document is preserved at
> `docs/archive/FPGAmixer_Architecture_Roadmap_arty_z7.md`, and the Arty-era
> reports, datasheets, and per-phase notes now live under `docs/archive/`.

---

## 1. What's actually being built

A network-based digital matrix mixer: N audio sources → 3-layer DSP/matrix core → N audio sinks, all normalized to PCM internally, controlled over OSC/TCP from a macOS app, with parameters that survive a power cycle. Sources/sinks are I2S (analog, via Pmod), USB (via a class-compliant interface), and network (AVB).

The most useful framing for scoping this: **the core (matrix + DSP + control + persistence) is one system, and I2S/USB/network are three interchangeable "front doors" into it.** Once the core works with the easiest front door (I2S, which is already clock-synchronous with your FPGA fabric), adding USB and network mostly means solving "how do I bridge this source's clock domain into my fixed internal clock domain" — that's the one hard sub-problem shared by both, not something specific to either protocol.

```
 I2S in    USB in (host)   Network in
    │            │              │
    └────────────┼──────────────┘
                 ▼
            Input DSP  (EQ, dynamics, level — per channel)
                 ▼
            Bus matrix (inputs → bus routing)
                 ▼
             Bus DSP   (EQ, dynamics, delay, level — per bus)
                 ▼
           Output matrix (bus → output routing)
                 ▼
            Output DSP (EQ, dynamics, level — per channel)
                 │
    ┌────────────┼──────────────┐
    ▼            ▼              ▼
 I2S out   USB out (host)  Network out

   (OSC/TCP control + persisted parameter store sit alongside
    the whole core — every DSP/matrix stage reads its parameters
    from the same store, which is what gets saved/restored.)
```

The core (Phases 1–3) is board-agnostic synthesizable SystemVerilog; the migration touches the platform layer (part, board, clocking, pins, PetaLinux target arch), not the datapath.

---

## 2. Key decisions

These are the calls that actually shape the roadmap. I'm giving a recommendation on each — push back on any of them.

### Decision 1 — Network audio protocol scope for v1

Your notes frame this as "AVB vs Milan," but Milan isn't an alternative to AVB — it's an AVnu Alliance interoperability profile *built on* AVB (802.1AS gPTP + IEEE 1722 streaming + IEEE 1722.1 AVDECC discovery, with stricter conformance requirements). So "AVB vs Milan" isn't really the axis that determines difficulty. The axis that matters is: **do you implement just clock sync + streaming, or clock sync + streaming + full AVDECC discovery + Milan conformance?**

**Recommendation:** for v1, do gPTP sync + minimal IEEE 1722 (AAF-style) streaming with static, hardcoded stream connections. Skip 1722.1 AVDECC discovery/enumeration entirely at first. AVDECC is a large, separate control-plane project (device discovery, connection management) that's orthogonal to whether audio flows and stays in sync — bolt it on later if you actually want the device to show up automatically in tools like Hive Controller or talk to certified Milan gear at work.

What *has* changed with the board move: because the ZU-3EG can now terminate gPTP itself (Decision 2), a later full-Milan/AVDECC endpoint can live on the Zynq board directly rather than requiring separate timestamp-capable hardware. That makes Phase 10 a real option rather than a hardware-blocked stretch.

### Decision 2 — PTP / timestamping strategy — *resolved by the board change*

This was the crux of "where the pain begins," and it's the reason for the migration, so it's worth restating precisely.

**On the old Arty Z7-20 (Zynq-7000):** the GEM's 1588 timestamp capture register is *non-latching* — a new PTP event packet overwrites it before software can reliably read it, so there was no dependable way to associate a timestamp with the packet that produced it. AMD's own driver docs state there is effectively no usable 1588/PTP support on Zynq-7000 for this reason, and it's documented to fail specifically under normal gPTP traffic (consecutive event packets, short sync intervals). EMIO didn't help — it only re-routes the same non-latching PS peripheral's signals.

**On the Genesys ZU-3EG (Zynq UltraScale+ MPSoC):** this is fixed in silicon. The UltraScale+ GEM has real hardware timestamp support suitable for 802.1AS/1588. On this board the Gigabit Ethernet path is a **TI DP83867CR PHY → RGMII → PS GEM0** (MIO 26–37, MDIO on MIO 76–77, per Digilent's board preset; earlier notes here said GEM3, which was wrong), which is a standard, well-supported PetaLinux/`linuxptp` configuration.

**One trap, found and handled in Phase 4 (2026-09-22):** Digilent's board preset leaves the GEM time-stamp unit **off** (`PSU__ENET0__TSU__ENABLE = 0`, no `GEM_TSU` clock configured). The macb driver falls back to `pclk`'s rate when the device tree has no `tsu_clk`, so PTP would have come up running at the wrong rate instead of failing visibly. The PS config now enables it (IOPLL / 250 MHz), verified through the XSA and into the generated device tree. See `setup_edf_hyperv_vm.md` §8.

Revised options:

| Option | What it means | Verdict on Genesys ZU3EG |
|---|---|---|
| **A. Terminate gPTP on the ZU-3EG's own PS GEM** | `linuxptp` (ptp4l) against the Cadence GEM driver's hardware timestamping, over the on-board DP83867CR | **Recommended for v1** — this is the capability the board was chosen for; no extra hardware |
| B. PL-fabric MAC + 1588 timer (AXI Ethernet Subsystem) | Hardware timestamping in the PL instead of the PS | Only if you outgrow the PS GEM (e.g. want PTP on a second, PL-routed link); not needed for v1 |
| C. Offload the AVB endpoint to RPi5 + I350 | Pi5 terminates gPTP/AVB, hands audio to the mixer over a simpler link | **Now a fallback, not the plan** — keep as a de-risking option / bring-up reference while the on-board PTP path is stood up |

One honest caveat: "the GEM supports hardware timestamping" is a silicon/driver fact, but end-to-end gPTP grandmaster/slave behaviour against real Milan gear still needs a bench spike (`ptp4l` + a known-good gPTP peer) before Phase 9 leans on it. The Pi5 + I350 can serve as that known-good peer.

### Decision 3 — USB audio — *host-mode recommended, device-mode now on the table*

**On the old Arty Z7:** its single PS USB port was host-only ("USB OTG and USB device modes are not supported"), so "FPGA as a USB soundcard" was simply impossible without different hardware.

**On the Genesys ZU-3EG:** the USB Type-C port is USB 3.0/2.0 with **Dual-Role-Data and Dual-Role-Power**, and the MPSoC's USB controller supports device/OTG mode. So both builds are now physically possible:

- **(a) ZU-3EG as a USB audio device** — it enumerates on your Mac as a USB soundcard. **Now possible on this hardware** (was not on the Arty), via a UAC gadget (Linux `f_uac2`) on the PS, or PL-based USB device IP. This is a real sub-project (gadget descriptors, isochronous endpoints, feedback endpoint for rate matching) but no longer hardware-blocked.
- **(b) ZU-3EG as a USB host** — you plug a class-compliant USB audio interface into it, and PetaLinux's standard `snd-usb-audio` ALSA driver talks to it. **Simplest path**, no custom USB gateware/firmware — just bridging ALSA capture/playback into the PCM matrix.

**Recommendation:** still start with (b) for Phase 8 — it's the least work and gets USB audio flowing. Keep (a) as an explicit, separately-scoped follow-on now that the hardware supports it, if you want the box to present as a soundcard to the Mac.

Clock-domain note either way: a USB interface (or a USB host driving us as a device) runs on its own clock, independent of the FPGA's fixed audio clock. You still need an elastic buffer + rate estimation to bridge domains — the same category of problem as network audio, solved in Linux/ALSA (host mode) or in the UAC feedback endpoint (device mode).

### Decision 4 — Control protocol

No changes recommended here — TCP OSC with echo-confirmation, optional UDP receive-only path, and a JSON-driven parameter store that all DSP/matrix stages read from is a solid design as specified. The main implication for sequencing: build the parameter store once, and have every stage (crosspoints, DSP, and now AVB stream connections) read from it — that's what makes persistence "just work" for everything, including network routing, instead of needing its own save/restore logic per feature.

---

## 3. Build roadmap

Phases 0–3 are the board-agnostic RTL core and are **already hardware-verified on the Arty Z7** (static 4-in/4-out matrix, 2026-08-18). On the ZU-3EG they need a **re-bring-up on the new silicon** (Phase 3.5 below) before the SoC/software layers stack on top — same RTL, new part/clocking/pins.

| Phase | Goal | Key tasks | Exit criteria |
|---|---|---|---|
| 0 | Repo & tooling | Version control, build scripts, board/part migration | Clean environment to build in on the ZU-3EG |
| 1 | I2S loopback | Vivado-only, one Pmod in → one Pmod out, no reformatting | Audio passes through unmodified |
| 2 | I2S ↔ PCM conversion | i2s rx → PCM → i2s tx, still loopback | Same audio, now through PCM in the middle |
| 3 | Static PCM matrix | N-in/N-out matrix, crosspoints fixed at compile time | Can route any input to any output by rebuilding |
| **3.5** | **ZU-3EG re-bring-up** ✅ *done 2026-09-21* | Rebuild Phases 1–3 on the new part/board: 25 MHz PL clock → 12.288 MHz MMCM, Pmod pins on JB/JC, re-run STA (codec timing carries over unchanged), re-verify in silicon | Same static matrix, now proven on the ZU-3EG hardware. **Met:** audio loops back correctly; WNS +2.421 ns (RX sampling), WHS +0.034 ns, 0 failing endpoints |
| — | **Checkpoint** | You have a working (if inflexible) hardware router on the target board. Confirm it in silicon before adding SoC complexity. | |
| 4 ✅ *boots from SD 2026-09-24* | EDF/Yocto bring-up | Boot Linux on the PS (now aarch64 quad A53, not armv7); Ethernet up on the PS GEM0. PS block design → XSA → SDT → machine conf → image: all done and clean | Stable boot, reachable over UART/network |
| 5 ✅ *done 2026-09-25* | Dynamic control | UDP OSC (write-to-memory), then TCP OSC server with echo-confirm | Crosspoints changeable live over OSC. **Met:** AXI4-Lite gain registers with atomic commit; OSC suite 18/19 on hardware; routing changes heard on the Pmods (`phase5_status_2026-09-25.md`). The Mac app became a separate subproject; OSC is driven from TouchDesigner / Python / Ableton meanwhile |
| 6 ✅ *done 2026-09-25* | Parameter persistence | Save-on-change, auto-load on boot, single param store used everywhere | Power-cycle survives with routing intact. **Met:** crash-safe batched store, boot service, routing restored after a power pull (`phase6_status_2026-09-25.md`). Re-test with multichannel audio once USB/AVB exists |
| — | **Checkpoint** | A complete, useful 4-in/4-out analog matrix mixer with saved state, controllable from the macOS app — a legitimate v1 on its own. | |
| 7 🔶 *first slice done as Phase 12* | DSP implementation | EQ, dynamics, delay — validate with hardcoded parameters first, then wire into the same OSC/param path as the matrix | Per-channel/bus processing works and is controllable. **Levels on every input, bus and output are done (Phase 12).** Still to come: mute, EQ, dynamics, delay, gain smoothing, metering taps; the user plans a larger DSP module library |
| 8 🔶 *device mode done 2026-09-26; pulled ahead of Phase 7* | PS↔PL audio link + USB audio | **Decided 2026-09-25: device mode first (the Mac sees an 8 × 8 UAC2 soundcard), host mode as well** (a class-compliant interface on the Type-A ports, separate controller). Generic link: AMD Audio Formatter → ALSA card on `mclk` time → `pcm_link` front door → core 12 × 12. Clock bridging in the USB front door's Linux half: our bridge steers the Mac through the UAC2 feedback pitch, no resampling | **Device mode met:** Mac ↔ matrix both ways, clock-locked (48,016 frames/s, 0 underruns); power-cycle restore of all 144 crosspoints with audio (`phase8_status_2026-09-25.md`). Open: one 8 × 8 device on the Mac (`f_uac2` patch). Host mode became Phase 11 (the time-multiplexed core it needed was built in Phase 9) |
| 9 🔶 *P9.A, P9.1–P9.6 done 2026-09-28; P9.7 heard with the Mac in Phase 10* | Network audio | Per Decisions 1–2: **gPTP terminated on the ZU-3EG's own PS GEM** (`linuxptp`), static IEEE 1722 (AAF) streaming into the PCM matrix. **Proposal (`phase9_status_2026-09-26.md`):** a second PS↔PL link + an AVB front door (alsa-plugins AAF + libavtp, GEM hardware CBS), `mclk` disciplined to gPTP (the PL timestamps frames against the GEM TSU counter and steers the MMCM), and a time-multiplexed matrix (20 × 20 exceeds the DSP48E2 budget) | Network audio flows in sync, as a source/sink like any other. **Met for the core path:** time-shared 20 × 20 core, gPTP at boot (2–3 ns RMS), `mclk` steered onto gPTP, a second PS↔PL link, software CBS + AAF (`phase9_status_2026-09-26.md`). Open: P9.7 checks (60-min log, round trip), P9.8 soak, a multi-hop soak through an AVB switch |
| 10 🔶 *Mac audio both ways 2026-09-30* | The board as an AVB device (AVDECC + MSRP) | 1722.1 entity (ADP/AECP/ACMP), MSRP/MVRP, one 8-ch talker and listener; full Milan conformance remains a stretch | **The Mac lists the board as an AVB device and audio runs both ways** (`phase10_status_2026-09-29.md`). Open: a clean boot with no manual steps, two streams to one listener, P9.7/P9.8. Conformance against real Milan gear only if interop becomes a hard requirement |
| 11 🔶 *in progress since 2026-10-06* | USB host mode | A class-compliant interface (MOTU M2, 2 × 2) on the Type-A port as a third front door, a libsamplerate rate stage and ratio servo in the bridge (`phase11_status_2026-09-30.md`, H0–H6). **Changed 2026-10-07 (P1):** the Pmods are removed and the M2 takes their core channels 0–3 through link #3; the core stays 20 × 20 × 20 | The interface reachable from the Mac/PC through the board. **Met 2026-10-07 (H.4):** the Mac → the board → the M2's headphones by ear on link #3, with no Pmods, restored across power pulls. Open: H.5, a 60-min soak (servo settling). *(The old Phase 11, USB device mode, was merged into Phase 8.)* |
| — ✅ *done 2026-10-04* | Controller support (F1–F9) | The OSC server meets the StudioRunner app's contract: the merged standard, config reply, errors, ordering, ping, Bonjour, TCP framing (`controller_support_status_2026-10-04.md`) | **The app connects to the board.** Open: metering (F4 + gateware F4a), the F1–F9 checks on the board |
| 12 ✅ *done 2026-10-06* | Channel levels and the bus layer | Levels on every input, bus and output (`pcm_gain`), and inputs → input matrix → 20 buses → bus matrix → outputs, inside one frame (D = 249, 11 DSPs); four new register windows; five OSC zones (`phase12_status_2026-10-04.md`) | **Met:** the app's Inputs, Buses and Outputs tabs and both matrix tabs work on the board; old state files keep their meaning. The first slice of Phase 7 |
| 13 ✅ *done 2026-10-06* | Metering | Peak meters on the three level stages' outputs (`pcm_peak`, tap ports on `mixer_core`, windows 0x8000_9000–B000), the server's meter protocol (`mixer_meters`: subscribe, lease, UDP stream) (`phase13_status_2026-10-06.md`) | **Met:** the app's meters follow the audio on every channel tab. Controller F4 + F4a done |

---

## 4. Risks & open items to revisit

- ~~**On-board gPTP maturity spike**~~ **Done 2026-09-24, PASS** (`gptp_spike_2026-09-24.md`). The board runs gPTP against the RPi5 + I350 at **3–4 ns RMS, ≤22 ns worst** over one hop, as slave and as grandmaster. The agreed Phase 9 criterion is 1 µs end to end. It needed three fixes:
  - the DP83867 PHY node, so the TI driver binds instead of Generic PHY;
  - a fixed MAC;
  - an FPGA design fix: `emio_enet0_tsu_inc_ctrl` must be tied to `2'b11`. Left at `00`, the GEM TSU counted seconds on every clock and timestamps were garbage (UG1085 ch. 34).

  Still open: a multi-hop soak through an AVB switch in Phase 9, and reading the MAC from QSPI instead of hard-coding it.
- **12.288 MHz from a 25 MHz reference** — the ZU-3EG PL clock is 25 MHz (from the DP83867CR PHY), not the Arty's 125 MHz. 12.288 MHz is not an integer ratio of 25 MHz, so the MMCM uses a fractional solution; check the generated `clk_wiz_audio` summary for the actual output frequency and jitter, and confirm it's within codec tolerance. (A cleaner alternative is to source the audio clock from a PS PLL / fabric clock — worth considering during Phase 4.)
  - **Measured on 2026-09-21:** the MMCM uses 25 MHz × 40.625 ÷ 82.625, which gives **12.2919 MHz**. That's about **+324 ppm** high, so Fs ≈ 48.016 kHz. The MMCM's jitter figure is 409 ps pk-pk. The codecs are fine with this, and analog-only routing doesn't care because every I2S port shares the one clock. **It does matter for Phases 8–9.** AVB (and any AES67/USB peer) expects 48.000 kHz locked to the network's media clock. A free-running +324 ppm local clock would slip about 16 samples per second against a network stream. Phase 9 therefore needs one of two things: a media clock that can be steered from the gPTP/1722 timing, or an asynchronous sample-rate converter at the network boundary. Decide this with the Phase 4 audio-clock choice. A fixed PS-derived clock alone doesn't solve it.
- **Codec timing carries over, but re-run STA** — the ODDR-forwarding + multicycle constraints are board-independent (same 12.288 MHz mclk / ÷4 sclk tree) and were copied verbatim into the ZU-3EG XDC. But routing and IO characteristics differ on UltraScale+, so re-read the RX-sampling WNS razor (the intentional ~+2 ns check) after the first ZU-3EG implementation, don't assume the Arty margins.
- **Pmod remap** — the ZU-3EG's **Pmod JA is the analog XADC Pmod** (LVCMOS18, RC-filtered), unusable for the 3.3 V I2S2, so the two modules moved to the digital Pmods **JB and JC** (JD spare). The RTL ports were renamed to match the silkscreen: `jb_*` (module #1) and `jc_*` (module #2).
- **10G is not on the 3EG** — the 10G SFP+ is a 5EV-only feature; the 3EG's Ethernet is Gigabit (10/100/1000). Gigabit is ample for AVB, but note it if bandwidth assumptions from earlier notes creep back in.
- **Milan/AVDECC conformance is its own project** — scope it (Phase 10) only if interop with your work's Milan devices is a real goal, not a nice-to-have.
- **USB device mode is a distinct sub-project** — now possible (Phase 11) but not free; isochronous + feedback-endpoint rate matching is the hard part.

## 5. Immediate next steps

1. ~~Finish the board/tooling migration~~ Done.
2. ~~Phase 3.5: re-verify the static matrix in silicon~~ Done 2026-09-21. The EDF build host is ready too (`buildhost_status_2026-09-21.md`).
3. ~~Phase 4 build and first boot~~ Done: built 2026-09-22 (`phase4_status_2026-09-22.md`), and it boots from SD to a login prompt with `end0` up and hardware timestamping (`phase4_status_2026-09-24.md`). The DP83867 driver now binds and the MAC is stable (`gptp_spike_2026-09-24.md` §2).
4. ~~Bench spike: `ptp4l` on the ZU-3EG's PS GEM0 against a known-good gPTP peer~~ Done 2026-09-24, PASS against the 1 µs criterion: 3–4 ns RMS over one hop in both roles (`gptp_spike_2026-09-24.md`).
5. Confirm the audio-clock source decision. Phase 4 kept the fractional MMCM off the 25 MHz PL clock (+324 ppm, measured). A PS-sourced fixed clock would not fix that on its own — see the 12.288 MHz risk item above, which now frames this as "steerable media clock vs. ASRC at the network boundary" for Phase 9.
6. ~~Phases 5 and 6~~ Done 2026-09-25: live OSC control of the matrix, the D1–D4 modularity refactor (`architecture_modules.md`), and a persistent, boot-restored parameter store (`phase5_status_2026-09-25.md`, `phase6_status_2026-09-25.md`). **The first checkpoint is reached:** a 4-in/4-out analog matrix mixer with saved state, controllable over OSC.
7. ~~When the first multichannel front door (USB or AVB) works: repeat the power-cycle restore test with real multichannel audio on every crosspoint~~ Done 2026-09-26 with the USB front door: all 144 crosspoints restored exactly after a power pull, audio verified (`phase8_status_2026-09-25.md` §19).
8. ~~Phase 8 remainder, Phases 9, 10, controller support, 12~~ Done or mostly done, see the table. **Open as of 2026-10-06**, in no fixed order (the user picks):
   - ~~Metering~~ Done 2026-10-06 (Phase 13).
   - **Phase 11, USB host mode** (the MOTU M2 as the board's headphone/mic I/O), with the **Pmods removed** (`phase11_status_2026-09-30.md` §8): H.1–H.4 done 2026-10-07 (by ear on link #3, restore across power pulls); **H.5, the 60-min soak, open**.
   - **Then: snapshots → virtual groups → channel sources (I/O patching)**: dated plans in `docs/plans/`, bundled in `docs/prompt_phase14_qol.md`.
   - **The F1–F9 checks on the board** (controller-support step 8: `osc_mixer_test.py` from the Mac).
   - **AVB loose ends:** a clean boot with no manual steps, two streams to one listener, P9.7 checks, P9.8 soak, a multi-hop soak through a switch.
   - **Phase 7, the rest of the DSP:** mute, EQ, dynamics, delay, gain smoothing.
   - **Phase 8 remainder:** one 8 × 8 device on the Mac (`f_uac2` single clock source, a carried kernel patch).
   - Recorded, not scheduled: OSC aliases (`proposal_osc_aliases.md`); reading the MAC from QSPI instead of hard-coding it.
   - Housekeeping: `main` is at the Phase 8 merge; `phase9/time-shared-core`, `controller-support` and `phase12-levels-buses` are stacked on each other and unmerged.
