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
set part          "xc7z020clg400-1"
set board_part    "digilentinc.com:arty-z7-20:part0:1.1"

# ------ Phase selection -------------------------------------------------------
# current_phase drives BOTH the synthesis top module and which XDC is used.
set current_phase "phase3"
set synth_top     "${current_phase}_top"
set sim_top       "tb_phase3_datapath"
set xdc_file      "constraints/${current_phase}_arty_z7.xdc"

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
set_property BOARD_PART      $board_part [current_project]
set_property TARGET_LANGUAGE Verilog     [current_project]

# ------ Add sources ------
add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset sim_1     $sim_files
add_files -norecurse -fileset constrs_1 $xdc_file

# ------ Clocking Wizard IP: 125 MHz -> ~12.288 MHz ------
create_ip -name clk_wiz -vendor xilinx.com -library ip \
    -module_name clk_wiz_audio

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ                {125.000} \
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
