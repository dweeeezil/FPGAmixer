// -----------------------------------------------------------------------------
// tb_i2s_tx_pin_phase.sv
//
// Pin-phase regression for the transmitter: sdata_o must only ever change
// while SCLK is LOW (between the falling and rising edges of a bit cell), so
// that it is stable across the rising edge -- the edge the external DAC
// (CS4344) samples. Every DUT output is an mclk-registered signal, so "same
// mclk cycle" in sim equals "same instant at the pins" on hardware, +/- a few
// ns of routing skew.
//
// This test exists because 2FF edge detection in the transmitter once delayed
// the data launch by exactly half an SCLK period (2 mclk), landing every
// sdata_o transition ON the DAC's sampling edge. The functional testbenches
// stayed green through that bug, because the in-house i2s_receiver used as
// their monitor samples one mclk AFTER the rising edge and always caught the
// new bit; the real DAC razor-raced instead. Functional capture checks cannot
// see this failure mode -- only a phase check like this one can. See
// docs/bugfix_2026-08-14_phase3-noise.md for the full story.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_i2s_tx_pin_phase;

    logic mclk = 0;
    logic rst_n = 0;
    logic sclk, lrck;
    logic sdata_o;

    // 0xAAAAAA/0x555555 make adjacent bits differ everywhere, forcing a
    // sdata_o transition in (nearly) every bit cell. A randomized phase
    // follows so the check isn't tied to one pattern.
    logic [23:0] left_data  = 24'hAAAAAA;
    logic [23:0] right_data = 24'h555555;

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

    // Fresh (pseudo-random) samples each frame, like a live datapath would
    // present. The DUT only reads these at LRCK edges, so mid-frame updates
    // are safe and realistic.
    always @(negedge lrck) begin
        if (rst_n) begin
            left_data  <= $urandom();
            right_data <= $urandom();
        end
    end

    // ------- Observer -------
    // DUT outputs change only on posedge mclk; sampling on negedge cleanly
    // shows what changed during the preceding posedge. The check: whenever
    // sdata_o has changed, SCLK must now be LOW. A transition in the same
    // cycle as (or after) the rising edge means the DAC's sample of this bit
    // is a race.
    int n_trans = 0;
    int errors  = 0;

    initial begin
        logic sdata_q;

        $display("");
        $display("=== tb_i2s_tx_pin_phase ===");

        // Reset
        rst_n = 0;
        repeat (10) @(posedge mclk);
        rst_n = 1;
        $display("Reset released.");

        // Flush to steady state (a few full frames).
        repeat (3*256) @(negedge mclk);

        // Observe 8 full LRCK frames: 2 with the worst-case fixed patterns,
        // then randomized frames from the always block above.
        sdata_q = sdata_o;
        repeat (8*256) begin
            @(negedge mclk);
            if (sdata_o !== sdata_q) begin
                n_trans++;
                if (sclk !== 1'b0) begin
                    errors++;
                    if (errors <= 5)
                        $display("  [FAIL] sdata_o changed while SCLK high (t=%0t) - lands on/after the DAC sampling edge", $time);
                end
            end
            sdata_q = sdata_o;
        end

        // Guard against a vacuous pass (e.g. stimulus accidentally constant).
        // Random data averages ~25 transitions/frame over 8 frames; a stuck
        // stimulus produces near zero. 100 splits those cleanly.
        if (n_trans < 100) begin
            $display("  [FAIL] only %0d sdata_o transitions observed - stimulus did not exercise the check", n_trans);
            errors++;
        end

        // ----- Summary -----
        $display("");
        if (errors == 0)
            $display("PASS: tb_i2s_tx_pin_phase - %0d transitions, all while SCLK low", n_trans);
        else
            $display("FAIL: tb_i2s_tx_pin_phase - %0d error(s)", errors);
        $display("");
        $finish;
    end

    initial begin
        #1ms;
        $display("FAIL: tb_i2s_tx_pin_phase TIMEOUT");
        $finish;
    end

endmodule
