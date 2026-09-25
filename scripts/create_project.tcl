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

# NOTE (board files): board files installed from the XHub board store are NOT
# picked up automatically -- get_board_parts returns nothing until
# board.repoPaths points at the store's boards/ directory (verified 2026-09-22,
# Vivado 2026.1). The block below sets it when that directory exists. Without a
# board part there is no "Apply Board Preset", so phase4 cannot configure the PS.
# To install the board files: Vivado XHub Store, or
#   xhub::install [xhub::get_xitems -filter {NAME =~ *gzu_3eg*}]
set xhub_boards \
  "$::env(APPDATA)/Xilinx/Vivado/2026.1/xhub/board_store/xilinx_board_store/XilinxBoardStore/Vivado/2026.1/boards"
if {[file isdirectory $xhub_boards]} {
    set_param board.repoPaths $xhub_boards
    puts "INFO: board.repoPaths -> $xhub_boards"
}

# ------ Phase selection -------------------------------------------------------
# current_phase drives the synthesis top module, which XDC is used, and (phase4
# onwards) whether the PS block design is built.
set current_phase "phase5"
set synth_top     "${current_phase}_top"
set sim_top       "tb_phase3_datapath"
set xdc_file      "constraints/${current_phase}_genesys_zu.xdc"

# phase4 = the hardware-verified phase3 datapath + the PS, so it keeps BOTH
# phase3_top and the Phase 3 XDC. The PS is instantiated inside phase3_top
# under `ifdef INCLUDE_PS.
#
# Do NOT wrap phase3_top in a higher-level top to add the PS: the XDC names
# instances by absolute path (u_fwd_*/u_oddr/C), so an extra hierarchy level
# drops 25 constraints and implementation fails in IO clock placement. Tried
# 2026-09-22; that is what the `ifdef exists to avoid.
#
# phase5 = phase4 + the AXI4-Lite gain registers (matrix_regs_axil, reached
# through M_AXI_CTRL on the BD) and their CDC constraints. The PS itself is
# configured identically.
set include_ps 0
set extra_xdc  {}
if {$current_phase in {phase4 phase5}} {
    set include_ps 1
    set synth_top "phase3_top"
    set xdc_file  "constraints/phase3_genesys_zu.xdc"
}
if {$current_phase eq "phase5"} {
    lappend extra_xdc "constraints/phase5_cdc.xdc"
}

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
    if {$include_ps} {
        puts "ERROR: phase '$current_phase' needs the board file: the PS is configured"
        puts "       by Apply Board Preset (DDR4 part/timing + the MIO map for UART,"
        puts "       SD, Ethernet and USB). Those values come from Digilent's"
        puts "       preset.xml and must not be entered by hand. Install the board"
        puts "       file, then re-run."
        return
    }
}

# ------ Add sources ------
add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset sim_1     $sim_files
add_files -norecurse -fileset constrs_1 $xdc_file
foreach f $extra_xdc {
    add_files -norecurse -fileset constrs_1 $f
}

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

