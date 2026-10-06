// -----------------------------------------------------------------------------
// fpgamixer_top.sv
//
// Platform layer (docs/architecture_modules.md): wires the blocks together and
// holds nothing else. Formerly phase3_top.
//
//   sysclk -> audio_clocking -> mclk, rst_n, sclk, lrck  (shared by everything)
//
//   Pmod JB pins <-> i2s_port u_jb <-> PCM ch0 (L), ch1 (R) ----.
//   Pmod JC pins <-> i2s_port u_jc <-> PCM ch2 (L), ch3 (R) -----+-> mixer_core
//   PS (Audio Formatter #1) <-> pcm_link u_link  <-> ch4..11 ---+   u_core
//   PS (Audio Formatter #2) <-> pcm_link u_link2 <-> ch12..19 --'
//                    (Phase 12: 20 in -> levels -> input matrix -> 20 buses
//                     -> levels -> bus matrix -> levels -> 20 out)
//   control plane (INCLUDE_PS): PS -> M_AXI_CTRL -> matrix_regs_axil u_regs
//                                   -> input matrix read port -> u_core
//                  Phase 12: M_AXI_BUSMX -> matrix_regs_axil u_busmx_regs,
//                  M_AXI_INLVL / BUSLVL / OUTLVL -> gain_regs_axil
//                  u_inlvl_regs / u_buslvl_regs / u_outlvl_regs
//                  Phase 13: the core's tap ports -> peak_regs_axil
//                  u_inmtr_regs / u_busmtr_regs / u_outmtr_regs <-
//                  M_AXI_INMTR / BUSMTR / OUTMTR (the meters)
//                  (without the PS: coef_flat_readers over the reset banks)
//                  (INCLUDE_LINK): PS -> M_AXI_LINKSTAT -> pcm_link_stat_regs
//                  (INCLUDE_LINK2): PS -> M_AXI_LINK2STAT -> pcm_link_stat_regs
//   platform (INCLUDE_MCLK, phase9): PS tsu_timer_cnt[45] (1PPS) ->
//                  media_clock_meter -> media_clock_stat_regs <- M_AXI_MCLKSTAT
//
// Everything this file decides:
//   - the channel map: which front-door channel is which core channel;
//   - N_BUS (= N, decision L2) and the reset state: IN_MX_GAINS, BUS_MX_GAINS
//     (identity), LEVEL_GAINS (unity);
//   - where the coefficients come from: the PS (INCLUDE_PS builds), or the
//     reset banks tied on directly (non-PS projects and the Icarus/XSim
//     integration TBs);
//   - whether the PS<->PL links exist (INCLUDE_LINK, phase8 builds; link #2,
//     INCLUDE_LINK2, phase9 builds: the AVB front door's PL half). Without a
//     link its channels read as silence, so the core is 20 x 20 in every
//     build and the non-PS TBs see the same Pmod routing as before.
//
// NOTE (ZU-3EG): the JB/JC names match the board's silkscreen -- module #1 is on
// Pmod JB, module #2 on Pmod JC. (The ZU-3EG's Pmod JA is the analog XADC Pmod,
// LVCMOS18 + RC-filtered, so it can't carry the I2S2; JB/JC are the digital
// Pmods.) See the constraints file headers for the pin map.
//
// Constraint paths: the board XDC (constraints/fpgamixer_genesys_zu.xdc) names
// u_clk/u_mmcm and u_jb|u_jc/u_fwd_*/u_oddr. Renaming these instances, or
// adding hierarchy ABOVE this module, means updating that file in the same
// change -- a missed path is only a critical warning at XDC parse time, and the
// build then fails in IO clock placement (seen 2026-09-22).
// -----------------------------------------------------------------------------
module fpgamixer_top (
    input  logic sysclk,       // 25 MHz PL ref, pin E12 (LVCMOS18)

    // ----- Pmod JB : Pmod I2S2 #1 -----
    output logic jb_da_mclk,   // JB1
    output logic jb_da_lrck,   // JB2
    output logic jb_da_sclk,   // JB3
    output logic jb_da_sdin,   // JB4
    output logic jb_ad_mclk,   // JB7
    output logic jb_ad_lrck,   // JB8
    output logic jb_ad_sclk,   // JB9
    input  logic jb_ad_sdout,  // JB10

    // ----- Pmod JC : Pmod I2S2 #2 -----
    output logic jc_da_mclk,   // JC1
    output logic jc_da_lrck,   // JC2
    output logic jc_da_sclk,   // JC3
    output logic jc_da_sdin,   // JC4
    output logic jc_ad_mclk,   // JC7
    output logic jc_ad_lrck,   // JC8
    output logic jc_ad_sclk,   // JC9
    input  logic jc_ad_sdout   // JC10
);

    localparam int N_PMOD = 4;              // 2 per Pmod
    localparam int N_LINK  = 8;             // PS<->PL link #1 (USB), each way
    localparam int N_LINK2 = 8;             // PS<->PL link #2 (AVB), each way
    localparam int N  = N_PMOD + N_LINK + N_LINK2;  // core channels in = out
    localparam int SW = 24;
    localparam int GW = 18;    // gain width,  Q2.16
    localparam int GF = 16;    // gain fraction bits

    // ----- Clock domain -----
    logic mclk, rst_n, sclk, lrck, mmcm_locked;
    // MMCM fine phase shift: driven by media_clock_steer in INCLUDE_MCLK
    // builds (PSCLK = pl_clk0, decision S1), tied off otherwise.
    logic ps_clk, ps_en, ps_incdec, ps_done;

    audio_clocking u_clk (
        .sysclk (sysclk),
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck),
        .mmcm_locked (mmcm_locked),
        .psclk (ps_clk), .psen (ps_en), .psincdec (ps_incdec), .psdone (ps_done)
    );

