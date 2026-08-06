# =============================================================================
# create_project.tcl
#
# Regenerates the FPGAmixer Vivado project from the sources in this repo.
#
# Usage (from the repo root):
#     vivado -source scripts/create_project.tcl
#
# Or from within Vivado's Tcl Console:
#     source scripts/create_project.tcl
#
# This wipes and recreates ./vivado_project/. Nothing under vivado_project/
# should be committed to git - it's a build artifact of this script.
# =============================================================================

set proj_name  "FPGAmixer"
set proj_dir   "vivado_project"
set part       "xc7z020clg400-1"
set board_part "digilentinc.com:arty-z7-20:part0:1.1"

# ------ Locate repo root ------
# This script assumes it's being sourced from the repo root, i.e. the current
# working directory contains src/, constraints/, scripts/, etc. Verify:
if {![file isdirectory "src/rtl"] || ![file isdirectory "constraints"]} {
    puts "ERROR: create_project.tcl must be run from the repo root."
    puts "       Expected to find src/rtl/ and constraints/ in [pwd]"
    return
}

# ------ Wipe any previous project directory ------
if {[file exists $proj_dir]} {
    puts "INFO: Removing existing $proj_dir/"
    file delete -force $proj_dir
}

# ------ Create project ------
create_project $proj_name $proj_dir -part $part -force
set_property BOARD_PART $board_part [current_project]
set_property TARGET_LANGUAGE Verilog [current_project]

# ------ Add RTL sources ------
add_files -norecurse -fileset sources_1 [glob src/rtl/*.sv]

# ------ Add constraint files ------
add_files -norecurse -fileset constrs_1 [glob constraints/*.xdc]

# ------ Create Clocking Wizard IP: 125 MHz -> ~12.288 MHz ------
# All IP configuration lives here rather than in a checked-in .xci file, so
# there's a single source of truth. Vivado picks the exact MMCM dividers to
# best approximate 12.288 MHz; typical result is within ~0.02%.
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

# ------ Set top module and refresh compile order ------
set_property top phase1_top [current_fileset]
update_compile_order -fileset sources_1

puts ""
puts "=================================================================="
puts "  Project created at $proj_dir/$proj_name.xpr"
puts "  Top module:        phase1_top"
puts "  Board:             $board_part"
puts ""
puts "  Next steps:"
puts "    1. Run synthesis + implementation + bitstream"
puts "    2. Plug Pmod I2S2 into JA (jumper JP1 in SLV position)"
puts "    3. Program the FPGA over JTAG"
puts "    4. Line In of the Pmod = source, Line Out = looped-back audio"
puts "=================================================================="
