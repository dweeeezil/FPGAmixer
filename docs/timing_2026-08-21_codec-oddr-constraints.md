# FPGAmixer — codec-interface timing hardening: ODDR forwarding + pin constraints

**Date:** August 21, 2026
**Status:** implemented; STA results below; **hardware re-test pending** (checklist item 5 of `handoff_codec_interface_timing.md` §7).
**Spec:** `docs/handoff_codec_interface_timing.md` (this note records what was actually done and measured).

---

## What changed

- `src/rtl/oddr_out.sv` (new): one-pin ODDR forwarder, behavioral model under
  `SIM_ODDR` for Icarus (define wired in `scripts/sim.mk`), real 7-series ODDR
  (`SAME_EDGE`, `SRTYPE=SYNC`, reset tied off) for synthesis.
- `src/rtl/phase3_top.sv`: all 14 codec-facing outputs now leave through
  `oddr_out` instances clocked by mclk — 4× MCLK as clock-forward (D1=1,D2=0),
  4× SCLK + 4× LRCK + 2× SDIN as SDR re-launch (D1=D2=signal). SCLK/LRCK/SDIN
  all gain the same +1 MCLK pin latency, preserving their relative alignment
  (the §4.2 invariant; mixing ODDR and combinational forwarding here would
  re-create the pin-phase race of `bugfix_2026-08-14_phase3-noise.md`).
- `constraints/phase3_arty_z7.xdc`: forwarded-clock definitions on all 8
  MCLK/SCLK pins + `set_output_delay`/`set_input_delay` on SDIN, LRCK, SDOUT
  with multicycle exceptions encoding the true launch/capture geometry.
  (`phase1_arty_z7.xdc` deliberately NOT mirrored: `phase1_top` still forwards
  combinationally, so these constraints would mis-describe that netlist.)

## Datasheet figures used

