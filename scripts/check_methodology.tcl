# =============================================================================
# check_methodology.tcl
#
# Post-route hook: runs report_methodology on the routed design and FAILS the
# implementation run if any Critical Warning is found.
#
# Why this exists: the Phase 3 duplicate-create_clock bug (TIMING-6, "no
# common primary clock") invalidated all static timing analysis while WNS
# still looked healthy. Nothing in the normal flow forced anyone to look at
# the methodology report. This hook makes that class of problem a build
# failure instead of a footnote.
#
# Wired in by create_project.tcl as STEPS.ROUTE_DESIGN.TCL.POST on impl_1,
# so it runs automatically inside the run context (routed design already
# open in memory). It can also be sourced manually with a routed design open.
# =============================================================================

puts "INFO: \[check_methodology\] running post-route methodology check..."

set rpt_file "postroute_methodology.rpt"
report_methodology -file $rpt_file

set crit_msgs {}

# Preferred path: query violation objects directly.
if {[catch {
    foreach v [get_methodology_violations -quiet] {
        if {[get_property SEVERITY $v] eq "Critical Warning"} {
            lappend crit_msgs "[get_property CHECK $v]: [get_property DESCRIPTION $v]"
        }
    }
} err]} {
    # Fallback if that API isn't available in this Vivado version: scan the
    # report text's summary table for Critical Warning rows.
    puts "WARNING: \[check_methodology\] get_methodology_violations unavailable ($err); parsing $rpt_file instead"
    set fh [open $rpt_file r]
    set rpt_text [read $fh]
    close $fh
    foreach line [split $rpt_text "\n"] {
        if {[string match "*| Critical Warning |*" $line]} {
            lappend crit_msgs [string trim $line]
        }
    }
}

if {[llength $crit_msgs] > 0} {
    puts "ERROR: \[check_methodology\] methodology Critical Warning(s) found:"
    foreach m $crit_msgs {
        puts "ERROR: \[check_methodology\]   $m"
    }
    puts "ERROR: \[check_methodology\] full report: \[run dir\]/$rpt_file"
    error "Methodology check failed: [llength $crit_msgs] Critical Warning(s). STA results may be invalid -- do not trust WNS until this is fixed."
}

puts "INFO: \[check_methodology\] PASS -- no methodology Critical Warnings."