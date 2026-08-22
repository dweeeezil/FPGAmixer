// -----------------------------------------------------------------------------
// phase3_top.sv
//
// Phase 3: static 4-in / 4-out PCM matrix mixer across both Pmod I2S2 modules.
//
// Four ADC channels (JA L/R + JB L/R) are deserialized to PCM, run through a
// compile-time crosspoint matrix, and reserialized to four DAC channels
// (JA L/R + JB L/R). No runtime control yet -- the routing is baked in via
// MATRIX_GAINS below; changing the mix means rebuilding.
//
// Both Pmods are driven from ONE set of clocks (single MMCM + single divider),
// so all four ADCs and all four DACs share the same MCLK/SCLK/LRCK. That makes
// every input and output sample-synchronous and puts them in one clock domain,
// which is exactly what lets the matrix combine them with no CDC.
//
//   sysclk 125MHz -> MMCM -> mclk -> reset_sync -> rst_n
//                                 -> divider    -> sclk, lrck  (to BOTH Pmods)
//
// All codec-facing outputs (MCLK/SCLK/LRCK/SDIN, 14 pins) leave through ODDR
// forwarders (oddr_out) clocked by mclk, so pin launch timing is set by the
// dedicated OLOGIC path, not per-build fabric routing. SCLK/LRCK/SDIN share
// one identical +1 MCLK relaunch -- see the invariant note at the instances.
//
//   ja_ad_sdout -> rx_ja -> {ja_l, ja_r} =ch0,ch1 -.
//   jb_ad_sdout -> rx_jb -> {jb_l, jb_r} =ch2,ch3 --+-> pcm_matrix -.
//                                                                    |
//   ch0,ch1 -> tx_ja -> ja_da_sdin   <-------------------------------+
//   ch2,ch3 -> tx_jb -> jb_da_sdin   <-- (matrix outputs)
//
// Default routing (rows = outputs, cols = inputs; see MATRIX_GAINS):
//   JA_L out = JA_L in                    (passthrough)
//   JA_R out = JB_L in                    (cross-Pmod route)
//   JB_L out = 0.5*JA_L in + 0.5*JB_L in  (summed mix)
//   JB_R out = JB_R in                    (passthrough)
// -----------------------------------------------------------------------------
module phase3_top (
    input  logic sysclk,       // 125 MHz, pin H16

    // ----- Pmod JA : Pmod I2S2 #1 -----
    output logic ja_da_mclk,   // JA1
    output logic ja_da_lrck,   // JA2
    output logic ja_da_sclk,   // JA3
    output logic ja_da_sdin,   // JA4
    output logic ja_ad_mclk,   // JA7
    output logic ja_ad_lrck,   // JA8
    output logic ja_ad_sclk,   // JA9
    input  logic ja_ad_sdout,  // JA10

    // ----- Pmod JB : Pmod I2S2 #2 -----
    output logic jb_da_mclk,   // JB1
    output logic jb_da_lrck,   // JB2
    output logic jb_da_sclk,   // JB3
    output logic jb_da_sdin,   // JB4
    output logic jb_ad_mclk,   // JB7
    output logic jb_ad_lrck,   // JB8
    output logic jb_ad_sclk,   // JB9
    input  logic jb_ad_sdout   // JB10
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
    // docs/handoff_codec_interface_timing.md 4.2 and oddr_out.sv.
    //
    // The pin-delay constraints in constraints/phase3_arty_z7.xdc name these
    // instances (u_fwd_*/u_oddr/C) -- keep names in sync when editing.
    oddr_out u_fwd_ja_da_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(ja_da_mclk));
    oddr_out u_fwd_ja_ad_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(ja_ad_mclk));
    oddr_out u_fwd_jb_da_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jb_da_mclk));
    oddr_out u_fwd_jb_ad_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(jb_ad_mclk));

    oddr_out u_fwd_ja_da_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(ja_da_sclk));
    oddr_out u_fwd_ja_ad_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(ja_ad_sclk));
    oddr_out u_fwd_jb_da_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jb_da_sclk));
    oddr_out u_fwd_jb_ad_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(jb_ad_sclk));

    oddr_out u_fwd_ja_da_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(ja_da_lrck));
    oddr_out u_fwd_ja_ad_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(ja_ad_lrck));
    oddr_out u_fwd_jb_da_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jb_da_lrck));
    oddr_out u_fwd_jb_ad_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(jb_ad_lrck));

    // ----- Receivers: I2S -> PCM (per Pmod, stereo) -----
    logic [SW-1:0] ja_l_in, ja_r_in, jb_l_in, jb_r_in;
    logic          valid_ja, valid_jb;  // identical timing (shared LRCK)

    i2s_receiver #(.DATA_WIDTH(SW)) u_rx_ja (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (ja_ad_sdout),
        .left_data (ja_l_in), .right_data (ja_r_in), .sample_valid (valid_ja)
    );
    i2s_receiver #(.DATA_WIDTH(SW)) u_rx_jb (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jb_ad_sdout),
        .left_data (jb_l_in), .right_data (jb_r_in), .sample_valid (valid_jb)
    );

    // ----- Matrix -----
    // Channel map (packed): ch0=JA_L, ch1=JA_R, ch2=JB_L, ch3=JB_R (ch0 at LSB).
    logic [N*SW-1:0] mtx_in, mtx_out;
    assign mtx_in = { jb_r_in, jb_l_in, ja_r_in, ja_l_in };

    logic [SW-1:0] ja_l_out, ja_r_out, jb_l_out, jb_r_out;
    assign { jb_r_out, jb_l_out, ja_r_out, ja_l_out } = mtx_out;

    // Gain constants (Q2.16): 1.0, 0.5, 0.0
    localparam logic signed [17:0] G_UNITY = 18'sh10000;
    localparam logic signed [17:0] G_HALF  = 18'sh08000;
    localparam logic signed [17:0] G_ZERO  = 18'sh00000;

    // -------------------------------------------------------------------------
    // IDENTITY routing (debug): each output = its own input at unity. Every
    // Pmod loops back to itself; no cross-routes, no fractional gains. This is
    // the minimal datapath test -- if an output is still noisy here, the matrix
    // insertion or the clocking (not the routing or the gains) is implicated.
    //   JA_L = JA_L,  JA_R = JA_R,  JB_L = JB_L,  JB_R = JB_R
    // Rows = outputs (out3..out0), each row lists cols i3,i2,i1,i0.
    localparam logic [N*N*18-1:0] MATRIX_GAINS = {
        //  i3       i2       i1       i0
        G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JB_R = JB_R in
        G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out2 JB_L = JB_L in
        G_ZERO,  G_ZERO,  G_UNITY, G_ZERO,    // out1 JA_R = JA_R in
        G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JA_L = JA_L in
    };

    // -------------------------------------------------------------------------
    // DEMO routing (restore when the datapath is proven clean): a passthrough,
    // a cross-Pmod route, and a summed 0.5+0.5 mix.
    //   JA_L = JA_L,  JA_R = JB_L,  JB_L = 0.5*JA_L + 0.5*JB_L,  JB_R = JB_R
    // localparam logic [N*N*18-1:0] MATRIX_GAINS = {
    //     G_UNITY, G_ZERO,  G_ZERO,  G_ZERO,    // out3 JB_R = JB_R in
    //     G_ZERO,  G_HALF,  G_ZERO,  G_HALF,    // out2 JB_L = 0.5*JA_L + 0.5*JB_L
    //     G_ZERO,  G_UNITY, G_ZERO,  G_ZERO,    // out1 JA_R = JB_L in
    //     G_ZERO,  G_ZERO,  G_ZERO,  G_UNITY    // out0 JA_L = JA_L in
    // };

    pcm_matrix #(
        .N (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (18), .GAIN_FRAC (16),
        .GAINS_FLAT (MATRIX_GAINS)
    ) u_matrix (
        .mclk (mclk), .rst_n (rst_n),
        .sample_valid_i (valid_ja),
        .in_flat  (mtx_in),
        .out_flat (mtx_out),
        .sample_valid_o ()
    );

    // ----- Transmitters: PCM -> I2S (per Pmod, stereo) -----
    // sdata leaves through the same SDR ODDR pattern as SCLK/LRCK above, so
    // the mid-cell launch phase fixed in i2s_transmitter survives at the pin.
    logic ja_sdin_int, jb_sdin_int;

    i2s_transmitter #(.DATA_WIDTH(SW)) u_tx_ja (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (ja_l_out), .right_data (ja_r_out), .sdata_o (ja_sdin_int)
    );
    i2s_transmitter #(.DATA_WIDTH(SW)) u_tx_jb (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (jb_l_out), .right_data (jb_r_out), .sdata_o (jb_sdin_int)
    );

    oddr_out u_fwd_ja_da_sdin (.clk(mclk), .d1(ja_sdin_int), .d2(ja_sdin_int), .q(ja_da_sdin));
    oddr_out u_fwd_jb_da_sdin (.clk(mclk), .d1(jb_sdin_int), .d2(jb_sdin_int), .q(jb_da_sdin));

endmodule
