# =============================================================================
# build.tcl -- batch build of the project made by create_project.tcl
#
# Usage (from repo root, after create_project.tcl):
#     vivado -mode batch -source scripts/build.tcl -tclargs <tag> [jobs]
#
# Runs synthesis and implementation through write_bitstream (the methodology
# gate in check_methodology.tcl runs after routing), then writes:
#   build/<tag>_timing.rpt        report_timing_summary (+ the 20 worst paths)
#   build/<tag>_util.rpt          report_utilization
#   build/<tag>_cdc.rpt           report_cdc -details
#   build/<tag>_clocks.rpt        report_clock_interaction
#   build/<tag>_exceptions.rpt    report_exceptions (which max-delays applied)
#   build/fpgamixer_<tag>.xsa     write_hw_platform -fixed -include_bit
# and prints WNS / WHS / failing endpoints. Exits non-zero if timing fails.
# =============================================================================

set tag  [lindex $argv 0]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
if {$tag eq ""} {
    puts "usage: vivado -mode batch -source scripts/build.tcl -tclargs <tag> \[jobs\]"
    exit 2
}

open_project vivado_project/FPGAmixer.xpr
file mkdir build

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synthesis failed"; exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: implementation failed (see vivado_project/FPGAmixer.runs/impl_1)"; exit 1
}

open_run impl_1
report_timing_summary -max_paths 20 -file build/${tag}_timing.rpt
report_utilization                  -file build/${tag}_util.rpt
report_cdc -details                 -file build/${tag}_cdc.rpt
report_clock_interaction            -file build/${tag}_clocks.rpt
report_exceptions                   -file build/${tag}_exceptions.rpt

write_hw_platform -fixed -include_bit -force build/fpgamixer_${tag}.xsa

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fails [llength [get_timing_paths -max_paths 1000 -slack_lesser_than 0]]
puts "RESULT: WNS $wns ns, WHS $whs ns, failing paths (of first 1000) $fails"
puts "RESULT: XSA build/fpgamixer_${tag}.xsa"
if {$wns < 0 || $whs < 0} { exit 1 }
exit 0
