// -----------------------------------------------------------------------------
// pcm_stream_monitor.sv  (simulation only)
//
// Checks one PCM stream (docs/architecture_modules.md 2.1) against the
// contract and, optionally, against a block's stated timing:
//   - every channel exactly once per frame, in ascending order 0 .. N-1;
//   - SPANS = 0 (the default): all beats of a frame between its strobe and
//     the next one;
//     SPANS = 1 (library foundation, LF1, 2026-10-26: a chain may span
//     frames): a frame may cross strobes. Channel 0 marks a frame; a frame
//     must be complete before the next frame's channel 0, and consecutive
//     frames start exactly FRAME cycles apart (a fixed schedule);
//   - FIRST_BEAT / LAST_BEAT: the cycle of beat 0 / beat N-1 after the strobe
//     (-1 = don't check). With SPANS = 1 the cycle is counted from the frame's
//     own strobe and may exceed FRAME: a beat at edge e is cycle c after a
//     strobe at edge s when e = s + c + 1, and some strobe must fit;
//   - CONTIGUOUS: no idle cycle between beats.
// Cycle numbering as in the converters: the edge that samples frame_i high is
// edge 0, and "cycle c" is the interval after edge c.
//
// Frames before the first beat ever seen may be empty (start-up); after that
// an empty or incomplete frame is an error (SPANS = 1: an incomplete one at
// the next channel 0, an empty one through the frame spacing). `errors` and
// `frames` (completed frames) are read by the TB; the first MAX_MSG errors
// are printed with NAME.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pcm_stream_monitor #(
    parameter int    N          = 12,
    parameter int    FIRST_BEAT = -1,
    parameter int    LAST_BEAT  = -1,
    parameter bit    CONTIGUOUS = 1'b0,
    parameter bit    SPANS      = 1'b0,
    parameter int    FRAME      = 256,
    parameter string NAME       = "stream",
    parameter int    MAX_MSG    = 10,
    localparam int   CW         = (N > 1) ? $clog2(N) : 1
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          frame_i,
    input  logic          s_valid,
    input  logic [CW-1:0] s_ch,
    output int            errors,
    output int            frames
);

    int  cyc      = -1;    // SPANS = 0: cycle within the frame; -1 = no strobe seen yet
    int  expect_c = 0;     // next channel expected
    bit  seen_any = 0;     // any beat since reset
    bit  prev_v   = 0;     // beat in the previous cycle

    // SPANS = 1
    int  edge_n     = 0;   // edges since reset
    int  strobes [$];      // edges of the recent strobes
    int  last_start = -1;  // edge of the last channel-0 beat

    initial begin errors = 0; frames = 0; end

    task automatic fail(input string what);
        errors++;
        if (errors <= MAX_MSG)
            $display("[%0t] %s: %s (cycle %0d, expected ch %0d)",
                     $time, NAME, what, SPANS ? edge_n : cyc, expect_c);
    endtask

    // SPANS = 1: whether a beat at edge e is at cycle c after some strobe.
    function automatic bit at_stated(input int e, input int c);
        foreach (strobes[k])
            if (strobes[k] == e - c - 1) return 1;
        return 0;
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc = -1; expect_c = 0; seen_any = 0; prev_v = 0;
            edge_n = 0; strobes.delete(); last_start = -1;
        end else if (!SPANS) begin
            // Signals sampled on this edge belong to cycle `cyc` of the
            // current frame (even on a strobe edge: the last cycle of it).
            if (s_valid) begin
                if (cyc < 0)
                    fail("beat before the first strobe");
                if (int'(s_ch) != expect_c)
                    fail($sformatf("beat for ch %0d", s_ch));
                if (expect_c == 0 && FIRST_BEAT >= 0 && cyc != FIRST_BEAT)
                    fail($sformatf("first beat at cycle %0d, stated %0d", cyc, FIRST_BEAT));
                if (int'(s_ch) == N-1 && LAST_BEAT >= 0 && cyc != LAST_BEAT)
                    fail($sformatf("last beat at cycle %0d, stated %0d", cyc, LAST_BEAT));
                if (CONTIGUOUS && expect_c != 0 && !prev_v)
                    fail("gap between beats");
                seen_any = 1;
                expect_c = int'(s_ch) + 1;
                if (expect_c == N) frames++;
            end
            prev_v = s_valid;

            if (frame_i) begin
                if (cyc >= 0 && seen_any && expect_c != N)
                    fail($sformatf("frame ended with %0d of %0d beats", expect_c, N));
                expect_c = 0;
                cyc      = 0;
            end else if (cyc >= 0) begin
                cyc++;
            end
        end else begin
            edge_n++;
            if (s_valid) begin
                if (strobes.size() == 0)
                    fail("beat before the first strobe");
                if (s_ch == '0) begin
                    // channel 0 opens a frame
                    if (expect_c != 0)
                        fail($sformatf("frame ended with %0d of %0d beats", expect_c, N));
                    expect_c = 0;
                    if (FRAME > 0 && last_start >= 0 && edge_n - last_start != FRAME)
                        fail($sformatf("frame started %0d cycles after the previous one, not %0d",
                                       edge_n - last_start, FRAME));
                    last_start = edge_n;
                    if (FIRST_BEAT >= 0 && !at_stated(edge_n, FIRST_BEAT))
                        fail($sformatf("first beat not at cycle %0d after a strobe", FIRST_BEAT));
                end
                if (int'(s_ch) != expect_c)
                    fail($sformatf("beat for ch %0d", s_ch));
                if (int'(s_ch) == N-1 && LAST_BEAT >= 0 && !at_stated(edge_n, LAST_BEAT))
                    fail($sformatf("last beat not at cycle %0d after a strobe", LAST_BEAT));
                if (CONTIGUOUS && s_ch != '0 && !prev_v)
                    fail("gap between beats");
                seen_any = 1;
                expect_c = int'(s_ch) + 1;
                if (expect_c == N) begin
                    frames++;
                    expect_c = 0;
                end
            end
            prev_v = s_valid;
            // A beat on a strobe edge belongs to the frames before it: record
            // the strobe after checking it. Keep the last 64 (16k cycles: far
            // past the longest chain, mixer_core_pkg::D_CAP).
            if (frame_i) begin
                strobes.push_back(edge_n);
                if (strobes.size() > 64) void'(strobes.pop_front());
            end
        end
    end

endmodule
