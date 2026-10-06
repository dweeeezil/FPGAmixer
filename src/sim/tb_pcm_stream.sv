// -----------------------------------------------------------------------------
// tb_pcm_stream.sv
//
// P9.A2: the PCM stream contract and the core boundary converters.
//
// Part 1, round trip: pcm_pack2stream -> pcm_stream_monitor -> pcm_stream2pack
// for N = 1, 12, 20 (stream_chain below). Random samples every frame, and the
// packed input is also scrambled mid-frame (the converter must capture it on
// the strobe only). Checks:
//   - out_flat == the in_flat captured at the strobe, bit-exact, every frame;
//   - out_flat changes only on the valid_o edge, all channels together, and
//     valid_o comes exactly at cycle N+1 (the stated timing);
//   - the monitor: order, one beat per channel, FIRST_BEAT = 1,
//     LAST_BEAT = N, contiguous, inside the frame;
//   - err_o never pulses.
// Part 2, pcm_stream2pack alone (N = 5), beats written by the TB:
//   - frames with idle gaps between beats: delivered, no error;
//   - two channels swapped: err_o;
//   - the last beat missing: err_o at the next strobe, output not updated.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module stream_chain #(
    parameter int N      = 12,
    parameter int SW     = 24,
    parameter int FRAMES = 40
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic frame,
    input  int   cyc,          // cycle within the frame (0 after the strobe edge)
    output int   errors,
    output int   checked,
    output bit   done
);
    localparam int CW = (N > 1) ? $clog2(N) : 1;

    logic [N*SW-1:0] in_flat, out_flat, out_prev;
    logic            s_valid, valid_o, err_o;
    logic [CW-1:0]   s_ch;
    logic [SW-1:0]   s_data;
    int              mon_err, mon_frames;

    pcm_pack2stream #(.N (N), .SW (SW)) u_p2s (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame), .in_flat (in_flat),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data));

    pcm_stream_monitor #(.N (N), .FIRST_BEAT (1), .LAST_BEAT (N), .CONTIGUOUS (1'b1),
                         .NAME ("chain monitor")) u_mon (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (s_valid), .s_ch (s_ch), .errors (mon_err), .frames (mon_frames));

    pcm_stream2pack #(.N (N), .SW (SW)) u_s2p (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data),
        .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o));

    function automatic logic [N*SW-1:0] rand_frame();
        logic [N*SW-1:0] v;
        for (int c = 0; c < N; c++) v[c*SW +: SW] = SW'($urandom);
        return v;
    endfunction

    logic [N*SW-1:0] sent [$];
    logic [N*SW-1:0] exp_v;
    int own_err = 0;

    // Drive: new samples just after each strobe edge, scrambled mid-frame.
    initial in_flat = rand_frame();
    always @(negedge mclk) begin
        if (cyc == 0 && frame === 1'b0) in_flat = rand_frame();
        if (cyc == N/2 + 1)             in_flat = rand_frame();  // not captured
    end

    // Record what the strobe captures; check every delivered frame.
    always @(posedge mclk) begin
        if (rst_n) begin
            if (frame) sent.push_back(in_flat);

            if (err_o) begin
                own_err++;
                $display("[%0t] chain N=%0d: err_o", $time, N);
            end

            if (valid_o) begin
                // valid_o/out_flat were set on the edge that ended cycle N,
                // so they are sampled here with cyc == N+1.
                if (cyc != N + 1) begin
                    own_err++;
                    $display("[%0t] chain N=%0d: valid_o at cycle %0d, stated %0d",
                             $time, N, cyc, N + 1);
                end
                if (sent.size() == 0) begin
                    own_err++;
                    $display("[%0t] chain N=%0d: frame delivered, none sent", $time, N);
                end else begin
                    exp_v = sent.pop_front();
                    if (out_flat !== exp_v) begin
                        own_err++;
                        for (int c = 0; c < N; c++)
                            if (out_flat[c*SW +: SW] !== exp_v[c*SW +: SW] && own_err < 12)
                                $display("[%0t] chain N=%0d: ch %0d got %h want %h",
                                         $time, N, c, out_flat[c*SW +: SW], exp_v[c*SW +: SW]);
                    end
                    checked++;
                end
            end else if (out_flat !== out_prev) begin
                own_err++;
                $display("[%0t] chain N=%0d: out_flat changed without valid_o", $time, N);
            end
            out_prev = out_flat;
        end
    end

    initial begin
        checked = 0; done = 0; out_prev = '0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = own_err + mon_err + ((done && mon_frames < FRAMES) ? 1 : 0);
endmodule


module tb_pcm_stream;

    localparam int SW = 24;
    localparam int FRAME_CYCLES = 256;

    logic mclk = 0;
    always #5 mclk = ~mclk;
    logic rst_n = 0;

    // ----- Frame strobe every 256 cycles; cyc = cycle after the strobe edge -----
    logic frame = 0;
    int   cyc   = -1;
    int   ctr   = 0;
    always @(posedge mclk) begin
        if (rst_n) begin
            ctr   <= (ctr == FRAME_CYCLES - 1) ? 0 : ctr + 1;
            frame <= (ctr == FRAME_CYCLES - 1);
            cyc   <= frame ? 0 : (cyc >= 0 ? cyc + 1 : -1);
        end
    end

    // ----- Part 1: round trips -----
    int e1, e12, e20, k1, k12, k20;
    bit d1, d12, d20;
    stream_chain #(.N (1),  .SW (SW)) u_n1  (.mclk, .rst_n, .frame, .cyc,
                                             .errors (e1),  .checked (k1),  .done (d1));
    stream_chain #(.N (12), .SW (SW)) u_n12 (.mclk, .rst_n, .frame, .cyc,
                                             .errors (e12), .checked (k12), .done (d12));
    stream_chain #(.N (20), .SW (SW)) u_n20 (.mclk, .rst_n, .frame, .cyc,
                                             .errors (e20), .checked (k20), .done (d20));

    // ----- Part 2: pcm_stream2pack alone, N = 5, TB-written beats -----
    localparam int N5 = 5, CW5 = 3;
    logic            t_frame = 0, t_valid = 0;
    logic [CW5-1:0]  t_ch = 0;
    logic [SW-1:0]   t_data = 0;
    logic [N5*SW-1:0] t_out;
    logic            t_vo, t_err;
    int              t_err_count = 0, t_vo_count = 0, part2_errors = 0;

    pcm_stream2pack #(.N (N5), .SW (SW)) u_s2p5 (
        .mclk (mclk), .rst_n (rst_n), .frame_i (t_frame),
        .s_valid (t_valid), .s_ch (t_ch), .s_data (t_data),
        .out_flat (t_out), .valid_o (t_vo), .err_o (t_err));

    always @(posedge mclk) begin
        if (t_err) t_err_count++;
        if (t_vo)  t_vo_count++;
    end

    task automatic t_strobe();
        @(negedge mclk) t_frame = 1;
        @(negedge mclk) t_frame = 0;
    endtask

    task automatic t_beat(input int ch, input logic [SW-1:0] d, input int gap);
        repeat (gap) @(negedge mclk);
        t_valid = 1; t_ch = CW5'(ch); t_data = d;
        @(negedge mclk) t_valid = 0;
    endtask

    function automatic logic [SW-1:0] pat(input int f, input int c);
        return SW'(f * 16 + c + 24'h300000);
    endfunction

    task automatic expect_part2(input string what, input int errs, input int vos);
        repeat (3) @(negedge mclk);
        if (t_err_count != errs || t_vo_count != vos) begin
            part2_errors++;
            $display("part 2, %s: err_o %0d (want %0d), valid_o %0d (want %0d)",
                     what, t_err_count, errs, t_vo_count, vos);
        end
    endtask

    task automatic part2();
        logic [N5*SW-1:0] held;
        // A: gaps between beats, delivered, no error
        t_strobe();
        for (int c = 0; c < N5; c++) t_beat(c, pat(1, c), c % 3);
        expect_part2("gaps", 0, 1);
        for (int c = 0; c < N5; c++)
            if (t_out[c*SW +: SW] !== pat(1, c)) begin
                part2_errors++;
                $display("part 2, gaps: ch %0d = %h, want %h", c, t_out[c*SW +: SW], pat(1, c));
            end
        // B: channels 1 and 2 swapped -> err_o (on the beat for 2, then for 1)
        t_strobe();
        t_beat(0, pat(2, 0), 0); t_beat(2, pat(2, 2), 0); t_beat(1, pat(2, 1), 0);
        t_beat(3, pat(2, 3), 0); t_beat(4, pat(2, 4), 0);
        expect_part2("swapped", 3, 2);   // 2 (want 1), 1 (want 3), 3 (want 2)
        // C: last beat missing -> err_o at the next strobe, output unchanged
        held = t_out;
        t_strobe();
        for (int c = 0; c < N5 - 1; c++) t_beat(c, pat(3, c), 0);
        t_strobe();
        expect_part2("missing last", 4, 2);
        if (t_out !== held) begin
            part2_errors++;
            $display("part 2, missing last: output changed");
        end
    endtask

    // ----- Run -----
    initial begin
        repeat (5) @(posedge mclk);
        rst_n = 1;
        part2();
        wait (d1 && d12 && d20);
        repeat (2) @(posedge mclk);

        $display("round trip N=1 : %0d frames, %0d errors", k1, e1);
        $display("round trip N=12: %0d frames, %0d errors", k12, e12);
        $display("round trip N=20: %0d frames, %0d errors", k20, e20);
        $display("stream2pack alone: %0d errors", part2_errors);
        if (e1 + e12 + e20 + part2_errors == 0) $display("PASS tb_pcm_stream");
        else                                     $display("FAIL tb_pcm_stream");
        $finish;
    end

    initial begin
        #50ms;
        $display("FAIL tb_pcm_stream: timeout. Delivered N=1/12/20: %0d/%0d/%0d frames, errors %0d/%0d/%0d",
                 k1, k12, k20, e1, e12, e20);
        $finish;
    end

endmodule