`ifndef INCLUDE_MCLK
    assign ps_clk    = 1'b0;
    assign ps_en     = 1'b0;
    assign ps_incdec = 1'b0;
`endif

    // ----- Front doors -----
    logic [2*SW-1:0] jb_rx, jb_tx, jc_rx, jc_tx;
    logic            jb_rx_valid, jc_rx_valid;  // identical timing (shared LRCK)

    i2s_port #(.SW (SW)) u_jb (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck),
        .da_mclk (jb_da_mclk), .da_lrck (jb_da_lrck), .da_sclk (jb_da_sclk),
        .da_sdin (jb_da_sdin),
        .ad_mclk (jb_ad_mclk), .ad_lrck (jb_ad_lrck), .ad_sclk (jb_ad_sclk),
        .ad_sdout (jb_ad_sdout),
        .rx_flat (jb_rx), .rx_valid (jb_rx_valid), .tx_flat (jb_tx)
    );

    i2s_port #(.SW (SW)) u_jc (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck),
        .da_mclk (jc_da_mclk), .da_lrck (jc_da_lrck), .da_sclk (jc_da_sclk),
        .da_sdin (jc_da_sdin),
        .ad_mclk (jc_ad_mclk), .ad_lrck (jc_ad_lrck), .ad_sclk (jc_ad_sclk),
        .ad_sdout (jc_ad_sdout),
        .rx_flat (jc_rx), .rx_valid (jc_rx_valid), .tx_flat (jc_tx)
    );

    // ----- PS<->PL link front doors (PCM side) -----
    logic [N_LINK*SW-1:0]  link_rx,  link_tx;   // rx = into the core, from the PS
    logic [N_LINK2*SW-1:0] link2_rx, link2_tx;

    // ----- Channel map (core ch0 at the LSB) -----
    //   ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R   (inputs and outputs)
    //   ch4..ch11 = link #1 channels 0..7: inputs = what the PS plays (USB: the
    //   Mac's outputs 1-8), outputs = what the PS records (the Mac's inputs 1-8)
    //   ch12..ch19 = link #2 channels 0..7 (Phase 9, P9.5: the AVB front door's
    //   ALSA card FPGAmixerLink2; inputs = what the PS plays into it)
    // New channels are appended, never interleaved, so saved crosspoint
    // indices keep their meaning when the core grows.
    logic [N*SW-1:0] core_in, core_out;
    assign core_in = { link2_rx, link_rx, jc_rx, jb_rx };
    assign { link2_tx, link_tx, jc_tx, jb_tx } = core_out;

    // ----- Buses (Phase 12, decision L2): one per output -----
    // With the bus matrix at identity, bus k feeds output k, so input -> bus k
    // sounds exactly like the old input -> output k (L3: saved inputMatrix
    // crosspoints keep their meaning).
    localparam int N_BUS = N;

    // ----- Reset state (Q2.16; a matrix's gain k = dst*N_src + src) -----
    localparam logic signed [GW-1:0] G_UNITY = 18'sh10000;

    // IDENTITY: input k -> bus k -> output k at unity, every level at unity
    // (L7). For the Pmods that is each ADC passed to its own DAC (the minimal
    // datapath test: noise here points at clocking or the ports, not the
    // routing); for each link it is the PS's playback returned to its capture.
    // Runtime control (INCLUDE_PS) starts from these banks, and the OSC server
    // seeds missing parameters with the same rule. Other routings for a non-PS
    // build: git history before Phase 8 has a worked 4 x 4 DEMO bank.
    function automatic logic [N_BUS*N*GW-1:0] identity_in_mx();     // rows = buses
        logic [N_BUS*N*GW-1:0] g = '0;
        for (int b = 0; b < N_BUS && b < N; b++) g[(b*N + b)*GW +: GW] = G_UNITY;
        return g;
    endfunction
    function automatic logic [N*N_BUS*GW-1:0] identity_bus_mx();    // rows = outputs
        logic [N*N_BUS*GW-1:0] g = '0;
        for (int o = 0; o < N && o < N_BUS; o++) g[(o*N_BUS + o)*GW +: GW] = G_UNITY;
        return g;
    endfunction
    function automatic logic [N*GW-1:0] unity_levels();             // N in = N_BUS = N out
        logic [N*GW-1:0] g;
        for (int c = 0; c < N; c++) g[c*GW +: GW] = G_UNITY;
        return g;
    endfunction
    localparam logic [N_BUS*N*GW-1:0] IN_MX_GAINS  = identity_in_mx();
    localparam logic [N*N_BUS*GW-1:0] BUS_MX_GAINS = identity_bus_mx();
    localparam logic [N*GW-1:0]       LEVEL_GAINS  = unity_levels();

    // ----- Control plane: where the coefficients come from -----
    // The core reads each block's coefficients through a read port
    // (docs/architecture_modules.md 3): from the PS's register windows
    // (coef_bank_ram inside matrix_regs_axil / gain_regs_axil), or from the
    // reset banks above through coef_flat_readers. Matrix stores are sized by
    // the same lane counts as the core (mixer_core_pkg's chooser).
    localparam int L1     = mixer_core_pkg::chain_l1(N, N_BUS, N);
    localparam int L2     = mixer_core_pkg::chain_l2(N, N_BUS, N);
    localparam int IMX_AW = $clog2(pcm_matrix_pkg::matrix_passes(N_BUS, L1) * N);
    localparam int BMX_AW = $clog2(pcm_matrix_pkg::matrix_passes(N, L2) * N_BUS);
    localparam int CW     = $clog2(N);
    logic [CW-1:0]     in_lvl_addr, bus_lvl_addr, out_lvl_addr;
    logic [GW-1:0]     in_lvl_data, bus_lvl_data, out_lvl_data;
    logic [IMX_AW-1:0] in_mx_addr;
    logic [L1*GW-1:0]  in_mx_data;
    logic [BMX_AW-1:0] bus_mx_addr;
    logic [L2*GW-1:0]  bus_mx_data;

    // the core's tap ports (Phase 13): the level stages' output streams,
    // metered in PS builds (unused without the PS)
    logic                 tap_in_valid, tap_bus_valid, tap_out_valid;
    logic [CW-1:0]        tap_in_ch, tap_out_ch;
    logic [$clog2(N_BUS)-1:0] tap_bus_ch;
    logic [SW-1:0]        tap_in_data, tap_bus_data, tap_out_data;

`ifdef INCLUDE_PS
    // ps_sys_wrapper (the BD) exports M_AXI_CTRL (AXI4-Lite, through a
    // SmartConnect off M_AXI_HPM0_LPD), its clock (pl_clk0) and a synchronized
    // reset. Only the low 12 bits of the address reach the register block;
    // the BD maps a 4 KB window at 0x8000_0000.
    //
    // Guarded by a define, not a parameter, so the text is removed by the
    // preprocessor: non-PS projects and the command-line sims never reference
    // a module that only exists once scripts/create_project.tcl builds the BD.
    logic        ctrl_aclk, ctrl_aresetn;
    logic [31:0] ctrl_awaddr, ctrl_araddr;
    logic [2:0]  ctrl_awprot, ctrl_arprot;
    logic        ctrl_awvalid, ctrl_awready, ctrl_wvalid, ctrl_wready;
    logic [31:0] ctrl_wdata, ctrl_rdata;
    logic [3:0]  ctrl_wstrb;
    logic [1:0]  ctrl_bresp, ctrl_rresp;
    logic        ctrl_bvalid, ctrl_bready, ctrl_arvalid, ctrl_arready;
    logic        ctrl_rvalid, ctrl_rready;

    // Phase 12 (decision L6): the bus matrix and the three level stages, one
    // AXI4-Lite window each, on the same clock and reset as M_AXI_CTRL:
    //   M_AXI_BUSMX  0x8000_5000  bmx_*   M_AXI_INLVL  0x8000_6000  ilv_*
    //   M_AXI_BUSLVL 0x8000_7000  blv_*   M_AXI_OUTLVL 0x8000_8000  olv_*
    logic [31:0] bmx_awaddr, bmx_araddr, bmx_wdata, bmx_rdata;
    logic [2:0]  bmx_awprot, bmx_arprot;
    logic [3:0]  bmx_wstrb;
    logic [1:0]  bmx_bresp, bmx_rresp;
    logic        bmx_awvalid, bmx_awready, bmx_wvalid, bmx_wready;
    logic        bmx_bvalid, bmx_bready, bmx_arvalid, bmx_arready;
    logic        bmx_rvalid, bmx_rready;
    logic [31:0] ilv_awaddr, ilv_araddr, ilv_wdata, ilv_rdata;
    logic [2:0]  ilv_awprot, ilv_arprot;
    logic [3:0]  ilv_wstrb;
    logic [1:0]  ilv_bresp, ilv_rresp;
    logic        ilv_awvalid, ilv_awready, ilv_wvalid, ilv_wready;
    logic        ilv_bvalid, ilv_bready, ilv_arvalid, ilv_arready;
    logic        ilv_rvalid, ilv_rready;
    logic [31:0] blv_awaddr, blv_araddr, blv_wdata, blv_rdata;
    logic [2:0]  blv_awprot, blv_arprot;
    logic [3:0]  blv_wstrb;
    logic [1:0]  blv_bresp, blv_rresp;
    logic        blv_awvalid, blv_awready, blv_wvalid, blv_wready;
    logic        blv_bvalid, blv_bready, blv_arvalid, blv_arready;
    logic        blv_rvalid, blv_rready;
    logic [31:0] olv_awaddr, olv_araddr, olv_wdata, olv_rdata;
    logic [2:0]  olv_awprot, olv_arprot;
    logic [3:0]  olv_wstrb;
    logic [1:0]  olv_bresp, olv_rresp;
    logic        olv_awvalid, olv_awready, olv_wvalid, olv_wready;
    logic        olv_bvalid, olv_bready, olv_arvalid, olv_arready;
    logic        olv_rvalid, olv_rready;

    // Phase 13 (decision M4): the three peak-meter windows, the same way:
    //   M_AXI_INMTR 0x8000_9000 imt_*   M_AXI_BUSMTR 0x8000_A000 bmt_*
    //   M_AXI_OUTMTR 0x8000_B000 omt_*
    logic [31:0] imt_awaddr, imt_araddr, imt_wdata, imt_rdata;
    logic [2:0]  imt_awprot, imt_arprot;
    logic [3:0]  imt_wstrb;
    logic [1:0]  imt_bresp, imt_rresp;
    logic        imt_awvalid, imt_awready, imt_wvalid, imt_wready;
    logic        imt_bvalid, imt_bready, imt_arvalid, imt_arready;
    logic        imt_rvalid, imt_rready;
    logic [31:0] bmt_awaddr, bmt_araddr, bmt_wdata, bmt_rdata;
    logic [2:0]  bmt_awprot, bmt_arprot;
    logic [3:0]  bmt_wstrb;
    logic [1:0]  bmt_bresp, bmt_rresp;
    logic        bmt_awvalid, bmt_awready, bmt_wvalid, bmt_wready;
    logic        bmt_bvalid, bmt_bready, bmt_arvalid, bmt_arready;
    logic        bmt_rvalid, bmt_rready;
    logic [31:0] omt_awaddr, omt_araddr, omt_wdata, omt_rdata;
    logic [2:0]  omt_awprot, omt_arprot;
    logic [3:0]  omt_wstrb;
    logic [1:0]  omt_bresp, omt_rresp;
    logic        omt_awvalid, omt_awready, omt_wvalid, omt_wready;
    logic        omt_bvalid, omt_bready, omt_arvalid, omt_arready;
    logic        omt_rvalid, omt_rready;

`ifdef INCLUDE_LINK
    // Link: formatter streams (pl_clk0) and the status window's AXI4-Lite port
    logic [31:0] mm2s_tdata, s2mm_tdata;
    logic [7:0]  mm2s_tid,   s2mm_tid;
    logic        mm2s_tvalid, mm2s_tready, s2mm_tvalid, s2mm_tready;

    logic [31:0] stat_awaddr, stat_araddr, stat_wdata, stat_rdata;
    logic [2:0]  stat_awprot, stat_arprot;
    logic [3:0]  stat_wstrb;
    logic [1:0]  stat_bresp, stat_rresp;
    logic        stat_awvalid, stat_awready, stat_wvalid, stat_wready;
    logic        stat_bvalid, stat_bready, stat_arvalid, stat_arready;
    logic        stat_rvalid, stat_rready;
