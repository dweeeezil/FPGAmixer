// -----------------------------------------------------------------------------
// tb_i2s_loopback.sv
//
// Integration test: the receiver's output registers feed the transmitter's
// inputs directly (the real Phase 2 datapath). A known value is driven into
// the receiver's sdata_i; after the pipeline settles the transmitter's
// sdata_o is captured and checked.
//
// Robustness note: an earlier version streamed a sequence of distinct frames
// and tried to track the one-frame rx->tx latency while capturing back-to-back
// without re-aligning to LRCK. Both the drive and capture helpers had bit-
// timing bugs (an extra delay bit on drive; no channel re-alignment on
// capture), and the latency bookkeeping was fragile. This version instead:
//   * drives each test value CONTINUOUSLY until it has flushed through, so the
//     exact latency is irrelevant -- steady state is what gets checked;
//   * captures one frame that is explicitly LRCK-aligned per channel.
// This mirrors tb_phase3_datapath, which uses the same modules as fixtures.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_i2s_loopback;

    logic mclk = 0;
    logic rst_n = 0;
    logic sclk, lrck;
    logic sdata_rx = 0;   // TB -> receiver
    logic sdata_tx;       // transmitter -> TB

    logic [23:0] left_data, right_data;
    logic        sample_valid;

    localparam real MCLK_PERIOD_NS = 81.0;
    always #(MCLK_PERIOD_NS / 2.0) mclk = ~mclk;

    i2s_clock_divider u_div (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck)
    );

    i2s_receiver #(.DATA_WIDTH(24)) u_rx (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (sdata_rx),
        .left_data (left_data), .right_data (right_data), .sample_valid (sample_valid)
    );

    i2s_transmitter #(.DATA_WIDTH(24)) u_tx (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data (left_data), .right_data (right_data), .sdata_o (sdata_tx)
    );

    // ------- Serial helpers (same timing as the fixed unit TBs) -------
    // drive_word: MSB on the first falling SCLK after the LRCK edge, then
    // MSB..LSB, then trailing zeros until LRCK toggles (self-re-aligning).
    task automatic drive_word(input logic [23:0] word);
        logic starting_lrck;
        starting_lrck = lrck;
        for (int i = 23; i >= 0; i--) begin
            @(negedge sclk); sdata_rx = word[i];
        end
        while (lrck == starting_lrck) begin
            @(negedge sclk); sdata_rx = 1'b0;
        end
    endtask

    // capture_word: skip one rising (delay bit) then capture 24, MSB first.
    // MUST be called right after the channel's LRCK edge (no self re-align).
    task automatic capture_word(output logic [23:0] captured);
        captured = 24'h000000;
        @(posedge sclk);
        for (int i = 23; i >= 0; i--) begin
            @(posedge sclk);
            captured[i] = sdata_tx;
        end
    endtask

    int errors = 0;
    task automatic check(input string what,
                         input logic [23:0] expected,
                         input logic [23:0] actual);
        if (actual === expected) $display("  [ok] %s: 0x%06h", what, actual);
        else begin
            $display("  [FAIL] %s: expected 0x%06h, got 0x%06h", what, expected, actual);
            errors++;
        end
    endtask

    // ------- Continuous driver: always serializes the CURRENT test value -------
    logic [23:0] cur_L = 24'h000000;
    logic [23:0] cur_R = 24'h000000;

    initial begin
        // Wait for reset + a clean LRCK edge, then drive forever.
        @(posedge rst_n);
        @(negedge lrck);
        forever begin
            // lrck==0 -> left half-period, else right. drive_word returns at
            // the next LRCK edge, so this stays phase-locked to the channels.
            if (lrck == 1'b0) drive_word(cur_L);
            else              drive_word(cur_R);
        end
    end

    // ------- Test: set value, let it flush, capture one aligned frame -------
    task automatic run_case(input string label,
                            input logic [23:0] L, input logic [23:0] R);
        logic [23:0] got_L, got_R;
        cur_L = L; cur_R = R;
        // Hold long enough for rx capture + tx reload to reach steady state.
        repeat (4) @(posedge sample_valid);
        // Capture one frame, each channel aligned to its own LRCK edge.
        @(negedge lrck); capture_word(got_L);
        @(posedge lrck); capture_word(got_R);
        $display("%s: L=0x%06h R=0x%06h", label, L, R);
        check("L round-trip", L, got_L);
        check("R round-trip", R, got_R);
    endtask

    initial begin
        $display("");
        $display("=== tb_i2s_loopback ===");

        rst_n = 0;
        repeat (10) @(posedge mclk);
        rst_n = 1;

        run_case("Frame 0", 24'hA5A5A5, 24'h5A5A5A);
        run_case("Frame 1", 24'hFFFFFF, 24'h000000);
        run_case("Frame 2", 24'h123456, 24'hABCDEF);
        run_case("Frame 3", 24'hDEADBE, 24'hEFCAFE);

        $display("");
        if (errors == 0) $display("PASS: tb_i2s_loopback - all checks passed");
        else             $display("FAIL: tb_i2s_loopback - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    initial begin
        #500us;
        $display("FAIL: tb_i2s_loopback TIMEOUT");
        $finish;
    end

endmodule
