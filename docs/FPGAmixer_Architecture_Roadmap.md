# FPGAmixer — architecture scoping & build roadmap (restart)

**Date:** August 4, 2026 (originally); revised September 21, 2026 for the board switch below
**Hardware:** Digilent Genesys ZU3EG (Zynq UltraScale+ MPSoC), 2x Pmod I2S AD/DA, OWC Thunderbolt 10G (Mac AVB), RPi5 + Intel I350-T4V2

**Board status:** Development moved from the Arty Z7-20 (Zynq-7000) to the Genesys ZU3EG (Zynq UltraScale+). Phases 0–3 (I2S loopback through the static PCM matrix, including the pin-phase-race fix) have reached parity on the new board — same hardware-validated functionality the Arty Z7-20 had. All phase numbering and exit criteria below carry over unchanged; only the silicon underneath changed. **PetaLinux bring-up (Phase 4) is the next step.**

One consequence of the board switch worth flagging up front: the Zynq UltraScale+ PS GEM has a genuine hardware 1588 timestamp queue, unlike the Zynq-7000's non-latching register (see revised Decision 2). That changes the PTP story for AVB and is a big part of why network audio now looks tractable directly on this board.

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

---

## 2. Key decisions

These are the calls that actually shape the roadmap. I'm giving a recommendation on each — push back on any of them.

### Decision 1 — Network audio protocol scope for v1

Your notes frame this as "AVB vs Milan," but Milan isn't an alternative to AVB — it's an AVnu Alliance interoperability profile *built on* AVB (802.1AS gPTP + IEEE 1722 streaming + IEEE 1722.1 AVDECC discovery, with stricter conformance requirements). So "AVB vs Milan" isn't really the axis that determines difficulty. The axis that matters is: **do you implement just clock sync + streaming, or clock sync + streaming + full AVDECC discovery + Milan conformance?**

**Recommendation:** for v1, do gPTP sync + minimal IEEE 1722 (AAF-style) streaming with static, hardcoded stream connections. Skip 1722.1 AVDECC discovery/enumeration entirely at first. AVDECC is a large, separate control-plane project (device discovery, connection management) that's orthogonal to whether audio flows and stays in sync — bolt it on later if you actually want the device to show up automatically in tools like Hive Controller or talk to certified Milan gear at work.

### Decision 2 — PTP / timestamping strategy — **revised for the Genesys ZU3EG**

This used to be "the crux of where the pain begins," and the original analysis is worth keeping for the record:

**On the Zynq-7000 (Arty Z7-20, no longer the target board):** the GEM's 1588 timestamp capture register is non-latching — a new PTP event packet overwrites it before software can reliably read it, so there's no dependable way to associate a timestamp with the packet that produced it. AMD's driver docs state there is effectively no usable 1588/PTP support on Zynq-7000 for this reason.

**On the Zynq UltraScale+ (Genesys ZU3EG, the current board):** AMD's own documentation is explicit that this is fixed — the UltraScale+ GEM has a real hardware timestamp queue, not the non-latching register the Zynq-7000 has. That means the option the original roadmap ruled out (**Option A: timestamp directly against the PS GEM**) is now plausible as the primary path, instead of needing to hand PTP/AVB duties off to the RPi5 + I350.

Revised options, in current priority order:

| Option | What it means | Verdict on Genesys ZU3EG |
|---|---|---|
| **A. Timestamp directly against the PS GEM (`linuxptp` + `igb`-class UltraScale+ driver, under PetaLinux)** | Native gPTP endpoint on the mixer itself, using the hardware timestamp queue the Zynq-7000 lacked | **New v1 candidate** — needs a short confirmation spike (below) before committing, but the documented blocker that ruled this out on the old board is gone |
| B. Add a real PL-fabric MAC + PHY with hardware 1588 capture | The old "technically correct fix" for boards without PS-level timestamp support | No longer needed as the primary path — Option A should cover the same requirement natively, assuming the confirmation spike checks out |
| C. Move the "real AVB endpoint" job onto the RPi5 + I350 | Let the Pi5 terminate gPTP and the AVB network, hand audio to the mixer over a simple point-to-point link | **Kept as fallback**, not the primary plan — worth having in reserve if Option A's spike turns up a UltraScale+-specific gotcha, but no longer the default given the board switch |

**Open item — confirm before Phase 5 depends on it:** the Zynq-7000 finding was confirmed directly from AMD documentation; the Zynq UltraScale+ GEM's *general* hardware-timestamp capability is well documented, but this hasn't yet been verified specifically against the Genesys ZU3EG's Ethernet PHY wiring (how RGMII/timestamp signals actually reach the PS on this board) or against real gPTP traffic patterns (consecutive event packets, short sync intervals) the way the Zynq-7000 finding was. Treat Option A as the working plan, not a settled fact, until that spike runs — see §5 Immediate next steps.

### Decision 3 — USB audio — **needs re-verification on the new board**

The original finding here — Arty Z7's single PS USB port is host-only, device/OTG mode unsupported per Digilent's reference manual, so build against **(b) Arty Z7 as USB host** with PetaLinux's `snd-usb-audio` — was specific to that board's USB wiring. It has **not** been re-checked against the Genesys ZU3EG's USB implementation, which may differ. Don't assume either way; confirm against Digilent's Genesys ZU3EG reference manual before Phase 9 depends on it. Until then, assume the same host-mode plan carries over, since it was the recommended path even where device mode was available (simpler, no custom USB device-class gateware needed).

Clock domain note either way: a plugged-in USB interface still runs on its own clock, independent of your FPGA's fixed audio clock. You still need an elastic buffer + rate estimation (ALSA handles a version of this itself) to bridge domains — same category of problem as network audio, just solved in Linux/ALSA rather than in gateware.

