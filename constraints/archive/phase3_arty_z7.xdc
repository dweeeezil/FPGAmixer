# =============================================================================
# phase3_arty_z7.xdc
#
# Physical constraints for Phase 3 (static PCM matrix, both Pmod I2S2 modules).
# Board:  Digilent Arty Z7-20
# Device: xc7z020clg400-1
#
# JA pins are unchanged from Phase 1/2. JB pins are taken from Digilent's
# official Arty-Z7-20 master XDC (https://github.com/Digilent/digilent-xdc),
# mirroring the same Pmod-pin -> I2S2-function mapping used on JA.
#
# HARDWARE NOTE: the second Pmod I2S2 on JB must have its master/slave jumper
# set the same way as the JA module (SLV), since both modules are clock-slaved
# to the FPGA-generated MCLK/SCLK/LRCK. (I can't verify your jumper from here --
# match whatever position made JA work in Phase 1/2.)
# =============================================================================

# ------ System clock: 125 MHz on H16 ------
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { sysclk }]

# =============================================================================
# Pmod JA : Pmod I2S2 #1
# =============================================================================

# DAC side (CS4344 "Line Out") - Pmod pins 1..4
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { ja_da_mclk }] ;# JA1  D/A MCLK
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports { ja_da_lrck }] ;# JA2  D/A LRCK
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sclk }] ;# JA3  D/A SCLK
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sdin }] ;# JA4  D/A SDIN

# ADC side (CS5343 "Line In") - Pmod pins 7..10
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_mclk  }] ;# JA7  A/D MCLK
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_lrck  }] ;# JA8  A/D LRCK
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sclk  }] ;# JA9  A/D SCLK
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sdout }] ;# JA10 A/D SDOUT

# =============================================================================
# Pmod JB : Pmod I2S2 #2
# =============================================================================

# DAC side (CS4344 "Line Out") - Pmod pins 1..4
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports { jb_da_mclk }] ;# JB1  D/A MCLK
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports { jb_da_lrck }] ;# JB2  D/A LRCK
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 } [get_ports { jb_da_sclk }] ;# JB3  D/A SCLK
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { jb_da_sdin }] ;# JB4  D/A SDIN

# ADC side (CS5343 "Line In") - Pmod pins 7..10
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports { jb_ad_mclk  }] ;# JB7  A/D MCLK
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports { jb_ad_lrck  }] ;# JB8  A/D LRCK
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports { jb_ad_sclk  }] ;# JB9  A/D SCLK
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports { jb_ad_sdout }] ;# JB10 A/D SDOUT

# =============================================================================
# Codec interface timing (ODDR forwarding + pin-delay constraints)
#
# Companion to the ODDR forwarders in phase3_top (u_fwd_*/u_oddr) -- see
# docs/handoff_codec_interface_timing.md. Every codec-facing pin launches from
# an ODDR clocked by mclk (clk_out1_clk_wiz_audio, 12.288 MHz, T=81.380 ns).
#
# Datasheet numbers used (all minimums):
#   CS4344 DAC  (docs/CS4344-45-48_F2.pdf p.9, External SCLK Mode):
#     t_sdlrs = 20 ns  SDIN valid to SCLK rising setup
#     t_sdh   = 20 ns  SCLK rising to SDIN hold
#     t_slrs/t_slrd = 20 ns  LRCK edge clear of SCLK rising, both sides
#   CS5343 ADC  (docs/CS5343-44_F5.pdf p.9, Slave Mode, CL = 20 pF):
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
create_generated_clock -name fwd_mclk_ja_da -source [get_pins u_fwd_ja_da_mclk/u_oddr/C] -divide_by 1 [get_ports ja_da_mclk]
create_generated_clock -name fwd_mclk_ja_ad -source [get_pins u_fwd_ja_ad_mclk/u_oddr/C] -divide_by 1 [get_ports ja_ad_mclk]
create_generated_clock -name fwd_mclk_jb_da -source [get_pins u_fwd_jb_da_mclk/u_oddr/C] -divide_by 1 [get_ports jb_da_mclk]
create_generated_clock -name fwd_mclk_jb_ad -source [get_pins u_fwd_jb_ad_mclk/u_oddr/C] -divide_by 1 [get_ports jb_ad_mclk]

