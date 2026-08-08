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
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

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