**CS4344/5/8 DAC — `docs/CS4344-45-48_F2.pdf` (DS691F2, JUL '13), p.9
"Switching Characteristics — Serial Audio Interface", External SCLK Mode.**
This PDF was fetched from cirrus.com for this change (the handoff called it
DS692; the current document number is DS691F2). All minimums:

| Parameter | Symbol | Value |
|---|---|---|
| SDIN valid to SCLK rising setup | t_sdlrs | 20 ns |
| SCLK rising to SDIN hold | t_sdh | 20 ns |
| SCLK rising to LRCK edge delay | t_slrd | 20 ns |
| SCLK rising to LRCK edge setup | t_slrs | 20 ns |
| SCLK pulse width low / high | t_sclkl / t_sclkh | 20 / 20 ns |

Also load-bearing (p.12 §4.1): MCLK, LRCK and SCLK "must be synchronous" —
**no phase relationship is required** between MCLK and SCLK.

**CS5343/4 ADC — `docs/CS5343-44_F5.pdf` (DS687F5), p.9, Slave Mode,
C_L = 20 pF** (verified against the PDF; matches the handoff):

| Parameter | Symbol | Value |
|---|---|---|
| SDOUT valid before SCLK rising | t_stp | 10 ns min |
| SDOUT valid after SCLK rising | t_hld | 40 ns min |
| SCLK falling to LRCK edge | t_slrd | −20…+20 ns |

**Board assumption:** ≤0.25 ns per Pmod trace; 0.5 ns total for the
SCLK-out → ADC → SDOUT-return round trip, folded into the SDOUT input delays.

## Constraint scheme (why these exact commands)

mclk = 12.288 MHz, T = 81.380 ns; SCLK = mclk/4. All codec pins launch from
ODDRs on the same mclk, so at the pins (mclk-edge grid): SCLK falls at E1,
SDIN changes at E2 (mid-cell), SCLK rises at E3, SDIN holds to E6; LRCK
changes coincident with SCLK falling (E1). STA cannot see divider phase — it
assumes launches on every mclk edge — so multicycle exceptions restore the
real geometry (guaranteed by construction and regression-tested by
`tb_i2s_tx_pin_phase`):

- **SDIN** vs same-Pmod forwarded SCLK: `-max 20 / -min −20`; setup default
  (1-mclk requirement = the true E2→E3 spacing), `-hold 3 -start`
  (true hold margin: E3→E6 = 3 mclk).
- **LRCK** (all four, uniformly) vs own side's forwarded SCLK:
  `-max 20 / -min −20`; setup default (1 mclk, conservative — true spacing
  is 2 mclk), `-hold 2 -start` (exact). The CS5343's ±20 ns
  LRCK-vs-SCLK-falling window is a coincident-edge skew spec that
  `set_output_delay` cannot express directly; it is covered by the matched
  ODDR launch (same mclk edge, same OLOGIC path) and confirmed numerically
  from the pin-skew numbers below.
- **SDOUT** vs forwarded AD-side SCLK: `-max = 0.5 − 10 = −9.5`,
  `-min = 0.5 + 40 = +40.5`; `set_multicycle_path -setup 0` so STA checks the
  true 0-cycle relationship — the receiver samples SDOUT on the very mclk
  edge that launches the SCLK rising edge to the ADC (§4.3(2)). This is the
  deliberately tight check; the t_hld side of the window has no natural SDC
  check at this pairing and its margin is arithmetic from the same numbers
  (≈ t_hld + SCLK-out insertion − mclk insertion to the capture flop − FF
  hold, ≈ +40 ns class — see report numbers below).

Division of labor: the constraints guard against **delay-path imbalance**
(routing, OBUF, corner spread); the sim regression `txphase` guards against
**launch-phase breakage** (which STA is structurally blind to). Both guards
are needed.

## Baseline (before this change, routed build of 2026-08-21 14:14)

- WNS **+74.831 ns**, WHS +0.106 ns, 0 failing endpoints; methodology **0
  checks**; `check_timing`: **2** input ports and **10** output ports with no
  delay constraints — i.e. every codec pin was invisible to STA.
- Baseline reports preserved (timing summary, methodology, bitstream) before
  the rebuild wiped `vivado_project/`.

## STA results (after — routed build of 2026-08-21 17:0x, methodology gate PASS)

Headline: **WNS +1.908 ns, WHS +0.060 ns, 0 failing endpoints (987), all
constraints met.** The WNS "regression" vs the +74.831 baseline is
definitional, not physical: baseline WNS was over internal reset-recovery
paths with every codec pin unconstrained; the new WNS **is** the codec RX
sampling check, which is exactly the path this change exists to watch.
Internal mclk-domain WNS is unchanged (75.8 vs 76.1 ns).

Constrained codec paths (slow corner, worst per group; slacks all MET):

| Path | Setup | Hold | Edge relationship confirmed in report |
|---|---|---|---|
| SDIN → CS4344 (×2) | +20.14 ns | +223.58 ns | hold shows `MCP -start 3`, requirement −244.140 ns; setup requirement 40.69 ns (the pessimistic ODDR falling-arc pairing — true data spacing is a full mclk, so real margin exceeds the report) |
| LRCK (×4) | +20.11 ns | +142.16 ns | hold shows `MCP -start 2`, requirement −162.760 ns |
| CS5343 → SDOUT (×2) | **+1.91 / +2.52 ns** | +123.51 ns | setup shows `MCP 0`, requirement 0.000 ns — the true same-edge check |

**§4.3(2) RX sampling margin, resolved:** the receiver keeps its internal
edge detect; STA proves the sample lands inside the CS5343 window with
+1.9 ns (JA) / +2.5 ns (JB) worst-corner setup margin, full round trip
included (BUFG→SCLK ODDR→OBUF [~3.5 ns, the dominant term]→board→ADC window
→SDOUT IBUF→FF). Thin by design — it is now the design's WNS, so any routing
or corner change that erodes it fails the build instead of failing on
hardware. If it ever goes negative: fastest lever is SLEW/DRIVE on the two
AD-side SCLK OBUFs. The t_hld side of the window (no natural SDC check at the
0-cycle pairing) has ≈ +47 ns by arithmetic from the same report numbers
(t_hld 40.5 + SCLK-out insertion 3.2 − FF clock insertion (−1.0) − FF hold),
plus the formal (trivial) −81.38 ns-edge hold check at +123.5 ns.

**§4.3(1) MCLK-vs-SCLK phase, confirmed:** report_datasheet clock-to-out,
same corner, per Pmod side — MCLK vs SCLK skew ≤ 0.05 ns (e.g. JA-DA
3.852 vs 3.807 ns slow / 0.305 vs 0.261 ns fast); every output launches from
OLOGIC ("ODDR (IO)"). The SDR group sits exactly one MCLK period behind the
reconstructed MCLK, which leaves the periodic MCLK↔SCLK relationship
unchanged modulo 81.38 ns; the codecs require only synchronicity (CS4344
§4.1 "no required phase relationship"; CS5343 specs no MCLK↔SCLK phase
parameter). LRCK-vs-SCLK pin skew on the ADC side ≤ 0.41 ns across corners —
inside the ±20 ns t_slrd window with two orders of magnitude to spare.

check_timing after: no_input_delay **0** (was 2), no_output_delay **0**
(was 10; 8 ports now report "timing clock defined on it", LOW — the
MCLK/SCLK forwarded-clock pins, as intended). Methodology: 6 Warning-level
TIMING-18 advisories remain — Vivado notes the LRCK/SDIN ports carry no
output delay *relative to the ÷1 forwarded-MCLK clocks* (an aliasing
artifact of defining ÷1 generated clocks on the MCLK pins; the ports are
fully constrained against their fwd_sclk_* clocks, which the path reports
above demonstrate). No Critical Warnings; the build gate stays armed.

## Sim regression

All seven testbenches pass with the ODDR forwarders in place (run via Vivado
xsim on this machine — Icarus not installed here; `scripts/sim.mk` carries the
same file lists + `SIM_ODDR` define for the usual Icarus flow). Per handoff
§6 this validates the datapath only, nothing about pin timing.

## Hardware result

*(pending — identity routing re-test, then DEMO routing, per §7 items 5)*