`endif

`ifdef INCLUDE_LINK2
    // Link #2 (Phase 9, P9.5): the same set of ports as link #1
    logic [31:0] mm2s2_tdata, s2mm2_tdata;
    logic [7:0]  mm2s2_tid,   s2mm2_tid;
    logic        mm2s2_tvalid, mm2s2_tready, s2mm2_tvalid, s2mm2_tready;

    logic [31:0] stat2_awaddr, stat2_araddr, stat2_wdata, stat2_rdata;
    logic [2:0]  stat2_awprot, stat2_arprot;
    logic [3:0]  stat2_wstrb;
    logic [1:0]  stat2_bresp, stat2_rresp;
    logic        stat2_awvalid, stat2_awready, stat2_wvalid, stat2_wready;
    logic        stat2_bvalid, stat2_bready, stat2_arvalid, stat2_arready;
    logic        stat2_rvalid, stat2_rready;
`endif

`ifdef INCLUDE_MCLK
    // Media-clock meter (Phase 9, P9.3): the GEM TSU counter from the PS and
    // the meter's status window (0x8000_2000)
    logic [93:0] tsu_timer_cnt;
    // ... and the steering window (0x8000_3000, P9.4b)
    logic [31:0] ms_awaddr, ms_araddr, ms_wdata, ms_rdata;
    logic [2:0]  ms_awprot, ms_arprot;
    logic [3:0]  ms_wstrb;
    logic [1:0]  ms_bresp, ms_rresp;
    logic        ms_awvalid, ms_awready, ms_wvalid, ms_wready;
    logic        ms_bvalid, ms_bready, ms_arvalid, ms_arready;
    logic        ms_rvalid, ms_rready;
    logic [31:0] mc_awaddr, mc_araddr, mc_wdata, mc_rdata;
    logic [2:0]  mc_awprot, mc_arprot;
    logic [3:0]  mc_wstrb;
    logic [1:0]  mc_bresp, mc_rresp;
    logic        mc_awvalid, mc_awready, mc_wvalid, mc_wready;
    logic        mc_bvalid, mc_bready, mc_arvalid, mc_arready;
    logic        mc_rvalid, mc_rready;
`endif

    ps_sys_wrapper u_ps (
`ifdef INCLUDE_MCLK
        .tsu_timer_cnt              (tsu_timer_cnt),
        .M_AXI_MCLKCTRL_awaddr      (ms_awaddr),
        .M_AXI_MCLKCTRL_awprot      (ms_awprot),
        .M_AXI_MCLKCTRL_awvalid     (ms_awvalid),
        .M_AXI_MCLKCTRL_awready     (ms_awready),
        .M_AXI_MCLKCTRL_wdata       (ms_wdata),
        .M_AXI_MCLKCTRL_wstrb       (ms_wstrb),
        .M_AXI_MCLKCTRL_wvalid      (ms_wvalid),
        .M_AXI_MCLKCTRL_wready      (ms_wready),
        .M_AXI_MCLKCTRL_bresp       (ms_bresp),
        .M_AXI_MCLKCTRL_bvalid      (ms_bvalid),
        .M_AXI_MCLKCTRL_bready      (ms_bready),
        .M_AXI_MCLKCTRL_araddr      (ms_araddr),
        .M_AXI_MCLKCTRL_arprot      (ms_arprot),
        .M_AXI_MCLKCTRL_arvalid     (ms_arvalid),
        .M_AXI_MCLKCTRL_arready     (ms_arready),
        .M_AXI_MCLKCTRL_rdata       (ms_rdata),
        .M_AXI_MCLKCTRL_rresp       (ms_rresp),
        .M_AXI_MCLKCTRL_rvalid      (ms_rvalid),
        .M_AXI_MCLKCTRL_rready      (ms_rready),
        .M_AXI_MCLKSTAT_awaddr      (mc_awaddr),
        .M_AXI_MCLKSTAT_awprot      (mc_awprot),
        .M_AXI_MCLKSTAT_awvalid     (mc_awvalid),
        .M_AXI_MCLKSTAT_awready     (mc_awready),
        .M_AXI_MCLKSTAT_wdata       (mc_wdata),
        .M_AXI_MCLKSTAT_wstrb       (mc_wstrb),
        .M_AXI_MCLKSTAT_wvalid      (mc_wvalid),
        .M_AXI_MCLKSTAT_wready      (mc_wready),
        .M_AXI_MCLKSTAT_bresp       (mc_bresp),
        .M_AXI_MCLKSTAT_bvalid      (mc_bvalid),
        .M_AXI_MCLKSTAT_bready      (mc_bready),
        .M_AXI_MCLKSTAT_araddr      (mc_araddr),
        .M_AXI_MCLKSTAT_arprot      (mc_arprot),
        .M_AXI_MCLKSTAT_arvalid     (mc_arvalid),
        .M_AXI_MCLKSTAT_arready     (mc_arready),
        .M_AXI_MCLKSTAT_rdata       (mc_rdata),
        .M_AXI_MCLKSTAT_rresp       (mc_rresp),
        .M_AXI_MCLKSTAT_rvalid      (mc_rvalid),
        .M_AXI_MCLKSTAT_rready      (mc_rready),
