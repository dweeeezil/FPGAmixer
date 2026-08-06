// -----------------------------------------------------------------------------
// tb_i2s_loopback.sv
//
// Integration test: connect the receiver's output registers directly to the
// transmitter's input, drive a stream of known values into the receiver's
// sdata_i, and verify that the transmitter's sdata_o reproduces those same
// values with exactly one frame of latency.
//
// This models the real Phase 2 datapath in the FPGA. If this passes and the
// unit testbenches pass, the RTL should behave correctly on hardware.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_i2s_loopback;

    logic mclk = 0;
    logic rst_n = 0;
    logic sclk, lrck;
    logic sdata_rx = 0;   // driven by TB into receiver
    logic sdata_tx;       // driven by transmitter

    logic [23:0] left_data, right_data;
    logic        sample_valid;

    localparam real MCLK_PERIOD_NS = 81.0;
    always #(MCLK_PERIOD_NS / 2.0) mclk = ~mclk;

    i2s_clock_divider u_div (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck)
    );

    i2s_receiver #(.DATA_WIDTH(24)) u_rx (
        .mclk        (mclk),
        .rst_n       (rst_n),
        .sclk_i      (sclk),
        .lrck_i      (lrck),
        .sdata_i     (sdata_rx),
        .left_data   (left_data),
        .right_data  (right_data),
        .sample_valid(sample_valid)
    );

    i2s_transmitter #(.DATA_WIDTH(24)) u_tx (
        .mclk       (mclk),
        .rst_n      (rst_n),
        .sclk_i     (sclk),
        .lrck_i     (lrck),
        .left_data  (left_data),
        .right_data (right_data),
        .sdata_o    (sdata_tx)
    );

    // ------- Helpers (same shape as tb_i2s_receiver / tb_i2s_transmitter) --
    task automatic drive_word(input logic [23:0] word);
        logic starting_lrck;
        starting_lrck = lrck;
        @(negedge sclk); sdata_rx = 1'b0;
        for (int i = 23; i >= 0; i--) begin
            @(negedge sclk); sdata_rx = word[i];
        end
        while (lrck == starting_lrck) begin
            @(negedge sclk); sdata_rx = 1'b0;
        end
    endtask

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
        if (actual === expected) begin
            $display("  [ok] %s: 0x%06h", what, actual);
        end else begin
            $display("  [FAIL] %s: expected 0x%06h, got 0x%06h", what, expected, actual);
            errors++;
        end
    endtask

    // ------- Main test -------
    // Strategy: use two parallel processes.
    //   Process A: drives frames 0, 1, 2, 3 into the receiver.
    //   Process B: captures frames 1, 2, 3, 4 from the transmitter (one frame
    //              later) and checks each against the frame that was driven.
    //
    // Frames driven (L, R):
    //   frame 0: (0xA5A5A5, 0x5A5A5A)
    //   frame 1: (0xFFFFFF, 0x000000)
    //   frame 2: (0x123456, 0xABCDEF)
    //   frame 3: (0xDEADBE, 0xEFCAFE)
    //
    // Expected on tx output (one frame delay):
    //   after frame 0: tx output starts producing frame 0's L,R during frame 1
    //   after frame 1: tx output produces frame 1's L,R during frame 2
    //   ...and so on.
    // -----------------------------------------------------------------------

    localparam int N_FRAMES = 4;
    logic [23:0] frames_L [0:N_FRAMES-1];
    logic [23:0] frames_R [0:N_FRAMES-1];

    initial begin
        frames_L[0] = 24'hA5A5A5;  frames_R[0] = 24'h5A5A5A;
        frames_L[1] = 24'hFFFFFF;  frames_R[1] = 24'h000000;
        frames_L[2] = 24'h123456;  frames_R[2] = 24'hABCDEF;
        frames_L[3] = 24'hDEADBE;  frames_R[3] = 24'hEFCAFE;
    end

    // Driver process
    initial begin
        rst_n = 0;
        sdata_rx = 0;
        repeat (10) @(posedge mclk);
        rst_n = 1;

        @(posedge lrck);
        @(negedge lrck);

        for (int f = 0; f < N_FRAMES; f++) begin
            drive_word(frames_L[f]);
            drive_word(frames_R[f]);
        end
    end

    // Checker process
    initial begin
        $display("");
        $display("=== tb_i2s_loopback ===");

        // Wait for reset release
        @(posedge rst_n);
        @(posedge lrck);
        @(negedge lrck);

        // Discard the first frame output - it's whatever the tx produces
        // before the receiver has captured anything meaningful.
        begin
            logic [23:0] junk_L, junk_R;
            capture_word(junk_L);
            capture_word(junk_R);
        end

        // Frames 0..N-2 should now appear at the tx output on successive
        // frames. (Frame N-1's data won't have time to reach the tx before
        // we finish, but that's fine for verifying correctness.)
        for (int f = 0; f < N_FRAMES - 1; f++) begin
            logic [23:0] got_L, got_R;
            capture_word(got_L);
            capture_word(got_R);
            $display("Frame %0d (driven earlier):", f);
            check("L round-trip", frames_L[f], got_L);
            check("R round-trip", frames_R[f], got_R);
        end

        $display("");
        if (errors == 0)
            $display("PASS: tb_i2s_loopback - all checks passed");
        else
            $display("FAIL: tb_i2s_loopback - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    initial begin
        #500us;
        $display("FAIL: tb_i2s_loopback TIMEOUT");
        $finish;
    end

endmodule
