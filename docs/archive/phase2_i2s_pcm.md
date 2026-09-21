# Phase 2 — I2S ↔ PCM ↔ I2S round-trip on JA

## What this phase does

The audio path from Line In to Line Out looks the same as Phase 1 — sound
still round-trips through the Pmod I2S2. But the middle now has real logic:
an **I2S receiver** deserializes the ADC's bit stream into a 24-bit parallel
sample per channel, and an **I2S transmitter** re-serializes those parallel
samples back to the DAC.

Because there's no processing between rx and tx, the audible result is
identical to Phase 1. That's the whole point: if Phase 2 sounds the same as
Phase 1, we know the rx and tx modules are bit-exact and ready for real
signal manipulation in Phase 3.

Analogy: Phase 1 was a wire. Phase 2 is a wire that goes through a translator
and a translator-back. If the translators are correct, you can't tell the
difference.

## Signal path

```
   Line In jack
       │
       ▼
   CS5343 ADC ──────► SDOUT (JA10, W19)
                             │
                             ▼
                       ┌──────────────┐
                       │ i2s_receiver │  (mclk domain)
                       │              │
                       │ deserialize  │
                       │ 24-bit L / R │
                       └──────┬───────┘
                              │
                    left_data / right_data
                              │
                              ▼
                       ┌──────────────┐
                       │i2s_transmitter│ (mclk domain)
                       │              │
                       │ serialize    │
                       │ MSB-first    │
                       └──────┬───────┘
                              │
                              ▼
   CS4344 DAC ◄────── SDIN (JA4, Y17)
       │
       ▼
   Line Out jack
```

Latency: one LRCK period (~21 µs at 48 kHz). Inaudible.

## What's new since Phase 1

| File                                   | Role                                                        |
|----------------------------------------|-------------------------------------------------------------|
| `src/rtl/i2s_receiver.sv`              | Deserializes SDATA to 24-bit L/R + sample_valid pulse       |
| `src/rtl/i2s_transmitter.sv`           | Serializes L/R back to SDATA                                |
| `src/rtl/reset_sync.sv`                | 2FF async-assert / sync-deassert reset synchronizer         |
| `src/rtl/phase2_top.sv`                | Wires it all together, replaces phase1_top                  |
| `src/sim/tb_i2s_receiver.sv`           | Unit test: drives known I2S bit patterns, checks captures   |
| `src/sim/tb_i2s_transmitter.sv`        | Unit test: sets L/R values, verifies output bit stream      |
| `src/sim/tb_i2s_loopback.sv`           | Integration: rx → tx round-trip with 1-frame latency check  |
| `scripts/run_sim.tcl`                  | Batch runner: executes all three testbenches                |

The XDC and Clocking Wizard configuration are unchanged from Phase 1.

## Design notes

**Everything runs in the mclk domain.** SCLK and LRCK are treated as sampled
signals with edges detected by 2FF-registered comparison (`sclk_r` vs
`sclk_prev`). No `create_generated_clock`, no clock-domain crossings, no
async paths to worry about at STA time. This keeps timing analysis clean.

**Reset is now proper.** The MMCM's `locked` signal is asynchronous to mclk,
so using it directly as a reset (which Phase 1 did) has a small metastability
risk on deassertion. `reset_sync` fixes this with the classic 2FF
async-assert / sync-deassert pattern.

**One-frame latency comes for free.** The receiver and transmitter both
respond to the same LRCK edges. Because non-blocking assignments read the
pre-update value of `left_data` / `right_data`, the transmitter serializes
the value that was written at the *previous* LRCK edge — which is exactly the
one-frame delay we want.

**Data width is 24 bits.** Matches the CS5343/CS4344 native word width in
standard Philips I2S mode. Parameterized so Phase 3+ can use different widths
if needed.

## Running the simulation

**Recommended for the first run — GUI mode.** After running
`scripts/create_project.tcl` and opening the project:

1. In the Flow Navigator, expand **SIMULATION** → click **Run Simulation** →
   **Run Behavioral Simulation**.
2. XSim opens with the waveform viewer. The Tcl Console at the bottom shows
   `$display` output — look for the "PASS:" or "FAIL:" line at the end.
3. In the waveform, expand `tb_i2s_loopback` in the Scopes panel to see all
   signals. Right-click any signal → **Add To Wave Window**. Useful ones to
   scope out: `sclk`, `lrck`, `sdata_rx`, `sdata_tx`, `left_data`,
   `right_data`, `sample_valid`, and inside `u_rx`: `shift_reg`,
   `bit_counter`, `channel_prev`.
4. To advance simulation time, type `run 200us` in the Tcl Console. The
   testbench uses `$finish` after all checks, so `run all` also works.

**Batch mode (once you trust it works).** From a terminal at the repo root:

```
vivado -mode batch -source scripts/run_sim.tcl
```

This runs all three testbenches back-to-back and prints pass/fail lines. Much
faster iteration than the GUI once you're not actively debugging.

## What "success" looks like

Simulation:

- All three testbenches print `PASS: ...` at the end.
- No `[FAIL]` lines in any testbench's output.
- Waveform shows the transmitter's `sdata_tx` matching the receiver's
  `sdata_rx` after a one-frame offset.

Hardware:

- Bitstream builds and programs successfully.
- Audio round-trips through Line In → Line Out with no perceptible artifacts.
- Silence in = silence out at rest.

## What "failure" tells us — and where to look

| Symptom                                     | Most likely cause                                            |
|---------------------------------------------|--------------------------------------------------------------|
| tb_i2s_receiver fails, wrong bits           | Bit ordering off; check `shift_reg` update direction         |
| tb_i2s_receiver fails, wrong channel        | `channel_prev` logic; check LRCK sense (0=L, 1=R)            |
| tb_i2s_receiver fails on Test 1 only        | Off-by-one on the "delay bit" — check bit_counter=0 case     |
| tb_i2s_transmitter fails, all bits shifted  | Off-by-one on MSB drive - check the LRCK-load branch         |
| tb_i2s_loopback fails but units pass        | rx/tx handshake / latency assumption is wrong                |
| Sim passes, no audio on hardware            | Constraint or clocking bug; scope MCLK/SCLK/LRCK/SDATA       |
| Sim passes, audio has clicks/pops           | Reset synchronizer needed? Metastability on `mmcm_locked`?   |

## Exit criteria

Simulation clean AND audio round-trip works on hardware AND sounds identical
to Phase 1. Move to Phase 3: static PCM matrix mixer.
