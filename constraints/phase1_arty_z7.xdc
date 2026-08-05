# =============================================================================
# phase1_arty_z7.xdc
#
# Physical constraints for Phase 1 (Pmod I2S2 loopback on JA).
# Board: Digilent Arty Z7-20
# Device: xc7z020clg400-1
#
# Pin assignments taken from Digilent's official Arty-Z7-20 master XDC:
#   https://github.com/Digilent/digilent-xdc
# =============================================================================

# ------ System clock: 125 MHz on H16 ------
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

# ------ Pmod JA: Pmod I2S2 ------

# DAC side (CS4344 "Line Out") - Pmod pins 1..4, JA bottom row
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { ja_da_mclk }] ;# JA1  (Pmod pin 1)  D/A MCLK
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports { ja_da_lrck }] ;# JA2  (Pmod pin 2)  D/A LRCK
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sclk }] ;# JA3  (Pmod pin 3)  D/A SCLK
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sdin }] ;# JA4  (Pmod pin 4)  D/A SDIN

# ADC side (CS5343 "Line In") - Pmod pins 7..10, JA top row
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_mclk  }] ;# JA7  (Pmod pin 7)  A/D MCLK
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_lrck  }] ;# JA8  (Pmod pin 8)  A/D LRCK
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sclk  }] ;# JA9  (Pmod pin 9)  A/D SCLK
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sdout }] ;# JA10 (Pmod pin 10) A/D SDOUT
