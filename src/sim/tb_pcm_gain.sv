// -----------------------------------------------------------------------------
// tb_pcm_gain.sv
//
// The per-channel gain stage (Phase 12, pcm_gain) with its coefficients from
// coef_flat_reader (ROW_LEN 1, LANES 1), across sizes:
//
//   N = 1, 4, 20 (today's core), 28 (the Phase 11 growth)   contiguous input
//   N = 20 with random gaps between beats                    timing follows beats
//
// Every frame gets new random samples and gains (extremes over-represented, so
// both saturation limits and the -2.0 gain are hit), each output beat checked
// bit-exact against a 64-bit reference model (the same arithmetic as one
// pcm_matrix crosspoint), on its channel, exactly GAIN_LAT cycles after its
// input beat, and with no output beat that wasn't expected. A
// pcm_stream_monitor checks the output stream against the contract, and in
// the contiguous cases the stated first/last-beat cycles (1 + GAIN_LAT,
// N + GAIN_LAT) and no gaps.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module gain_harness
    import mixer_core_pkg::*;
#(
    parameter int N      = 4,
    parameter bit GAPS   = 1'b0,
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
    localparam int CW = (N > 1) ? $clog2(N) : 1;

    logic          in_valid = 0;
    logic [CW-1:0] in_ch    = '0;
    logic [SW-1:0] in_data  = '0;
    logic [N*GW-1:0] gains  = '0;

    logic          out_valid;
    logic [CW-1:0] out_ch, coef_addr;
    logic [SW-1:0] out_data;
    logic [GW-1:0] coef_data;

    pcm_gain #(.N (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) dut (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (in_valid), .in_ch (in_ch), .in_data (in_data),
        .coef_addr (coef_addr), .coef_data (coef_data),
        .out_valid (out_valid), .out_ch (out_ch), .out_data (out_data));

    coef_flat_reader #(.W (GW), .N_ROWS (N), .ROW_LEN (1), .LANES (1)) u_coefs (
        .mclk (mclk), .frame_i (frame), .coefs_flat (gains),
        .rd_addr (coef_addr), .rd_data (coef_data));

    int mon_err, mon_frames;
    pcm_stream_monitor #(.N (N),
                         .FIRST_BEAT (GAPS ? -1 : 1 + GAIN_LAT),
                         .LAST_BEAT  (GAPS ? -1 : N + GAIN_LAT),
                         .CONTIGUOUS (!GAPS), .NAME ("gain out")) u_mon (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (out_valid), .s_ch (out_ch),
        .errors (mon_err), .frames (mon_frames));

    // ----- reference -----
    function automatic logic [SW-1:0] ref_out(input logic [SW-1:0] x, input logic [GW-1:0] g);
        longint acc;
        acc = longint'($signed(x)) * longint'($signed(g));
        acc = acc >>> GF;
        if (acc >  64'sd8388607) acc =  64'sd8388607;
        if (acc < -64'sd8388608) acc = -64'sd8388608;
        return acc[SW-1:0];
    endfunction

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

    // ----- stimulus: one frame's beats, cycles 1 .. (N, or later with gaps) -----
    typedef struct { int cyc; int ch; logic [SW-1:0] data; } beat_t;
    beat_t expect_q [$];
    int    next_ch = N;          // N = no beat pending this frame
    int    wait_n  = 0;          // idle cycles before the next beat

    always @(negedge mclk) begin
        in_valid = 1'b0;
        if (cyc == 0) begin
            for (int c = 0; c < N; c++) gains[c*GW +: GW] = rgain();
            next_ch = 0;
            wait_n  = GAPS ? $urandom % 4 : 0;
        end else if (cyc > 0 && next_ch < N) begin
            if (wait_n > 0) begin
                wait_n--;
            end else begin
                beat_t b;
                in_valid = 1'b1;
                in_ch    = CW'(next_ch);
                in_data  = rsamp();
                b.cyc  = cyc + GAIN_LAT;
                b.ch   = next_ch;
                b.data = ref_out(in_data, gains[next_ch*GW +: GW]);
                expect_q.push_back(b);
                next_ch++;
                wait_n = GAPS ? (($urandom % 3 == 0) ? $urandom % 5 : 0) : 0;
            end
        end
    end

    // ----- check -----
    int err = 0;
    always @(posedge mclk) begin
        if (rst_n) begin
            if (out_valid) begin
                if (expect_q.size() == 0) begin
                    err++;
                    if (err < 10) $display("[%0t] N=%0d: unexpected beat ch %0d", $time, N, out_ch);
                end else begin
                    beat_t b;
                    b = expect_q.pop_front();
                    if (cyc != b.cyc || int'(out_ch) != b.ch || out_data !== b.data) begin
                        err++;
                        if (err < 10)
                            $display("[%0t] N=%0d: beat ch %0d = %06h at cycle %0d; expected ch %0d = %06h at %0d",
                                     $time, N, out_ch, out_data, cyc, b.ch, b.data, b.cyc);
                    end
                    if (b.ch == N-1) checked++;
                end
            end else if (expect_q.size() != 0 && expect_q[0].cyc == cyc) begin
                err++;
                if (err < 10) $display("[%0t] N=%0d: no beat at cycle %0d (ch %0d expected)",
                                       $time, N, cyc, expect_q[0].ch);
            end
        end
    end

    initial begin
        checked = 0; done = 0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = err + mon_err + ((done && mon_frames < FRAMES) ? 1 : 0);
endmodule


module tb_pcm_gain;
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

    localparam int NH = 5;
    int  e [NH], k [NH];
    bit  d [NH];

    gain_harness #(.N (1))                h0 (.mclk, .rst_n, .frame, .cyc, .errors (e[0]), .checked (k[0]), .done (d[0]));
    gain_harness #(.N (4))                h1 (.mclk, .rst_n, .frame, .cyc, .errors (e[1]), .checked (k[1]), .done (d[1]));
    gain_harness #(.N (20))               h2 (.mclk, .rst_n, .frame, .cyc, .errors (e[2]), .checked (k[2]), .done (d[2]));
    gain_harness #(.N (28))               h3 (.mclk, .rst_n, .frame, .cyc, .errors (e[3]), .checked (k[3]), .done (d[3]));
    gain_harness #(.N (20), .GAPS (1'b1)) h4 (.mclk, .rst_n, .frame, .cyc, .errors (e[4]), .checked (k[4]), .done (d[4]));

    initial begin
        int total;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        wait (d[0] && d[1] && d[2] && d[3] && d[4]);
        repeat (2) @(posedge mclk);
        $display("  N = 1           %0d frames, %0d errors", k[0], e[0]);
        $display("  N = 4           %0d frames, %0d errors", k[1], e[1]);
        $display("  N = 20          %0d frames, %0d errors", k[2], e[2]);
        $display("  N = 28          %0d frames, %0d errors", k[3], e[3]);
        $display("  N = 20, gaps    %0d frames, %0d errors", k[4], e[4]);
        total = 0;
        foreach (e[n]) total += e[n];
        if (total == 0) $display("PASS: tb_pcm_gain (GAIN_LAT = %0d)", GAIN_LAT);
        else            $display("FAIL: tb_pcm_gain - %0d errors", total);
        $finish;
    end

    initial begin
        #20ms;
        $display("FAIL: tb_pcm_gain TIMEOUT");
        $finish;
    end
endmodule
