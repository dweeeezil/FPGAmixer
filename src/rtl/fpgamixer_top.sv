// -----------------------------------------------------------------------------
// fpgamixer_top.sv
//
// Platform layer (docs/architecture_modules.md): wires the blocks together and
// holds nothing else. Formerly phase3_top.
//
//   sysclk -> audio_clocking -> mclk, rst_n, sclk, lrck  (shared by everything)
//
//   Pmod JB pins <-> i2s_port u_jb <-> PCM ch0 (L), ch1 (R) -.
//   Pmod JC pins <-> i2s_port u_jc <-> PCM ch2 (L), ch3 (R) --+-> mixer_core
//   PS (Audio Formatter) <-> pcm_link u_link <-> PCM ch4..11 -'   u_core
//                                                   (time-shared 12 x 12 matrix)
//   control plane (INCLUDE_PS): PS -> M_AXI_CTRL -> matrix_regs_axil u_regs
//                                   -> coefficient read port -> u_core
//                  (without the PS: coef_flat_reader u_gains, MATRIX_GAINS)
//                  (INCLUDE_LINK): PS -> M_AXI_LINKSTAT -> pcm_link_stat_regs
//   platform (INCLUDE_MCLK, phase9): PS tsu_timer_cnt[45] (1PPS) ->
//                  media_clock_meter -> media_clock_stat_regs <- M_AXI_MCLKSTAT
//
// Everything this file decides:
//   - the channel map: which front-door channel is which core channel;
//   - MATRIX_GAINS: the routing the matrix resets to (identity);
//   - where the gains come from: the PS (INCLUDE_PS builds), or MATRIX_GAINS
//     tied on directly (non-PS projects and the Icarus/XSim integration TBs);
//   - whether the PS<->PL link exists (INCLUDE_LINK, phase8 builds). Without
//     it the link channels read as silence, so the core is 12 x 12 in every
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
    localparam int N_LINK = 8;              // PS<->PL link, each way
    localparam int N  = N_PMOD + N_LINK;    // core channels in = out
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

    // ----- PS<->PL link front door (PCM side) -----
    logic [N_LINK*SW-1:0] link_rx, link_tx;   // rx = into the core, from the PS

    // ----- Channel map (core ch0 at the LSB) -----
    //   ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R   (inputs and outputs)
    //   ch4..ch11 = link channels 0..7: inputs = what the PS plays (USB: the
    //   Mac's outputs 1-8), outputs = what the PS records (the Mac's inputs 1-8)
    // New channels are appended, never interleaved, so saved crosspoint
    // indices keep their meaning when the core grows.
    logic [N*SW-1:0] core_in, core_out;
    assign core_in = { link_rx, jc_rx, jb_rx };
    assign { link_tx, jc_tx, jb_tx } = core_out;

    // ----- Reset routing (Q2.16 gains; gain k = o*N + i, output o, input i) -----
    localparam logic signed [GW-1:0] G_UNITY = 18'sh10000;

    // IDENTITY: each output = its own input at unity. For the Pmods that is
    // each ADC passed to its own DAC (the minimal datapath test: noise here
    // points at clocking or the ports, not the routing); for the link it is the
    // PS's playback returned to its capture. Runtime control (INCLUDE_PS)
    // starts from this bank, and the OSC server seeds missing crosspoints with
    // the same rule. Other routings for a non-PS build: git history before
    // Phase 8 has a worked 4 x 4 DEMO bank.
    function automatic logic [N*N*GW-1:0] identity_gains();
        logic [N*N*GW-1:0] g = '0;
        for (int o = 0; o < N; o++) g[(o*N + o)*GW +: GW] = G_UNITY;
        return g;
    endfunction
    localparam logic [N*N*GW-1:0] MATRIX_GAINS = identity_gains();

    // ----- Control plane: where the gains come from -----
    // Since Phase 9 the core reads its gains through a coefficient read port
    // (docs/architecture_modules.md 3): from the PS's register window
    // (coef_bank_ram inside matrix_regs_axil), or from MATRIX_GAINS through a
    // coef_flat_reader. Both are sized by the same lane count as the core.
    localparam int LANES   = pcm_matrix_pkg::matrix_lanes(N, N);
    localparam int COEF_AW = $clog2(pcm_matrix_pkg::matrix_passes(N, LANES) * N);
    logic [COEF_AW-1:0]  coef_addr;
    logic [LANES*GW-1:0] coef_data;

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

    matrix_regs_axil #(
        .N_IN (N), .N_OUT (N), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (LANES),
        .ADDR_WIDTH (12), .RESET_GAINS (MATRIX_GAINS)
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
        .coef_addr (coef_addr), .coef_data (coef_data)
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
    coef_flat_reader #(.W (GW), .N_ROWS (N), .ROW_LEN (N), .LANES (LANES)) u_gains (
        .mclk (mclk), .frame_i (jb_rx_valid), .coefs_flat (MATRIX_GAINS),
        .rd_addr (coef_addr), .rd_data (coef_data)
    );
    assign link_rx = '0;
`endif

    // ----- PCM core -----
    // mixer_core: pack -> stream -> time-shared pcm_matrix -> stream -> pack.
    // core_out updates D cycles after the strobe (162 at 12 x 12), before
    // i2s_port samples its pair (edge 254) and the link its frame (the next
    // strobe): the same latency as the parallel matrix had.
    mixer_core #(
        .N_IN (N), .N_OUT (N), .SW (SW), .GW (GW), .GF (GF), .LANES (LANES)
    ) u_core (
        .mclk (mclk), .rst_n (rst_n),
        .frame_i (jb_rx_valid),
        .in_flat  (core_in),
        .out_flat (core_out),
        .valid_o  (),
        .err_o    (),
        .coef_addr (coef_addr),
        .coef_data (coef_data)
    );

endmodule
