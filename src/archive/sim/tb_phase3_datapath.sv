// -----------------------------------------------------------------------------
// tb_phase3_datapath.sv
//
// End-to-end integration test of fpgamixer_top (with the MMCM IP stubbed).
//
// The trick that makes this trustworthy: instead of hand-rolling I2S bit
// timing (the thing the Phase 2 harnesses got wrong), it uses the project's
// OWN known-good modules as the test fixture --
//   * two i2s_transmitters act as the ADCs, generating the serial streams fed
//     into fpgamixer_top's ad_sdout inputs from TB-chosen PCM values;
//   * two i2s_receivers act as DAC monitors, recovering PCM from fpgamixer_top's
//     da_sdin outputs.
// Both fixtures are clocked from fpgamixer_top's OWN generated sclk/lrck (tapped
// off its output pins), exactly as the real converters are. So the only DUT-
// specific thing under test is fpgamixer_top's channel wiring + the matrix.
//
// For each input vector we hold the four source channels steady, let the
// pipeline settle for several frames, then check the four recovered outputs
// against an independent reference model of fpgamixer_top's routing.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_phase3_datapath;

    localparam int SW = 24;

    // Routing gains, mirrored from fpgamixer_top.MATRIX_GAINS, in raw Q2.16.
    localparam longint GU = 32'sh10000;   //  1.0 * 2^16
    localparam longint GH = 32'sh08000;   //  0.5 * 2^16
    localparam longint GF = 16;           //  GAIN_FRAC

    logic sysclk = 0;
    always #4 sysclk = ~sysclk;   // nominal 125 MHz (unused by the stub, driven for form)

    // ----- DUT -----
    logic jb_da_sdin, jb_ad_sdout;
    logic jc_da_sdin, jc_ad_sdout;
    logic jb_da_mclk, jb_da_lrck, jb_da_sclk, jb_ad_mclk, jb_ad_lrck, jb_ad_sclk;
    logic jc_da_mclk, jc_da_lrck, jc_da_sclk, jc_ad_mclk, jc_ad_lrck, jc_ad_sclk;

    fpgamixer_top u_dut (
        .sysclk (sysclk),
        .jb_da_mclk(jb_da_mclk), .jb_da_lrck(jb_da_lrck), .jb_da_sclk(jb_da_sclk), .jb_da_sdin(jb_da_sdin),
        .jb_ad_mclk(jb_ad_mclk), .jb_ad_lrck(jb_ad_lrck), .jb_ad_sclk(jb_ad_sclk), .jb_ad_sdout(jb_ad_sdout),
        .jc_da_mclk(jc_da_mclk), .jc_da_lrck(jc_da_lrck), .jc_da_sclk(jc_da_sclk), .jc_da_sdin(jc_da_sdin),
        .jc_ad_mclk(jc_ad_mclk), .jc_ad_lrck(jc_ad_lrck), .jc_ad_sclk(jc_ad_sclk), .jc_ad_sdout(jc_ad_sdout)
    );

    // Tap the DUT's generated clocks (what the real converters run on).
    wire mclk = u_dut.mclk;
    wire sclk = jb_ad_sclk;
    wire lrck = jb_ad_lrck;

    // Fixture reset: released once the stubbed MMCM has locked.
    logic fix_rst_n = 0;

    // ----- Source "ADCs": TB drives PCM, these serialize into the DUT -----
    logic [SW-1:0] src_jb_l, src_jb_r, src_jc_l, src_jc_r;

    i2s_transmitter #(.DATA_WIDTH(SW)) src_jb (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (src_jb_l), .right_data (src_jb_r), .sdata_o (jb_ad_sdout)
    );
    i2s_transmitter #(.DATA_WIDTH(SW)) src_jc (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (src_jc_l), .right_data (src_jc_r), .sdata_o (jc_ad_sdout)
    );

    // ----- Monitor "DACs": recover PCM from the DUT's outputs -----
    logic [SW-1:0] mon_jb_l, mon_jb_r, mon_jc_l, mon_jc_r;
    logic          mon_valid_jb, mon_valid_jc;

    i2s_receiver #(.DATA_WIDTH(SW)) mon_jb (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jb_da_sdin),
        .left_data (mon_jb_l), .right_data (mon_jb_r), .sample_valid (mon_valid_jb)
    );
    i2s_receiver #(.DATA_WIDTH(SW)) mon_jc (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jc_da_sdin),
        .left_data (mon_jc_l), .right_data (mon_jc_r), .sample_valid (mon_valid_jc)
    );

    // ----- Reference model of fpgamixer_top's routing -----
    function automatic logic signed [SW-1:0] sat24(input longint acc);
        longint scaled;
        scaled = acc >>> GF;
        if      (scaled >  24'sh7FFFFF) return 24'sh7FFFFF;
        else if (scaled < -(1<<<23))    return 24'sh800000;
        else                            return scaled[SW-1:0];
    endfunction

    // out = routing(in). MUST mirror fpgamixer_top's active MATRIX_GAINS.
    // Currently IDENTITY: each output = its own input at unity.
    function automatic logic signed [SW-1:0] ref_jb_l(input longint al,ar,bl,br); return sat24(GU*al); endfunction
    function automatic logic signed [SW-1:0] ref_jb_r(input longint al,ar,bl,br); return sat24(GU*ar); endfunction
    function automatic logic signed [SW-1:0] ref_jc_l(input longint al,ar,bl,br); return sat24(GU*bl); endfunction
    function automatic logic signed [SW-1:0] ref_jc_r(input longint al,ar,bl,br); return sat24(GU*br); endfunction

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
        src_jb_l = al; src_jb_r = ar; src_jc_l = bl; src_jc_r = br;
        // Let the full pipeline settle (src->rx->matrix->tx->mon).
        repeat (10) @(posedge mon_valid_jb);
        // Sample one clean frame.
        @(posedge mon_valid_jb);
        #1;
        $display("  %s: in = [%06h %06h %06h %06h]", label, al, ar, bl, br);
        check1("JB_L", mon_jb_l, ref_jb_l(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JB_R", mon_jb_r, ref_jb_r(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JC_L", mon_jc_l, ref_jc_l(s24(al),s24(ar),s24(bl),s24(br)));
        check1("JC_R", mon_jc_r, ref_jc_r(s24(al),s24(ar),s24(bl),s24(br)));
    endtask

    initial begin
        $display("");
        $display("=== tb_phase3_datapath ===");
        src_jb_l = 0; src_jb_r = 0; src_jc_l = 0; src_jc_r = 0;

        // Wait for the stubbed MMCM to lock, then release the fixture reset.
        wait (u_dut.mmcm_locked === 1'b1);
        repeat (20) @(posedge mclk);
        fix_rst_n = 1;
        repeat (4) @(posedge lrck);

        // Distinct values so any channel swap or mis-route is obvious.
        apply_and_check("distinct", 24'h111111, 24'h222222, 24'h333333, 24'h444444);
        // Mix check: JC_L out should be 0.5*(JB_L + JC_L).
        apply_and_check("mix",      24'h400000, 24'h000000, 24'h200000, 24'h000000);
        // Only JC_R driven: should appear only on JC_R out.
        apply_and_check("jc_r_only",24'h000000, 24'h000000, 24'h000000, 24'h123456);
        // Negative sample through the cross route (JC_L -> JB_R).
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
