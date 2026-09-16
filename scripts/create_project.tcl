# =============================================================================
# create_project.tcl
#
# Regenerates the FPGAmixer Vivado project for the current phase. Run once,
# then use the GUI for subsequent work.
#
# Usage (from repo root):
#     vivado -source scripts/create_project.tcl
#
# NOTE ON SIMULATION: the trustworthy sim path is command-line Icarus, not
# XSim -- see scripts/sim.mk. This script still sets a Vivado sim top for
# convenience, but the sim-only MMCM stub (src/sim/clk_wiz_audio_stub.sv) is
# deliberately EXCLUDED here: in Vivado the real Clocking Wizard IP provides
# clk_wiz_audio, and adding the stub would collide with it.
# =============================================================================

set proj_name     "FPGAmixer"
set proj_dir      "vivado_project"
# Target: Digilent Genesys ZU-3EG (Zynq UltraScale+ MPSoC). Migrated off the
# Arty Z7-20 (xc7z020) -- see docs/FPGAmixer_Architecture_Roadmap.md.
set part          "xczu3eg-sfvc784-1-e"
set board_part    "digilentinc.com:gzu_3eg:part0:1.0"

# NOTE (batch mode): Vivado in -mode batch may not see the Digilent board files
# and will then fail on BOARD_PART. If so, set the board repo path before
# sourcing this script (adjust the version/path to your install), e.g.:
#   set_param board.repoPaths \
#     "C:/Users/<you>/AppData/Roaming/Xilinx/Vivado/2026.1/xhub/board_store/xilinx_board_store"
# GUI sessions with the board files installed do not need this.

# ------ Phase selection -------------------------------------------------------
# current_phase drives BOTH the synthesis top module and which XDC is used.
set current_phase "phase3"
set synth_top     "${current_phase}_top"
set sim_top       "tb_phase3_datapath"
set xdc_file      "constraints/${current_phase}_genesys_zu.xdc"

# ------ Verify we're at the repo root ------
foreach d {src/rtl src/sim constraints scripts} {
    if {![file isdirectory $d]} {
        puts "ERROR: expected directory '$d' not found under [pwd]"
        puts "       Run this script from the repo root."
        return
    }
}

# ------ Gather sources ------
set rtl_files [glob -nocomplain src/rtl/*.sv]

# Sim files: everything in src/sim EXCEPT the sim-only IP stub.
set sim_files {}
foreach f [glob -nocomplain src/sim/*.sv] {
    if {[string match "*clk_wiz_audio_stub.sv" $f]} continue
    lappend sim_files $f
}

if {[llength $rtl_files] == 0} {
    puts "ERROR: no RTL sources found in src/rtl/"
    return
}
if {![file exists $xdc_file]} {
    puts "ERROR: constraints file '$xdc_file' not found for phase '$current_phase'"
    return
}

puts "INFO: phase '$current_phase' -> synth top '$synth_top', xdc '$xdc_file'"
puts "INFO: [llength $rtl_files] RTL files, [llength $sim_files] sim files (stub excluded)"

# ------ Wipe previous project directory ------
if {[file exists $proj_dir]} {
    puts "INFO: removing existing $proj_dir/"
    file delete -force $proj_dir
}

# ------ Create project ------
create_project $proj_name $proj_dir -part $part -force
set_property TARGET_LANGUAGE Verilog [current_project]

# ------ BOARD_PART (optional) ------
# This design does NOT depend on the board file: every pin comes from the XDC
# (explicit PACKAGE_PINs) and the Clocking Wizard uses a Custom interface
# (USE_BOARD_FLOW false), not the board flow. So BOARD_PART is cosmetic here.
# Set it only if the Digilent board file is actually installed; otherwise warn
# and continue on the raw part. This keeps the build working whether or not the
# Genesys ZU-3EG board files are present (XHub board store, or board.repoPaths).
set bp [get_board_parts -quiet $board_part]
if {[llength $bp] == 0} {
    # Tolerate version drift (e.g. :1.1) by matching the board name loosely.
    set bp [lindex [get_board_parts -quiet -filter {NAME =~ *gzu_3eg*}] 0]
}
if {$bp ne ""} {
    set_property BOARD_PART $bp [current_project]
    puts "INFO: BOARD_PART set to '$bp'"
} else {
    puts "WARNING: Genesys ZU-3EG board file not installed -- continuing on part"
    puts "         '$part' alone. The build does not need it (pins from XDC,"
    puts "         Custom MMCM clock). To install it: Vivado XHub board store, or"
    puts "         set board.repoPaths to Digilent's vivado-boards/new/board_files."
}

# ------ Add sources ------
add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset sim_1     $sim_files
add_files -norecurse -fileset constrs_1 $xdc_file

# ------ Clocking Wizard IP: 25 MHz -> ~12.288 MHz ------
# The ZU-3EG PL reference (sysclk on E12) is 25 MHz, not the Arty's 125 MHz, so
# PRIM_IN_FREQ changes. Output stays 12.288 MHz, so the whole audio clock tree
# (SCLK divider, ODDR forwarding, codec timing) is unchanged. 12.288 MHz is not
# an integer ratio of 25 MHz -- the wizard uses a fractional MMCM solution;
# check the generated clk_wiz_audio summary for the actual output freq/jitter.
#
# PRIM_SOURCE = Global_buffer: sysclk (E12) is on a HIGH_DENSITY (HDIO) bank,
# whose pins have no clock-capable path to the CMT. Feeding the MMCM straight
# from it trips DRC PLHDIO-4. Global_buffer makes the IP insert a BUFG between
# the input pad and the MMCM (Digilent's documented requirement for this clock).
create_ip -name clk_wiz -vendor xilinx.com -library ip \
    -module_name clk_wiz_audio

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ                {25.000} \
    CONFIG.PRIM_SOURCE                 {Global_buffer} \
    CONFIG.CLK_IN1_BOARD_INTERFACE     {Custom} \
    CONFIG.USE_BOARD_FLOW              {false} \
    CONFIG.CLKOUT1_USED                {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ  {12.288} \
    CONFIG.CLK_OUT1_PORT               {clk_out1} \
    CONFIG.USE_RESET                   {true} \
    CONFIG.RESET_TYPE                  {ACTIVE_HIGH} \
    CONFIG.USE_LOCKED                  {true} \
] [get_ips clk_wiz_audio]

generate_target all [get_files -of_objects [get_ips clk_wiz_audio]]

# ------ Methodology gate ------
# Fail implementation if report_methodology finds any Critical Warning
set_property STEPS.ROUTE_DESIGN.TCL.POST \
    [file normalize scripts/check_methodology.tcl] [get_runs impl_1]

# ------ Set synthesis and simulation tops ------
set_property top $synth_top [current_fileset]
update_compile_order -fileset sources_1

set_property top $sim_top [get_filesets sim_1]
update_compile_order -fileset sim_1

# ------ Summary ------
puts ""
puts "=================================================================="
puts "  Project created at $proj_dir/$proj_name.xpr"
puts "  Synthesis top:  $synth_top"
puts "  Simulation top: $sim_top   (Vivado uses the real clk_wiz_audio IP)"
puts ""
puts "  For trustworthy command-line simulation instead, run:"
puts "    make -f scripts/sim.mk all"
puts "=================================================================="
