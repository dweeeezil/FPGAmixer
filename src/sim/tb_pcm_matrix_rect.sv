// -----------------------------------------------------------------------------
// tb_pcm_matrix_rect.sv
//
// The time-shared matrix (Phase 9, P9.A4) across sizes and lane counts, through
// mixer_core (pack -> stream -> pcm_matrix -> stream -> pack) with its
// coefficients from coef_flat_reader. tb_pcm_matrix covers the arithmetic
// corner cases on a 4x4; this checks the schedule and the indexing:
//
//   3 -> 5, 5 -> 2      non-square (the original D3 cases)
//   12 x 12             today's core, 1 lane
//   20 x 20             Pmod + USB + AVB: 2 lanes
//   7 -> 5, LANES = 3   forced: the last pass has an idle lane
//   32 x 32             6 lanes
//   1 -> 1              degenerate
//
// Every frame gets new random samples and new random gains (full range, so
// both saturation limits are hit), compared bit-exact with a 64-bit
// reference model, the same one the parallel matrix was checked against.
// Plus, per size: the output updates at exactly D cycles after the strobe
// (pcm_matrix_pkg::core_latency), only on the valid_o edge, and the matrix's
// output stream obeys the stream contract with its stated first/last-beat
// cycles (pcm_stream_monitor).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module matrix_harness
    import pcm_matrix_pkg::*;
