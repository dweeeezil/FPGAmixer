set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS18} [get_ports sysclk]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports jb_da_mclk]
set_property -dict {PACKAGE_PIN AG14 IOSTANDARD LVCMOS33} [get_ports jb_da_lrck]
set_property -dict {PACKAGE_PIN AH14 IOSTANDARD LVCMOS33} [get_ports jb_da_sclk]
set_property -dict {PACKAGE_PIN AG13 IOSTANDARD LVCMOS33} [get_ports jb_da_sdin]
set_property -dict {PACKAGE_PIN AE14 IOSTANDARD LVCMOS33} [get_ports jb_ad_mclk]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports jb_ad_lrck]
set_property -dict {PACKAGE_PIN AE15 IOSTANDARD LVCMOS33} [get_ports jb_ad_sclk]
set_property -dict {PACKAGE_PIN AH13 IOSTANDARD LVCMOS33} [get_ports jb_ad_sdout]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33} [get_ports jc_da_mclk]
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports jc_da_lrck]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports jc_da_sclk]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports jc_da_sdin]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports jc_ad_mclk]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports jc_ad_lrck]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports jc_ad_sclk]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports jc_ad_sdout]
# =============================================================================
# phase3_genesys_zu.xdc
#
# Physical constraints for Phase 3 (static PCM matrix, both Pmod I2S2 modules).
# Board:  Digilent Genesys ZU-3EG  (board_part digilentinc.com:gzu_3eg:part0:1.0)
# Device: xczu3eg-sfvc784-1-e  (Zynq UltraScale+ MPSoC)
#
# Ported from constraints/archive/phase3_arty_z7.xdc. Pin assignments taken
# from Digilent's official Genesys-ZU-3EG master XDC:
#   https://github.com/Digilent/digilent-xdc  (Genesys-ZU-3EG-Master.xdc)
#
# PORT NAMING: the RTL port prefixes match the board silkscreen -- jb_* is Pmod
# JB (I2S2 module #1), jc_* is Pmod JC (I2S2 module #2). The ZU-3EG's Pmod JA is
# the analog XADC Pmod (LVCMOS18, RC-filtered) and cannot carry the 3.3 V I2S2,
# so the two modules use the digital Pmods JB and JC (JD is the remaining spare).
#
# CLOCK NOTE: the ZU-3EG PL reference is a 25 MHz LVCMOS18 clock on E12 (from
# the on-board Ethernet PHY), not the Arty's 125 MHz LVCMOS33 on H16. The
# Clocking Wizard input is 25.000 MHz (scripts/create_project.tcl); the
# 12.288 MHz audio MCLK and everything downstream are identical to the Arty
# build, so the codec-interface timing section below is unchanged (T still
# 81.380 ns).
#
# HARDWARE NOTE: both Pmod I2S2 modules must have their master/slave jumper set
# to SLV, since both are clock-slaved to the FPGA-generated MCLK/SCLK/LRCK.
# =============================================================================

# ------ PL system clock: 25 MHz on E12 (from Ethernet PHY) ------
# LVCMOS18 (bank is 1.8 V) -- do NOT reuse the Arty's LVCMOS33 here.

# HDIO clock-route override: E12 is on a HIGH_DENSITY bank with no dedicated
# clock route to the CMT, so the IOB->BUFG->MMCM chain can't stay within one
# clock region and the IO clock placer fails (Place 30-716 / 30-99). Allow the
# MMCM input clock to reach the CMT over a non-region-local column route. This
# is acceptable here: the MMCM reconditions the clock and the 12.288 MHz audio
# domain has ~81 ns of margin. The cleaner long-term fix is to source the PL
# clock from the PS (pl_clk) once the PS is brought up at Phase 4, instead of
# this HDIO pin. Net name is the clk_wiz (u_clk/u_mmcm) input; matches Vivado's own
# suggestion in the placer error.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets u_clk/u_mmcm/inst/clk_in1_clk_wiz_audio]

# =============================================================================
# Pmod JB : Pmod I2S2 #1   (jb_* ports)
# =============================================================================