`endif
`ifdef INCLUDE_LINK
        .link_mclk                  (mclk),
        .link_mreset                (!rst_n),
        .M_AXIS_LINK_MM2S_tdata     (mm2s_tdata),
        .M_AXIS_LINK_MM2S_tid       (mm2s_tid),
        .M_AXIS_LINK_MM2S_tvalid    (mm2s_tvalid),
        .M_AXIS_LINK_MM2S_tready    (mm2s_tready),
        .S_AXIS_LINK_S2MM_tdata     (s2mm_tdata),
        .S_AXIS_LINK_S2MM_tid       (s2mm_tid),
        .S_AXIS_LINK_S2MM_tvalid    (s2mm_tvalid),
        .S_AXIS_LINK_S2MM_tready    (s2mm_tready),
        .M_AXI_LINKSTAT_awaddr      (stat_awaddr),
        .M_AXI_LINKSTAT_awprot      (stat_awprot),
        .M_AXI_LINKSTAT_awvalid     (stat_awvalid),
        .M_AXI_LINKSTAT_awready     (stat_awready),
        .M_AXI_LINKSTAT_wdata       (stat_wdata),
        .M_AXI_LINKSTAT_wstrb       (stat_wstrb),
        .M_AXI_LINKSTAT_wvalid      (stat_wvalid),
        .M_AXI_LINKSTAT_wready      (stat_wready),
        .M_AXI_LINKSTAT_bresp       (stat_bresp),
        .M_AXI_LINKSTAT_bvalid      (stat_bvalid),
        .M_AXI_LINKSTAT_bready      (stat_bready),
        .M_AXI_LINKSTAT_araddr      (stat_araddr),
        .M_AXI_LINKSTAT_arprot      (stat_arprot),
        .M_AXI_LINKSTAT_arvalid     (stat_arvalid),
        .M_AXI_LINKSTAT_arready     (stat_arready),
        .M_AXI_LINKSTAT_rdata       (stat_rdata),
        .M_AXI_LINKSTAT_rresp       (stat_rresp),
        .M_AXI_LINKSTAT_rvalid      (stat_rvalid),
        .M_AXI_LINKSTAT_rready      (stat_rready),
`endif
`ifdef INCLUDE_LINK2
        .M_AXIS_LINK2_MM2S_tdata    (mm2s2_tdata),
        .M_AXIS_LINK2_MM2S_tid      (mm2s2_tid),
        .M_AXIS_LINK2_MM2S_tvalid   (mm2s2_tvalid),
        .M_AXIS_LINK2_MM2S_tready   (mm2s2_tready),
        .S_AXIS_LINK2_S2MM_tdata    (s2mm2_tdata),
        .S_AXIS_LINK2_S2MM_tid      (s2mm2_tid),
        .S_AXIS_LINK2_S2MM_tvalid   (s2mm2_tvalid),
        .S_AXIS_LINK2_S2MM_tready   (s2mm2_tready),
        .M_AXI_LINK2STAT_awaddr     (stat2_awaddr),
        .M_AXI_LINK2STAT_awprot     (stat2_awprot),
        .M_AXI_LINK2STAT_awvalid    (stat2_awvalid),
        .M_AXI_LINK2STAT_awready    (stat2_awready),
        .M_AXI_LINK2STAT_wdata      (stat2_wdata),
        .M_AXI_LINK2STAT_wstrb      (stat2_wstrb),
        .M_AXI_LINK2STAT_wvalid     (stat2_wvalid),
        .M_AXI_LINK2STAT_wready     (stat2_wready),
        .M_AXI_LINK2STAT_bresp      (stat2_bresp),
        .M_AXI_LINK2STAT_bvalid     (stat2_bvalid),
        .M_AXI_LINK2STAT_bready     (stat2_bready),
        .M_AXI_LINK2STAT_araddr     (stat2_araddr),
        .M_AXI_LINK2STAT_arprot     (stat2_arprot),
        .M_AXI_LINK2STAT_arvalid    (stat2_arvalid),
        .M_AXI_LINK2STAT_arready    (stat2_arready),
        .M_AXI_LINK2STAT_rdata      (stat2_rdata),
        .M_AXI_LINK2STAT_rresp      (stat2_rresp),
        .M_AXI_LINK2STAT_rvalid     (stat2_rvalid),
        .M_AXI_LINK2STAT_rready     (stat2_rready),
