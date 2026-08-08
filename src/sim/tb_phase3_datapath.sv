// -----------------------------------------------------------------------------
// tb_phase3_datapath.sv
//
// End-to-end integration test of phase3_top (with the MMCM IP stubbed).
//
// The trick that makes this trustworthy: instead of hand-rolling I2S bit
// timing (the thing the Phase 2 harnesses got wrong), it uses the project's
// OWN known-good modules as the test fixture --
//   * two i2s_transmitters act as the ADCs, generating the serial streams fed
//     into phase3_top's ad_sdout inputs from TB-chosen PCM values;
//   * two i2s_receivers act as DAC monitors, recovering PCM from phase3_top's
//     da_sdin outputs.
// Both fixtures are clocked from phase3_top's OWN generated sclk/lrck (tapped
// off its output pins), exactly as the real converters are. So the only DUT-
// specific thing under test is phase3_top's channel wiring + the matrix.
//
// For each input vector we hold the four source channels steady, let the
// pipeline settle for several frames, then check the four recovered outputs
// against an independent reference model of phase3_top's routing.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_phase3_datapath;

    localparam int SW = 24;

    // Routing gains, mirrored from phase3_top.MATRIX_GAINS, in raw Q2.16.
    localparam longint GU = 32'sh10000;   //  1.0 * 2^16
    localparam longint GH = 32'sh08000;   //  0.5 * 2^16
    localparam longint GF = 16;           //  GAIN_FRAC

    logic sysclk = 0;
    always #4 sysclk = ~sysclk;   // nominal 125 MHz (unused by the stub, driven for form)

    // ----- DUT -----
    logic ja_da_sdin, ja_ad_sdout;
    logic jb_da_sdin, jb_ad_sdout;
    logic ja_da_mclk, ja_da_lrck, ja_da_sclk, ja_ad_mclk, ja_ad_lrck, ja_ad_sclk;
    logic jb_da_mclk, jb_da_lrck, jb_da_sclk, jb_ad_mclk, jb_ad_lrck, jb_ad_sclk;

    phase3_top u_dut (
        .sysclk (sysclk),
        .ja_da_mclk(ja_da_mclk), .ja_da_lrck(ja_da_lrck), .ja_da_sclk(ja_da_sclk), .ja_da_sdin(ja_da_sdin),
        .ja_ad_mclk(ja_ad_mclk), .ja_ad_lrck(ja_ad_lrck), .ja_ad_sclk(ja_ad_sclk), .ja_ad_sdout(ja_ad_sdout),
        .jb_da_mclk(jb_da_mclk), .jb_da_lrck(jb_da_lrck), .jb_da_sclk(jb_da_sclk), .jb_da_sdin(jb_da_sdin),
        .jb_ad_mclk(jb_ad_mclk), .jb_ad_lrck(jb_ad_lrck), .jb_ad_sclk(jb_ad_sclk), .jb_ad_sdout(jb_ad_sdout)
    );

    // Tap the DUT's generated clocks (what the real converters run on).
    wire mclk = u_dut.mclk;
    wire sclk = ja_ad_sclk;
    wire lrck = ja_ad_lrck;

    // Fixture reset: released once the stubbed MMCM has locked.
    logic fix_rst_n = 0;

    // ----- Source "ADCs": TB drives PCM, these serialize into the DUT -----
    logic [SW-1:0] src_ja_l, src_ja_r, src_jb_l, src_jb_r;

    i2s_transmitter #(.DATA_WIDTH(SW)) src_ja (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (src_ja_l), .right_data (src_ja_r), .sdata_o (ja_ad_sdout)
    );
    i2s_transmitter #(.DATA_WIDTH(SW)) src_jb (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (src_jb_l), .right_data (src_jb_r), .sdata_o (jb_ad_sdout)
    );

    // ----- Monitor "DACs": recover PCM from the DUT's outputs -----
    logic [SW-1:0] mon_ja_l, mon_ja_r, mon_jb_l, mon_jb_r;
    logic          mon_valid_ja, mon_valid_jb;

    i2s_receiver #(.DATA_WIDTH(SW)) mon_ja (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (ja_da_sdin),
        .left_data (mon_ja_l), .right_data (mon_ja_r), .sample_valid (mon_valid_ja)
    );
    i2s_receiver #(.DATA_WIDTH(SW)) mon_jb (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jb_da_sdin),
        .left_data (mon_jb_l), .right_data (mon_jb_r), .sample_valid (mon_valid_jb)
    );

    // ----- Reference model of phase3_top's routing -----
    function automatic logic signed [SW-1:0] sat24(input longint acc);
        longint scaled;
        scaled = acc >>> GF;
        if      (scaled >  24'sh7FFFFF) return 24'sh7FFFFF;
        else if (scaled < -(1<<<23))    return 24'sh800000;
        else                            return scaled[SW-1:0];
    endfunction

    // out = routing(in). Uses the same gains as phase3_top.MATRIX_GAINS.
    function automatic logic signed [SW-1:0] ref_ja_l(input longint al,ar,bl,br); return sat24(GU*al); endfunction
    function automatic logic signed [SW-1:0] ref_ja_r(input longint al,ar,bl,br); return sat24(GU*bl); endfunction
    function automatic logic signed [SW-1:0] ref_jb_l(input longint al,ar,bl,br); return sat24(GH*al + GH*bl); endfunction
    function automatic logic signed [SW-1:0] ref_jb_r(input longint al,ar,bl,br); return sat24(GU*br); endfunction

    int errors = 0;

    task automatic check1(input string what,
                          input logic signed [SW-1:0] got,
                          input logic signed [SW-1:0] exp);
        if (got === exp) $display("    [ok]  %-6s = %06h", what, got);
        else begin
            $display("    [FAIL] %-6s = %06h, ref = %06h", what, got, exp);
            errors++;
        end
    endtask

    // sign-extend a 24-bit sample to longint for the reference math
    function automatic longint s24(input logic signed [SW-1:0] v); return longint'($signed(v)); endfunction

    task automatic apply_and_check(input string label,
                                   input logic [SW-1:0] al, input logic [SW-1:0] ar,
                                   input logic [SW-1:0] bl, input logic [SW-1:0] br);
        // Drive the sources and hold steady.
        src_ja_l = al; src_ja_r = ar; src_jb_l = bl; src_jb_r = br;
        // Let the full pipeline settle (src->rx->matrix->tx->mon).
        repeat (10) @(posedge mon_valid_ja);
        // Sample one clean frame.
        @(posedge mon_valid_ja);
        #1;
        $display("  %s: in = [%06h %06h %06h %06h]", label, al, ar, bl, br);
        check1("JA_L", mon_ja_l, ref_ja_l(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JA_R", mon_ja_r, ref_ja_r(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JB_L", mon_jb_l, ref_jb_l(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JB_R", mon_jb_r, ref_jb_r(s24(al),s24(ar),s24(bl),s24(br)));
    endtask

    initial begin
        $display("");
        $display("=== tb_phase3_datapath ===");
        src_ja_l = 0; src_ja_r = 0; src_jb_l = 0; src_jb_r = 0;

        // Wait for the stubbed MMCM to lock, then release the fixture reset.
        wait (u_dut.mmcm_locked === 1'b1);
        repeat (20) @(posedge mclk);
        fix_rst_n = 1;
        repeat (4) @(posedge lrck);

        // Distinct values so any channel swap or mis-route is obvious.
        apply_and_check("distinct", 24'h111111, 24'h222222, 24'h333333, 24'h444444);
        // Mix check: JB_L out should be 0.5*(JA_L + JB_L).
        apply_and_check("mix",      24'h400000, 24'h000000, 24'h200000, 24'h000000);
        // Only JB_R driven: should appear only on JB_R out.
        apply_and_check("jb_r_only",24'h000000, 24'h000000, 24'h000000, 24'h123456);
        // Negative sample through the cross route (JB_L -> JA_R).
        apply_and_check("neg",      24'h000000, 24'h000000, 24'hFF0000, 24'h000000);

        $display("");
        if (errors == 0) $display("PASS: tb_phase3_datapath - all checks passed");
        else             $display("FAIL: tb_phase3_datapath - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    initial begin
        #5ms;
        $display("FAIL: tb_phase3_datapath TIMEOUT");
        $finish;
    end

endmodule