# DAC side (CS4344 "Line Out") - Pmod pins 1..4

# ADC side (CS5343 "Line In") - Pmod pins 7..10

# =============================================================================
# Pmod JC : Pmod I2S2 #2   (jc_* ports)
# =============================================================================

# DAC side (CS4344 "Line Out") - Pmod pins 1..4

# ADC side (CS5343 "Line In") - Pmod pins 7..10

# =============================================================================
# Codec interface timing (ODDR forwarding + pin-delay constraints)
#
# Board-INDEPENDENT: this whole section references internal ODDR pins and codec
# datasheet numbers, and the 12.288 MHz mclk / /4 sclk tree is identical to the
# Arty build, so it is carried over unchanged from the archived Arty XDC.
#
# Companion to the ODDR forwarders in i2s_port (u_jb|u_jc/u_fwd_*/u_oddr) -- see the
# archived docs/archive/handoff_codec_interface_timing.md. Every codec-facing
# pin launches from an ODDR clocked by mclk (clk_out1_clk_wiz_audio,
# 12.288 MHz, T=81.380 ns).
#
# Datasheet numbers used (all minimums):
#   CS4344 DAC  (docs/archive/CS4344-45-48_F2.pdf p.9, External SCLK Mode):
#     t_sdlrs = 20 ns  SDIN valid to SCLK rising setup
#     t_sdh   = 20 ns  SCLK rising to SDIN hold
#     t_slrs/t_slrd = 20 ns  LRCK edge clear of SCLK rising, both sides
#   CS5343 ADC  (docs/archive/CS5343-44_F5.pdf p.9, Slave Mode, CL = 20 pF):
#     t_stp = 10 ns  SDOUT valid before SCLK rising
#     t_hld = 40 ns  SDOUT valid after SCLK rising
#     t_slrd = -20..+20 ns  SCLK falling to LRCK edge (skew window; checked
#       via matched ODDR launch + report_datasheet skew, not set_output_delay)
#
# Board assumption: <=0.25 ns per Pmod trace, 0.5 ns for the SCLK-out +
# SDOUT-return round trip. Small vs the margins; revisit if wiring changes.
#
# RTL-geometry facts the multicycle exceptions encode (all guaranteed by
# construction in i2s_clock_divider/i2s_transmitter and regression-tested by
# tb_i2s_tx_pin_phase; STA cannot see counter phase and would otherwise check
# a coincident-edge relationship that never occurs):
#   - SDIN changes mid-bit-cell: 1 mclk before an SCLK rising edge, and holds
#     3 mclk after the previous rising edge  -> setup default, hold MCP 3.
#   - LRCK changes on SCLK falling edges: 2 mclk from surrounding SCLK rising
#     edges  -> setup default (1 mclk, conservative), hold MCP 2 (exact).
#   - The receiver samples SDOUT on the same mclk edge that launches the
#     SCLK rising edge to the ADC  -> setup MCP 0 (0-cycle, the real check).
# =============================================================================

# ------ Forwarded-clock definitions at the pins (one per ODDR) ------
create_generated_clock -name fwd_mclk_jb_da -source [get_pins u_jb/u_fwd_da_mclk/u_oddr/C] -divide_by 1 [get_ports jb_da_mclk]
create_generated_clock -name fwd_mclk_jb_ad -source [get_pins u_jb/u_fwd_ad_mclk/u_oddr/C] -divide_by 1 [get_ports jb_ad_mclk]
create_generated_clock -name fwd_mclk_jc_da -source [get_pins u_jc/u_fwd_da_mclk/u_oddr/C] -divide_by 1 [get_ports jc_da_mclk]
create_generated_clock -name fwd_mclk_jc_ad -source [get_pins u_jc/u_fwd_ad_mclk/u_oddr/C] -divide_by 1 [get_ports jc_ad_mclk]