create_generated_clock -name fwd_sclk_ja_da -source [get_pins u_fwd_ja_da_sclk/u_oddr/C] -divide_by 4 [get_ports ja_da_sclk]
create_generated_clock -name fwd_sclk_ja_ad -source [get_pins u_fwd_ja_ad_sclk/u_oddr/C] -divide_by 4 [get_ports ja_ad_sclk]
create_generated_clock -name fwd_sclk_jb_da -source [get_pins u_fwd_jb_da_sclk/u_oddr/C] -divide_by 4 [get_ports jb_da_sclk]
create_generated_clock -name fwd_sclk_jb_ad -source [get_pins u_fwd_jb_ad_sclk/u_oddr/C] -divide_by 4 [get_ports jb_ad_sclk]

# ------ DAC data outputs: SDIN vs the same Pmod's forwarded SCLK ------
set_output_delay -clock fwd_sclk_ja_da -max  20.000 [get_ports ja_da_sdin]
set_output_delay -clock fwd_sclk_ja_da -min -20.000 [get_ports ja_da_sdin]
set_output_delay -clock fwd_sclk_jb_da -max  20.000 [get_ports jb_da_sdin]
set_output_delay -clock fwd_sclk_jb_da -min -20.000 [get_ports jb_da_sdin]
set_multicycle_path -hold 3 -start -to [get_ports {ja_da_sdin jb_da_sdin}]

# ------ LRCK outputs: framed against their own side's forwarded SCLK ------
# CS4344 spec is 20/20 vs SCLK rising; the CS5343's +/-20-vs-falling window is
# tighter than what set_output_delay can express for a coincident edge and is
# confirmed by pin-skew report instead. Constraining all four identically also
# keeps the identical-ODDR-treatment rule visible to STA.
set_output_delay -clock fwd_sclk_ja_da -max  20.000 [get_ports ja_da_lrck]
set_output_delay -clock fwd_sclk_ja_da -min -20.000 [get_ports ja_da_lrck]
set_output_delay -clock fwd_sclk_ja_ad -max  20.000 [get_ports ja_ad_lrck]
set_output_delay -clock fwd_sclk_ja_ad -min -20.000 [get_ports ja_ad_lrck]
set_output_delay -clock fwd_sclk_jb_da -max  20.000 [get_ports jb_da_lrck]
set_output_delay -clock fwd_sclk_jb_da -min -20.000 [get_ports jb_da_lrck]
set_output_delay -clock fwd_sclk_jb_ad -max  20.000 [get_ports jb_ad_lrck]
set_output_delay -clock fwd_sclk_jb_ad -min -20.000 [get_ports jb_ad_lrck]
set_multicycle_path -hold 2 -start -to [get_ports {ja_da_lrck ja_ad_lrck jb_da_lrck jb_ad_lrck}]

# ------ ADC data inputs: SDOUT vs the forwarded SCLK, round trip included ---
# -max = board round trip - t_stp ; -min = board round trip + t_hld.
# The MCP 0 makes STA check the true 0-cycle relationship: capture on the same
# mclk edge that launches the SCLK rising edge to the ADC. This is the 4.3(2)
# RX-sampling-margin check -- expected tight (roughly t_stp minus the off-chip
# loop) and must be read, not assumed. The t_hld side of the window has no
# natural SDC check at this pairing; its ~40 ns margin is arithmetic from the
# same report numbers (see the docs note).
set_input_delay -clock fwd_sclk_ja_ad -max  -9.500 [get_ports ja_ad_sdout]
set_input_delay -clock fwd_sclk_ja_ad -min  40.500 [get_ports ja_ad_sdout]
set_input_delay -clock fwd_sclk_jb_ad -max  -9.500 [get_ports jb_ad_sdout]
set_input_delay -clock fwd_sclk_jb_ad -min  40.500 [get_ports jb_ad_sdout]
set_multicycle_path -setup 0 -from [get_ports {ja_ad_sdout jb_ad_sdout}]
# Explicit hold 0 = the same edges the setup-0 default derives (capture one
# mclk before launch, trivially positive). Stated so XDCH-1 records the hold
# relationship as deliberate; the real window-end bound is the arithmetic one.
set_multicycle_path -hold 0 -from [get_ports {ja_ad_sdout jb_ad_sdout}]