`endif
        .M_AXI_BUSMX_awaddr   (bmx_awaddr),
        .M_AXI_BUSMX_awprot   (bmx_awprot),
        .M_AXI_BUSMX_awvalid  (bmx_awvalid),
        .M_AXI_BUSMX_awready  (bmx_awready),
        .M_AXI_BUSMX_wdata    (bmx_wdata),
        .M_AXI_BUSMX_wstrb    (bmx_wstrb),
        .M_AXI_BUSMX_wvalid   (bmx_wvalid),
        .M_AXI_BUSMX_wready   (bmx_wready),
        .M_AXI_BUSMX_bresp    (bmx_bresp),
        .M_AXI_BUSMX_bvalid   (bmx_bvalid),
        .M_AXI_BUSMX_bready   (bmx_bready),
        .M_AXI_BUSMX_araddr   (bmx_araddr),
        .M_AXI_BUSMX_arprot   (bmx_arprot),
        .M_AXI_BUSMX_arvalid  (bmx_arvalid),
        .M_AXI_BUSMX_arready  (bmx_arready),
        .M_AXI_BUSMX_rdata    (bmx_rdata),
        .M_AXI_BUSMX_rresp    (bmx_rresp),
        .M_AXI_BUSMX_rvalid   (bmx_rvalid),
        .M_AXI_BUSMX_rready   (bmx_rready),
        .M_AXI_INLVL_awaddr   (ilv_awaddr),
        .M_AXI_INLVL_awprot   (ilv_awprot),
        .M_AXI_INLVL_awvalid  (ilv_awvalid),
        .M_AXI_INLVL_awready  (ilv_awready),
        .M_AXI_INLVL_wdata    (ilv_wdata),
        .M_AXI_INLVL_wstrb    (ilv_wstrb),
        .M_AXI_INLVL_wvalid   (ilv_wvalid),
        .M_AXI_INLVL_wready   (ilv_wready),
        .M_AXI_INLVL_bresp    (ilv_bresp),
        .M_AXI_INLVL_bvalid   (ilv_bvalid),
        .M_AXI_INLVL_bready   (ilv_bready),
        .M_AXI_INLVL_araddr   (ilv_araddr),
        .M_AXI_INLVL_arprot   (ilv_arprot),
        .M_AXI_INLVL_arvalid  (ilv_arvalid),
        .M_AXI_INLVL_arready  (ilv_arready),
        .M_AXI_INLVL_rdata    (ilv_rdata),
        .M_AXI_INLVL_rresp    (ilv_rresp),
        .M_AXI_INLVL_rvalid   (ilv_rvalid),
        .M_AXI_INLVL_rready   (ilv_rready),
        .M_AXI_BUSLVL_awaddr  (blv_awaddr),
        .M_AXI_BUSLVL_awprot  (blv_awprot),
        .M_AXI_BUSLVL_awvalid (blv_awvalid),
        .M_AXI_BUSLVL_awready (blv_awready),
        .M_AXI_BUSLVL_wdata   (blv_wdata),
        .M_AXI_BUSLVL_wstrb   (blv_wstrb),
        .M_AXI_BUSLVL_wvalid  (blv_wvalid),
        .M_AXI_BUSLVL_wready  (blv_wready),
        .M_AXI_BUSLVL_bresp   (blv_bresp),
        .M_AXI_BUSLVL_bvalid  (blv_bvalid),
        .M_AXI_BUSLVL_bready  (blv_bready),
        .M_AXI_BUSLVL_araddr  (blv_araddr),
        .M_AXI_BUSLVL_arprot  (blv_arprot),
        .M_AXI_BUSLVL_arvalid (blv_arvalid),
        .M_AXI_BUSLVL_arready (blv_arready),
        .M_AXI_BUSLVL_rdata   (blv_rdata),
        .M_AXI_BUSLVL_rresp   (blv_rresp),
        .M_AXI_BUSLVL_rvalid  (blv_rvalid),
        .M_AXI_BUSLVL_rready  (blv_rready),
        .M_AXI_OUTLVL_awaddr  (olv_awaddr),
        .M_AXI_OUTLVL_awprot  (olv_awprot),
        .M_AXI_OUTLVL_awvalid (olv_awvalid),
        .M_AXI_OUTLVL_awready (olv_awready),
        .M_AXI_OUTLVL_wdata   (olv_wdata),
        .M_AXI_OUTLVL_wstrb   (olv_wstrb),
        .M_AXI_OUTLVL_wvalid  (olv_wvalid),
        .M_AXI_OUTLVL_wready  (olv_wready),
        .M_AXI_OUTLVL_bresp   (olv_bresp),
        .M_AXI_OUTLVL_bvalid  (olv_bvalid),
        .M_AXI_OUTLVL_bready  (olv_bready),
        .M_AXI_OUTLVL_araddr  (olv_araddr),
        .M_AXI_OUTLVL_arprot  (olv_arprot),
        .M_AXI_OUTLVL_arvalid (olv_arvalid),
        .M_AXI_OUTLVL_arready (olv_arready),
        .M_AXI_OUTLVL_rdata   (olv_rdata),
        .M_AXI_OUTLVL_rresp   (olv_rresp),
        .M_AXI_OUTLVL_rvalid  (olv_rvalid),
        .M_AXI_OUTLVL_rready  (olv_rready),
        .M_AXI_INMTR_awaddr   (imt_awaddr),
        .M_AXI_INMTR_awprot   (imt_awprot),
        .M_AXI_INMTR_awvalid  (imt_awvalid),
        .M_AXI_INMTR_awready  (imt_awready),
        .M_AXI_INMTR_wdata    (imt_wdata),
        .M_AXI_INMTR_wstrb    (imt_wstrb),
        .M_AXI_INMTR_wvalid   (imt_wvalid),
        .M_AXI_INMTR_wready   (imt_wready),
        .M_AXI_INMTR_bresp    (imt_bresp),
        .M_AXI_INMTR_bvalid   (imt_bvalid),
        .M_AXI_INMTR_bready   (imt_bready),
        .M_AXI_INMTR_araddr   (imt_araddr),
        .M_AXI_INMTR_arprot   (imt_arprot),
        .M_AXI_INMTR_arvalid  (imt_arvalid),
        .M_AXI_INMTR_arready  (imt_arready),
        .M_AXI_INMTR_rdata    (imt_rdata),
        .M_AXI_INMTR_rresp    (imt_rresp),
        .M_AXI_INMTR_rvalid   (imt_rvalid),
        .M_AXI_INMTR_rready   (imt_rready),
        .M_AXI_BUSMTR_awaddr  (bmt_awaddr),
        .M_AXI_BUSMTR_awprot  (bmt_awprot),
        .M_AXI_BUSMTR_awvalid (bmt_awvalid),
        .M_AXI_BUSMTR_awready (bmt_awready),
        .M_AXI_BUSMTR_wdata   (bmt_wdata),
        .M_AXI_BUSMTR_wstrb   (bmt_wstrb),
        .M_AXI_BUSMTR_wvalid  (bmt_wvalid),
        .M_AXI_BUSMTR_wready  (bmt_wready),
        .M_AXI_BUSMTR_bresp   (bmt_bresp),
        .M_AXI_BUSMTR_bvalid  (bmt_bvalid),
        .M_AXI_BUSMTR_bready  (bmt_bready),
        .M_AXI_BUSMTR_araddr  (bmt_araddr),
        .M_AXI_BUSMTR_arprot  (bmt_arprot),
        .M_AXI_BUSMTR_arvalid (bmt_arvalid),
        .M_AXI_BUSMTR_arready (bmt_arready),
        .M_AXI_BUSMTR_rdata   (bmt_rdata),
        .M_AXI_BUSMTR_rresp   (bmt_rresp),
        .M_AXI_BUSMTR_rvalid  (bmt_rvalid),
        .M_AXI_BUSMTR_rready  (bmt_rready),
        .M_AXI_OUTMTR_awaddr  (omt_awaddr),
        .M_AXI_OUTMTR_awprot  (omt_awprot),
        .M_AXI_OUTMTR_awvalid (omt_awvalid),
        .M_AXI_OUTMTR_awready (omt_awready),
        .M_AXI_OUTMTR_wdata   (omt_wdata),
        .M_AXI_OUTMTR_wstrb   (omt_wstrb),
        .M_AXI_OUTMTR_wvalid  (omt_wvalid),
        .M_AXI_OUTMTR_wready  (omt_wready),
        .M_AXI_OUTMTR_bresp   (omt_bresp),
        .M_AXI_OUTMTR_bvalid  (omt_bvalid),
        .M_AXI_OUTMTR_bready  (omt_bready),
        .M_AXI_OUTMTR_araddr  (omt_araddr),
        .M_AXI_OUTMTR_arprot  (omt_arprot),
        .M_AXI_OUTMTR_arvalid (omt_arvalid),
        .M_AXI_OUTMTR_arready (omt_arready),
        .M_AXI_OUTMTR_rdata   (omt_rdata),
        .M_AXI_OUTMTR_rresp   (omt_rresp),
        .M_AXI_OUTMTR_rvalid  (omt_rvalid),
        .M_AXI_OUTMTR_rready  (omt_rready),
        .ctrl_aclk            (ctrl_aclk),
        .ctrl_aresetn         (ctrl_aresetn),
        .M_AXI_CTRL_awaddr    (ctrl_awaddr),
        .M_AXI_CTRL_awprot    (ctrl_awprot),
        .M_AXI_CTRL_awvalid   (ctrl_awvalid),
        .M_AXI_CTRL_awready   (ctrl_awready),
        .M_AXI_CTRL_wdata     (ctrl_wdata),
        .M_AXI_CTRL_wstrb     (ctrl_wstrb),
        .M_AXI_CTRL_wvalid    (ctrl_wvalid),
        .M_AXI_CTRL_wready    (ctrl_wready),
        .M_AXI_CTRL_bresp     (ctrl_bresp),
        .M_AXI_CTRL_bvalid    (ctrl_bvalid),
        .M_AXI_CTRL_bready    (ctrl_bready),
        .M_AXI_CTRL_araddr    (ctrl_araddr),
        .M_AXI_CTRL_arprot    (ctrl_arprot),
        .M_AXI_CTRL_arvalid   (ctrl_arvalid),
        .M_AXI_CTRL_arready   (ctrl_arready),
        .M_AXI_CTRL_rdata     (ctrl_rdata),
        .M_AXI_CTRL_rresp     (ctrl_rresp),
        .M_AXI_CTRL_rvalid    (ctrl_rvalid),
        .M_AXI_CTRL_rready    (ctrl_rready)
    );

    // The input matrix (zone inputMatrix: input -> bus since Phase 12), at
    // 0x8000_0000 as before.
    matrix_regs_axil #(
        .N_IN (N), .N_OUT (N_BUS), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L1),
        .ADDR_WIDTH (12), .RESET_GAINS (IN_MX_GAINS)
    ) u_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (ctrl_awaddr[11:0]), .s_axi_awvalid (ctrl_awvalid),
        .s_axi_awready (ctrl_awready),
        .s_axi_wdata   (ctrl_wdata),  .s_axi_wstrb  (ctrl_wstrb),
        .s_axi_wvalid  (ctrl_wvalid), .s_axi_wready (ctrl_wready),
        .s_axi_bresp   (ctrl_bresp),  .s_axi_bvalid (ctrl_bvalid),
        .s_axi_bready  (ctrl_bready),
        .s_axi_araddr  (ctrl_araddr[11:0]), .s_axi_arvalid (ctrl_arvalid),
        .s_axi_arready (ctrl_arready),
        .s_axi_rdata   (ctrl_rdata),  .s_axi_rresp  (ctrl_rresp),
        .s_axi_rvalid  (ctrl_rvalid), .s_axi_rready (ctrl_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .coef_addr (in_mx_addr), .coef_data (in_mx_data)
    );

    // Phase 12: the bus matrix (zone busMatrix, bus -> output) ...
    matrix_regs_axil #(
        .N_IN (N_BUS), .N_OUT (N), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L2),
        .ADDR_WIDTH (12), .RESET_GAINS (BUS_MX_GAINS)
    ) u_busmx_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (bmx_awaddr[11:0]), .s_axi_awvalid (bmx_awvalid),
        .s_axi_awready (bmx_awready),
        .s_axi_wdata   (bmx_wdata),  .s_axi_wstrb  (bmx_wstrb),
        .s_axi_wvalid  (bmx_wvalid), .s_axi_wready (bmx_wready),
        .s_axi_bresp   (bmx_bresp),  .s_axi_bvalid (bmx_bvalid),
        .s_axi_bready  (bmx_bready),
        .s_axi_araddr  (bmx_araddr[11:0]), .s_axi_arvalid (bmx_arvalid),
        .s_axi_arready (bmx_arready),
        .s_axi_rdata   (bmx_rdata),  .s_axi_rresp  (bmx_rresp),
        .s_axi_rvalid  (bmx_rvalid), .s_axi_rready (bmx_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .coef_addr (bus_mx_addr), .coef_data (bus_mx_data)
    );

    // ... and the three level stages (zones inputChannel, busChannel,
    // outputChannel); TAP in CONFIG says which is which.
    gain_regs_axil #(
        .N (N), .TAP (0), .GAIN_WIDTH (GW), .GAIN_FRAC (GF),
        .ADDR_WIDTH (12), .RESET_GAINS (LEVEL_GAINS)
    ) u_inlvl_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (ilv_awaddr[11:0]), .s_axi_awvalid (ilv_awvalid),
        .s_axi_awready (ilv_awready),
        .s_axi_wdata   (ilv_wdata),  .s_axi_wstrb  (ilv_wstrb),
        .s_axi_wvalid  (ilv_wvalid), .s_axi_wready (ilv_wready),
        .s_axi_bresp   (ilv_bresp),  .s_axi_bvalid (ilv_bvalid),
        .s_axi_bready  (ilv_bready),
        .s_axi_araddr  (ilv_araddr[11:0]), .s_axi_arvalid (ilv_arvalid),
        .s_axi_arready (ilv_arready),
        .s_axi_rdata   (ilv_rdata),  .s_axi_rresp  (ilv_rresp),
        .s_axi_rvalid  (ilv_rvalid), .s_axi_rready (ilv_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .coef_addr (in_lvl_addr), .coef_data (in_lvl_data)
    );

    gain_regs_axil #(
        .N (N_BUS), .TAP (1), .GAIN_WIDTH (GW), .GAIN_FRAC (GF),
        .ADDR_WIDTH (12), .RESET_GAINS (LEVEL_GAINS)
    ) u_buslvl_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (blv_awaddr[11:0]), .s_axi_awvalid (blv_awvalid),
        .s_axi_awready (blv_awready),
        .s_axi_wdata   (blv_wdata),  .s_axi_wstrb  (blv_wstrb),
        .s_axi_wvalid  (blv_wvalid), .s_axi_wready (blv_wready),
        .s_axi_bresp   (blv_bresp),  .s_axi_bvalid (blv_bvalid),
        .s_axi_bready  (blv_bready),
        .s_axi_araddr  (blv_araddr[11:0]), .s_axi_arvalid (blv_arvalid),
        .s_axi_arready (blv_arready),
        .s_axi_rdata   (blv_rdata),  .s_axi_rresp  (blv_rresp),
        .s_axi_rvalid  (blv_rvalid), .s_axi_rready (blv_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .coef_addr (bus_lvl_addr), .coef_data (bus_lvl_data)
    );

    gain_regs_axil #(
        .N (N), .TAP (2), .GAIN_WIDTH (GW), .GAIN_FRAC (GF),
        .ADDR_WIDTH (12), .RESET_GAINS (LEVEL_GAINS)
    ) u_outlvl_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (olv_awaddr[11:0]), .s_axi_awvalid (olv_awvalid),
        .s_axi_awready (olv_awready),
        .s_axi_wdata   (olv_wdata),  .s_axi_wstrb  (olv_wstrb),
        .s_axi_wvalid  (olv_wvalid), .s_axi_wready (olv_wready),
        .s_axi_bresp   (olv_bresp),  .s_axi_bvalid (olv_bvalid),
        .s_axi_bready  (olv_bready),
        .s_axi_araddr  (olv_araddr[11:0]), .s_axi_arvalid (olv_arvalid),
        .s_axi_arready (olv_arready),
        .s_axi_rdata   (olv_rdata),  .s_axi_rresp  (olv_rresp),
        .s_axi_rvalid  (olv_rvalid), .s_axi_rready (olv_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .coef_addr (out_lvl_addr), .coef_data (out_lvl_data)
    );

    // Phase 13: a peak meter on each tap (zones inputChannel, busChannel,
    // outputChannel, post-level); TAP in CONFIG says which is which.
    peak_regs_axil #(.N (N), .TAP (0), .SW (SW), .ADDR_WIDTH (12)) u_inmtr_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (imt_awaddr[11:0]), .s_axi_awvalid (imt_awvalid),
        .s_axi_awready (imt_awready),
        .s_axi_wdata   (imt_wdata),  .s_axi_wstrb  (imt_wstrb),
        .s_axi_wvalid  (imt_wvalid), .s_axi_wready (imt_wready),
        .s_axi_bresp   (imt_bresp),  .s_axi_bvalid (imt_bvalid),
        .s_axi_bready  (imt_bready),
        .s_axi_araddr  (imt_araddr[11:0]), .s_axi_arvalid (imt_arvalid),
        .s_axi_arready (imt_arready),
        .s_axi_rdata   (imt_rdata),  .s_axi_rresp  (imt_rresp),
        .s_axi_rvalid  (imt_rvalid), .s_axi_rready (imt_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .s_valid (tap_in_valid), .s_ch (tap_in_ch), .s_data (tap_in_data)
    );

    peak_regs_axil #(.N (N_BUS), .TAP (1), .SW (SW), .ADDR_WIDTH (12)) u_busmtr_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (bmt_awaddr[11:0]), .s_axi_awvalid (bmt_awvalid),
        .s_axi_awready (bmt_awready),
        .s_axi_wdata   (bmt_wdata),  .s_axi_wstrb  (bmt_wstrb),
        .s_axi_wvalid  (bmt_wvalid), .s_axi_wready (bmt_wready),
        .s_axi_bresp   (bmt_bresp),  .s_axi_bvalid (bmt_bvalid),
        .s_axi_bready  (bmt_bready),
        .s_axi_araddr  (bmt_araddr[11:0]), .s_axi_arvalid (bmt_arvalid),
        .s_axi_arready (bmt_arready),
        .s_axi_rdata   (bmt_rdata),  .s_axi_rresp  (bmt_rresp),
        .s_axi_rvalid  (bmt_rvalid), .s_axi_rready (bmt_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .s_valid (tap_bus_valid), .s_ch (tap_bus_ch), .s_data (tap_bus_data)
    );

    peak_regs_axil #(.N (N), .TAP (2), .SW (SW), .ADDR_WIDTH (12)) u_outmtr_regs (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (omt_awaddr[11:0]), .s_axi_awvalid (omt_awvalid),
        .s_axi_awready (omt_awready),
        .s_axi_wdata   (omt_wdata),  .s_axi_wstrb  (omt_wstrb),
        .s_axi_wvalid  (omt_wvalid), .s_axi_wready (omt_wready),
        .s_axi_bresp   (omt_bresp),  .s_axi_bvalid (omt_bvalid),
        .s_axi_bready  (omt_bready),
        .s_axi_araddr  (omt_araddr[11:0]), .s_axi_arvalid (omt_arvalid),
        .s_axi_arready (omt_arready),
        .s_axi_rdata   (omt_rdata),  .s_axi_rresp  (omt_rresp),
        .s_axi_rvalid  (omt_rvalid), .s_axi_rready (omt_rready),
        .mclk (mclk), .frame_i (jb_rx_valid),
        .s_valid (tap_out_valid), .s_ch (tap_out_ch), .s_data (tap_out_data)
    );

`ifdef INCLUDE_LINK
    // ----- Front door: PS<->PL link (PL half) -----
    // Same frame strobe as the matrix; the link's only clock crossing is
    // inside (async_fifo, scoped XDC). aresetn and rst_n are both asserted
    // from configuration until the PS releases pl_resetn0 and the MMCM locks.
    logic [31:0] lk_frames_rx, lk_frames_tx, lk_underruns, lk_starved;
    logic [31:0] lk_overruns, lk_tid_errors;
    logic [15:0] lk_rx_fill;
    logic        lk_rx_running;

    localparam int LINK_FIFO_FRAMES = 8;

    pcm_link #(.N_CH (N_LINK), .SW (SW), .FIFO_FRAMES (LINK_FIFO_FRAMES)) u_link (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axis_tdata (mm2s_tdata), .s_axis_tid (mm2s_tid),
        .s_axis_tvalid (mm2s_tvalid), .s_axis_tready (mm2s_tready),
        .m_axis_tdata (s2mm_tdata), .m_axis_tid (s2mm_tid),
        .m_axis_tvalid (s2mm_tvalid), .m_axis_tready (s2mm_tready),
        .mclk (mclk), .rst_n (rst_n), .frame_i (jb_rx_valid),
        .rx_flat (link_rx), .rx_valid (), .tx_flat (link_tx),
        .frames_rx (lk_frames_rx), .frames_tx (lk_frames_tx),
        .underruns (lk_underruns), .starved (lk_starved),
        .overruns (lk_overruns), .tid_errors (lk_tid_errors),
        .rx_fill (lk_rx_fill), .rx_running (lk_rx_running)
    );

    // ----- Control plane: the link's status window (0x8000_1000) -----
    pcm_link_stat_regs #(
        .N_CH_RX (N_LINK), .N_CH_TX (N_LINK),
        .FIFO_WORDS (LINK_FIFO_FRAMES * 8), .ADDR_WIDTH (12)
    ) u_link_stat (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (stat_awaddr[11:0]), .s_axi_awvalid (stat_awvalid),
        .s_axi_awready (stat_awready),
        .s_axi_wdata   (stat_wdata),  .s_axi_wstrb  (stat_wstrb),
        .s_axi_wvalid  (stat_wvalid), .s_axi_wready (stat_wready),
        .s_axi_bresp   (stat_bresp),  .s_axi_bvalid (stat_bvalid),
        .s_axi_bready  (stat_bready),
        .s_axi_araddr  (stat_araddr[11:0]), .s_axi_arvalid (stat_arvalid),
        .s_axi_arready (stat_arready),
        .s_axi_rdata   (stat_rdata),  .s_axi_rresp  (stat_rresp),
        .s_axi_rvalid  (stat_rvalid), .s_axi_rready (stat_rready),
        .mclk (mclk), .mrst_n (rst_n), .frame_i (jb_rx_valid),
        .frames_rx (lk_frames_rx), .frames_tx (lk_frames_tx),
        .underruns (lk_underruns), .starved (lk_starved),
        .overruns (lk_overruns), .tid_errors (lk_tid_errors),
        .rx_fill (lk_rx_fill), .rx_running (lk_rx_running)
    );
