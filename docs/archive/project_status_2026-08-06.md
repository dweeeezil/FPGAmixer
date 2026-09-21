# FPGAmixer — Project Status

**Date:** August 6, 2026
**Current phase:** Phase 2 complete and hardware-validated. Ready to begin Phase 3.

---

## Purpose of this document

Two audiences: (1) someone picking up the project fresh who needs to know
where things stand, and (2) an LLM starting a new chat that needs enough
context to be useful without re-plowing old ground. If you're the first,
read straight through. If you're the second, this plus the two architecture
docs in `docs/` should be enough to get started on Phase 3.

Related documents:
- `docs/FPGA Network Audio Device.md` — original project vision and goals
- `docs/FPGAmixer_Architecture_Roadmap.md` — full phased build plan through Phase 10
- `docs/phase1_i2s_loopback.md` — Phase 1 specifics
- `docs/phase2_i2s_pcm.md` — Phase 2 specifics

---

## What the project is

A network-based digital matrix mixer built on the Digilent Arty Z7-20
(Zynq-7000). Audio flows in from three source types (analog via Pmod I2S2,
USB, and network AVB), gets normalized to PCM internally, passes through a
three-layer DSP/matrix core (input DSP → bus matrix → bus DSP → output matrix
→ output DSP), and flows back out to the same three sink types. Controlled
from a macOS app over OSC/TCP, with parameters that persist across power
cycles.

See `FPGAmixer_Architecture_Roadmap.md` section 1 for the full framing.

---

## What's built

### Phase 1 — I2S loopback (complete)

A minimal PL-only design that generates the three I2S clocks (MCLK, SCLK,
LRCK) from the Arty Z7's 125 MHz system clock via an MMCM, drives them to
both sides of a Pmod I2S2 on JA, and wires the ADC's serial data output
directly to the DAC's serial data input as a combinational passthrough.
No Zynq PS involvement.

Files: `src/rtl/phase1_top.sv`, `src/rtl/i2s_clock_divider.sv`,
`constraints/phase1_arty_z7.xdc`.

Hardware-validated: audio round-tripped through Line In → Line Out cleanly.

### Phase 2 — I2S ↔ PCM ↔ I2S round-trip (complete)

Same audible behavior as Phase 1, but the FPGA now deserializes the ADC's
I2S bit stream into a parallel 24-bit stereo PCM sample per frame, then
reserializes back to the DAC. Introduces one frame (~21 µs at ~48 kHz) of
latency, which is inaudible.

The receiver and transmitter both run entirely in the MCLK domain, treating
SCLK and LRCK as sampled signals with edges detected by 2FF-registered
comparison. This avoids clock-domain-crossing complexity and keeps timing
analysis clean. Standard Philips I2S timing: LRCK 0 = left, 1 = right,
data changes on falling SCLK, one delay bit between LRCK transition and MSB.
The one-frame latency emerges naturally from non-blocking assignment
semantics — the transmitter reads L/R registers at the same LRCK edge the
receiver latches to them, so it serializes the previous frame's data.

Also added in Phase 2: a proper `reset_sync` module (async-assert /
sync-deassert 2FF synchronizer) replacing Phase 1's direct use of the MMCM's
`locked` signal as a reset.

Files added: `src/rtl/i2s_receiver.sv`, `src/rtl/i2s_transmitter.sv`,
`src/rtl/reset_sync.sv`, `src/rtl/phase2_top.sv`.

Hardware-validated: audio round-trip works with correct channel assignment
(no L/R swap) and correct levels. Loopback quality is subjectively identical
to Phase 1, which is the intended result.

---

## Known issues

### Simulation infrastructure never worked

Phase 2 was intended to be validated with XSim testbenches
(`src/sim/tb_i2s_receiver.sv`, `tb_i2s_transmitter.sv`, `tb_i2s_loopback.sv`)
before touching hardware. Getting Vivado's simulation flow to work in
Vivado 2026.1 didn't succeed during this session — a combination of the TCL
script not adding sim files reliably, confusion about how `restart` vs
`launch_simulation` work in the XSim GUI, and my guidance being speculative
about Vivado GUI behaviors I couldn't verify. The testbench source files
exist in `src/sim/` and are believed correct in shape, but none were
successfully executed end-to-end.

The RTL turned out to be correct anyway (verified on hardware), but this is
a hole that will get more expensive as later phases add DSP and matrix
logic where bugs are harder to characterize by ear. Before Phase 3 goes
deep, the simulation flow needs to be gotten working — either XSim with a
human who has done this before, or an external simulator (Verilator,
ModelSim/QuestaSim) that we drive from the command line and can trust more.

### DC power supply is unreliable

Physical power delivery to the board is not consistent. Workarounds
currently in use: gaff tape to hold connections in place, and USB power as
an alternate supply path. Both are fine for bring-up but will not be
acceptable once real audio work is happening — a loose power connection
during a mix session would be a serious problem. A proper solution
(new/replacement supply, or a more robust connector) should be sourced
before the mixer is put in front of anything that matters.

