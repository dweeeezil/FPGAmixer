// -----------------------------------------------------------------------------
// phase3_top.sv
//
// Phase 3: static 4-in / 4-out PCM matrix mixer across both Pmod I2S2 modules.
//
// Four ADC channels (JB L/R + JC L/R) are deserialized to PCM, run through a
// compile-time crosspoint matrix, and reserialized to four DAC channels
// (JB L/R + JC L/R). No runtime control yet -- the routing is baked in via
// MATRIX_GAINS below; changing the mix means rebuilding.
//
// Both Pmods are driven from ONE set of clocks (single MMCM + single divider),
// so all four ADCs and all four DACs share the same MCLK/SCLK/LRCK. That makes
// every input and output sample-synchronous and puts them in one clock domain,
// which is exactly what lets the matrix combine them with no CDC.
//
//   sysclk 25MHz -> MMCM -> mclk -> reset_sync -> rst_n
//                                 -> divider    -> sclk, lrck  (to BOTH Pmods)
//
// All codec-facing outputs (MCLK/SCLK/LRCK/SDIN, 14 pins) leave through ODDR
// forwarders (oddr_out) clocked by mclk, so pin launch timing is set by the
// dedicated OLOGIC path, not per-build fabric routing. SCLK/LRCK/SDIN share
// one identical +1 MCLK relaunch -- see the invariant note at the instances.
//
//   jb_ad_sdout -> rx_jb -> {jb_l, jb_r} =ch0,ch1 -.
//   jc_ad_sdout -> rx_jc -> {jc_l, jc_r} =ch2,ch3 --+-> pcm_matrix -.
//                                                                    |
//   ch0,ch1 -> tx_jb -> jb_da_sdin   <-------------------------------+
//   ch2,ch3 -> tx_jc -> jc_da_sdin   <-- (matrix outputs)
//
// Phase 5 (INCLUDE_PS builds): the gains are runtime registers, written by the
// PS over AXI4-Lite (matrix_regs_axil, M_AXI_HPM0_LPD at 0x8000_0000). Their
// reset value is MATRIX_GAINS, so the board still boots into the routing below
// until software changes it. Without INCLUDE_PS (phase1-3 projects, Icarus
// sims) MATRIX_GAINS is tied straight to the matrix, as in Phase 3.
//
// Default routing = IDENTITY / loopback (rows = outputs, cols = inputs; see
// MATRIX_GAINS): each channel loops straight back to itself at unity, so every
// Pmod passes its own ADC input through to its own DAC output.
//   JB_L out = JB_L in,  JB_R out = JB_R in,  JC_L out = JC_L in,  JC_R out = JC_R in
// A DEMO mix (passthrough + cross-Pmod route + 0.5/0.5 sum) is kept commented
// out beside MATRIX_GAINS below; swap it in to exercise real crosspoint mixing.
//
// NOTE (ZU-3EG): the JB/JC names match the board's silkscreen -- module #1 is on
// Pmod JB, module #2 on Pmod JC. (The ZU-3EG's Pmod JA is the analog XADC Pmod,
// LVCMOS18 + RC-filtered, so it can't carry the I2S2; JB/JC are the digital
// Pmods.) See the constraints file headers for the pin map.
// -----------------------------------------------------------------------------
module phase3_top (
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

    localparam int N  = 4;
    localparam int SW = 24;

    // ----- Clocking -----
    logic mclk, mmcm_locked;

    clk_wiz_audio u_mmcm (
        .clk_in1  (sysclk),
        .reset    (1'b0),
        .clk_out1 (mclk),
        .locked   (mmcm_locked)
    );

    logic rst_n;
    reset_sync u_rst_sync (
        .clk         (mclk),
        .async_rst_n (mmcm_locked),
        .sync_rst_n  (rst_n)
    );

    logic sclk, lrck;
    i2s_clock_divider u_div (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck)
    );

    // ----- Fan the same clocks out to both Pmods, both sides -----
    // Every codec-facing output leaves through an ODDR (oddr_out), one per
    // physical pin, all clocked by mclk. MCLK pins use the clock-forwarding
    // pattern (d1=1, d2=0); SCLK/LRCK (and SDIN below) pass through as SDR
    // data (d1=d2=signal), which re-launches them on the mclk rising edge and
    // adds one identical MCLK of pin latency to each.
    //
    // INVARIANT: SCLK, LRCK and SDIN must all get this same SDR treatment so
    // their relative pin alignment (data changes mid-cell, half an SCLK before
    // the DAC's sampling edge) is preserved. Mixing ODDR and combinational
    // forwarding here re-creates the Phase 3 pin-phase race. See
    // docs/archive/handoff_codec_interface_timing.md 4.2 and oddr_out.sv.
    //
    // The pin-delay constraints in constraints/phase3_genesys_zu.xdc name these
    // instances (u_fwd_*/u_oddr/C) -- keep names in sync when editing.
    oddr_out u_fwd_jb_da_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jb_da_mclk));
    oddr_out u_fwd_jb_ad_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jb_ad_mclk));
    oddr_out u_fwd_jc_da_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jc_da_mclk));
    oddr_out u_fwd_jc_ad_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jc_ad_mclk));

    oddr_out u_fwd_jb_da_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jb_da_sclk));
    oddr_out u_fwd_jb_ad_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jb_ad_sclk));
    oddr_out u_fwd_jc_da_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jc_da_sclk));
    oddr_out u_fwd_jc_ad_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jc_ad_sclk));

    oddr_out u_fwd_jb_da_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jb_da_lrck));
    oddr_out u_fwd_jb_ad_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jb_ad_lrck));
    oddr_out u_fwd_jc_da_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jc_da_lrck));
    oddr_out u_fwd_jc_ad_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jc_ad_lrck));

    // ----- Receivers: I2S -> PCM (per Pmod, stereo) -----
    logic [SW-1:0] jb_l_in, jb_r_in, jc_l_in, jc_r_in;
    logic          valid_jb, valid_jc;  // identical timing (shared LRCK)

    i2s_receiver #(.DATA_WIDTH(SW)) u_rx_jb (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jb_ad_sdout),
        .left_data (jb_l_in), .right_data (jb_r_in), .sample_valid (valid_jb)
    );
    i2s_receiver #(.DATA_WIDTH(SW)) u_rx_jc (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jc_ad_sdout),
        .left_data (jc_l_in), .right_data (jc_r_in), .sample_valid (valid_jc)
    );

    // ----- Matrix -----
    // Channel map (packed): ch0=JB_L, ch1=JB_R, ch2=JC_L, ch3=JC_R (ch0 at LSB).
    logic [N*SW-1:0] mtx_in, mtx_out;
    assign mtx_in = { jc_r_in, jc_l_in, jb_r_in, jb_l_in };

    logic [SW-1:0] jb_l_out, jb_r_out, jc_l_out, jc_r_out;
    assign { jc_r_out, jc_l_out, jb_r_out, jb_l_out } = mtx_out;

    // Gain constants (Q2.16): 1.0, 0.5, 0.0
    localparam logic signed [17:0] G_UNITY = 18'sh10000;
    localparam logic signed [17:0] G_HALF  = 18'sh08000;
    localparam logic signed [17:0] G_ZERO  = 18'sh00000;

    // -------------------------------------------------------------------------
    // IDENTITY routing (debug): each output = its own input at unity. Every
    // Pmod loops back to itself; no cross-routes, no fractional gains. This is
    // the minimal datapath test -- if an output is still noisy here, the matrix
    // insertion or the clocking (not the routing or the gains) is implicated.
    //   JB_L = JB_L,  JB_R = JB_R,  JC_L = JC_L,  JC_R = JC_R
    // Rows = outputs (out3..out0), each row lists cols i3,i2,i1,i0.
    localparam logic [N*N*18-1:0] MATRIX_GAINS = {
        //  i3       i2       i1       i0
        G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JC_R = JC_R in
        G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out2 JC_L = JC_L in
        G_ZERO,  G_ZERO,  G_UNITY, G_ZERO,    // out1 JB_R = JB_R in
        G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JB_L = JB_L in
    };

    // -------------------------------------------------------------------------
    // DEMO routing (restore when the datapath is proven clean): a passthrough,
    // a cross-Pmod route, and a summed 0.5+0.5 mix.
    //   JB_L = JB_L,  JB_R = JC_L,  JC_L = 0.5*JB_L + 0.5*JC_L,  JC_R = JC_R
    // localparam logic [N*N*18-1:0] MATRIX_GAINS = {
    //     G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JC_R = JC_R in
    //     G_ZERO,  G_HALF,  G_ZERO,  G_HALF,    // out2 JC_L = 0.5*JB_L + 0.5*JC_L
    //     G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out1 JB_R = JC_L in
    //     G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JB_L = JB_L in
    // };

    logic [N*N*18-1:0] gains;

