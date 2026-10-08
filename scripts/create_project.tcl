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
set current_phase "phase9"
set synth_top     "${current_phase}_top"
# tb_mixer_core: the core alone, which builds against the real IP (the
# tb_phase3_* top-level TBs went with the Pmods, Phase 11 H.3; tb_top_windows
# needs the PS stub, which collides with the BD wrapper here).
set sim_top       "tb_mixer_core"
set xdc_file      "constraints/${current_phase}_genesys_zu.xdc"

# phase1 / phase2 : the historical loopback tops (phase1_top, phase2_top);
#                   archived in src/archive/ since Phase 11 H.3, so these two
#                   no longer build from this tree. phase3 still builds but,
#                   with the Pmods gone, has no audio in or out.
# phase3          : fpgamixer_top WITHOUT the PS -- the static core, every
#                   coefficient tied to its reset bank (identity, unity).
# phase4, phase5  : fpgamixer_top WITH the PS (INCLUDE_PS): the BD, the
#                   M_AXI_CTRL port and the matrix gain registers. Since the
#                   Phase 5 control plane landed these are the same build; the
#                   PS-only Phase 4 design is in git history (82d4386).
# phase8          : phase5 + the PS<->PL audio link (INCLUDE_LINK): the AMD
#                   Audio Formatter in the BD, pcm_link + its status window in
#                   fpgamixer_top, and the matrix grown to 12 x 12
#                   (docs/phase8_status_2026-09-25.md). The phase5 build (4 x 4,
#                   no link) is in git history before this change.
# phase9          : phase8 + the media-clock meter (INCLUDE_MCLK): the GEM
#                   TSU counter exported from the PS (tsu_timer_cnt, no PS
#                   setting changed) and a status window at 0x8000_2000
#                   (docs/phase9_status_2026-09-26.md, P9.3); its steering
#                   window at 0x8000_3000 (P9.4b); and since P9.5 link #2
#                   (INCLUDE_LINK2): a second Audio Formatter at 0x8011_0000
#                   + pcm_link + status window at 0x8000_4000, the AVB front
#                   door's PL half. phase8 stays selectable and builds its
#                   BD as before (the core is 20 x 20 in every build since
#                   P9.5, the link #2 channels silent without link #2).
#
# The top-level XDC names a few instances by path (u_clk/u_mmcm and
# u_jb|u_jc/u_fwd_*/u_oddr). Adding hierarchy ABOVE fpgamixer_top, or renaming
# those instances, needs that file updated in the same change: a missed path is
# only a critical warning at parse time, and implementation then fails in IO
# clock placement (seen 2026-09-22).
#
# scoped_xdc: module-scoped constraint files, as {file module} pairs. Each is
# applied to EVERY instance of its module (SCOPED_TO_REF), with cell names
# relative to the instance, so a constraint travels with its module instead of
# naming instance paths in the top-level XDC (docs/architecture_modules.md).
set include_ps   0
set include_link 0
set include_mclk 0
set include_link2 0
set include_link3 0
set scoped_xdc {}
if {$current_phase in {phase3 phase4 phase5 phase8 phase9}} {
    set synth_top "fpgamixer_top"
    set xdc_file  "constraints/fpgamixer_genesys_zu.xdc"
}
if {$current_phase in {phase4 phase5 phase8 phase9}} {
    set include_ps 1
    lappend scoped_xdc {constraints/coef_bank_handoff.xdc coef_bank_handoff}
    # Phase 9: the matrix's gains live in coef_bank_ram (the handoff above
    # stays for the reverse-direction status windows).
    lappend scoped_xdc {constraints/coef_bank_ram.xdc coef_bank_ram}
    # Phase 13: the peak meters behind the meter windows
    lappend scoped_xdc {constraints/pcm_peak.xdc pcm_peak}
}
if {$current_phase in {phase8 phase9}} {
    set include_link 1
    lappend scoped_xdc {constraints/async_fifo.xdc async_fifo}
}
if {$current_phase in {phase9}} {
    set include_mclk 1
    set include_link2 1
    # Phase 11 (H.3): link #3, the USB host front door (decision P1)
    set include_link3 1
    lappend scoped_xdc {constraints/media_clock_meter.xdc media_clock_meter}
    lappend scoped_xdc {constraints/media_clock_steer.xdc media_clock_steer}
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
    # the BD wrapper's sim stand-in (tb_top_windows); the real one is generated
    if {[string match "*ps_sys_wrapper_stub.sv" $f]} continue
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
foreach pair $scoped_xdc {
    lassign $pair f ref
    add_files -norecurse -fileset constrs_1 $f
    set_property SCOPED_TO_REF $ref [get_files $f]
    puts "INFO: $f scoped to every instance of '$ref'"
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

# Phase 9 (P9.4a, docs/phase9_status_2026-09-26.md): the dividers are FORCED.
# Left to itself the wizard picks 25 x 40.625 / 82.625 (VCO 1015.6 MHz) =
# 12.29198 MHz, +324 ppm: too far off for the media clock's phase-step
# steering (18.4 M steps/s). No single-MMCM setting reaches 12.288 MHz from
# 25 MHz; the closest all-integer one is 25 x 58 / 118 (VCO 1450 MHz) =
# 12.28814 MHz, +11.03 ppm, with a 12.3 ps fine-phase step (VCO/56).
# Integer dividers keep fine phase shift free of any fractional-divide
# restriction. The wizard only takes forced values in override mode; its
# own jitter figure then isn't recomputed, so the real jitter is read from
# Vivado's clock analysis after implementation (report_clocks / timing).
# (Requesting 12.288136 MHz instead gets the same ratio as 43.5 / 88.5, VCO
# 1087.5 MHz, fractional -- not used.)
#
# Phase 9 (P9.4b): dynamic fine phase shift on clk_out1 (mclk), driven by
# media_clock_steer. TRAP: in override mode USE_DYN_PHASE_SHIFT only adds the
# psclk/psen/psincdec/psdone ports -- the generated MMCM still had
# CLKOUT0_USE_FINE_PS("FALSE") (checked 2026-09-27), so the steering would
# silently do nothing. MMCM_CLKOUT0_USE_FINE_PS must be forced too, and is
# printed below. Builds without the steerer tie psen low.
set_property CONFIG.USE_DYN_PHASE_SHIFT {true} [get_ips clk_wiz_audio]
set_property -dict [list \
    CONFIG.OVERRIDE_MMCM               {true} \
    CONFIG.MMCM_DIVCLK_DIVIDE          {1} \
    CONFIG.MMCM_CLKFBOUT_MULT_F        {58.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F       {118.000} \
    CONFIG.MMCM_CLKOUT0_USE_FINE_PS    {true} \
] [get_ips clk_wiz_audio]
puts "INFO: clk_wiz_audio forced: D=[get_property CONFIG.MMCM_DIVCLK_DIVIDE [get_ips clk_wiz_audio]]\
 M=[get_property CONFIG.MMCM_CLKFBOUT_MULT_F [get_ips clk_wiz_audio]]\
 O=[get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F [get_ips clk_wiz_audio]]\
 dyn_ps=[get_property CONFIG.USE_DYN_PHASE_SHIFT [get_ips clk_wiz_audio]]\
 clkout0_fine_ps=[get_property CONFIG.MMCM_CLKOUT0_USE_FINE_PS [get_ips clk_wiz_audio]]"
if {[get_property CONFIG.MMCM_CLKOUT0_USE_FINE_PS [get_ips clk_wiz_audio]] ne "true"} {
    puts "ERROR: clk_wiz_audio: CLKOUT0 fine phase shift is not enabled; the media-clock steering would do nothing"
    return
}

generate_target all [get_files -of_objects [get_ips clk_wiz_audio]]

# ------ One PS <-> PL link's BD half (Phase 8; link #2 in P9.5) --------------
# An AMD Audio Formatter named <cell>, 8 ch each way, formats at the IP
# defaults (see the Phase 8 block below): AXI/AXIS on pl_clk0, its registers on
# control-SmartConnect master <smc_mi>, its two DMA masters on <dma_smc> slave
# ports <dma_si> and <dma_si>+1, its IRQs on <irqs> inputs <irq_in> and
# <irq_in>+1, aud_mclk / aud_mreset from the shared link_mclk / link_mreset
# ports, and its streams exported as M_AXIS_<tag>_MM2S / S_AXIS_<tag>_S2MM.
# The caller assigns its register address. Returns the cell.
proc add_link_formatter {cell smc smc_mi dma_smc dma_si irqs irq_in tag rst pl_clk0_hz} {
    set fmt [create_bd_cell -type ip \
        -vlnv [get_ipdefs -filter {NAME == audio_formatter}] $cell]
    set_property -dict [list \
        CONFIG.C_INCLUDE_MM2S          {1} \
        CONFIG.C_INCLUDE_S2MM          {1} \
        CONFIG.C_MAX_NUM_CHANNELS_MM2S {8} \
        CONFIG.C_MAX_NUM_CHANNELS_S2MM {8} \
        CONFIG.C_PACKING_MODE_MM2S     {0} \
        CONFIG.C_PACKING_MODE_S2MM     {0} \
    ] $fmt

    foreach p {s_axi_lite_aclk m_axis_mm2s_aclk s_axis_s2mm_aclk} {
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins $fmt/$p]
    }
    foreach p {s_axi_lite_aresetn m_axis_mm2s_aresetn s_axis_s2mm_aresetn} {
        connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $fmt/$p]
    }
    connect_bd_intf_net [get_bd_intf_pins $smc/$smc_mi] [get_bd_intf_pins $fmt/s_axi_lite]

    connect_bd_net [get_bd_ports link_mclk]   [get_bd_pins $fmt/aud_mclk]
    connect_bd_net [get_bd_ports link_mreset] [get_bd_pins $fmt/aud_mreset]

    connect_bd_intf_net [get_bd_intf_pins $fmt/m_axi_mm2s] \
        [get_bd_intf_pins $dma_smc/[format S%02d_AXI $dma_si]]
    connect_bd_intf_net [get_bd_intf_pins $fmt/m_axi_s2mm] \
        [get_bd_intf_pins $dma_smc/[format S%02d_AXI [expr {$dma_si + 1}]]]

    connect_bd_net [get_bd_pins $fmt/irq_mm2s] [get_bd_pins $irqs/In$irq_in]
    connect_bd_net [get_bd_pins $fmt/irq_s2mm] [get_bd_pins $irqs/In[expr {$irq_in + 1}]]

    set m_mm2s [create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_${tag}_MM2S]
    connect_bd_intf_net [get_bd_intf_pins $fmt/m_axis_mm2s] $m_mm2s
    set s_s2mm [create_bd_intf_port -mode Slave \
        -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_${tag}_S2MM]
    set_property -dict [list \
        CONFIG.TDATA_NUM_BYTES {4} CONFIG.TID_WIDTH {8} \
        CONFIG.HAS_TREADY {1} CONFIG.FREQ_HZ $pl_clk0_hz \
    ] $s_s2mm
    connect_bd_intf_net $s_s2mm [get_bd_intf_pins $fmt/s_axis_s2mm]
    return $fmt
}

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
    # -> external port M_AXI_CTRL, which fpgamixer_top connects to
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
    # M00 = matrix window; with the link also M01 = link status window and
    # M02 = the Audio Formatter's own registers (below); phase9 adds
    # M03 = the media-clock status window and M04 = its steering window,
    # and (P9.5) M05 = formatter #2, M06 = link #2's status window.
    # Phase 12: the four bus-layer windows take the next four masters in
    # every PS build (M01-M04 in phase5, M03-M06 in phase8, M07-M10 in phase9);
    # Phase 13: the three meter windows the next three (phase9: M11-M13).
    # Phase 11 (H.3, phase9): M14 = formatter #3, M15 = link #3's status
    # window -- 16 masters, the SmartConnect's limit.
    set n_mi_base [expr {$include_link2 ? 7 : ($include_mclk ? 5 : ($include_link ? 3 : 1))}]
    set_property -dict [list CONFIG.NUM_SI {1} \
        CONFIG.NUM_MI [expr {$n_mi_base + 7 + ($include_link3 ? 2 : 0)}]] $smc
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
    # (Phase 8 extends ASSOCIATED_BUSIF once the link ports exist; naming a
    # port before it is created only warns and is dropped.)
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

    # ----- Phase 8: the PS <-> PL audio link (docs/phase8_status_2026-09-25.md) -----
    # AMD Audio Formatter (PG330, no-charge IP): DMA between DDR ring buffers
    # and AXI4-Stream audio. Linux drives it with the in-kernel ASoC driver
    # xlnx_formatter_pcm (compatible "xlnx,audio-formatter-1.0").
    #   registers : control SmartConnect M02, 0x8010_0000 (64K). Driver-owned
    #               devices live at 0x801x_xxxx; 0x8000_x000 stays for our
    #               self-describing windows (ID/CONFIG header).
    #   DMA       : m_axi_mm2s + m_axi_s2mm -> SmartConnect -> S_AXI_HPC0_FPD,
    #               which the preset already enables and clocks from pl_clk0.
    #               So, as in Phase 5, NO PS8 setting changes.
    #   IRQs      : irq_mm2s, irq_s2mm -> xlconcat -> pl_ps_irq0 (enabled by
    #               the preset).
    #   streams   : exported as M_AXIS_LINK_MM2S / S_AXIS_LINK_S2MM on pl_clk0;
    #               pcm_link in fpgamixer_top crosses them to mclk.
    #   aud_mclk  : = the design's mclk (input port link_mclk). The formatter
    #               paces MM2S at aud_mclk / Fs multiplier, which is what puts
    #               the Linux-side ALSA card on mclk time. FREQ_HZ on the port is
    #               the nominal 12.288 MHz (it reaches the device tree; the real
    #               clock is 12.2919 MHz, see the status doc).
    # Formatter modes are its defaults: MM2S PCM -> AES and S2MM AES -> PCM,
    # i.e. PCM (S24_LE) in memory and the AES3-subframe layout on the stream
    # (sample at TDATA[27:4]), which is what pcm_link expects.
    #
    # P9.5 (link #2, phase9): a second formatter, link2_formatter, built by the
    # same proc (add_link_formatter): registers on M05 at 0x8011_0000, DMA on
    # the same SmartConnect (4 slaves) into HPC0, IRQs on the same concat (4
    # inputs) into pl_ps_irq0, the SAME aud_mclk (link_mclk), streams
    # M_AXIS_LINK2_MM2S / S_AXIS_LINK2_S2MM. Still no PS8 setting changes.
    if {$include_link} {
        set n_links [expr {$include_link3 ? 3 : ($include_link2 ? 2 : 1)}]

        set link_mclk [create_bd_port -dir I -type clk -freq_hz 12288000 link_mclk]
        set link_mreset [create_bd_port -dir I -type rst link_mreset]
        set_property CONFIG.POLARITY {ACTIVE_HIGH} $link_mreset

        set dma_smc [create_bd_cell -type ip \
            -vlnv [get_ipdefs -filter {NAME == smartconnect}] link_dma_smc]
        set_property -dict [list CONFIG.NUM_SI [expr {2 * $n_links}] CONFIG.NUM_MI {1}] $dma_smc
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins $dma_smc/aclk]
        connect_bd_net [get_bd_pins $rst/interconnect_aresetn] [get_bd_pins $dma_smc/aresetn]
        connect_bd_intf_net [get_bd_intf_pins $dma_smc/M00_AXI] \
                            [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HPC0_FPD]

        set irqs [create_bd_cell -type ip \
            -vlnv [get_ipdefs -filter {NAME == xlconcat}] link_irqs]
        set_property CONFIG.NUM_PORTS [expr {2 * $n_links}] $irqs
        connect_bd_net [get_bd_pins $irqs/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

        set fmt [add_link_formatter link_formatter $smc M02_AXI $dma_smc 0 $irqs 0 \
                     LINK $rst $pl_clk0_hz]

        # Link status window: plain RTL (pcm_link_stat_regs) outside the BD,
        # like the matrix window.
        set m_stat [create_bd_intf_port -mode Master \
            -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_LINKSTAT]
        set_property -dict [list \
            CONFIG.PROTOCOL   {AXI4LITE} \
            CONFIG.DATA_WIDTH {32} \
            CONFIG.ADDR_WIDTH {32} \
            CONFIG.FREQ_HZ    $pl_clk0_hz \
        ] $m_stat
        connect_bd_intf_net [get_bd_intf_pins $smc/M01_AXI] $m_stat

        # (phase9 appends M_AXI_MCLKSTAT below, once that port exists.)
        set_property CONFIG.ASSOCIATED_BUSIF \
            {M_AXI_CTRL:M_AXI_LINKSTAT:M_AXIS_LINK_MM2S:S_AXIS_LINK_S2MM} \
            [get_bd_ports ctrl_aclk]

        assign_bd_address -offset 0x80001000 -range 4K \
            -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
            [get_bd_addr_segs M_AXI_LINKSTAT/Reg]

        # ----- Phase 9 (P9.3): media-clock meter -----
        # The GEM0 TSU counter is already a PS output (it appeared when the
        # TSU was enabled in Phase 4); exporting it to the RTL changes no PS
        # setting. The RTL uses the inverse of bit 45 as a 1PPS (UG1085 v2.5
        # p. 1061). Its status window is plain RTL (media_clock_stat_regs),
        # like the other windows.
        if {$include_mclk} {
            set tsu_cnt [create_bd_port -dir O -from 93 -to 0 tsu_timer_cnt]
            connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/emio_enet0_enet_tsu_timer_cnt] $tsu_cnt

            set m_mclk [create_bd_intf_port -mode Master \
                -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_MCLKSTAT]
            set_property -dict [list \
                CONFIG.PROTOCOL   {AXI4LITE} \
                CONFIG.DATA_WIDTH {32} \
                CONFIG.ADDR_WIDTH {32} \
                CONFIG.FREQ_HZ    $pl_clk0_hz \
            ] $m_mclk
            connect_bd_intf_net [get_bd_intf_pins $smc/M03_AXI] $m_mclk
            assign_bd_address -offset 0x80002000 -range 4K \
                -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                [get_bd_addr_segs M_AXI_MCLKSTAT/Reg]

            # P9.4b: the steering window (media_clock_ctrl_regs, RW)
            set m_mctl [create_bd_intf_port -mode Master \
                -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_MCLKCTRL]
            set_property -dict [list \
                CONFIG.PROTOCOL   {AXI4LITE} \
                CONFIG.DATA_WIDTH {32} \
                CONFIG.ADDR_WIDTH {32} \
                CONFIG.FREQ_HZ    $pl_clk0_hz \
            ] $m_mctl
            connect_bd_intf_net [get_bd_intf_pins $smc/M04_AXI] $m_mctl
            assign_bd_address -offset 0x80003000 -range 4K \
                -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                [get_bd_addr_segs M_AXI_MCLKCTRL/Reg]

            set_property CONFIG.ASSOCIATED_BUSIF \
                {M_AXI_CTRL:M_AXI_LINKSTAT:M_AXI_MCLKSTAT:M_AXI_MCLKCTRL:M_AXIS_LINK_MM2S:S_AXIS_LINK_S2MM} \
                [get_bd_ports ctrl_aclk]
        }
        assign_bd_address -offset 0x80100000 -range 64K \
            -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
            [get_bd_addr_segs $fmt/s_axi_lite/reg0]
        set fmts [list $fmt]

        # ----- Phase 9 (P9.5): link #2, the AVB front door's PL half -----
        # Formatter #2 on M05 at 0x8011_0000 (driver-owned range, like #1);
        # its status window (pcm_link_stat_regs u_link2_stat) on M06 at
        # 0x8000_4000, the next free window slot (decision L3).
        if {$include_link2} {
            set fmt2 [add_link_formatter link2_formatter $smc M05_AXI $dma_smc 2 $irqs 2 \
                          LINK2 $rst $pl_clk0_hz]
            assign_bd_address -offset 0x80110000 -range 64K \
                -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                [get_bd_addr_segs $fmt2/s_axi_lite/reg0]
            lappend fmts $fmt2

            set m_stat2 [create_bd_intf_port -mode Master \
                -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_LINK2STAT]
            set_property -dict [list \
                CONFIG.PROTOCOL   {AXI4LITE} \
                CONFIG.DATA_WIDTH {32} \
                CONFIG.ADDR_WIDTH {32} \
                CONFIG.FREQ_HZ    $pl_clk0_hz \
            ] $m_stat2
            connect_bd_intf_net [get_bd_intf_pins $smc/M06_AXI] $m_stat2
            assign_bd_address -offset 0x80004000 -range 4K \
                -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
                [get_bd_addr_segs M_AXI_LINK2STAT/Reg]

            set_property CONFIG.ASSOCIATED_BUSIF \
                {M_AXI_CTRL:M_AXI_LINKSTAT:M_AXI_MCLKSTAT:M_AXI_MCLKCTRL:M_AXI_LINK2STAT:M_AXIS_LINK_MM2S:S_AXIS_LINK_S2MM:M_AXIS_LINK2_MM2S:S_AXIS_LINK2_S2MM} \
                [get_bd_ports ctrl_aclk]
        }

        # The formatters' DMA masters see DDR through HPC0.
        assign_bd_address
        foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] {
            puts "INFO: PS address map: [get_property NAME $seg] \
[get_property OFFSET $seg] [get_property RANGE $seg]"
        }
        foreach f $fmts {
            foreach sp [get_bd_addr_spaces $f/*] {
                foreach seg [get_bd_addr_segs -of_objects $sp] {
                    puts "INFO: [get_property NAME $f] [get_property NAME $sp] -> \
[get_property NAME $seg] [get_property OFFSET $seg] [get_property RANGE $seg]"
                }
            }
        }
    }

    # ----- Phase 12: the bus layer's windows (decision L6) -----
    # Plain RTL bindings in fpgamixer_top, like the matrix window: the bus
    # matrix (matrix_regs_axil u_busmx_regs) and the input / bus / output
    # level stages (gain_regs_axil u_inlvl_regs / u_buslvl_regs /
    # u_outlvl_regs), on the SmartConnect masters after the ones above, at the
    # next free window slots. Still no PS8 setting changes.
    # Phase 13 (decision M4): the three peak-meter windows (peak_regs_axil
    # u_inmtr_regs / u_busmtr_regs / u_outmtr_regs) follow, the same way.
    set mi $n_mi_base
    foreach {port offset} {M_AXI_BUSMX  0x80005000 M_AXI_INLVL  0x80006000 \
                           M_AXI_BUSLVL 0x80007000 M_AXI_OUTLVL 0x80008000 \
                           M_AXI_INMTR  0x80009000 M_AXI_BUSMTR 0x8000A000 \
                           M_AXI_OUTMTR 0x8000B000} {
        set p [create_bd_intf_port -mode Master \
            -vlnv xilinx.com:interface:aximm_rtl:1.0 $port]
        set_property -dict [list \
            CONFIG.PROTOCOL   {AXI4LITE} \
            CONFIG.DATA_WIDTH {32} \
            CONFIG.ADDR_WIDTH {32} \
            CONFIG.FREQ_HZ    $pl_clk0_hz \
        ] $p
        connect_bd_intf_net [get_bd_intf_pins $smc/[format "M%02d_AXI" $mi]] $p
        assign_bd_address -offset $offset -range 4K \
            -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
            [get_bd_addr_segs $port/Reg]
        puts "INFO: $port = [get_property OFFSET [get_bd_addr_segs \
zynq_ultra_ps_e_0/Data/SEG_${port}_Reg]] (4K) on [format "M%02d" $mi]"
        incr mi
    }
    set_property CONFIG.ASSOCIATED_BUSIF \
        "[get_property CONFIG.ASSOCIATED_BUSIF [get_bd_ports ctrl_aclk]]:M_AXI_BUSMX:M_AXI_INLVL:M_AXI_BUSLVL:M_AXI_OUTLVL:M_AXI_INMTR:M_AXI_BUSMTR:M_AXI_OUTMTR" \
        [get_bd_ports ctrl_aclk]

    # ----- Phase 11 (H.3): link #3, the USB host front door (decision P1) -----
    # A third copy of link #1/#2 (add_link_formatter): formatter #3's
    # registers on M14 at 0x8012_0000 (driver-owned range, like #1 and #2),
    # its DMA on link_dma_smc S04/S05 into HPC0, its IRQs on link_irqs In4/In5,
    # the same aud_mclk, streams M_AXIS_LINK3_MM2S / S_AXIS_LINK3_S2MM; its
    # status window (pcm_link_stat_regs u_link3_stat) on M15 at 0x8000_C000,
    # the next free window slot. It follows the Phase 12/13 windows so their
    # master numbers don't move. Still no PS8 setting changes.
    if {$include_link3} {
        set fmt3 [add_link_formatter link3_formatter $smc [format "M%02d_AXI" $mi] \
                      $dma_smc 4 $irqs 4 LINK3 $rst $pl_clk0_hz]
        assign_bd_address -offset 0x80120000 -range 64K \
            -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
            [get_bd_addr_segs $fmt3/s_axi_lite/reg0]
        puts "INFO: link3_formatter = 0x80120000 (64K) on [format "M%02d" $mi]"
        incr mi

        set m_stat3 [create_bd_intf_port -mode Master \
            -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_LINK3STAT]
        set_property -dict [list \
            CONFIG.PROTOCOL   {AXI4LITE} \
            CONFIG.DATA_WIDTH {32} \
            CONFIG.ADDR_WIDTH {32} \
            CONFIG.FREQ_HZ    $pl_clk0_hz \
        ] $m_stat3
        connect_bd_intf_net [get_bd_intf_pins $smc/[format "M%02d_AXI" $mi]] $m_stat3
        assign_bd_address -offset 0x8000C000 -range 4K \
            -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
            [get_bd_addr_segs M_AXI_LINK3STAT/Reg]
        puts "INFO: M_AXI_LINK3STAT = 0x8000C000 (4K) on [format "M%02d" $mi]"
        incr mi

        set_property CONFIG.ASSOCIATED_BUSIF \
            "[get_property CONFIG.ASSOCIATED_BUSIF [get_bd_ports ctrl_aclk]]:M_AXI_LINK3STAT:M_AXIS_LINK3_MM2S:S_AXIS_LINK3_S2MM" \
            [get_bd_ports ctrl_aclk]

        # Its DMA masters see DDR through HPC0, like #1 and #2.
        assign_bd_address
        foreach sp [get_bd_addr_spaces $fmt3/*] {
            foreach seg [get_bd_addr_segs -of_objects $sp] {
                puts "INFO: link3_formatter [get_property NAME $sp] -> \
[get_property NAME $seg] [get_property OFFSET $seg] [get_property RANGE $seg]"
            }
        }
    }

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

    # Turns on the `ifdef INCLUDE_PS instance of ps_sys_wrapper in fpgamixer_top.
    if {$include_link3} {
        set_property verilog_define {INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK INCLUDE_LINK2 INCLUDE_LINK3} [get_filesets sources_1]
        puts "INFO: verilog_define INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK INCLUDE_LINK2 INCLUDE_LINK3 -- + link #3 (USB host)"
    } elseif {$include_link2} {
        set_property verilog_define {INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK INCLUDE_LINK2} [get_filesets sources_1]
        puts "INFO: verilog_define INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK INCLUDE_LINK2 -- + media clock, link #2"
    } elseif {$include_mclk} {
        set_property verilog_define {INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK} [get_filesets sources_1]
        puts "INFO: verilog_define INCLUDE_PS INCLUDE_LINK INCLUDE_MCLK -- + media-clock meter"
    } elseif {$include_link} {
        set_property verilog_define {INCLUDE_PS INCLUDE_LINK} [get_filesets sources_1]
        puts "INFO: verilog_define INCLUDE_PS INCLUDE_LINK -- PS + PS<->PL audio link"
    } else {
        set_property verilog_define {INCLUDE_PS} [get_filesets sources_1]
        puts "INFO: verilog_define INCLUDE_PS set -- fpgamixer_top instantiates the PS"
    }
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