### Decision 4 — Control protocol

No changes recommended here — TCP OSC with echo-confirmation, optional UDP receive-only path, and a JSON-driven parameter store that all DSP/matrix stages read from is a solid design as specified. The main implication for sequencing: build the parameter store once, and have every stage (crosspoints, DSP, and now AVB stream connections) read from it — that's what makes persistence "just work" for everything, including network routing, instead of needing its own save/restore logic per feature.

---

## 3. Build roadmap

Phases 0–3 are unchanged and now validated on the Genesys ZU3EG (parity with the Arty Z7-20 build). The sequencing from Phase 4 on reflects the priority shift: **get PetaLinux running, then get network audio (AVB) flowing as a source/sink, then build OSC control on top of a system that already has something worth controlling — matrix crosspoints *and* AVB stream connections together — rather than wiring up dynamic control before there's a second front door to control.** AVB needs PetaLinux underneath it regardless (the gPTP daemon and IEEE 1722 streaming run in Linux userspace, per revised Decision 2), which is the other reason it can't move ahead of Phase 4. DSP and USB stay after the OSC/persistence checkpoint, same rationale as before: they only depend on the core (and, for DSP, the control path) working, not on each other.

| Phase | Goal | Key tasks | Exit criteria |
|---|---|---|---|
| 0 | Repo & tooling | Set up version control, build scripts | Clean environment to build in |
| 1 | I2S loopback | Vivado-only, one Pmod in → one Pmod out, no reformatting | Audio passes through unmodified |
| 2 | I2S ↔ PCM conversion | i2s rx → PCM → i2s tx, still loopback | Same audio, now through PCM in the middle |
| 3 | Static PCM matrix | N-in/N-out matrix, crosspoints fixed at compile time | Can route any input to any output by rebuilding |
| — | **Checkpoint** | Working (if inflexible) hardware router, hardware-validated on the Genesys ZU3EG — parity with the prior Arty Z7-20 build. | |
| **4** | **PetaLinux bring-up** | **Boot Linux on the Genesys ZU3EG's PS** | **Stable boot, can reach the board over UART/network** |
| 5 | Network audio (AVB) | Per revised Decision 1–2: native gPTP (`linuxptp`) + minimal IEEE 1722 (AAF) streaming directly on the ZU3EG's PS GEM under PetaLinux, static hardcoded stream connections, no AVDECC yet. Fall back to Pi5+I350 (old Option C) only if the PTP confirmation spike rules out native timestamping. | Network audio flows in sync, as a source/sink like any other |
| 6 | Dynamic control | UDP OSC (write-to-memory), then TCP OSC server with echo-confirm — controls matrix crosspoints *and* AVB stream connections | Crosspoints and AVB routing changeable live from your Mac app |
| 7 | Parameter persistence | Save-on-change, auto-load on boot, single param store used everywhere (matrix, AVB, later DSP) | Power-cycle survives with routing intact |
| — | **Checkpoint** | Complete, useful matrix mixer with I2S and network audio, saved state, controllable from your macOS app — a legitimate v1 on its own. | |
| 8 | DSP implementation | EQ, dynamics, delay — validate with hardcoded parameters first, then wire into the same OSC/param path as the matrix | Per-channel/bus processing works and is controllable |
| 9 | USB audio (host mode) | ALSA `snd-usb-audio` capture/playback bridged into the PCM matrix as another source/sink; elastic buffer for clock bridging — pending Decision 3 re-verification on the ZU3EG | A plugged-in USB interface behaves like any other input/output |
| 10 (stretch) | Full Milan / AVDECC compliance | 1722.1 discovery, conformance testing against real Milan gear; revisit Option B (PL-fabric hardware timestamping) only if native PS-GEM timestamping (Option A) turns out insufficient | Only pursue if real interop with commercial gear is a hard requirement |

---

## 4. Risks & open items to revisit

- **Genesys ZU3EG PS-GEM PTP confirmation spike** — the Zynq-7000 non-latching-register blocker is gone on UltraScale+ per AMD's documentation, but this hasn't been verified against this specific board's PHY wiring or under real gPTP traffic. Run this before Phase 5 leans on it. This replaces the old "RPi5 + I350 Milan/gPTP maturity" spike as the primary gate — RPi5+I350 is now the fallback (Option C), not the default plan.
- **USB mode on the Genesys ZU3EG is unconfirmed** — the Arty Z7's host-only USB finding doesn't automatically carry over; re-check against Digilent's Genesys ZU3EG reference manual before Phase 9.
- **Milan/AVDECC conformance is its own project** — scope it only if interop with your work's Milan devices is a real goal, not a nice-to-have.
- **No Icarus-simulatable path for AVB/PTP** — same category of limitation the codec-timing handoff (`docs/handoff_codec_interface_timing.md`) called out for pin-level timing: gPTP sync accuracy and IEEE 1722 stream timing are validated on hardware, not in the functional sim.

## 5. Immediate next steps

1. Start Phase 4: PetaLinux bring-up on the Genesys ZU3EG (boot, confirm reachability over UART/network).
2. Once Linux is up, run the PS-GEM PTP confirmation spike (`linuxptp` against the UltraScale+ GEM driver) before Phase 5 depends on it — this is the gate for whether Option A (native on-chip AVB) or Option C (RPi5+I350 fallback) is the real Phase 5 plan.
3. Re-check the Decision 3 USB finding against the Genesys ZU3EG's actual USB wiring — don't assume the Arty Z7's host-only limitation carries over unverified.
4. Keep `docs/handoff_codec_interface_timing.md` in mind once ODDR/pin-delay work resumes — that work targeted the Arty Z7-20's XDC; the same ODDR-forwarding rationale applies on the Genesys ZU3EG but the pin constraints will need to be redone against its own XDC.