# ------ PS block design (phase4+) --------------------------------------------
# The BD holds the Zynq UltraScale+ PS plus one constant (the GEM0 TSU
# increment-control tie-off, below). Everything board-specific in
# it comes from Apply Board Preset (Digilent's preset.xml), never from values
# typed in here. The preset provides DDR4 (DDR4_1866L, 64-bit), UART0 on
# MIO18-19, SD1 on MIO39-51 with card detect, USB0/USB1, and Ethernet on
# *ENET0/GEM0*, MIO26-37, MDIO on MIO76-77.
#
# GEM0 TSU (IEEE 1588 time stamp unit) is the one setting added on top of the
# preset, which leaves it off. Why it's needed, from the driver source
# (Xilinx linux-xlnx, drivers/net/ethernet/cadence/):
#   - macb_main.c gem_get_tsu_rate() reads the "tsu_clk" clock from the device
#     tree; if it is absent it silently falls back to pclk's rate.
#   - macb_ptp.c gem_ptp_init_timer() turns that rate into the timer increment
#     (ns + sub-ns per tick). A wrong rate => a PTP clock that runs at the wrong
#     speed, which is far worse to debug than one that plainly doesn't work.
#   - zynqmp.dtsi wires gem0's "tsu_clk" to the PS GEM_TSU clock, and that
#     clock's frequency is programmed from THIS PS configuration.
# Enabling it makes Vivado configure GEM_TSU_REF_CTRL = IOPLL / 250 MHz
# (divisors 6/1). 250 MHz divides 1e9 exactly -> a whole-number 4 ns increment
# with no sub-ns remainder. Phase 9 (gPTP/AVB) depends on this being right.
if {$include_ps} {
    set bd_name "ps_sys"
    create_bd_design $bd_name
    set ps [create_bd_cell -type ip \
        -vlnv [get_ipdefs -filter {NAME == zynq_ultra_ps_e}] zynq_ultra_ps_e_0]
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} $ps

    set_property -dict [list CONFIG.PSU__ENET0__TSU__ENABLE {1}] $ps

    # Enabling the TSU exposes emio_enet0_tsu_inc_ctrl[1:0], and the BD ties an
    # unconnected input to 2'b00. UG1085 (v2.5) ch.34 "Precision Time Protocol
    # via EMIO": "Whenever exposed, gem_tsu_inc_ctrl[1:0] SHOULD BE tied to 0b11
    # in order for GEM TSU to increment normally". With 00, GEM0 (gem_tsu_ms = 1)
    # clears the ns register and bumps seconds on every tsu_clk cycle. Measured
    # over JTAG before this tie-off (2026-09-24): tsu_timer_nsec stuck at 0,
    # tsu_timer_sec rising ~250 M/s; ptp4l saw constant RX timestamps ("bad
    # timestamps in nrate calculation").
    set tsu_inc [create_bd_cell -type ip \
        -vlnv [get_ipdefs -filter {NAME == xlconstant}] tsu_inc_ctrl_normal]
    set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {3}] $tsu_inc
    connect_bd_net [get_bd_pins $tsu_inc/dout] \
                   [get_bd_pins zynq_ultra_ps_e_0/emio_enet0_tsu_inc_ctrl]

    # The preset also turns on PSU_DYNAMIC_DDR_CONFIG_EN. That defines
    # XPAR_DYNAMIC_DDR_ENABLED, which makes psu_init() skip the static DDR init
    # and has FSBL call XFsbl_DdrInit() instead (embeddedsw zynqmp_fsbl,
    # xfsbl_initialization.c). XFsbl_IicReadSpdEeprom() is hard-wired to the
    # ZCU102/106 topology: I2C1, a TCA9548 mux at 0x75, channel 0x08, then the
    # SODIMM SPD. On this board it fails, FSBL returns XFSBL_FAILURE (0x3FFFFFFF)
    # from stage 1, falls back (multiboot++ and a soft reset), and the ROM ends
    # with CSU_BR_ERROR 0x4B -- a silent board that looks like a ROM failure.
    # The static values the preset generates are proven: psu_init.tcl brings
    # DDR up over JTAG every time.
    set_property -dict [list CONFIG.PSU_DYNAMIC_DDR_CONFIG_EN {0}] $ps

    # With dynamic config off, the static DDR geometry must match the SODIMM
    # actually fitted. The preset describes x8 4 Gb devices (2 bank-group
    # bits), matching the originally bundled Kingston HX424S14IB/4. This board
    # ships with a Kingston CBD26D4S9S1KC-4: 4 GB, 1Rx16, four 512M x16 (8 Gb)
    # devices -- x16 DDR4 has ONE bank-group bit. With the x8 map, BG1 sits on
    # HIF bit 11 = byte address bit 14 (ADDRMAP8 BG_B1 0x8 + base 3), which
    # drives nothing: 0x30000000 and 0x30004000 alias (measured over JTAG with
    # mwr/mrd, 2026-09-24). Everything bulk-loaded into DDR was folded in 16 KB
    # steps -- the "xsdb dow is broken" symptom and FSBL's bitstream staging.
    # The SODIMM is user-replaceable: a different module needs these changed.
    # Vivado does not re-derive the address counts from width/capacity; it
    # flags them instead (PSU-2: BG must be 1 for x16; PSU-3: row must be 16
    # for 8 Gb), so all four are set together.
    set_property -dict [list \
        CONFIG.PSU__DDRC__DRAM_WIDTH      {16 Bits} \
        CONFIG.PSU__DDRC__DEVICE_CAPACITY {8192 MBits} \
        CONFIG.PSU__DDRC__BG_ADDR_COUNT   {1} \
        CONFIG.PSU__DDRC__ROW_ADDR_COUNT  {16} \
    ] $ps

    # The preset enables M_AXI_HPM0_LPD and S_AXI_HPC0_FPD. Their aclk pins are
    # unconnected out of the box and validate_bd_design fails on that, so clock
    # them from pl_clk0 (100 MHz). S_AXI_HPC0_FPD is still unused.
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
                   [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk] \
                   [get_bd_pins zynq_ultra_ps_e_0/saxihpc0_fpd_aclk]

    # ----- Phase 5: AXI4-Lite control port for the matrix gains -----
    # M_AXI_HPM0_LPD -> SmartConnect (AXI4 -> AXI4-Lite, ID/burst handling)
    # -> external port M_AXI_CTRL, which phase3_top connects to
    # matrix_regs_axil. The register block is plain RTL outside the BD so the
    # Icarus/XSim testbenches exercise the same source that is synthesized.
    # Mapped at 0x8000_0000 (start of the LPD PL window), 4 KB.
    #
    # No PS configuration changes: the PS8 settings (and so psu_init, the
    # FSBL, and the machine config) are identical to Phase 4. The XSA still
    # changes (new bitstream, new hwh), so the sdtgen -> bitbake chain is rerun.
    set rst [create_bd_cell -type ip \
        -vlnv [get_ipdefs -filter {NAME == proc_sys_reset}] rst_ctrl]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
                   [get_bd_pins $rst/slowest_sync_clk]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
                   [get_bd_pins $rst/ext_reset_in]

    set smc [create_bd_cell -type ip \
        -vlnv [get_ipdefs -filter {NAME == smartconnect}] ctrl_smc]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $smc
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] \
                        [get_bd_intf_pins $smc/S00_AXI]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins $smc/aclk]
    connect_bd_net [get_bd_pins $rst/interconnect_aresetn] [get_bd_pins $smc/aresetn]

    set pl_clk0_hz [get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]]
    set m_ctrl [create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_CTRL]
    set_property -dict [list \
        CONFIG.PROTOCOL   {AXI4LITE} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.ADDR_WIDTH {32} \
        CONFIG.FREQ_HZ    $pl_clk0_hz \
    ] $m_ctrl
    connect_bd_intf_net [get_bd_intf_pins $smc/M00_AXI] $m_ctrl

    set ctrl_clk [create_bd_port -dir O -type clk ctrl_aclk]
    set_property -dict [list \
        CONFIG.FREQ_HZ          $pl_clk0_hz \
        CONFIG.ASSOCIATED_BUSIF {M_AXI_CTRL} \
        CONFIG.ASSOCIATED_RESET {ctrl_aresetn} \
    ] $ctrl_clk
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $ctrl_clk
    set ctrl_rst [create_bd_port -dir O -type rst ctrl_aresetn]
    set_property CONFIG.POLARITY {ACTIVE_LOW} $ctrl_rst
    connect_bd_net [get_bd_pins $rst/peripheral_aresetn] $ctrl_rst

    assign_bd_address -offset 0x80000000 -range 4K \
        -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
        [get_bd_addr_segs M_AXI_CTRL/Reg]
    puts "INFO: M_AXI_CTRL      = [get_property OFFSET [get_bd_addr_segs \
zynq_ultra_ps_e_0/Data/SEG_M_AXI_CTRL_Reg]] (4K), pl_clk0 $pl_clk0_hz Hz"

    puts "INFO: PS Ethernet     = ENET0/GEM0 [get_property CONFIG.PSU__ENET0__PERIPHERAL__IO $ps]"
    puts "INFO: PS GEM0 TSU     = [get_property CONFIG.PSU__ENET0__TSU__ENABLE $ps] \
(src [get_property CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__SRCSEL $ps], \
[get_property CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__ACT_FREQMHZ $ps] MHz)"
    puts "INFO: PS DDR          = [get_property CONFIG.PSU__DDRC__MEMORY_TYPE $ps] \
[get_property CONFIG.PSU__DDRC__SPEED_BIN $ps]"
    puts "INFO: PS DDR geometry = x[get_property CONFIG.PSU__DDRC__DRAM_WIDTH $ps],\
[get_property CONFIG.PSU__DDRC__DEVICE_CAPACITY $ps],\
BG [get_property CONFIG.PSU__DDRC__BG_ADDR_COUNT $ps],\
BA [get_property CONFIG.PSU__DDRC__BANK_ADDR_COUNT $ps],\
row [get_property CONFIG.PSU__DDRC__ROW_ADDR_COUNT $ps],\
col [get_property CONFIG.PSU__DDRC__COL_ADDR_COUNT $ps],\
dynamic [get_property CONFIG.PSU_DYNAMIC_DDR_CONFIG_EN $ps]"

    validate_bd_design
    save_bd_design
    add_files -norecurse [make_wrapper -files [get_files ${bd_name}.bd] -top]

    # Turns on the `ifdef INCLUDE_PS instance of ps_sys_wrapper in phase3_top.
    set_property verilog_define {INCLUDE_PS} [get_filesets sources_1]
    puts "INFO: verilog_define INCLUDE_PS set -- phase3_top instantiates the PS"
}

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
