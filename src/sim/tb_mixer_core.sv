// -----------------------------------------------------------------------------
// tb_mixer_core.sv
//
// The whole PCM core since Phase 12 (mixer_core: input levels -> input matrix
// -> bus levels -> bus matrix -> output levels, between the converters), its
// five coefficient ports served by coef_flat_readers, across sizes:
//
//   20 -> 20 -> 20   today's core (4 + 4 lanes, D = 249)
//   12 -> 12 -> 12   2 + 2
//   28 -> 28 -> 28   the Phase 11 growth (10 + 10)
//   20 ->  8 -> 20   fewer buses than channels
//    3 ->  5 ->  2   expand, then reduce
//    7 ->  5 ->  3   lanes forced to 3 + 2: idle lanes in both matrices' last pass
//    1 ->  1 ->  1   degenerate
//
// Every frame gets new random samples and all five gain banks, in one of
// three modes: "extreme" (full-range gains with the extremes over-represented:
// every saturation point is hit), "console" (levels and sparse crosspoints in
// -1.0 .. +1.0: signals pass mostly unclipped, so the arithmetic is visible),
// and "reset" (unity levels, identity matrices: output = input). The packed
// output is compared bit-exact with a 64-bit model of the chain that
// saturates to 24 bits after every block (decision L5); it must update
// exactly at D = chain_latency and nowhere else; err_o must stay low; the
// bus stream and the output-level stream obey the stream contract at their
// stated first/last-beat cycles (pcm_stream_monitor).
//
// The model also runs once WITHOUT the bus saturation; frames where that
// changes the output are counted ("bus clips"), so the run shows that the
// check can tell a saturating bus from a wide one.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module core_harness
    import pcm_matrix_pkg::*;
    import mixer_core_pkg::*;
