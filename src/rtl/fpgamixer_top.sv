// -----------------------------------------------------------------------------
// fpgamixer_top.sv
//
// Platform layer (docs/architecture_modules.md): wires the blocks together and
// holds nothing else. Formerly phase3_top.
//
//   sysclk -> audio_clocking -> mclk, rst_n, sclk, lrck  (shared by everything)
//
//   Pmod JB pins <-> i2s_port u_jb <-> PCM ch0 (L), ch1 (R) -.
//   Pmod JC pins <-> i2s_port u_jc <-> PCM ch2 (L), ch3 (R) --+-> pcm_matrix
//                                                             <-'  u_matrix
//   control plane (INCLUDE_PS): PS -> M_AXI_CTRL -> matrix_regs_axil u_regs
//                                                    -> u_matrix.gains_flat
//
// Everything this file decides:
//   - the channel map: which front-door channel is which core channel;
//   - MATRIX_GAINS: the routing the matrix resets to (identity);
//   - where the gains come from: the PS (INCLUDE_PS builds), or MATRIX_GAINS
//     tied on directly (non-PS projects and the Icarus/XSim integration TBs).
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

    localparam int N  = 4;     // core channels in = out (2 per Pmod)
    localparam int SW = 24;
    localparam int GW = 18;    // gain width,  Q2.16
    localparam int GF = 16;    // gain fraction bits

    // ----- Clock domain -----
    logic mclk, rst_n, sclk, lrck, mmcm_locked;

    audio_clocking u_clk (
        .sysclk (sysclk),
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck),
        .mmcm_locked (mmcm_locked)
    );

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

    // ----- Channel map (core ch0 at the LSB) -----
    //   ch0 = JB_L, ch1 = JB_R, ch2 = JC_L, ch3 = JC_R   (inputs and outputs)
    logic [N*SW-1:0] core_in, core_out;
    assign core_in = { jc_rx, jb_rx };
    assign { jc_tx, jb_tx } = core_out;

    // ----- Reset routing (Q2.16 gains; rows = outputs, cols = inputs) -----
    localparam logic signed [GW-1:0] G_UNITY = 18'sh10000;
    localparam logic signed [GW-1:0] G_HALF  = 18'sh08000;
    localparam logic signed [GW-1:0] G_ZERO  = 18'sh00000;

    // IDENTITY: each output = its own input at unity, so every Pmod passes its
    // own ADC input through to its own DAC output. The minimal datapath test --
    // if an output is noisy here, the clocking or the ports are implicated, not
    // the routing. Runtime control (INCLUDE_PS) starts from this bank.
    //   JB_L = JB_L,  JB_R = JB_R,  JC_L = JC_L,  JC_R = JC_R
    // Rows = outputs (out3..out0), each row lists cols i3,i2,i1,i0.
    localparam logic [N*N*GW-1:0] MATRIX_GAINS = {
        //  i3       i2       i1       i0
        G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JC_R = JC_R in
        G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out2 JC_L = JC_L in
        G_ZERO,  G_ZERO,  G_UNITY, G_ZERO,    // out1 JB_R = JB_R in
        G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JB_L = JB_L in
    };

    // DEMO routing (a passthrough, a cross-Pmod route, a 0.5+0.5 sum), for a
    // non-PS build that should exercise real mixing:
    //   JB_L = JB_L,  JB_R = JC_L,  JC_L = 0.5*JB_L + 0.5*JC_L,  JC_R = JC_R
    // localparam logic [N*N*GW-1:0] MATRIX_GAINS = {
    //     G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JC_R = JC_R in
    //     G_ZERO,  G_HALF,  G_ZERO,  G_HALF,    // out2 JC_L = 0.5*JB_L + 0.5*JC_L
    //     G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out1 JB_R = JC_L in
    //     G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JB_L = JB_L in
    // };

    // ----- Control plane: where the gains come from -----
    logic [N*N*GW-1:0] gains;

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

    ps_sys_wrapper u_ps (
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
        .N_IN (N), .N_OUT (N), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .ADDR_WIDTH (12),
        .RESET_GAINS (MATRIX_GAINS)
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
        .mclk (mclk), .mrst_n (rst_n),
        .gains_flat (gains)
    );
`else
    assign gains = MATRIX_GAINS;
`endif

    // ----- PCM core -----
    pcm_matrix #(
        .N_IN (N), .N_OUT (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)
    ) u_matrix (
        .mclk (mclk), .rst_n (rst_n),
        .sample_valid_i (jb_rx_valid),
        .gains_flat (gains),
        .in_flat  (core_in),
        .out_flat (core_out),
        .sample_valid_o ()
    );

endmodule
