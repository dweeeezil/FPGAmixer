# Phase 1 — Pmod I2S2 loopback on JA

## What this phase does

Takes stereo analog audio in one side of a Pmod I2S2 and pushes it straight
back out the other side. No FPGA-side processing at all — the ADC captures the
audio, produces I2S serial data, and the FPGA acts as a wire: it hands that
same serial data back to the DAC on the same Pmod.

The point isn't the audio effect (there isn't one). The point is to prove that
the electrical path, pin constraints, and clock generation are all working
before any RTL logic is added that could hide a bug.

## Signal path

```
   Line In jack
       │
       ▼
   CS5343 ADC ──────► SDOUT (pin 10, JA10, FPGA input W19)
                             │
                             │  combinational wire in fabric
                             ▼
   CS4344 DAC ◄────── SDIN  (pin 4,  JA4,  FPGA output Y17)
       │
       ▼
   Line Out jack

   FPGA also drives (broadcast to both chips):
       MCLK  ~12.288 MHz   (pins 1 and 7)
       SCLK  ~3.072 MHz    (pins 3 and 9)
       LRCK  ~48 kHz       (pins 2 and 8)
```

## Clocking

The Cirrus converters on the Pmod need three clocks in specific ratios:

| Clock | Frequency (48 kHz Fs) | Ratio          | Role                                        |
|-------|----------------------|-----------------|---------------------------------------------|
| MCLK  | 12.288 MHz           | 256 × Fs        | Chip master timing reference                |
| SCLK  | 3.072 MHz            | 64 × Fs         | Serial bit clock                            |
| LRCK  | 48 kHz               | 1 × Fs          | Left/right word select (frame marker)       |

Analogy for the three-clock hierarchy: MCLK is the crystal-oscillator
metronome the chip actually runs on internally. SCLK is the bit-shift tempo
for the serial line. LRCK is the beat marker that says "this next bit is the
MSB of a new sample" — and it toggles left/right to indicate which channel.

### 125 → 12.288 MHz

The Arty Z7's 125 MHz sysclk on H16 doesn't divide cleanly to 12.288 MHz, so
the MMCM approximates it. In practice the Clocking Wizard picks fractional
dividers that land within ~0.02% of 12.288 MHz, giving Fs ≈ 48 kHz to a few
parts per million. The Cirrus chips derive everything from MCLK and don't care
about the absolute rate, so audio still sounds right; we're just not at
*exactly* 48 kHz.

Later phases that require true 48 kHz (USB audio, network AVB) will either use
the Zynq PS's fractional PLLs (`FCLK`, which gets closer) or add an external
audio-grade oscillator. Not this phase's problem.

## Files

| File                                 | Role                                                        |
|--------------------------------------|-------------------------------------------------------------|
| `src/rtl/phase1_top.sv`              | Top module: MMCM + divider + loopback wire                  |
| `src/rtl/i2s_clock_divider.sv`       | Counter dividing MCLK to SCLK and LRCK                      |
| `constraints/phase1_arty_z7.xdc`     | Pin assignments (sysclk H16, JA1..JA10) and 125 MHz clock   |
| `scripts/create_project.tcl`         | Builds project + configures Clocking Wizard IP              |

## Hardware setup

1. Plug **Pmod I2S2** into **JA** on the Arty Z7-20 (align pin 1 correctly).
2. Set **JP1** on the Pmod I2S2 to **SLV** (slave mode). This tells the CS5343
   ADC to receive SCLK and LRCK from the FPGA instead of generating its own.
3. Connect an audio source to **Line In** (the ADC jack) — a phone playing a
   test tone works well.
4. Connect headphones or powered speakers to **Line Out** (the DAC jack).

## What "success" looks like

- Vivado synth + impl complete without errors. Some warnings about clock
  domain crossings on the MMCM's `locked` signal are expected and OK for now.
- After programming over JTAG, whatever is playing into Line In comes back out
  of Line Out with no perceptible processing (small delay, but no artifacts).
- Silence in = silence out. If you hear buzz or hash at rest, that's a
  clocking or pin-constraint problem — not something the loopback wire is
  hiding.

## What "failure" tells us

Because there's no RTL logic between ADC and DAC, any problem is easy to
localize:

| Symptom                                | Most likely cause                          |
|----------------------------------------|--------------------------------------------|
| No sound at all                        | Bad pin constraint, JP1 in MST, or bit-file not programmed |
| Loud continuous buzz/hash              | MCLK not running, or SCLK/LRCK ratio wrong |
| Sound but very quiet / distorted       | Clock ratios OK but MCLK frequency far off |
| Sound but with periodic clicks/pops    | MMCM losing lock momentarily; check `locked` |

## Exit criteria

Once clean audio passes end-to-end at reasonable volume, Phase 1 is done. Move
on to Phase 2: I2S ↔ PCM conversion. Same signal path, but now the FPGA
deserializes I2S into a parallel PCM word, holds it briefly, and reserializes
it — proving we can extract audio samples into a form we can eventually
process.
