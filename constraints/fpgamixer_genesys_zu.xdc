# =============================================================================
# fpgamixer_genesys_zu.xdc
#
# Board-level constraints for fpgamixer_top.
# Board:  Digilent Genesys ZU-3EG  (board_part digilentinc.com:gzu_3eg:part0:1.0)
# Device: xczu3eg-sfvc784-1-e  (Zynq UltraScale+ MPSoC)
#
# Phase 11 (2026-10-07): the Pmod I2S2 modules are gone (user decision P1:
# "The pmods are terrible and I never want to go back to them"), and with them
# the 34 Pmod pin assignments (JB and JC) and the codec-interface timing (ODDR
# forwarded clocks, set_output_delay / set_input_delay, multicycle paths). The
# board's analog I/O is now a USB interface on the Type-A port (link #3). Those
# constraints are in git history before this change, with their datasheet
# derivation (and in docs/archive/handoff_codec_interface_timing.md), should a
# codec on Pmods ever come back.
#
# The PS block design's ports (AXI windows, link streams) need no constraints
# here: they stay inside the device. Module-scoped CDC constraints live in their
# own files (create_project.tcl, scoped_xdc).
# =============================================================================

# ------ PL system clock: 25 MHz on E12 (from Ethernet PHY) ------
# LVCMOS18 (bank is 1.8 V).
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS18} [get_ports sysclk]
create_clock -period 40.000 -name sysclk [get_ports sysclk]

# HDIO clock-route override: E12 is on a HIGH_DENSITY bank with no dedicated
# clock route to the CMT, so the IOB->BUFG->MMCM chain can't stay within one
# clock region and the IO clock placer fails (Place 30-716 / 30-99). Allow the
# MMCM input clock to reach the CMT over a non-region-local column route. This
# is acceptable here: the MMCM reconditions the clock and the 12.288 MHz audio
# domain has ~81 ns of margin. Net name is the clk_wiz (u_clk/u_mmcm) input;
# matches Vivado's own suggestion in the placer error.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets u_clk/u_mmcm/inst/clk_in1_clk_wiz_audio]