### MCLK is ~12.5 MHz, not exactly 12.288 MHz

The Arty Z7's 125 MHz sysclk doesn't divide cleanly to 12.288 MHz through
the MMCM. The Clocking Wizard picks the closest fractional divider
combination — typically landing within ~0.02% of the target — but the
actual sample rate is not exactly 48 kHz. The Cirrus CS5343/CS4344 don't
care (they derive everything from MCLK), so audio quality is unaffected.

This becomes a real problem for USB audio (Phase 8) and network AVB
(Phase 9), which require true 48 kHz. The two known solutions are: use the
Zynq PS's fractional PLLs via `FCLK` (gets much closer, but requires the PS
to be up), or add an external audio-grade oscillator. Decision deferred to
those phases.

### No output timing constraints on Pmod pins

The XDC declares pin locations and the input clock, but does not include
`set_output_delay` constraints for the MCLK/SCLK/LRCK/SDIN outputs to the
Pmod. At ~12 MHz clock rate with hundreds of nanoseconds of slack, this is
not currently a problem, but should be added if any future phase uses
higher clock rates or if timing anomalies show up.

### Known dead-ends inherited from the roadmap

- **Zynq-7000 PS PTP** is documented by AMD as unreliable under normal
  traffic (non-latching timestamp register). Not fixable in software. The
  planned workaround is to move the AVB endpoint role to the Raspberry Pi 5
  + Intel I350 in Phase 9.
- **USB device mode is not supported on the Arty Z7-20**, per Digilent's
  reference manual. The board's single USB port is host-only. USB audio in
  Phase 8 will be the FPGA acting as a USB host to an external
  class-compliant audio interface, not as a USB soundcard.

See `FPGAmixer_Architecture_Roadmap.md` sections 2 and 4 for the full
analysis of both.

---

## Repo structure and tooling

```
FPGAmixer/
├── docs/                          Design docs, per-phase notes, status
├── scripts/
│   ├── create_project.tcl         Regenerates Vivado project from sources
│   └── run_sim.tcl                Batch simulation runner (currently unverified)
├── src/
│   ├── rtl/                       Synthesizable HDL
│   └── sim/                       Testbenches (currently unverified)
├── constraints/                   XDC pin/timing constraints
└── vivado_project/                (gitignored) generated by create_project.tcl
```

The Vivado project directory is deliberately not committed. The TCL script
in `scripts/create_project.tcl` is the source of truth — running it
regenerates a working project from the RTL, XDC, and IP configuration.
Vivado version: 2026.1.

To bring up a fresh project on a new machine:

```
git clone https://github.com/dweeeezil/FPGAmixer.git
cd FPGAmixer
vivado -source scripts/create_project.tcl
```

Requires the Digilent board files installed so `Arty-Z7-20` appears in the
board picker.

---

## Hardware setup currently in use

- Digilent Arty Z7-20 (XC7Z020)
- One Digilent Pmod I2S2 on JA (JP1 jumper in SLV position for Phase 1/2)
- Second Pmod I2S2 on JB, physically present but not yet driven — comes
  online in Phase 3 for the 4-in/4-out matrix
- Not yet in play: OWC Thunderbolt 10G adapter, Raspberry Pi 5 with
  Intel I350-T4V2 (both queued for Phase 9)

---

## What's next: Phase 3

Per `FPGAmixer_Architecture_Roadmap.md` section 3, Phase 3 is the **static
PCM matrix mixer**. The scope:

- N-in / N-out matrix (initially N=4, since both Pmods will be active
  giving four ADC channels in and four DAC channels out)
- Crosspoint gains fixed at compile time — no runtime control yet, that
  comes in Phase 5
- Signal flow: four `i2s_receiver` instances → matrix → four
  `i2s_transmitter` instances
- JB comes online. XDC needs new pin assignments for the second Pmod.

The audible test at the end of Phase 3 is that any input can be routed to
any output by rebuilding the design with different compile-time gain
constants. Still no DSP, no dynamic control, no PetaLinux — those follow
in later phases per the roadmap.

Before starting Phase 3 implementation, the simulation flow should get
sorted out. Phase 3 is the first phase with real signal manipulation (gain
multiplies, summing across crosspoints, saturation handling), and hearing
"it sounds wrong" is a much worse way to find fixed-point bugs than seeing
them in a waveform.

---

## Context for continuation

Two things worth carrying forward into any new session on this project:

1. **The planning-first approach has been working.** Phase 1 took about an
   hour on this attempt vs. over a week on previous attempts, largely
   because the roadmap doc removed scope debate from implementation time.
   Phase 2 similarly benefited from having the module boundaries and
   timing assumptions written down before any RTL was drafted. Continue
   this at each phase boundary.

2. **Trust hardware over speculation.** The simulation attempt in Phase 2
   consumed significant time on Vivado GUI/Tcl behaviors that turned out
   to be either wrong or inconsistent between machines. When guidance
   feels speculative and the setup isn't working, going straight to
   hardware is a legitimate call — as it was here. Get sim working before
   Phase 3 goes deep, but don't let sim setup become the project.