create_generated_clock -name fwd_sclk_jb_da -source [get_pins u_jb/u_fwd_da_sclk/u_oddr/C] -divide_by 4 [get_ports jb_da_sclk]
create_generated_clock -name fwd_sclk_jb_ad -source [get_pins u_jb/u_fwd_ad_sclk/u_oddr/C] -divide_by 4 [get_ports jb_ad_sclk]
create_generated_clock -name fwd_sclk_jc_da -source [get_pins u_jc/u_fwd_da_sclk/u_oddr/C] -divide_by 4 [get_ports jc_da_sclk]
create_generated_clock -name fwd_sclk_jc_ad -source [get_pins u_jc/u_fwd_ad_sclk/u_oddr/C] -divide_by 4 [get_ports jc_ad_sclk]

# ------ DAC data outputs: SDIN vs the same Pmod's forwarded SCLK ------
set_output_delay -clock fwd_sclk_jb_da -max 20.000 [get_ports jb_da_sdin]
set_output_delay -clock fwd_sclk_jb_da -min -20.000 [get_ports jb_da_sdin]
set_output_delay -clock fwd_sclk_jc_da -max 20.000 [get_ports jc_da_sdin]
set_output_delay -clock fwd_sclk_jc_da -min -20.000 [get_ports jc_da_sdin]
set_multicycle_path -hold -start -to [get_ports {jb_da_sdin jc_da_sdin}] 3

# ------ LRCK outputs: framed against their own side's forwarded SCLK ------
# CS4344 spec is 20/20 vs SCLK rising; the CS5343's +/-20-vs-falling window is
# tighter than what set_output_delay can express for a coincident edge and is
# confirmed by pin-skew report instead. Constraining all four identically also
# keeps the identical-ODDR-treatment rule visible to STA.
set_output_delay -clock fwd_sclk_jb_da -max 20.000 [get_ports jb_da_lrck]
set_output_delay -clock fwd_sclk_jb_da -min -20.000 [get_ports jb_da_lrck]
set_output_delay -clock fwd_sclk_jb_ad -max 20.000 [get_ports jb_ad_lrck]
set_output_delay -clock fwd_sclk_jb_ad -min -20.000 [get_ports jb_ad_lrck]
set_output_delay -clock fwd_sclk_jc_da -max 20.000 [get_ports jc_da_lrck]
set_output_delay -clock fwd_sclk_jc_da -min -20.000 [get_ports jc_da_lrck]
set_output_delay -clock fwd_sclk_jc_ad -max 20.000 [get_ports jc_ad_lrck]
set_output_delay -clock fwd_sclk_jc_ad -min -20.000 [get_ports jc_ad_lrck]
set_multicycle_path -hold -start -to [get_ports {jb_da_lrck jb_ad_lrck jc_da_lrck jc_ad_lrck}] 2

# ------ ADC data inputs: SDOUT vs the forwarded SCLK, round trip included ---
# -max = board round trip - t_stp ; -min = board round trip + t_hld.
# The MCP 0 makes STA check the true 0-cycle relationship: capture on the same
# mclk edge that launches the SCLK rising edge to the ADC. This is the 4.3(2)
# RX-sampling-margin check -- expected tight (roughly t_stp minus the off-chip
# loop) and must be read, not assumed. The t_hld side of the window has no
# natural SDC check at this pairing; its ~40 ns margin is arithmetic from the
# same report numbers (see the docs note).
set_input_delay -clock fwd_sclk_jb_ad -max -9.500 [get_ports jb_ad_sdout]
set_input_delay -clock fwd_sclk_jb_ad -min 40.500 [get_ports jb_ad_sdout]
set_input_delay -clock fwd_sclk_jc_ad -max -9.500 [get_ports jc_ad_sdout]
set_input_delay -clock fwd_sclk_jc_ad -min 40.500 [get_ports jc_ad_sdout]
set_multicycle_path -setup -from [get_ports {jb_ad_sdout jc_ad_sdout}] 0
# Explicit hold 0 = the same edges the setup-0 default derives (capture one
# mclk before launch, trivially positive). Stated so XDCH-1 records the hold
# relationship as deliberate; the real window-end bound is the arithmetic one.
set_multicycle_path -hold -from [get_ports {jb_ad_sdout jc_ad_sdout}] 0

create_clock -period 40.000 -name sysclk [get_ports sysclk]
