set_property SRC_FILE_INFO {cfile:C:/Users/Alex/Desktop/FPGAmixer_main/FPGAmixer/constraints/phase1_arty_z7.xdc rfile:../../../../constraints/phase1_arty_z7.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:13 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
set_property src_info {type:XDC file:1 line:19 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { ja_da_mclk }] ;# JA1  (Pmod pin 1)  D/A MCLK
set_property src_info {type:XDC file:1 line:20 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports { ja_da_lrck }] ;# JA2  (Pmod pin 2)  D/A LRCK
set_property src_info {type:XDC file:1 line:21 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sclk }] ;# JA3  (Pmod pin 3)  D/A SCLK
set_property src_info {type:XDC file:1 line:22 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 } [get_ports { ja_da_sdin }] ;# JA4  (Pmod pin 4)  D/A SDIN
set_property src_info {type:XDC file:1 line:25 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_mclk  }] ;# JA7  (Pmod pin 7)  A/D MCLK
set_property src_info {type:XDC file:1 line:26 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_lrck  }] ;# JA8  (Pmod pin 8)  A/D LRCK
set_property src_info {type:XDC file:1 line:27 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sclk  }] ;# JA9  (Pmod pin 9)  A/D SCLK
set_property src_info {type:XDC file:1 line:28 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 } [get_ports { ja_ad_sdout }] ;# JA10 (Pmod pin 10) A/D SDOUT
