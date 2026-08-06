// -----------------------------------------------------------------------------
// tb_i2s_transmitter.sv
//
// Sets left_data/right_data to known values and samples sdata_o at rising
// SCLK edges (the way an I2S receiver would), reassembling the transmitted
// words and comparing against expected.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_i2s_transmitter;

    // ------- Signals -------
    logic mclk = 0;
    logic rst_n = 0;
    logic sclk, lrck;
    logic sdata_o;

    logic [23:0] left_data  = 24'h000000;
    logic [23:0] right_data = 24'h000000;

    localparam real MCLK_PERIOD_NS = 81.0;
    always #(MCLK_PERIOD_NS / 2.0) mclk = ~mclk;

    i2s_clock_divider u_div (
        .mclk  (mclk),
        .rst_n (rst_n),
        .sclk  (sclk),
        .lrck  (lrck)
    );

    i2s_transmitter #(.DATA_WIDTH(24)) dut (
        .mclk       (mclk),
        .rst_n      (rst_n),
        .sclk_i     (sclk),
        .lrck_i     (lrck),
        .left_data  (left_data),
        .right_data (right_data),
        .sdata_o    (sdata_o)
    );

    // ------- Capture helper -------
    // Samples the 24 data bits of the current channel's half-period into
    // `captured`. Called immediately after an LRCK edge; steps through the
    // delay bit and then 24 rising SCLK edges.
    task automatic capture_word(output logic [23:0] captured);
        captured = 24'h000000;
        // 1st rising SCLK after LRCK edge - delay bit, ignore
        @(posedge sclk);
        // 24 data bits, MSB first
        for (int i = 23; i >= 0; i--) begin
            @(posedge sclk);
            captured[i] = sdata_o;
        end
    endtask

    // ------- Assertion helper -------
    int errors = 0;
    task automatic check(input string what,
                         input logic [23:0] expected,
                         input logic [23:0] actual);
        if (actual === expected) begin
            $display("  [ok] %s: 0x%06h", what, actual);
        end else begin
            $display("  [FAIL] %s: expected 0x%06h, got 0x%06h", what, expected, actual);
            errors++;
        end
    endtask

    // ------- Main test sequence -------
    initial begin
        logic [23:0] captured_L, captured_R;

        $display("");
        $display("=== tb_i2s_transmitter ===");

        // Reset
        rst_n = 0;
        repeat (10) @(posedge mclk);
        rst_n = 1;
        $display("Reset released.");

        // Wait for a full LRCK cycle to reach steady state.
        @(posedge lrck);

        // ----- Test 1 -----
        $display("Test 1: L=0xA5A5A5, R=0x5A5A5A");
        left_data  = 24'hA5A5A5;
        right_data = 24'h5A5A5A;

        // Wait for start of a new left-channel frame, then capture two words
        @(negedge lrck);
        capture_word(captured_L);
        capture_word(captured_R);
        check("captured L", 24'hA5A5A5, captured_L);
        check("captured R", 24'h5A5A5A, captured_R);

        // ----- Test 2 -----
        $display("Test 2: L=0xFFFFFF, R=0x000000");
        left_data  = 24'hFFFFFF;
        right_data = 24'h000000;

        @(negedge lrck);
        capture_word(captured_L);
        capture_word(captured_R);
        check("captured L", 24'hFFFFFF, captured_L);
        check("captured R", 24'h000000, captured_R);

        // ----- Test 3 -----
        $display("Test 3: L=0x123456, R=0xABCDEF");
        left_data  = 24'h123456;
        right_data = 24'hABCDEF;

        @(negedge lrck);
        capture_word(captured_L);
        capture_word(captured_R);
        check("captured L", 24'h123456, captured_L);
        check("captured R", 24'hABCDEF, captured_R);

        // ----- Summary -----
        $display("");
        if (errors == 0)
            $display("PASS: tb_i2s_transmitter - all checks passed");
        else
            $display("FAIL: tb_i2s_transmitter - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    initial begin
        #200us;
        $display("FAIL: tb_i2s_transmitter TIMEOUT");
        $finish;
    end

endmodule
