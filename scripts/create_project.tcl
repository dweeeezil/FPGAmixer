# =============================================================================
# create_project.tcl
#
# Regenerates the FPGAmixer Vivado project. Run once, then use the GUI (or
# run_sim.tcl for batch mode) for subsequent work.
#
# Usage (from repo root):
#     vivado -source scripts/create_project.tcl
# =============================================================================

set proj_name    "FPGAmixer"
set proj_dir     "vivado_project"
set part         "xc7z020clg400-1"
set board_part   "digilentinc.com:arty-z7-20:part0:1.1"
set current_phase "phase2_top"
set sim_top      "tb_i2s_loopback"

# ------ Verify we're at the repo root ------
foreach d {src/rtl src/sim constraints scripts} {
    if {![file isdirectory $d]} {
        puts "ERROR: expected directory '$d' not found under [pwd]"
        puts "       Run this script from the repo root."
        return
    }
}

# ------ Verify sim files actually exist (this is what broke last time) ------
set rtl_files [glob -nocomplain src/rtl/*.sv]
set sim_files [glob -nocomplain src/sim/*.sv]
set xdc_files [glob -nocomplain constraints/*.xdc]

if {[llength $rtl_files] == 0} {
    puts "ERROR: no RTL sources found in src/rtl/"
    return
}
if {[llength $sim_files] == 0} {
    puts "ERROR: no simulation sources found in src/sim/"
    puts "       Testbenches should be at src/sim/tb_*.sv"
    return
}
if {[llength $xdc_files] == 0} {
    puts "ERROR: no XDC constraints found in constraints/"
    return
}

puts "INFO: found [llength $rtl_files] RTL files, [llength $sim_files] sim files, [llength $xdc_files] XDC files"

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
add_files -norecurse -fileset constrs_1 $xdc_files

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

# ------ Set synthesis and simulation tops ------
set_property top $current_phase [current_fileset]
update_compile_order -fileset sources_1

set_property top $sim_top [get_filesets sim_1]
update_compile_order -fileset sim_1

# ------ Verify what got added ------
set added_sim_files [get_files -of_objects [get_filesets sim_1]]
puts ""
puts "=================================================================="
puts "  Project created at $proj_dir/$proj_name.xpr"
puts "  Synthesis top:  $current_phase"
puts "  Simulation top: $sim_top"
puts ""
puts "  Simulation fileset contains [llength $added_sim_files] files:"
foreach f $added_sim_files {
    puts "    [file tail $f]"
}
puts "=================================================================="
