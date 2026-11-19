// -----------------------------------------------------------------------------
// tb_ltc_decoder.sv
//
// ltc_decoder against the vectors of src/sim/ltc_gen.py (an independent
// encoder; xsim_regress.ps1 runs it first, so vectors are never stale).
//
// Checks:
//   - every expected frame is reported, in order, with its 64 bits exact, and
//     nothing else is ever reported (music, noise and steady tones included);
//   - each is reported within a few samples of its last bit;
//   - FRAME_SAMPLES of consecutive frames is within 2 samples of the distance
//     between their expected positions, and exactly 1,600 on the clean 30 fps
//     segment;
//   - locked is high at the end of every LTC segment, and is low again after
//     the gap that follows it; signal follows the same rule;
//   - `locked` is never high during a segment that isn't LTC, and `signal`
//     stays low for noise below the slicer's threshold;
//   - clear in mid-stream: locked drops at once, no frame is reported across
//     it, and frames resume, starting from the second sync word after it.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ltc_decoder;

    `include "ltc_params.svh"

    localparam int LATE_MAX = 4;     // samples a report may trail the last bit

    logic mclk = 0;
    always #40.69 mclk = ~mclk;

    logic               rst_n = 0, clear = 0, sample_valid = 0;
    logic signed [23:0] sample = '0;
    logic [63:0]        tc_data;
    logic [31:0]        frames;
    logic [15:0]        frame_samples;
    logic               signal, locked;

    ltc_decoder dut (
        .mclk (mclk), .rst_n (rst_n), .clear (clear),
        .sample_valid (sample_valid), .sample (sample),
        .tc_data (tc_data), .frames (frames), .frame_samples (frame_samples),
        .signal (signal), .locked (locked));

    logic [23:0]  mem_samples [0:N_SAMPLES-1];
    logic [95:0]  mem_expect  [0:N_EXPECT-1];
    logic [127:0] mem_meta    [0:N_SEG-1];

    int          idx = 0;           // the sample being presented
    int          seg = 0, a, b, c, d;
    int          errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 25) $display("  ERROR at sample %0d: %s", idx, msg);
    endtask

    int          got = 0;           // frames seen so far
    logic [31:0] frames_q = 0;
    int          prev_pos = -1;

    // Sends one sample, 4 mclk cycles apart (256 on the board; the block does
    // all of a sample's work on the strobe edge, so the spacing doesn't matter).
    task automatic send(input logic [23:0] s);
        @(negedge mclk);
        sample       = s;
        sample_valid = 1'b1;
        @(negedge mclk);
        sample_valid = 1'b0;
        check_report();
        repeat (2) @(negedge mclk);
    endtask

    task automatic check_report();
        int pos;
        logic [63:0] word;
        if (frames === frames_q) return;
        if (frames !== frames_q + 1) fail($sformatf("frames jumped %0d -> %0d", frames_q, frames));
        frames_q = frames;
        if (got >= N_EXPECT) begin
            fail($sformatf("an extra frame: %016h", tc_data));
            return;
        end
        {pos, word} = mem_expect[got];
        if (tc_data !== word)
            fail($sformatf("frame %0d: got %016h, expected %016h", got, tc_data, word));
        if (idx < pos - LATE_MAX || idx > pos + LATE_MAX)
            fail($sformatf("frame %0d reported at sample %0d, its last bit is at %0d", got, idx, pos));
        if (prev_pos >= 0 && pos - prev_pos < 3000) begin
            int d = pos - prev_pos, m = int'(frame_samples);
            if (m < d - 2 || m > d + 2)
                fail($sformatf("frame %0d: FRAME_SAMPLES %0d, the distance is %0d", got, m, d));
        end
        if (seg == 0 && frame_samples !== 16'd1600)
            fail($sformatf("frame %0d: FRAME_SAMPLES %0d, expected 1600", got, frame_samples));
        prev_pos = pos;
        got++;
    endtask

    initial begin
        $readmemh("ltc_samples.mem", mem_samples);
        $readmemh("ltc_expect.mem",  mem_expect);
        $readmemh("ltc_meta.mem",    mem_meta);

        repeat (10) @(negedge mclk);
        rst_n = 1;
        repeat (4) @(negedge mclk);
        if (locked !== 1'b0 || signal !== 1'b0 || frames !== 0) fail("not idle after reset");

        for (seg = 0; seg < N_SEG; seg++) begin
            {a, b, c, d} = mem_meta[seg];
            for (idx = a; idx <= b; idx++) begin
                send(mem_samples[idx]);
                if (c != 1 && locked !== 1'b0) fail($sformatf("segment %0d isn't LTC, yet locked", seg));
                if (c == 2 && signal !== 1'b0) fail($sformatf("segment %0d is below the slicer, yet a signal", seg));
            end
            if (c == 1 && locked !== 1'b1) fail($sformatf("segment %0d: not locked at its end", seg));
            if (c == 1 && signal !== 1'b1) fail($sformatf("segment %0d: no signal at its end", seg));
            // the gap after the segment
            for (idx = b + 1; idx <= b + GAP; idx++) send(mem_samples[idx]);
            if (locked !== 1'b0) fail($sformatf("segment %0d: still locked after the gap", seg));
            if (signal !== 1'b0) fail($sformatf("segment %0d: signal still high after the gap", seg));
            prev_pos = -1;
        end
        if (got != N_EXPECT) fail($sformatf("%0d frames reported, expected %0d", got, N_EXPECT));

        // ----- clear in mid-stream: the first LTC segment again -----
        begin
            automatic int first, last, unused1, unused2;
            automatic int at_clear = 0, n = 0;
            {first, last, unused1, unused2} = mem_meta[0];
            for (idx = first; idx < first + (last - first) / 2; idx++) begin
                @(negedge mclk); sample = mem_samples[idx]; sample_valid = 1;
                @(negedge mclk); sample_valid = 0;
            end
            if (locked !== 1'b1) fail("clear test: not locked before the clear");
            at_clear = frames;
            @(negedge mclk); clear = 1;
            @(negedge mclk); clear = 0;
            @(negedge mclk);
            if (locked !== 1'b0) fail("clear: locked didn't drop");
            if (signal !== 1'b0) fail("clear: signal didn't drop");
            if (frames !== at_clear) fail("clear changed the frame counter");
            for (; idx <= last; idx++) begin
                @(negedge mclk); sample = mem_samples[idx]; sample_valid = 1;
                @(negedge mclk); sample_valid = 0;
                n++;
                // a report needs a sync word and then a whole frame: at least 1,600 samples
                if (n < 1500 && frames !== at_clear) fail("clear: a frame reported too soon after it");
            end
            if (frames == at_clear) fail("clear: frames didn't resume");
            if (locked !== 1'b1) fail("clear: no lock after it");
        end

        if (errors == 0) $display("tb_ltc_decoder: PASS (%0d frames, %0d segments, %0d samples)", got, N_SEG, N_SAMPLES);
        else             $display("tb_ltc_decoder: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