`else
    assign link_rx = '0;
`endif

`ifdef INCLUDE_LINK2
    // ----- Front door: PS<->PL link #2 (Phase 9, P9.5, decision L1) -----
    // A second instance of link #1, nothing changed: its own formatter in the
    // BD (0x8011_0000, driver-owned; ALSA card FPGAmixerLink2), the same
    // frame strobe, and its own status window at 0x8000_4000. Nothing in it
    // is AVB-specific: the AVB half lives in Linux (P9.6/P9.7).
    logic [31:0] lk2_frames_rx, lk2_frames_tx, lk2_underruns, lk2_starved;
    logic [31:0] lk2_overruns, lk2_tid_errors;
    logic [15:0] lk2_rx_fill;
    logic        lk2_rx_running;

    pcm_link #(.N_CH (N_LINK2), .SW (SW), .FIFO_FRAMES (LINK_FIFO_FRAMES)) u_link2 (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axis_tdata (mm2s2_tdata), .s_axis_tid (mm2s2_tid),
        .s_axis_tvalid (mm2s2_tvalid), .s_axis_tready (mm2s2_tready),
        .m_axis_tdata (s2mm2_tdata), .m_axis_tid (s2mm2_tid),
        .m_axis_tvalid (s2mm2_tvalid), .m_axis_tready (s2mm2_tready),
        .mclk (mclk), .rst_n (rst_n), .frame_i (jb_rx_valid),
        .rx_flat (link2_rx), .rx_valid (), .tx_flat (link2_tx),
        .frames_rx (lk2_frames_rx), .frames_tx (lk2_frames_tx),
        .underruns (lk2_underruns), .starved (lk2_starved),
        .overruns (lk2_overruns), .tid_errors (lk2_tid_errors),
        .rx_fill (lk2_rx_fill), .rx_running (lk2_rx_running)
    );

    // ----- Control plane: link #2's status window (0x8000_4000) -----
    pcm_link_stat_regs #(
        .N_CH_RX (N_LINK2), .N_CH_TX (N_LINK2),
        .FIFO_WORDS (LINK_FIFO_FRAMES * 8), .ADDR_WIDTH (12)
    ) u_link2_stat (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (stat2_awaddr[11:0]), .s_axi_awvalid (stat2_awvalid),
        .s_axi_awready (stat2_awready),
        .s_axi_wdata   (stat2_wdata),  .s_axi_wstrb  (stat2_wstrb),
        .s_axi_wvalid  (stat2_wvalid), .s_axi_wready (stat2_wready),
        .s_axi_bresp   (stat2_bresp),  .s_axi_bvalid (stat2_bvalid),
        .s_axi_bready  (stat2_bready),
        .s_axi_araddr  (stat2_araddr[11:0]), .s_axi_arvalid (stat2_arvalid),
        .s_axi_arready (stat2_arready),
        .s_axi_rdata   (stat2_rdata),  .s_axi_rresp  (stat2_rresp),
        .s_axi_rvalid  (stat2_rvalid), .s_axi_rready (stat2_rready),
        .mclk (mclk), .mrst_n (rst_n), .frame_i (jb_rx_valid),
        .frames_rx (lk2_frames_rx), .frames_tx (lk2_frames_tx),
        .underruns (lk2_underruns), .starved (lk2_starved),
        .overruns (lk2_overruns), .tid_errors (lk2_tid_errors),
        .rx_fill (lk2_rx_fill), .rx_running (lk2_rx_running)
    );
`else
    assign link2_rx = '0;
