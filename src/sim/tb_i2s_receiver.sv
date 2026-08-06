// -----------------------------------------------------------------------------
// tb_i2s_receiver.sv
//
// Drives known I2S bit patterns into the receiver and checks the captured
// left/right registers match. Uses the actual i2s_clock_divider to generate
// SCLK/LRCK so the timing is realistic; MCLK is generated locally at
// 12.288 MHz (period ~81.4 ns) rather than through the MMCM, since we don't
// need to simulate the MMCM here.
//
// Test values are chosen with easy-to-spot bit patterns so waveform
// inspection is quick if something fails.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_i2s_receiver;

    // ------- Signals -------
    logic mclk = 0;
    logic rst_n = 0;
    logic sclk, lrck;
    logic sdata_i = 0;

    logic [23:0] left_data, right_data;
    logic        sample_valid;

    // ------- Clock: 12.288 MHz -> period ~81.4 ns -------
    // Using 81 ns for simplicity (12.346 MHz); doesn't affect logical
    // correctness, just makes the numbers rounder.
    localparam real MCLK_PERIOD_NS = 81.0;
    always #(MCLK_PERIOD_NS / 2.0) mclk = ~mclk;

    // ------- DUT clock generator (the real divider from the design) -------
    i2s_clock_divider u_div (
        .mclk  (mclk),
        .rst_n (rst_n),
        .sclk  (sclk),
        .lrck  (lrck)
    );

    // ------- DUT (receiver under test) -------
    i2s_receiver #(.DATA_WIDTH(24)) dut (
        .mclk         (mclk),
        .rst_n        (rst_n),
        .sclk_i       (sclk),
        .lrck_i       (lrck),
        .sdata_i      (sdata_i),
        .left_data    (left_data),
        .right_data   (right_data),
        .sample_valid (sample_valid)
    );

    // ------- Stimulus helper -------
    // Drives a 24-bit word onto sdata_i over one LRCK half-period, using
    // proper I2S timing (data changes on falling SCLK, one delay bit before
    // MSB, then MSB..LSB, then zeros until LRCK toggles).
    //
    // Assumes called immediately after an LRCK edge.
    task automatic drive_word(input logic [23:0] word);
        logic starting_lrck;
        starting_lrck = lrck;

        // 1st falling SCLK after LRCK edge - delay bit
        @(negedge sclk); sdata_i = 1'b0;

        // 24 bits, MSB first
        for (int i = 23; i >= 0; i--) begin
            @(negedge sclk); sdata_i = word[i];
        end

        // Trailing zeros until LRCK toggles
        while (lrck == starting_lrck) begin
            @(negedge sclk); sdata_i = 1'b0;
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
        $display("");
        $display("=== tb_i2s_receiver ===");

        // Reset
        rst_n = 0;
        sdata_i = 0;
        repeat (10) @(posedge mclk);
        rst_n = 1;
        $display("Reset released.");

        // Wait for the first full LRCK cycle to establish sync.
        @(posedge lrck);
        @(negedge lrck);

        // ----- Test 1: alternating bit pattern -----
        $display("Test 1: L=0xA5A5A5, R=0x5A5A5A");
        @(negedge lrck);                 // start of left channel
        drive_word(24'hA5A5A5);          // through left half-period
        drive_word(24'h5A5A5A);          // through right half-period
        @(posedge sample_valid);         // fires at end of right channel
        check("left_data",  24'hA5A5A5, left_data);
        check("right_data", 24'h5A5A5A, right_data);

        // ----- Test 2: all ones, all zeros -----
        $display("Test 2: L=0xFFFFFF, R=0x000000");
        @(negedge lrck);
        drive_word(24'hFFFFFF);
        drive_word(24'h000000);
        @(posedge sample_valid);
        check("left_data",  24'hFFFFFF, left_data);
        check("right_data", 24'h000000, right_data);

        // ----- Test 3: distinct arbitrary values -----
        $display("Test 3: L=0x123456, R=0xABCDEF");
        @(negedge lrck);
        drive_word(24'h123456);
        drive_word(24'hABCDEF);
        @(posedge sample_valid);
        check("left_data",  24'h123456, left_data);
        check("right_data", 24'hABCDEF, right_data);

        // ----- Summary -----
        $display("");
        if (errors == 0)
            $display("PASS: tb_i2s_receiver - all checks passed");
        else
            $display("FAIL: tb_i2s_receiver - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    // Safety net so a broken sim doesn't run forever
    initial begin
        #200us;
        $display("FAIL: tb_i2s_receiver TIMEOUT");
        $finish;
    end

endmodule
