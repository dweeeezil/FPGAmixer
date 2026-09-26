# =============================================================================
# async_fifo.xdc -- CDC constraints for EVERY async_fifo instance
#
# Scoped to the module (scripts/create_project.tcl sets SCOPED_TO_REF
# async_fifo on this file), so cell names are relative to each instance. Keep
# the register names in step with src/rtl/async_fifo.sv.
#
# The two clocks are unrelated (pcm_link: AXI pl_clk0 and audio mclk). The ONLY
# paths between them inside the module:
#   1. wptr_gray -> rsync_wptr1   Gray pointer into a 2FF synchronizer
#   2. rptr_gray -> wsync_rptr1   Gray pointer into a 2FF synchronizer
#   3. mem (LUTRAM, written in wclk) -> read-side logic, through the
#      combinational read. A word is read >= 2 rclk cycles after its pointer
#      crossed, so only a routing bound is needed.
#
# For Gray pointers the bound must stay below one source period so that at most
# one bit is in flight: 10 ns = one pl_clk0 period at 100 MHz (the faster
# domain; mclk is 81 ns).
# =============================================================================

set_max_delay -datapath_only 10.000 \
    -from [get_cells {wptr_gray_reg[*]}] \
    -to   [get_cells {rsync_wptr1_reg[*]}]

set_max_delay -datapath_only 10.000 \
    -from [get_cells {rptr_gray_reg[*]}] \
    -to   [get_cells {wsync_rptr1_reg[*]}]

# Path 3 ends outside this module (rdata feeds the instantiating block's rclk
# registers), so it is bounded by its source alone: every path out of mem is a
# read-side path, since the write side never reads the array.
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hierarchical -filter {NAME =~ *mem_reg*}]