`endif

`ifdef INCLUDE_MCLK
    // ----- Platform: media-clock meter (Phase 9, P9.3) -----
    // 1PPS on the gPTP second = the inverse of tsu_timer_cnt[45], the ns
    // field's MSB (UG1085 v2.5 p. 1061). It comes from the board's own PHC,
    // so it is the gPTP second whichever gPTP role the board has.
    logic [31:0] mc_pps_count, mc_cyc_last, mc_cyc_prev, mc_frames_last;
    logic [31:0] mc_implausible, mc_cyc_now;
    logic [15:0] mc_phase_last;

    media_clock_meter #(.NOMINAL (12_288_000)) u_mclk_meter (
        .mclk (mclk), .rst_n (rst_n),
        .pps_async (~tsu_timer_cnt[45]),
        .frame_i (jb_rx_valid),
        .pps_count (mc_pps_count), .cyc_last (mc_cyc_last), .cyc_prev (mc_cyc_prev),
        .frames_last (mc_frames_last), .phase_last (mc_phase_last),
        .implausible (mc_implausible), .cyc_now (mc_cyc_now)
    );

    media_clock_stat_regs #(.NOMINAL (12_288_000), .ADDR_WIDTH (12)) u_mclk_stat (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (mc_awaddr[11:0]), .s_axi_awvalid (mc_awvalid),
        .s_axi_awready (mc_awready),
        .s_axi_wdata   (mc_wdata),  .s_axi_wstrb  (mc_wstrb),
        .s_axi_wvalid  (mc_wvalid), .s_axi_wready (mc_wready),
        .s_axi_bresp   (mc_bresp),  .s_axi_bvalid (mc_bvalid),
        .s_axi_bready  (mc_bready),
        .s_axi_araddr  (mc_araddr[11:0]), .s_axi_arvalid (mc_arvalid),
        .s_axi_arready (mc_arready),
        .s_axi_rdata   (mc_rdata),  .s_axi_rresp  (mc_rresp),
        .s_axi_rvalid  (mc_rvalid), .s_axi_rready (mc_rready),
        .mclk (mclk), .mrst_n (rst_n), .frame_i (jb_rx_valid),
        .pps_count (mc_pps_count), .cyc_last (mc_cyc_last), .cyc_prev (mc_cyc_prev),
        .frames_last (mc_frames_last), .phase_last (mc_phase_last),
        .implausible (mc_implausible), .cyc_now (mc_cyc_now)
    );

    // ----- Platform: media-clock steering (Phase 9, P9.4b) -----
    // A rate from Linux (the loop, decision S3) -> MMCM fine phase steps on
    // pl_clk0 (PSCLK, decision S1). The window and the steerer share that
    // clock, so there is no crossing but LOCKED (synchronized inside).
    logic [31:0] ms_rate, ms_steps_inc, ms_steps_dec, ms_dropped;
    logic        ms_busy, ms_locked;

    assign ps_clk = ctrl_aclk;

    media_clock_steer u_mclk_steer (
        .psclk (ctrl_aclk), .rst_n (ctrl_aresetn),
        .rate (ms_rate), .mmcm_locked (mmcm_locked),
        .psen (ps_en), .psincdec (ps_incdec), .psdone (ps_done),
        .steps_inc (ms_steps_inc), .steps_dec (ms_steps_dec),
        .dropped (ms_dropped), .busy (ms_busy), .locked (ms_locked)
    );

    media_clock_ctrl_regs #(
        .PSCLK_HZ (100_000_000), .VCO_HZ (1_450_000_000), .PS_DIV (56),
        .ADDR_WIDTH (12)
    ) u_mclk_ctrl (
        .aclk (ctrl_aclk), .aresetn (ctrl_aresetn),
        .s_axi_awaddr  (ms_awaddr[11:0]), .s_axi_awvalid (ms_awvalid),
        .s_axi_awready (ms_awready),
        .s_axi_wdata   (ms_wdata),  .s_axi_wstrb  (ms_wstrb),
        .s_axi_wvalid  (ms_wvalid), .s_axi_wready (ms_wready),
        .s_axi_bresp   (ms_bresp),  .s_axi_bvalid (ms_bvalid),
        .s_axi_bready  (ms_bready),
        .s_axi_araddr  (ms_araddr[11:0]), .s_axi_arvalid (ms_arvalid),
        .s_axi_arready (ms_arready),
        .s_axi_rdata   (ms_rdata),  .s_axi_rresp  (ms_rresp),
        .s_axi_rvalid  (ms_rvalid), .s_axi_rready (ms_rready),
        .rate (ms_rate),
        .steps_inc (ms_steps_inc), .steps_dec (ms_steps_dec),
        .dropped (ms_dropped), .busy (ms_busy), .locked (ms_locked)
    );