#(
    parameter int N_IN   = 3,
    parameter int N_OUT  = 5,
    parameter int LANES  = matrix_lanes(N_IN, N_OUT),
    parameter int FRAMES = 60
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic frame,
    input  int   cyc,
    output int   errors,
    output int   checked,
    output bit   done
);
    localparam int SW = 24, GW = 18, GF = 16;
    localparam int D      = core_latency(N_IN, N_OUT, LANES);
    localparam int PASSES = matrix_passes(N_OUT, LANES);
    localparam int AW     = (PASSES*N_IN > 1) ? $clog2(PASSES*N_IN) : 1;

    logic [N_IN*SW-1:0]        in_flat;
    logic [N_OUT*SW-1:0]       out_flat, out_prev;
    logic [N_OUT*N_IN*GW-1:0]  gains;
    logic                      valid_o, err_o;
    logic [AW-1:0]             coef_addr;
    logic [LANES*GW-1:0]       coef_data;

    mixer_core #(.N_IN (N_IN), .N_OUT (N_OUT), .SW (SW), .GW (GW), .GF (GF), .LANES (LANES)) dut (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame),
        .in_flat (in_flat), .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o),
        .coef_addr (coef_addr), .coef_data (coef_data));

    coef_flat_reader #(.W (GW), .N_ROWS (N_OUT), .ROW_LEN (N_IN), .LANES (LANES)) u_coefs (
        .mclk (mclk), .frame_i (frame), .coefs_flat (gains),
        .rd_addr (coef_addr), .rd_data (coef_data));

    int mon_err, mon_frames;
    pcm_stream_monitor #(.N (N_OUT), .FIRST_BEAT (N_IN + matrix_lat_first(N_IN)),
                         .LAST_BEAT (N_IN + matrix_lat_last(N_IN, N_OUT, LANES)),
                         .CONTIGUOUS (1'b0), .NAME ("matrix out")) u_mon (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (dut.b_valid), .s_ch (dut.b_ch),
        .errors (mon_err), .frames (mon_frames));

    // ----- reference -----
    function automatic logic [SW-1:0] ref_out(input logic [N_IN*SW-1:0] x,
                                              input logic [N_OUT*N_IN*GW-1:0] g,
                                              input int o);
        longint acc = 0;
        for (int i = 0; i < N_IN; i++)
            acc += longint'($signed(x[i*SW +: SW])) * longint'($signed(g[(o*N_IN + i)*GW +: GW]));
        acc = acc >>> GF;
        if (acc >  64'sd8388607) acc =  64'sd8388607;
        if (acc < -64'sd8388608) acc = -64'sd8388608;
        return acc[SW-1:0];
    endfunction

    // random sample / gain with the extremes over-represented
    function automatic logic [SW-1:0] rsamp();
        case ($urandom % 8)
            0: return 24'h7FFFFF;
            1: return 24'h800000;
            2: return SW'($urandom % 5) - 2;
            default: return SW'($urandom);
        endcase
    endfunction
    function automatic logic [GW-1:0] rgain();
        case ($urandom % 8)
            0: return 18'h1FFFF;              // just under +2.0
            1: return 18'h20000;              // -2.0
            2: return 18'h10000;              // 1.0
            3: return 18'h00000;
            default: return GW'($urandom);
        endcase
    endfunction

    int err = 0;
    logic [N_IN*SW-1:0]       x_sent [$];
    logic [N_OUT*N_IN*GW-1:0] g_sent [$];
    logic [N_IN*SW-1:0]       x_exp;
    logic [N_OUT*N_IN*GW-1:0] g_exp;

    // New samples and gains in cycle 0 (right after the strobe edge). The
    // samples are captured at the NEXT strobe (recorded there); the gains are
    // read during THIS frame (recorded now). A change only in cycle 0 is the
    // coef_flat_reader's rule, as for the packed coefficient port.
    always @(negedge mclk) begin
        if (cyc < 0 || cyc == 0)
            for (int i = 0; i < N_IN; i++) in_flat[i*SW +: SW] = rsamp();
        if (cyc == 0) begin
            for (int k = 0; k < N_OUT*N_IN; k++) gains[k*GW +: GW] = rgain();
            g_sent.push_back(gains);
        end
    end

    always @(posedge mclk) begin
        if (rst_n) begin
            if (frame) x_sent.push_back(in_flat);
            if (err_o) begin
                err++;
                if (err < 10) $display("[%0t] %0dx%0d/L%0d: err_o", $time, N_IN, N_OUT, LANES);
            end
            if (valid_o) begin
                if (cyc != D) begin
                    err++;
                    if (err < 10) $display("[%0t] %0dx%0d/L%0d: output at cycle %0d, D = %0d",
                                           $time, N_IN, N_OUT, LANES, cyc, D);
                end
                x_exp = x_sent.pop_front();
                g_exp = g_sent.pop_front();
                for (int o = 0; o < N_OUT; o++)
                    if (out_flat[o*SW +: SW] !== ref_out(x_exp, g_exp, o)) begin
                        err++;
                        if (err < 10) $display("[%0t] %0dx%0d/L%0d: out%0d = %06h, ref %06h",
                                               $time, N_IN, N_OUT, LANES, o,
                                               out_flat[o*SW +: SW], ref_out(x_exp, g_exp, o));
                    end
                checked++;
            end else if (out_flat !== out_prev) begin
                err++;
                if (err < 10) $display("[%0t] %0dx%0d/L%0d: out_flat changed without valid_o",
                                       $time, N_IN, N_OUT, LANES);
            end
            out_prev = out_flat;
        end
    end

    initial begin
        checked = 0; done = 0; out_prev = '0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = err + mon_err + ((done && mon_frames < FRAMES) ? 1 : 0);
endmodule


module tb_pcm_matrix_rect;
    import pcm_matrix_pkg::*;

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
    int  e [NH], k [NH];
    bit  d [NH];

    matrix_harness #(.N_IN (3),  .N_OUT (5))              h0 (.mclk, .rst_n, .frame, .cyc, .errors (e[0]), .checked (k[0]), .done (d[0]));
    matrix_harness #(.N_IN (5),  .N_OUT (2))              h1 (.mclk, .rst_n, .frame, .cyc, .errors (e[1]), .checked (k[1]), .done (d[1]));
    matrix_harness #(.N_IN (12), .N_OUT (12))             h2 (.mclk, .rst_n, .frame, .cyc, .errors (e[2]), .checked (k[2]), .done (d[2]));
    matrix_harness #(.N_IN (20), .N_OUT (20))             h3 (.mclk, .rst_n, .frame, .cyc, .errors (e[3]), .checked (k[3]), .done (d[3]));
    matrix_harness #(.N_IN (7),  .N_OUT (5), .LANES (3))  h4 (.mclk, .rst_n, .frame, .cyc, .errors (e[4]), .checked (k[4]), .done (d[4]));
    matrix_harness #(.N_IN (32), .N_OUT (32))             h5 (.mclk, .rst_n, .frame, .cyc, .errors (e[5]), .checked (k[5]), .done (d[5]));
    matrix_harness #(.N_IN (1),  .N_OUT (1))              h6 (.mclk, .rst_n, .frame, .cyc, .errors (e[6]), .checked (k[6]), .done (d[6]));

    function automatic string row(input string name, input int ni, input int no, input int l,
                                  input int ee, input int kk);
        return $sformatf("  %-8s %2dx%-2d lanes %0d  D = %3d  %0d frames, %0d errors",
                         name, ni, no, l, core_latency(ni, no, l), kk, ee);
    endfunction

    initial begin
        int total;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        wait (d[0] && d[1] && d[2] && d[3] && d[4] && d[5] && d[6]);
        repeat (2) @(posedge mclk);
        $display(row("3->5",   3,  5, h0.LANES, e[0], k[0]));
        $display(row("5->2",   5,  2, h1.LANES, e[1], k[1]));
        $display(row("12x12", 12, 12, h2.LANES, e[2], k[2]));
        $display(row("20x20", 20, 20, h3.LANES, e[3], k[3]));
        $display(row("7->5",   7,  5, h4.LANES, e[4], k[4]));
        $display(row("32x32", 32, 32, h5.LANES, e[5], k[5]));
        $display(row("1->1",   1,  1, h6.LANES, e[6], k[6]));
        total = 0;
        foreach (e[n]) total += e[n];
        if (total == 0) $display("PASS: tb_pcm_matrix_rect");
        else            $display("FAIL: tb_pcm_matrix_rect - %0d errors", total);
        $finish;
    end

    initial begin
        #20ms;
        $display("FAIL: tb_pcm_matrix_rect TIMEOUT");
        $finish;
    end
endmodule
