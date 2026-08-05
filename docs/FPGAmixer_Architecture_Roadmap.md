# FPGAmixer — architecture scoping & build roadmap (restart)

**Date:** August 4, 2026
**Hardware:** Arty Z7-20 (Zynq-7000), 2x Pmod I2S AD/DA, OWC Thunderbolt 10G (Mac AVB), RPi5 + Intel I350-T4V2

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

### Decision 2 — PTP / timestamping strategy on the Zynq-7000

This is the crux of "where the pain begins" in your original notes, and it's worth being precise about, because it determines whether the rest of the network-audio plan is viable as originally conceived.

**Confirmed (AMD's own documentation, not just your earlier testing):** the Zynq-7000 GEM's 1588 timestamp capture register is *non-latching* — a new PTP event packet overwrites it before software can reliably read it, so there's no dependable way to associate a timestamp with the packet that produced it. AMD's driver docs state plainly that there is effectively no usable 1588/PTP support on Zynq-7000 for this reason (it's fixed on Zynq UltraScale+ and Versal, which have real hardware timestamp queues). This isn't a rare edge case — it's documented to fail specifically under normal traffic patterns like consecutive PTP event packets or short sync intervals, which real gPTP traffic produces routinely.

This also explains why the EMIO route you explored before didn't pan out: EMIO just changes which physical pins the PS's Ethernet signals reach through — the timestamp capture hardware is still the same non-latching PS peripheral either way, so it doesn't fix the underlying limitation.

Three real options:

| Option | What it means | Verdict |
|---|---|---|
| A. Use the PS GEM anyway | Software-timestamp against the non-latching register | Don't build on this — it's documented to be unreliable, not just imprecise |
| B. Add a real PL-fabric MAC + PHY with hardware 1588 capture (e.g. AXI Ethernet Subsystem's 1588 timer) | The technically correct fix | Needs new hardware — the Arty Z7-20's only PHY is wired via RGMII straight to the PS's dedicated MIO pins; there's no second PHY broken out to PL fabric pins on this board |
| **C. Move the "real AVB endpoint" job onto the RPi5 + I350** | The I350 has genuine hardware PTP timestamp support (it's a common choice in real AVB/TSN reference builds). Let the Pi5 terminate gPTP and the actual AVB/Milan network, then hand audio to the Zynq mixer over a simple point-to-point link that doesn't need sample-accurate network timestamping at all | **Recommended for v1** — reuses hardware you already have, no board rework |

Option C repurposes the Pi5 from "network switch if needed" to "the thing that actually speaks AVB," with the Zynq mixer sitting downstream of it on a much easier link. Option B stays on the table as the eventual path if you want the Zynq board itself to be a first-class AVB endpoint someday.

One honest caveat: I'm confident in the non-latching-register finding since it's stated directly in AMD's documentation. I'm not certain how turnkey a Milan-capable stack is on RPi5 + I350 today — that's worth a short feasibility spike before committing to it as the backbone of the plan.

### Decision 3 — USB audio: this needs a correction, not just a decision

The Arty Z7 reference manual states this directly, in the USB section, twice: **"USB OTG and USB device modes are not supported."** The board's single PS USB port is wired as host-only — the VBUS/ID-pin sensing needed for device or OTG mode isn't present (the documented hardware mod adds host-qualifying capacitance, it doesn't add device support).

This matters because "USB audio device implementation" in your original roadmap is ambiguous between two very different builds:

- **(a) Arty Z7 as a USB audio device** — it appears to a computer as a USB soundcard. **Not supported on this hardware as-is.**
- **(b) Arty Z7 as a USB host** — you plug a class-compliant USB audio interface into it, and PetaLinux's standard ALSA USB-audio driver (`snd-usb-audio`) talks to it. **Fully supported**, and genuinely simpler than (a) would have been — no custom USB device-class gateware/firmware needed, just bridging ALSA capture/playback into your PCM matrix.

**Recommendation:** go with (b) — it's both the only option this hardware supports and considerably less work. If you actually wanted the FPGA box to present as a USB soundcard to your Mac, that's a different sub-project needing different hardware (a Zynq board with OTG/device support, or PL-based soft USB device IP) and is worth scoping separately rather than folding into this build.

Clock domain note either way: a plugged-in USB interface still runs on its own clock, independent of your FPGA's fixed audio clock. You still need an elastic buffer + rate estimation (ALSA handles a version of this itself) to bridge domains — same category of problem as network audio, just solved in Linux/ALSA rather than in gateware.

### Decision 4 — Control protocol

No changes recommended here — TCP OSC with echo-confirmation, optional UDP receive-only path, and a JSON-driven parameter store that all DSP/matrix stages read from is a solid design as specified. The main implication for sequencing: build the parameter store once, early, and have every stage (crosspoints, DSP) read from it — that's what makes persistence "just work" for everything added later instead of needing its own save/restore logic per feature.

---

## 3. Build roadmap

Phases 0–3 match your original draft closely — they were already well-sequenced (get audio moving in hardware before adding the SoC/software layer). The changes start after that: DSP moves earlier (it only depends on the core working, not on USB or network), and USB/network are reframed as parallel bolt-on sources rather than one blocking the other.

| Phase | Goal | Key tasks | Exit criteria |
|---|---|---|---|
| 0 | Repo & tooling | Set up version control, build scripts | Clean environment to build in |
| 1 | I2S loopback | Vivado-only, one Pmod in → one Pmod out, no reformatting | Audio passes through unmodified |
| 2 | I2S ↔ PCM conversion | i2s rx → PCM → i2s tx, still loopback | Same audio, now through PCM in the middle |
| 3 | Static PCM matrix | N-in/N-out matrix, crosspoints fixed at compile time | Can route any input to any output by rebuilding |
| — | **Checkpoint** | You have a working (if inflexible) hardware router. Confirm it in silicon before adding SoC complexity. | |
| 4 | PetaLinux bring-up | Boot Linux on the PS | Stable boot, can reach the board over UART/network |
| 5 | Dynamic control | UDP OSC (write-to-memory), then TCP OSC server with echo-confirm | Crosspoints changeable live from your Mac app |
| 6 | Parameter persistence | Save-on-change, auto-load on boot, single param store used everywhere | Power-cycle survives with routing intact |
| — | **Checkpoint** | This is a complete, useful 4-in/4-out analog matrix mixer with saved state, controllable from your macOS app — a legitimate v1 on its own. | |
| 7 | DSP implementation | EQ, dynamics, delay — validate with hardcoded parameters first, then wire into the same OSC/param path as the matrix | Per-channel/bus processing works and is controllable |
| 8 | USB audio (host mode) | ALSA `snd-usb-audio` capture/playback bridged into the PCM matrix as another source/sink; elastic buffer for clock bridging | A plugged-in USB interface behaves like any other input/output |
| 9 | Network audio | Per Decisions 1–2: Pi5+I350 as the real AVB/gPTP endpoint, static IEEE 1722 streaming into the Zynq mixer | Network audio flows in sync, as a source/sink like any other |
| 10 (stretch) | Full Milan / AVDECC compliance | 1722.1 discovery, conformance testing against real Milan gear; PL-based hardware timestamping on the Zynq itself if you decide the mixer needs to be a first-class AVB endpoint | Only pursue if real interop with commercial gear is a hard requirement |

---

## 4. Risks & open items to revisit

- **RPi5 + I350 Milan/gPTP maturity** — needs a short feasibility spike (e.g. `linuxptp` against the `igb` driver) before Phase 9 depends on it.
- **PS GEM PTP** — documented as unreliable under normal traffic, not just imprecise. Don't spend time trying to make it work for sync; it's a dead end on this silicon.
- **No second PL-routed PHY on the Arty Z7-20** — if Phase 10 ever needs a real hardware-timestamped AVB endpoint on the Zynq itself, that's new hardware, not just new gateware.
- **USB device mode is off the table** on this board — confirmed directly from Digilent's docs, not just inferred.
- **Milan/AVDECC conformance is its own project** — scope it only if interop with your work's Milan devices is a real goal, not a nice-to-have.

## 5. Immediate next steps

1. Finish repo/tooling setup (already in progress).
2. Quick spike: confirm `linuxptp` + the I350's hardware timestamp support work as expected on the RPi5, before Phase 9 leans on it.
3. Confirm the USB read in Decision 3 matches what you actually wanted — if you did want device mode, that's a separate scoping conversation.
4. Start Phase 1 (I2S loopback).
