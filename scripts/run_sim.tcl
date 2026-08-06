# =============================================================================
# run_sim.tcl
#
# Runs all Phase 2 testbenches back-to-back in batch mode and prints
# pass/fail summaries. Uses the existing project at vivado_project/; run
# scripts/create_project.tcl first if the project doesn't exist yet.
#
# Usage (from the repo root):
#     vivado -mode batch -source scripts/run_sim.tcl
#
# Or from an interactive Vivado Tcl Console with the project already open:
#     source scripts/run_sim.tcl
# =============================================================================

set proj_file "vivado_project/FPGAmixer.xpr"

if {![file exists $proj_file]} {
    puts "ERROR: $proj_file not found. Run scripts/create_project.tcl first."
    return
}

# Open the project if it isn't already open. When running under
# `vivado -mode batch`, no project is open initially.
if {[catch {current_project}]} {
    open_project $proj_file
}

# List of testbench top modules to run, in order.
set testbenches {
    tb_i2s_receiver
    tb_i2s_transmitter
    tb_i2s_loopback
}

foreach tb $testbenches {
    puts ""
    puts "------------------------------------------------------------------"
    puts "  Running $tb"
    puts "------------------------------------------------------------------"

    # Point the sim fileset at this testbench and launch behavioral sim.
    set_property top $tb [get_filesets sim_1]

    # If a previous simulation is still open, close it before relaunching.
    if {![catch {current_sim}]} {
        close_sim -quiet
    }

    launch_simulation -mode behavioral
    run all
    close_sim
}

puts ""
puts "=================================================================="
puts "  All testbenches complete."
puts "  Look for 'PASS:' or 'FAIL:' lines above for each testbench."
puts "=================================================================="