`ifdef INCLUDE_PS
    // ----- Phase 5: runtime gains from the PS -----
    // ps_sys_wrapper exports M_AXI_CTRL (AXI4-Lite, through a SmartConnect off
    // M_AXI_HPM0_LPD) plus its clock (pl_clk0) and a synchronized reset.
    // Only the low 12 bits of the address reach the register block; the BD
    // maps a 4 KB window at 0x8000_0000.
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

    // Instance name u_regs is referenced by the CDC constraints in the XDC.
    matrix_regs_axil #(
        .N (N), .GAIN_WIDTH (18), .GAIN_FRAC (16), .ADDR_WIDTH (12),
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

    pcm_matrix #(
        .N_IN (N), .N_OUT (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (18), .GAIN_FRAC (16)
    ) u_matrix (
        .mclk (mclk), .rst_n (rst_n),
        .sample_valid_i (valid_jb),
        .gains_flat (gains),
        .in_flat  (mtx_in),
        .out_flat (mtx_out),
        .sample_valid_o ()
    );

    // ----- Transmitters: PCM -> I2S (per Pmod, stereo) -----
    // sdata leaves through the same SDR ODDR pattern as SCLK/LRCK above, so
    // the mid-cell launch phase fixed in i2s_transmitter survives at the pin.
    logic jb_sdin_int, jc_sdin_int;

    i2s_transmitter #(.DATA_WIDTH(SW)) u_tx_jb (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (jb_l_out), .right_data (jb_r_out), .sdata_o (jb_sdin_int)
    );
    i2s_transmitter #(.DATA_WIDTH(SW)) u_tx_jc (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (jc_l_out), .right_data (jc_r_out), .sdata_o (jc_sdin_int)
    );

    oddr_out u_fwd_jb_da_sdin (.clk(mclk), .d1(jb_sdin_int), .d2(jb_sdin_int), .q(jb_da_sdin));
    oddr_out u_fwd_jc_da_sdin (.clk(mclk), .d1(jc_sdin_int), .d2(jc_sdin_int), .q(jc_da_sdin));

    // ----- The PS lives inside this module, not in a wrapper above it -----
    // ps_sys_wrapper (instantiated with the Phase 5 register block, above) sits
    // HERE rather than in a wrapper above phase3_top. The XDC names these
    // instances by absolute path (u_fwd_*/u_oddr/C, see the note at the ODDR
    // forwarders above), so adding a level of hierarchy above phase3_top
    // silently invalidates 25 timing constraints and implementation then fails
    // in IO clock placement (observed 2026-09-22).
    //
    // Guarded by a define, not a parameter, so the text is removed by the
    // preprocessor: phase1-3 projects and the Icarus sim never reference a
    // module that only exists once scripts/create_project.tcl builds the BD.
    // create_project.tcl sets INCLUDE_PS for phase4 onwards.

endmodule
