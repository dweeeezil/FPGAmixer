// -----------------------------------------------------------------------------
// tb_pcm_patch.sv
//
// Phase 15: the patch converters, pcm_patch2stream (input patch) and
// pcm_stream2patch (output patch), against a model.
//
// Part 1, chains: pcm_patch2stream -> pcm_stream_monitor -> pcm_stream2patch,
// both tables served by coef_flat_readers, for ports/channels/ports =
// 20/20/20, 20/12/20 (fewer channels than ports), 20/28/20 (more), 5/3/4,
// 3/7/2 and 1/1/1. Every frame gets new random port samples (also scrambled
// mid-frame: only the strobe captures) and new tables in one of four modes:
//   0 "raw"       every entry random over its whole field: None, ports, and
//                 values past P (silence / nothing)
//   1 "console"   sources random in 0..P, destinations a random partial
//                 one-to-one map (each port at most once, some channels None)
//   2 "identity"  channel k <- port k, channel c -> port c: out = in
//   3 "pileup"    every destination the same port: the last channel wins
// Checks: every stream beat = the model's channel sample for this frame
// (bit-exact); the stream contract and the stated timing (FIRST_BEAT 2,
// LAST_BEAT N+1, contiguous); out_flat = the model's ports, updated only at
// valid_o, exactly at cycle N+3 (2 after the last beat); in identity mode
// out = in on the shared ports; err_o never pulses.
// Part 2, pcm_stream2patch alone (N 5, P 4), TB-written beats, a constant
// table {c0->p2, c1->None, c2->p0, c3->p2 (later wins), c4->p3; p1 unnamed}:
//   - gaps between beats: delivered 2 cycles after the last beat, the right
//     ports, p1 silent, no error;
//   - two channels swapped: err_o (as pcm_stream2pack);
//   - the last beat missing: err_o at the next strobe, output unchanged.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module patch_chain #(
    parameter int P_IN   = 20,
    parameter int N      = 20,
    parameter int P_OUT  = 20,
    parameter int FRAMES = 60
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic frame,
    input  int   cyc,
    output int   errors,
    output int   checked,
    output int   modes_seen,    // bit m: a frame of mode m was checked
    output bit   done
);
    localparam int SW  = 24;
    localparam int CW  = (N > 1) ? $clog2(N) : 1;
    localparam int PWI = $clog2(P_IN + 1);
    localparam int PWO = $clog2(P_OUT + 1);

    typedef logic [P_IN*SW-1:0]  pin_t;
    typedef logic [P_OUT*SW-1:0] pout_t;
    typedef logic [N*PWI-1:0]    src_t;
    typedef logic [N*PWO-1:0]    dst_t;

    pin_t  in_flat;
    pout_t out_flat, out_prev;
    src_t  src;
    dst_t  dst;
    logic  s_valid, valid_o, err_o;
    logic [CW-1:0] s_ch;
    logic [SW-1:0] s_data;
    logic [CW-1:0]  in_addr, out_addr;
    logic [PWI-1:0] in_data;
    logic [PWO-1:0] out_data;
    int mon_err, mon_frames;

    pcm_patch2stream #(.P (P_IN), .N (N), .SW (SW)) u_in (
        .mclk, .rst_n, .frame_i (frame), .in_flat,
        .coef_addr (in_addr), .coef_data (in_data),
        .s_valid, .s_ch, .s_data);

    coef_flat_reader #(.W (PWI), .N_ROWS (N), .ROW_LEN (1), .LANES (1)) u_src (
        .mclk, .frame_i (frame), .coefs_flat (src), .rd_addr (in_addr), .rd_data (in_data));

    pcm_stream_monitor #(.N (N), .FIRST_BEAT (2), .LAST_BEAT (N + 1), .CONTIGUOUS (1'b1),
                         .NAME ("patch stream")) u_mon (
        .clk (mclk), .rst_n, .frame_i (frame), .s_valid, .s_ch,
        .errors (mon_err), .frames (mon_frames));

    pcm_stream2patch #(.N (N), .P (P_OUT), .SW (SW)) u_out (
        .mclk, .rst_n, .frame_i (frame), .s_valid, .s_ch, .s_data,
        .coef_addr (out_addr), .coef_data (out_data),
        .out_flat, .valid_o, .err_o);

    coef_flat_reader #(.W (PWO), .N_ROWS (N), .ROW_LEN (1), .LANES (1)) u_dst (
        .mclk, .frame_i (frame), .coefs_flat (dst), .rd_addr (out_addr), .rd_data (out_data));

    // ----- the model -----
    function automatic logic [SW-1:0] chan(input pin_t x, input src_t s, input int k);
        int v;
        v = int'(s[k*PWI +: PWI]);
        return (v >= 1 && v <= P_IN) ? x[(v-1)*SW +: SW] : '0;
    endfunction
    function automatic pout_t ports(input pin_t x, input src_t s, input dst_t d);
        pout_t o;
        int v;
        o = '0;
        for (int c = 0; c < N; c++) begin          // ascending: the later channel wins
            v = int'(d[c*PWO +: PWO]);
            if (v >= 1 && v <= P_OUT) o[(v-1)*SW +: SW] = chan(x, s, c);
        end
        return o;
    endfunction

    // ----- stimulus -----
    function automatic pin_t rand_ports();
        pin_t v;
        for (int p = 0; p < P_IN; p++) v[p*SW +: SW] = SW'($urandom);
        return v;
    endfunction

    task automatic make_tables(input int mode, output src_t s, output dst_t d);
        int perm [P_OUT];
        int j, t;
        s = '0; d = '0;
        case (mode)
            0: begin
                for (int k = 0; k < N; k++) s[k*PWI +: PWI] = PWI'($urandom);
                for (int c = 0; c < N; c++) d[c*PWO +: PWO] = PWO'($urandom);
            end
            1: begin
                for (int k = 0; k < N; k++) s[k*PWI +: PWI] = PWI'($urandom % (P_IN + 1));
                for (int p = 0; p < P_OUT; p++) perm[p] = p;
                for (int p = P_OUT - 1; p > 0; p--) begin
                    j = $urandom % (p + 1); t = perm[p]; perm[p] = perm[j]; perm[j] = t;
                end
                for (int c = 0; c < N; c++)
                    d[c*PWO +: PWO] = (c < P_OUT && $urandom % 4 != 0) ? PWO'(perm[c] + 1) : '0;
            end
            2: begin
                for (int k = 0; k < N; k++) s[k*PWI +: PWI] = (k < P_IN)  ? PWI'(k + 1) : '0;
                for (int c = 0; c < N; c++) d[c*PWO +: PWO] = (c < P_OUT) ? PWO'(c + 1) : '0;
            end
            default: begin
                t = $urandom % P_OUT;
                for (int k = 0; k < N; k++) s[k*PWI +: PWI] = PWI'($urandom % (P_IN + 1));
                for (int c = 0; c < N; c++) d[c*PWO +: PWO] = PWO'(t + 1);
            end
        endcase
    endtask

    // What each frame used, in frame order: the ports recorded at the strobe
    // that captures them, the tables when they are set (cycle 0).
    pin_t x_q [$];
    src_t s_q [$];
    dst_t d_q [$];
    int   m_q [$];

    initial begin in_flat = rand_ports(); src = '0; dst = '0; end
    always @(negedge mclk) begin
        int mode;
        if (cyc == 0) begin
            in_flat = rand_ports();
            mode = $urandom % 4;
            make_tables(mode, src, dst);
            s_q.push_back(src); d_q.push_back(dst); m_q.push_back(mode);
        end
        if (cyc == N / 2 + 2) in_flat = rand_ports();   // not captured
    end

    // ----- check -----
    int err = 0;
    always @(posedge mclk) begin
        pin_t x; src_t s; dst_t d; pout_t want;
        int m;
        if (rst_n) begin
            if (frame) x_q.push_back(in_flat);
            if (err_o) begin
                err++;
                if (err < 10) $display("[%0t] %0d/%0d/%0d: err_o", $time, P_IN, N, P_OUT);
            end
            if (s_valid) begin
                // during frame k the queues' fronts are frame k's (k-1 popped at valid_o)
                if (x_q.size() == 0 || s_q.size() == 0) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: beat outside a frame", $time, P_IN, N, P_OUT);
                end else if (s_data !== chan(x_q[0], s_q[0], int'(s_ch))) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: ch%0d = %06h, model %06h (source %0d)",
                                           $time, P_IN, N, P_OUT, s_ch, s_data,
                                           chan(x_q[0], s_q[0], int'(s_ch)), s_q[0][s_ch*PWI +: PWI]);
                end
            end
            if (valid_o) begin
                if (cyc != N + 3) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: output at cycle %0d, stated %0d",
                                           $time, P_IN, N, P_OUT, cyc, N + 3);
                end
                if (x_q.size() == 0 || s_q.size() == 0) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: frame delivered, none sent", $time, P_IN, N, P_OUT);
                end else begin
                    x = x_q.pop_front(); s = s_q.pop_front(); d = d_q.pop_front(); m = m_q.pop_front();
                    want = ports(x, s, d);
                    for (int p = 0; p < P_OUT; p++)
                        if (out_flat[p*SW +: SW] !== want[p*SW +: SW]) begin
                            err++;
                            if (err < 10) $display("[%0t] %0d/%0d/%0d mode %0d: port %0d = %06h, model %06h",
                                                   $time, P_IN, N, P_OUT, m, p, out_flat[p*SW +: SW], want[p*SW +: SW]);
                        end
                    if (m == 2)
                        for (int p = 0; p < P_OUT && p < N && p < P_IN; p++)
                            if (out_flat[p*SW +: SW] !== x[p*SW +: SW]) begin
                                err++;
                                if (err < 10) $display("[%0t] %0d/%0d/%0d identity: port %0d = %06h, in %06h",
                                                       $time, P_IN, N, P_OUT, p, out_flat[p*SW +: SW], x[p*SW +: SW]);
                            end
                    modes_seen |= (1 << m);
                    checked++;
                end
            end else if (out_flat !== out_prev) begin
                err++;
                if (err < 10) $display("[%0t] %0d/%0d/%0d: out_flat changed without valid_o", $time, P_IN, N, P_OUT);
            end
            out_prev = out_flat;
        end
    end

    initial begin
        checked = 0; modes_seen = 0; done = 0; out_prev = '0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = err + mon_err + ((done && mon_frames < FRAMES) ? 1 : 0)
                        + ((done && modes_seen != 4'hF) ? 1 : 0);
endmodule


module tb_pcm_patch;

    localparam int SW = 24;

    logic mclk = 0;
    always #5 mclk = ~mclk;
    logic rst_n = 0;

    logic frame = 0;
    int   cyc = -1, ctr = 0;
    always @(posedge mclk) begin
        if (rst_n) begin
            ctr   <= (ctr == 255) ? 0 : ctr + 1;
            frame <= (ctr == 255);
            cyc   <= frame ? 0 : (cyc >= 0 ? cyc + 1 : -1);
        end
    end

    // ----- Part 1: chains -----
    localparam int NH = 6;
    int e [NH], k [NH], ms [NH];
    bit d [NH];
    patch_chain #(.P_IN (20), .N (20), .P_OUT (20)) h0 (.mclk, .rst_n, .frame, .cyc, .errors (e[0]), .checked (k[0]), .modes_seen (ms[0]), .done (d[0]));
    patch_chain #(.P_IN (20), .N (12), .P_OUT (20)) h1 (.mclk, .rst_n, .frame, .cyc, .errors (e[1]), .checked (k[1]), .modes_seen (ms[1]), .done (d[1]));
    patch_chain #(.P_IN (20), .N (28), .P_OUT (20)) h2 (.mclk, .rst_n, .frame, .cyc, .errors (e[2]), .checked (k[2]), .modes_seen (ms[2]), .done (d[2]));
    patch_chain #(.P_IN (5),  .N (3),  .P_OUT (4))  h3 (.mclk, .rst_n, .frame, .cyc, .errors (e[3]), .checked (k[3]), .modes_seen (ms[3]), .done (d[3]));
    patch_chain #(.P_IN (3),  .N (7),  .P_OUT (2))  h4 (.mclk, .rst_n, .frame, .cyc, .errors (e[4]), .checked (k[4]), .modes_seen (ms[4]), .done (d[4]));
    patch_chain #(.P_IN (1),  .N (1),  .P_OUT (1))  h5 (.mclk, .rst_n, .frame, .cyc, .errors (e[5]), .checked (k[5]), .modes_seen (ms[5]), .done (d[5]));

    // ----- Part 2: pcm_stream2patch alone, N 5, P 4, TB-written beats -----
    localparam int N5 = 5, CW5 = 3, P4 = 4, PW4 = 3;
    // c0->p2 (3), c1->None, c2->p0 (1), c3->p2 (3: later wins), c4->p3 (4)
    localparam logic [N5*PW4-1:0] T_DST = {3'd4, 3'd3, 3'd1, 3'd0, 3'd3};
    logic            t_frame = 0, t_valid = 0;
    logic [CW5-1:0]  t_ch = 0;
    logic [SW-1:0]   t_data = 0;
    logic [P4*SW-1:0] t_out;
    logic            t_vo, t_err;
    logic [CW5-1:0]  t_addr;
    logic [PW4-1:0]  t_dst;
    int              t_err_count = 0, t_vo_count = 0, t_last_beat = 0, t_vo_at = 0, tcyc = 0;
    int              part2_errors = 0;

    pcm_stream2patch #(.N (N5), .P (P4), .SW (SW)) u_s2p5 (
        .mclk, .rst_n, .frame_i (t_frame),
        .s_valid (t_valid), .s_ch (t_ch), .s_data (t_data),
        .coef_addr (t_addr), .coef_data (t_dst),
        .out_flat (t_out), .valid_o (t_vo), .err_o (t_err));
    coef_flat_reader #(.W (PW4), .N_ROWS (N5), .ROW_LEN (1), .LANES (1)) u_t_dst (
        .mclk, .frame_i (t_frame), .coefs_flat (T_DST), .rd_addr (t_addr), .rd_data (t_dst));

    always @(posedge mclk) begin
        tcyc++;
        if (t_valid && t_ch == CW5'(N5 - 1)) t_last_beat = tcyc;
        if (t_err) t_err_count++;
        if (t_vo) begin t_vo_count++; t_vo_at = tcyc; end
    end

    task automatic t_strobe();
        @(negedge mclk) t_frame = 1;
        @(negedge mclk) t_frame = 0;
    endtask

    task automatic t_beat(input int ch, input logic [SW-1:0] dd, input int gap);
        repeat (gap) @(negedge mclk);
        t_valid = 1; t_ch = CW5'(ch); t_data = dd;
        @(negedge mclk) t_valid = 0;
    endtask

    function automatic logic [SW-1:0] pat(input int f, input int c);
        return SW'(f * 16 + c + 24'h300000);
    endfunction

    task automatic expect_part2(input string what, input int errs, input int vos);
        repeat (4) @(negedge mclk);
        if (t_err_count != errs || t_vo_count != vos) begin
            part2_errors++;
            $display("part 2, %s: err_o %0d (want %0d), valid_o %0d (want %0d)",
                     what, t_err_count, errs, t_vo_count, vos);
        end
    endtask

    task automatic expect_ports(input string what, input int f);
        // p0 <- c2, p1 silent, p2 <- c3 (not c0), p3 <- c4
        logic [SW-1:0] want [P4];
        want[0] = pat(f, 2); want[1] = '0; want[2] = pat(f, 3); want[3] = pat(f, 4);
        for (int p = 0; p < P4; p++)
            if (t_out[p*SW +: SW] !== want[p]) begin
                part2_errors++;
                $display("part 2, %s: port %0d = %h, want %h", what, p, t_out[p*SW +: SW], want[p]);
            end
    endtask

    task automatic part2();
        logic [P4*SW-1:0] held;
        // A: gaps between beats
        t_strobe();
        for (int c = 0; c < N5; c++) t_beat(c, pat(1, c), c % 3);
        expect_part2("gaps", 0, 1);
        expect_ports("gaps", 1);
        if (t_vo_at != t_last_beat + 2) begin
            part2_errors++;
            $display("part 2, gaps: valid_o %0d cycles after the last beat, stated 2", t_vo_at - t_last_beat);
        end
        // B: channels 1 and 2 swapped -> err_o; still delivered
        t_strobe();
        t_beat(0, pat(2, 0), 0); t_beat(2, pat(2, 2), 0); t_beat(1, pat(2, 1), 0);
        t_beat(3, pat(2, 3), 0); t_beat(4, pat(2, 4), 0);
        expect_part2("swapped", 3, 2);
        expect_ports("swapped", 2);
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
        // D: the next whole frame is delivered clean (channel 0 clears the slots)
        for (int c = 0; c < N5; c++) t_beat(c, pat(4, c), 1);
        expect_part2("recovery", 4, 3);
        expect_ports("recovery", 4);
    endtask

    // ----- Run -----
    initial begin
        int total;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        part2();
        wait (d[0] && d[1] && d[2] && d[3] && d[4] && d[5]);
        repeat (2) @(posedge mclk);
        $display("  20/20/20: %0d frames, modes %h, %0d errors", k[0], ms[0], e[0]);
        $display("  20/12/20: %0d frames, modes %h, %0d errors", k[1], ms[1], e[1]);
        $display("  20/28/20: %0d frames, modes %h, %0d errors", k[2], ms[2], e[2]);
        $display("   5/ 3/ 4: %0d frames, modes %h, %0d errors", k[3], ms[3], e[3]);
        $display("   3/ 7/ 2: %0d frames, modes %h, %0d errors", k[4], ms[4], e[4]);
        $display("   1/ 1/ 1: %0d frames, modes %h, %0d errors", k[5], ms[5], e[5]);
        $display("  stream2patch alone: %0d errors", part2_errors);
        total = part2_errors;
        foreach (e[n]) total += e[n];
        if (total == 0) $display("PASS: tb_pcm_patch");
        else            $display("FAIL: tb_pcm_patch - %0d errors", total);
        $finish;
    end

    initial begin
        #50ms;
        $display("FAIL: tb_pcm_patch TIMEOUT");
        $finish;
    end

endmodule