`endif
`else
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (N), .LANES (L1)) u_in_mx_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (IN_MX_GAINS),
        .rd_addr (in_mx_addr), .rd_data (in_mx_data)
    );
    // Without the PS the bus matrix and the three level stages also read
    // their reset banks (identity, unity).
    coef_flat_reader #(.W (GW), .N_ROWS (N), .ROW_LEN (N_BUS), .LANES (L2)) u_bus_mx_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (BUS_MX_GAINS),
        .rd_addr (bus_mx_addr), .rd_data (bus_mx_data)
    );
    coef_flat_reader #(.W (GW), .N_ROWS (N), .ROW_LEN (1), .LANES (1)) u_in_lvl_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (LEVEL_GAINS),
        .rd_addr (in_lvl_addr), .rd_data (in_lvl_data)
    );
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (1), .LANES (1)) u_bus_lvl_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (LEVEL_GAINS),
        .rd_addr (bus_lvl_addr), .rd_data (bus_lvl_data)
    );
    coef_flat_reader #(.W (GW), .N_ROWS (N), .ROW_LEN (1), .LANES (1)) u_out_lvl_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (LEVEL_GAINS),
        .rd_addr (out_lvl_addr), .rd_data (out_lvl_data)
    );
    assign link_rx  = '0;
    assign link2_rx = '0;
`endif

    // ----- PCM core -----
    // mixer_core (Phase 12): input levels -> input matrix -> bus levels ->
    // bus matrix -> output levels, between the stream converters. core_out
    // updates D cycles after the strobe (249 at 20 -> 20 -> 20 on 4 + 4 lanes;
    // the single matrix was 227), before i2s_port samples its pair (edge 254)
    // and the link its frame (the next strobe): the same latency in frames as
    // the parallel matrix had.
    mixer_core #(
        .N_IN (N), .N_BUS (N_BUS), .N_OUT (N), .SW (SW), .GW (GW), .GF (GF),
        .L1 (L1), .L2 (L2)
    ) u_core (
        .mclk (mclk), .rst_n (rst_n),
        .frame_i (jb_rx_valid),
        .in_flat  (core_in),
        .out_flat (core_out),
        .valid_o  (),
        .err_o    (),
        .in_lvl_addr  (in_lvl_addr),  .in_lvl_data  (in_lvl_data),
        .in_mx_addr   (in_mx_addr),   .in_mx_data   (in_mx_data),
        .bus_lvl_addr (bus_lvl_addr), .bus_lvl_data (bus_lvl_data),
        .bus_mx_addr  (bus_mx_addr),  .bus_mx_data  (bus_mx_data),
        .out_lvl_addr (out_lvl_addr), .out_lvl_data (out_lvl_data),
        .tap_in_valid  (tap_in_valid),  .tap_in_ch  (tap_in_ch),  .tap_in_data  (tap_in_data),
        .tap_bus_valid (tap_bus_valid), .tap_bus_ch (tap_bus_ch), .tap_bus_data (tap_bus_data),
        .tap_out_valid (tap_out_valid), .tap_out_ch (tap_out_ch), .tap_out_data (tap_out_data)
    );

endmodule