#(
    parameter int N_IN   = 3,
    parameter int N_BUS  = 5,
    parameter int N_OUT  = 2,
    parameter int L1     = chain_l1(N_IN, N_BUS, N_OUT),
    parameter int L2     = chain_l2(N_IN, N_BUS, N_OUT),
    parameter int FRAMES = 60
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic frame,
    input  int   cyc,
    output int   errors,
    output int   checked,
    output int   bus_clips,
    output bit   done
);
    localparam int SW = 24, GW = 18, GF = 16;
    localparam int D      = chain_latency(N_IN, N_BUS, N_OUT, L1, L2);
    localparam int CWI    = (N_IN  > 1) ? $clog2(N_IN)  : 1;
    localparam int CWB    = (N_BUS > 1) ? $clog2(N_BUS) : 1;
    localparam int CWO    = (N_OUT > 1) ? $clog2(N_OUT) : 1;
    localparam int DEPTH1 = matrix_passes(N_BUS, L1) * N_IN;
    localparam int DEPTH2 = matrix_passes(N_OUT, L2) * N_BUS;
    localparam int AW1    = (DEPTH1 > 1) ? $clog2(DEPTH1) : 1;
    localparam int AW2    = (DEPTH2 > 1) ? $clog2(DEPTH2) : 1;

    typedef logic [N_IN*GW-1:0]       gin_t;
    typedef logic [N_BUS*N_IN*GW-1:0] gim_t;
    typedef logic [N_BUS*GW-1:0]      gbl_t;
    typedef logic [N_OUT*N_BUS*GW-1:0] gbm_t;
    typedef logic [N_OUT*GW-1:0]      gol_t;

    logic [N_IN*SW-1:0]  in_flat;
    logic [N_OUT*SW-1:0] out_flat, out_prev;
    logic                valid_o, err_o;
    gin_t g_in;  gim_t g_im;  gbl_t g_bl;  gbm_t g_bm;  gol_t g_ol;

    logic [CWI-1:0] in_lvl_addr;  logic [GW-1:0] in_lvl_data;
    logic [AW1-1:0] in_mx_addr;   logic [L1*GW-1:0] in_mx_data;
    logic [CWB-1:0] bus_lvl_addr; logic [GW-1:0] bus_lvl_data;
    logic [AW2-1:0] bus_mx_addr;  logic [L2*GW-1:0] bus_mx_data;
    logic [CWO-1:0] out_lvl_addr; logic [GW-1:0] out_lvl_data;

    mixer_core #(.N_IN (N_IN), .N_BUS (N_BUS), .N_OUT (N_OUT), .SW (SW), .GW (GW), .GF (GF),
                 .L1 (L1), .L2 (L2)) dut (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame),
        .in_flat (in_flat), .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o),
        .in_lvl_addr (in_lvl_addr),   .in_lvl_data (in_lvl_data),
        .in_mx_addr (in_mx_addr),     .in_mx_data (in_mx_data),
        .bus_lvl_addr (bus_lvl_addr), .bus_lvl_data (bus_lvl_data),
        .bus_mx_addr (bus_mx_addr),   .bus_mx_data (bus_mx_data),
        .out_lvl_addr (out_lvl_addr), .out_lvl_data (out_lvl_data));

    coef_flat_reader #(.W (GW), .N_ROWS (N_IN),  .ROW_LEN (1),     .LANES (1))  u_c0 (
        .mclk, .frame_i (frame), .coefs_flat (g_in), .rd_addr (in_lvl_addr),  .rd_data (in_lvl_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (N_IN),  .LANES (L1)) u_c1 (
        .mclk, .frame_i (frame), .coefs_flat (g_im), .rd_addr (in_mx_addr),   .rd_data (in_mx_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (1),     .LANES (1))  u_c2 (
        .mclk, .frame_i (frame), .coefs_flat (g_bl), .rd_addr (bus_lvl_addr), .rd_data (bus_lvl_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_OUT), .ROW_LEN (N_BUS), .LANES (L2)) u_c3 (
        .mclk, .frame_i (frame), .coefs_flat (g_bm), .rd_addr (bus_mx_addr),  .rd_data (bus_mx_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_OUT), .ROW_LEN (1),     .LANES (1))  u_c4 (
        .mclk, .frame_i (frame), .coefs_flat (g_ol), .rd_addr (out_lvl_addr), .rd_data (out_lvl_data));

    // ----- stream checks: the buses (input matrix out) and the output levels -----
    int mon_err_b, mon_frames_b, mon_err_o, mon_frames_o;
    localparam int BUS_LAST = chain_bus_last(N_IN, N_BUS, L1);
    pcm_stream_monitor #(.N (N_BUS),
                         .FIRST_BEAT (N_IN + GAIN_LAT + matrix_lat_first(N_IN)),
                         .LAST_BEAT  (BUS_LAST),
                         .NAME ("buses")) u_mon_b (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (dut.c_valid), .s_ch (dut.c_ch),
        .errors (mon_err_b), .frames (mon_frames_b));
    pcm_stream_monitor #(.N (N_OUT),
                         .FIRST_BEAT (BUS_LAST + GAIN_LAT + matrix_lat_first(N_BUS) + GAIN_LAT),
                         .LAST_BEAT  (chain_out_last(N_IN, N_BUS, N_OUT, L1, L2) + GAIN_LAT),
                         .NAME ("outputs")) u_mon_o (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (dut.f_valid), .s_ch (dut.f_ch),
        .errors (mon_err_o), .frames (mon_frames_o));

    // ----- the chain model -----
    function automatic longint sat(input longint v);
        if (v >  64'sd8388607) return  64'sd8388607;
        if (v < -64'sd8388608) return -64'sd8388608;
        return v;
    endfunction
    function automatic longint sx(input logic [SW-1:0] v);  return longint'($signed(v)); endfunction
    function automatic longint gx(input logic [GW-1:0] v);  return longint'($signed(v)); endfunction

    // y[o] for samples x and the five banks; bus_sat = 0 models a wide bus.
    function automatic logic [SW-1:0] model(input logic [N_IN*SW-1:0] x,
                                            input gin_t gi, input gim_t gm, input gbl_t gb,
                                            input gbm_t gbm, input gol_t go,
                                            input int o, input bit bus_sat);
        longint xi [N_IN];
        longint bl [N_BUS];
        longint acc;
        for (int i = 0; i < N_IN; i++)
            xi[i] = sat((sx(x[i*SW +: SW]) * gx(gi[i*GW +: GW])) >>> GF);
        for (int b = 0; b < N_BUS; b++) begin
            acc = 0;
            for (int i = 0; i < N_IN; i++) acc += xi[i] * gx(gm[(b*N_IN + i)*GW +: GW]);
            acc = acc >>> GF;
            if (bus_sat) acc = sat(acc);
            bl[b] = sat((acc * gx(gb[b*GW +: GW])) >>> GF);
        end
        acc = 0;
        for (int b = 0; b < N_BUS; b++) acc += bl[b] * gx(gbm[(o*N_BUS + b)*GW +: GW]);
        acc = sat(acc >>> GF);
        acc = sat((acc * gx(go[o*GW +: GW])) >>> GF);
        return acc[SW-1:0];
    endfunction

    // ----- stimulus -----
    function automatic logic [SW-1:0] rsamp(input int mode);
        if (mode == 1) return SW'($urandom % 24'h400000) - 24'h200000;   // +-2^21: headroom
        case ($urandom % 8)
            0: return 24'h7FFFFF;
            1: return 24'h800000;
            2: return SW'($urandom % 5) - 2;
            default: return SW'($urandom);
        endcase
    endfunction
    function automatic logic [GW-1:0] rgain_x();          // extreme
        case ($urandom % 8)
            0: return 18'h1FFFF;
            1: return 18'h20000;
            2: return 18'h10000;
            3: return 18'h00000;
            default: return GW'($urandom);
        endcase
    endfunction
    function automatic logic [GW-1:0] rgain_c();          // -1.0 .. +1.0
        return GW'(int'($urandom % 131073) - 65536);
    endfunction
    function automatic logic [GW-1:0] rgain_sparse();     // a console's crosspoints
        return ($urandom % 4 == 0) ? rgain_c() : '0;
    endfunction

    // What each frame used, in frame order: samples recorded at the strobe
    // that captures them, gains (and the mode) when they are set, in cycle 0.
    logic [N_IN*SW-1:0] x_q [$];
    gin_t gi_q [$];  gim_t gm_q [$];  gbl_t gb_q [$];  gbm_t gbm_q [$];  gol_t go_q [$];
    int   mode_q [$];

    // mode picks the gains of the frame whose cycle 0 this is; samples are set
    // a frame ahead of their capture, so they follow the previous mode
    // (harmless: the mode only shapes the stimulus, the model checks all).
    int mode = 0;
    always @(negedge mclk) begin
        if (cyc < 0 || cyc == 0)
            for (int i = 0; i < N_IN; i++) in_flat[i*SW +: SW] = rsamp(mode);
        if (cyc == 0) begin
            for (int k = 0; k < N_IN; k++)        g_in[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
            for (int k = 0; k < N_BUS; k++)       g_bl[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
            for (int k = 0; k < N_OUT; k++)       g_ol[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
            for (int k = 0; k < N_BUS*N_IN; k++)  g_im[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_sparse()
                                                                     : ((k / N_IN == k % N_IN) ? 18'h10000 : 18'h0);
            for (int k = 0; k < N_OUT*N_BUS; k++) g_bm[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_sparse()
                                                                     : ((k / N_BUS == k % N_BUS) ? 18'h10000 : 18'h0);
            gi_q.push_back(g_in); gm_q.push_back(g_im); gb_q.push_back(g_bl);
            gbm_q.push_back(g_bm); go_q.push_back(g_ol); mode_q.push_back(mode);
            mode = $urandom % 3;
        end
    end

    // ----- check -----
    int err = 0;

    always @(posedge mclk) begin
        logic [N_IN*SW-1:0] x;
        gin_t gi; gim_t gm; gbl_t gb; gbm_t gbm; gol_t go;
        int m;
        bit clipped;
        if (rst_n) begin
            if (frame) x_q.push_back(in_flat);
            if (err_o) begin
                err++;
                if (err < 10) $display("[%0t] %0d/%0d/%0d: err_o", $time, N_IN, N_BUS, N_OUT);
            end
            if (valid_o) begin
                if (cyc != D) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: output at cycle %0d, D = %0d",
                                           $time, N_IN, N_BUS, N_OUT, cyc, D);
                end
                x = x_q.pop_front();
                gi = gi_q.pop_front(); gm = gm_q.pop_front(); gb = gb_q.pop_front();
                gbm = gbm_q.pop_front(); go = go_q.pop_front(); m = mode_q.pop_front();
                clipped = 0;
                for (int o = 0; o < N_OUT; o++) begin
                    logic [SW-1:0] want;
                    want = model(x, gi, gm, gb, gbm, go, o, 1'b1);
                    if (out_flat[o*SW +: SW] !== want) begin
                        err++;
                        if (err < 10) $display("[%0t] %0d/%0d/%0d mode %0d: out%0d = %06h, model %06h",
                                               $time, N_IN, N_BUS, N_OUT, m, o, out_flat[o*SW +: SW], want);
                    end
                    if (model(x, gi, gm, gb, gbm, go, o, 1'b0) !== want) clipped = 1;
                    if (m == 2 && o < N_IN && o < N_BUS && out_flat[o*SW +: SW] !== x[o*SW +: SW]) begin
                        err++;
                        if (err < 10) $display("[%0t] %0d/%0d/%0d reset routing: out%0d = %06h, in %06h",
                                               $time, N_IN, N_BUS, N_OUT, o, out_flat[o*SW +: SW], x[o*SW +: SW]);
                    end
                end
                if (clipped) bus_clips++;
                checked++;
            end else if (out_flat !== out_prev) begin
                err++;
                if (err < 10) $display("[%0t] %0d/%0d/%0d: out_flat changed without valid_o",
                                       $time, N_IN, N_BUS, N_OUT);
            end
            out_prev = out_flat;
        end
    end

    initial begin
        checked = 0; bus_clips = 0; done = 0; out_prev = '0;
        g_in = '0; g_im = '0; g_bl = '0; g_bm = '0; g_ol = '0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = err + mon_err_b + mon_err_o +
                    ((done && (mon_frames_b < FRAMES || mon_frames_o < FRAMES)) ? 1 : 0);
endmodule


module tb_mixer_core;
    import mixer_core_pkg::*;

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

    localparam int NH = 7;
    int  e [NH], k [NH], c [NH];
    bit  d [NH];

    core_harness #(.N_IN (20), .N_BUS (20), .N_OUT (20)) h0 (.mclk, .rst_n, .frame, .cyc, .errors (e[0]), .checked (k[0]), .bus_clips (c[0]), .done (d[0]));
    core_harness #(.N_IN (12), .N_BUS (12), .N_OUT (12)) h1 (.mclk, .rst_n, .frame, .cyc, .errors (e[1]), .checked (k[1]), .bus_clips (c[1]), .done (d[1]));
    core_harness #(.N_IN (28), .N_BUS (28), .N_OUT (28)) h2 (.mclk, .rst_n, .frame, .cyc, .errors (e[2]), .checked (k[2]), .bus_clips (c[2]), .done (d[2]));
    core_harness #(.N_IN (20), .N_BUS (8),  .N_OUT (20)) h3 (.mclk, .rst_n, .frame, .cyc, .errors (e[3]), .checked (k[3]), .bus_clips (c[3]), .done (d[3]));
    core_harness #(.N_IN (3),  .N_BUS (5),  .N_OUT (2))  h4 (.mclk, .rst_n, .frame, .cyc, .errors (e[4]), .checked (k[4]), .bus_clips (c[4]), .done (d[4]));
    core_harness #(.N_IN (7),  .N_BUS (5),  .N_OUT (3), .L1 (3), .L2 (2))
                                                         h5 (.mclk, .rst_n, .frame, .cyc, .errors (e[5]), .checked (k[5]), .bus_clips (c[5]), .done (d[5]));
    core_harness #(.N_IN (1),  .N_BUS (1),  .N_OUT (1))  h6 (.mclk, .rst_n, .frame, .cyc, .errors (e[6]), .checked (k[6]), .bus_clips (c[6]), .done (d[6]));

    function automatic string row(input int ni, input int nb, input int no, input int l1, input int l2,
                                  input int ee, input int kk, input int cc);
        return $sformatf("  %2d -> %2d -> %2d  lanes %2d + %2d  D = %3d  %0d frames, %0d bus clips, %0d errors",
                         ni, nb, no, l1, l2, chain_latency(ni, nb, no, l1, l2), kk, cc, ee);
    endfunction

    initial begin
        int total, clips;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        wait (d[0] && d[1] && d[2] && d[3] && d[4] && d[5] && d[6]);
        repeat (2) @(posedge mclk);
        $display(row(20, 20, 20, h0.L1, h0.L2, e[0], k[0], c[0]));
        $display(row(12, 12, 12, h1.L1, h1.L2, e[1], k[1], c[1]));
        $display(row(28, 28, 28, h2.L1, h2.L2, e[2], k[2], c[2]));
        $display(row(20,  8, 20, h3.L1, h3.L2, e[3], k[3], c[3]));
        $display(row( 3,  5,  2, h4.L1, h4.L2, e[4], k[4], c[4]));
        $display(row( 7,  5,  3, h5.L1, h5.L2, e[5], k[5], c[5]));
        $display(row( 1,  1,  1, h6.L1, h6.L2, e[6], k[6], c[6]));
        total = 0; clips = 0;
        foreach (e[n]) begin total += e[n]; clips += c[n]; end
        if (clips == 0) begin
            total++;
            $display("  no frame where the bus saturation changed the output: the check can't see it");
        end
        if (total == 0) $display("PASS: tb_mixer_core");
        else            $display("FAIL: tb_mixer_core - %0d errors", total);
        $finish;
    end

    initial begin
        #20ms;
        $display("FAIL: tb_mixer_core TIMEOUT");
        $finish;
    end
endmodule
