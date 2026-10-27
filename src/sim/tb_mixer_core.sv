// -----------------------------------------------------------------------------
// tb_mixer_core.sv
//
// The whole PCM core since Phase 12 (mixer_core: input levels -> input matrix
// -> bus levels -> bus matrix -> output levels, between the converters), its
// seven coefficient ports served by coef_flat_readers, across sizes
// (I/O ports in, channels in -> buses -> channels out, I/O ports out):
//
//   20 | 20 -> 20 -> 20 | 20   today's core (4 + 4 lanes, D = 251)
//   20 | 12 -> 12 -> 12 | 20   fewer channels than ports (1 + 2)
//   20 | 28 -> 28 -> 28 | 20   more channels than ports (10 + 10)
//   20 | 20 ->  8 -> 20 | 20   fewer buses than channels
//    5 |  3 ->  5 ->  2 |  4   expand, then reduce
//    7 |  7 ->  5 ->  3 |  3   lanes forced to 3 + 2: idle lanes in both matrices' last pass
//    1 |  1 ->  1 ->  1 |  1   degenerate
//   16 | 16 -> 16 -> 16 | 16   LF1: lanes forced to 2 + 2, D = 299 (> one frame): the bus
//                              matrix, the output levels and the output patch cross a strobe
//   16 | 16 -> 16 -> 16 | 16   LF1: lanes forced to 1 + 16, D = 328: the input matrix and
//                              the bus levels cross a strobe
//
// ----- Coefficients (library foundation, LF1, 2026-10-26) -----
// Every bank swaps on its block's own frame boundary (mixer_core's *_swap
// pulses, wired to coef_flat_readers with LATCH = 1, as fpgamixer_top wires
// them to its coef_bank_rams), so the blocks don't all change coefficients
// on the same frame, and in a chain longer than a frame a block's reads of
// one frame may fall after the next strobe. What the core guarantees is that
// each frame sees ONE WHOLE BANK PER BLOCK (never a mix), and that a new bank
// is in use within a frame or so. The TB checks exactly that:
//   - coefficient SETS (all seven banks, in one of three modes: "extreme",
//     full-range gains with the extremes over-represented and patch entries
//     random over their whole field; "console", levels and sparse crosspoints
//     in -1.0 .. +1.0, sources random, destinations one-to-one with some None;
//     "reset", identity patch, unity levels, identity matrices) are presented
//     in turn, each for HOLD frames, changing in cycle 0;
//   - frame f may use, per block, any set presented in frames f-1 .. f+1
//     (with HOLD = 3, at most two: the old and the new). Every tap stream's
//     frame and every output frame must be explained by ONE choice per block
//     for ALL its beats: a block that read a frame's coefficients from two
//     banks (a torn frame) fails, beat values and all. Frames whose window
//     holds one set are checked against it exactly;
//   - the packed output, bit-exact against a 64-bit model of the chain
//     (through the input patch, then onto the ports by the destinations, the
//     later channel winning a shared port) that saturates to 24 bits after
//     every block (decision L5); it must update exactly at cycle D mod FRAME
//     after a strobe (D = chain_latency) and nowhere else; err_o must stay
//     low; the bus stream, the three taps and the output-level stream obey
//     the stream contract (pcm_stream_monitor, SPANS = 1: frames may cross
//     strobes, start FRAME cycles apart, first/last beats at their stated
//     cycles after the frame's own strobe, which may exceed FRAME).
//
// The model also runs once WITHOUT the bus saturation on exactly-checked
// frames; frames where that changes the output are counted ("bus clips"), so
// the run shows that the check can tell a saturating bus from a wide one.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module core_harness
    import pcm_matrix_pkg::*;
    import mixer_core_pkg::*;
#(
    parameter int N_IN   = 3,
    parameter int N_BUS  = 5,
    parameter int N_OUT  = 2,
    parameter int P_IN   = N_IN,
    parameter int P_OUT  = N_OUT,
    parameter int L1     = chain_l1(N_IN, N_BUS, N_OUT),
    parameter int L2     = chain_l2(N_IN, N_BUS, N_OUT),
    parameter int FRAMES = 90,
    parameter int HOLD   = 3
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
    localparam int PWI    = $clog2(P_IN + 1);
    localparam int PWO    = $clog2(P_OUT + 1);

    typedef logic [P_IN*SW-1:0]       pin_t;
    typedef logic [P_OUT*SW-1:0]      pout_t;
    typedef logic [N_IN*SW-1:0]       chin_t;
    typedef logic [N_IN*PWI-1:0]      src_t;
    typedef logic [N_OUT*PWO-1:0]     dst_t;
    typedef logic [N_IN*GW-1:0]       gin_t;
    typedef logic [N_BUS*N_IN*GW-1:0] gim_t;
    typedef logic [N_BUS*GW-1:0]      gbl_t;
    typedef logic [N_OUT*N_BUS*GW-1:0] gbm_t;
    typedef logic [N_OUT*GW-1:0]      gol_t;

    // One coefficient set: all seven banks. Block numbers (bits of a choice):
    // 0 input patch, 1 input levels, 2 input matrix, 3 bus levels,
    // 4 bus matrix, 5 output levels, 6 output patch.
    typedef struct {
        src_t s;  gin_t gi;  gim_t gm;  gbl_t gb;  gbm_t gbm;  gol_t go;  dst_t d;
        int   mode;
    } set_t;

    pin_t                in_flat;
    pout_t               out_flat, out_prev;
    logic                valid_o, err_o;
    gin_t g_in;  gim_t g_im;  gbl_t g_bl;  gbm_t g_bm;  gol_t g_ol;
    src_t t_src;  dst_t t_dst;

    logic [CWI-1:0] in_patch_addr;  logic [PWI-1:0] in_patch_data;
    logic [CWO-1:0] out_patch_addr; logic [PWO-1:0] out_patch_data;
    logic [CWI-1:0] in_lvl_addr;  logic [GW-1:0] in_lvl_data;
    logic [AW1-1:0] in_mx_addr;   logic [L1*GW-1:0] in_mx_data;
    logic [CWB-1:0] bus_lvl_addr; logic [GW-1:0] bus_lvl_data;
    logic [AW2-1:0] bus_mx_addr;  logic [L2*GW-1:0] bus_mx_data;
    logic [CWO-1:0] out_lvl_addr; logic [GW-1:0] out_lvl_data;
    logic sw_ip, sw_il, sw_im, sw_bl, sw_bm, sw_ol, sw_op;    // the bank swap pulses

    // tap ports (Phase 13)
    logic ti_v, tb_v, to_v;
    logic [CWI-1:0] ti_c;  logic [CWB-1:0] tb_c;  logic [CWO-1:0] to_c;
    logic [SW-1:0]  ti_d, tb_d, to_d;

    mixer_core #(.N_IN (N_IN), .N_BUS (N_BUS), .N_OUT (N_OUT), .P_IN (P_IN), .P_OUT (P_OUT),
                 .SW (SW), .GW (GW), .GF (GF), .L1 (L1), .L2 (L2)) dut (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame),
        .in_flat (in_flat), .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o),
        .in_patch_swap (sw_ip), .in_lvl_swap (sw_il), .in_mx_swap (sw_im),
        .bus_lvl_swap (sw_bl), .bus_mx_swap (sw_bm), .out_lvl_swap (sw_ol),
        .out_patch_swap (sw_op),
        .in_patch_addr (in_patch_addr),   .in_patch_data (in_patch_data),
        .out_patch_addr (out_patch_addr), .out_patch_data (out_patch_data),
        .in_lvl_addr (in_lvl_addr),   .in_lvl_data (in_lvl_data),
        .in_mx_addr (in_mx_addr),     .in_mx_data (in_mx_data),
        .bus_lvl_addr (bus_lvl_addr), .bus_lvl_data (bus_lvl_data),
        .bus_mx_addr (bus_mx_addr),   .bus_mx_data (bus_mx_data),
        .out_lvl_addr (out_lvl_addr), .out_lvl_data (out_lvl_data),
        .tap_in_valid (ti_v),  .tap_in_ch (ti_c),  .tap_in_data (ti_d),
        .tap_bus_valid (tb_v), .tap_bus_ch (tb_c), .tap_bus_data (tb_d),
        .tap_out_valid (to_v), .tap_out_ch (to_c), .tap_out_data (to_d));

    // The banks: latched on their block's swap pulse, as coef_bank_ram is.
    coef_flat_reader #(.W (GW), .N_ROWS (N_IN),  .ROW_LEN (1),     .LANES (1),  .LATCH (1)) u_c0 (
        .mclk, .frame_i (sw_il), .coefs_flat (g_in), .rd_addr (in_lvl_addr),  .rd_data (in_lvl_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (N_IN),  .LANES (L1), .LATCH (1)) u_c1 (
        .mclk, .frame_i (sw_im), .coefs_flat (g_im), .rd_addr (in_mx_addr),   .rd_data (in_mx_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_BUS), .ROW_LEN (1),     .LANES (1),  .LATCH (1)) u_c2 (
        .mclk, .frame_i (sw_bl), .coefs_flat (g_bl), .rd_addr (bus_lvl_addr), .rd_data (bus_lvl_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_OUT), .ROW_LEN (N_BUS), .LANES (L2), .LATCH (1)) u_c3 (
        .mclk, .frame_i (sw_bm), .coefs_flat (g_bm), .rd_addr (bus_mx_addr),  .rd_data (bus_mx_data));
    coef_flat_reader #(.W (GW), .N_ROWS (N_OUT), .ROW_LEN (1),     .LANES (1),  .LATCH (1)) u_c4 (
        .mclk, .frame_i (sw_ol), .coefs_flat (g_ol), .rd_addr (out_lvl_addr), .rd_data (out_lvl_data));
    coef_flat_reader #(.W (PWI), .N_ROWS (N_IN),  .ROW_LEN (1),    .LANES (1),  .LATCH (1)) u_c5 (
        .mclk, .frame_i (sw_ip), .coefs_flat (t_src), .rd_addr (in_patch_addr),  .rd_data (in_patch_data));
    coef_flat_reader #(.W (PWO), .N_ROWS (N_OUT), .ROW_LEN (1),    .LANES (1),  .LATCH (1)) u_c6 (
        .mclk, .frame_i (sw_op), .coefs_flat (t_dst), .rd_addr (out_patch_addr), .rd_data (out_patch_data));

    // ----- stream checks: frames may cross strobes (SPANS) -----
    int mon_err_b, mon_frames_b, mon_err_o, mon_frames_o;
    localparam int BUS_LAST = chain_bus_last(N_IN, N_BUS, L1);
    pcm_stream_monitor #(.N (N_BUS),
                         .FIRST_BEAT (chain_in_last(N_IN) + GAIN_LAT + matrix_lat_first(N_IN)),
                         .LAST_BEAT  (BUS_LAST), .SPANS (1'b1), .FRAME (FRAME),
                         .NAME ("buses")) u_mon_b (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (dut.c_valid), .s_ch (dut.c_ch),
        .errors (mon_err_b), .frames (mon_frames_b));
    pcm_stream_monitor #(.N (N_OUT),
                         .FIRST_BEAT (BUS_LAST + GAIN_LAT + matrix_lat_first(N_BUS) + GAIN_LAT),
                         .LAST_BEAT  (chain_out_last(N_IN, N_BUS, N_OUT, L1, L2) + GAIN_LAT),
                         .SPANS (1'b1), .FRAME (FRAME), .NAME ("outputs")) u_mon_o (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame),
        .s_valid (to_v), .s_ch (to_c),                    // the output tap = the output levels' stream
        .errors (mon_err_o), .frames (mon_frames_o));

    // the other two taps: the stream contract at their stated last beats
    int mon_err_ti, mon_frames_ti, mon_err_tb, mon_frames_tb;
    pcm_stream_monitor #(.N (N_IN), .FIRST_BEAT (1 + IN_PATCH_LAT + GAIN_LAT),
                         .LAST_BEAT (chain_in_last(N_IN) + GAIN_LAT),
                         .CONTIGUOUS (1'b1), .SPANS (1'b1), .FRAME (FRAME), .NAME ("tap in")) u_mon_ti (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame), .s_valid (ti_v), .s_ch (ti_c),
        .errors (mon_err_ti), .frames (mon_frames_ti));
    pcm_stream_monitor #(.N (N_BUS), .LAST_BEAT (BUS_LAST + GAIN_LAT), .SPANS (1'b1), .FRAME (FRAME),
                         .NAME ("tap bus")) u_mon_tb (
        .clk (mclk), .rst_n (rst_n), .frame_i (frame), .s_valid (tb_v), .s_ch (tb_c),
        .errors (mon_err_tb), .frames (mon_frames_tb));

    // ----- the chain model -----
    function automatic longint sat(input longint v);
        if (v >  64'sd8388607) return  64'sd8388607;
        if (v < -64'sd8388608) return -64'sd8388608;
        return v;
    endfunction
    function automatic longint sx(input logic [SW-1:0] v);  return longint'($signed(v)); endfunction
    function automatic longint gx(input logic [GW-1:0] v);  return longint'($signed(v)); endfunction

    // Input i after its level, and bus b after its level.
    function automatic logic [SW-1:0] model_in(input logic [N_IN*SW-1:0] x, input gin_t gi, input int i);
        longint v;
        v = sat((sx(x[i*SW +: SW]) * gx(gi[i*GW +: GW])) >>> GF);
        return v[SW-1:0];
    endfunction
    function automatic logic [SW-1:0] model_bus(input logic [N_IN*SW-1:0] x, input gin_t gi,
                                                input gim_t gm, input gbl_t gb, input int b);
        longint acc;
        acc = 0;
        for (int i = 0; i < N_IN; i++)
            acc += sx(model_in(x, gi, i)) * gx(gm[(b*N_IN + i)*GW +: GW]);
        acc = sat(acc >>> GF);
        acc = sat((acc * gx(gb[b*GW +: GW])) >>> GF);
        return acc[SW-1:0];
    endfunction

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

    // Phase 15, the patch: the input channels from the ports (0 = None, past
    // P = silence), and which output channel each port carries (-1 = none;
    // in ascending order, so the later channel wins a shared port).
    function automatic chin_t chans(input pin_t xp, input src_t s);
        chin_t x;
        int v;
        for (int k = 0; k < N_IN; k++) begin
            v = int'(s[k*PWI +: PWI]);
            x[k*SW +: SW] = (v >= 1 && v <= P_IN) ? xp[(v-1)*SW +: SW] : '0;
        end
        return x;
    endfunction
    function automatic int port_owner(input dst_t d, input int p);
        int owner;
        owner = -1;
        for (int c = 0; c < N_OUT; c++)
            if (int'(d[c*PWO +: PWO]) == p + 1) owner = c;
        return owner;
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
    task automatic make_patch(input int mode, output src_t s, output dst_t d);
        int perm [P_OUT];
        int j, t;
        for (int p = 0; p < P_OUT; p++) perm[p] = p;
        for (int p = P_OUT - 1; p > 0; p--) begin
            j = $urandom % (p + 1); t = perm[p]; perm[p] = perm[j]; perm[j] = t;
        end
        for (int k = 0; k < N_IN; k++)
            s[k*PWI +: PWI] = (mode == 0) ? PWI'($urandom) : (mode == 1) ? PWI'($urandom % (P_IN + 1))
                            : ((k < P_IN) ? PWI'(k + 1) : '0);
        for (int c = 0; c < N_OUT; c++)
            d[c*PWO +: PWO] = (mode == 0) ? PWO'($urandom)
                            : (mode == 1) ? ((c < P_OUT && $urandom % 4 != 0) ? PWO'(perm[c] + 1) : '0)
                            : ((c < P_OUT) ? PWO'(c + 1) : '0);
    endtask
    task automatic make_set(input int mode, output set_t z);
        z.mode = mode;
        make_patch(mode, z.s, z.d);
        for (int k = 0; k < N_IN; k++)        z.gi[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
        for (int k = 0; k < N_BUS; k++)       z.gb[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
        for (int k = 0; k < N_OUT; k++)       z.go[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_c() : 18'h10000;
        for (int k = 0; k < N_BUS*N_IN; k++)  z.gm[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_sparse()
                                                                 : ((k / N_IN == k % N_IN) ? 18'h10000 : 18'h0);
        for (int k = 0; k < N_OUT*N_BUS; k++) z.gbm[k*GW +: GW] = (mode == 0) ? rgain_x() : (mode == 1) ? rgain_sparse()
                                                                 : ((k / N_BUS == k % N_BUS) ? 18'h10000 : 18'h0);
    endtask

    // The sets, by id; frame f is presented set f / HOLD (frames counted from
    // the first strobe after reset; before it, set 0).
    set_t sets [$];
    function automatic int set_of(input int f);
        return (f < 0) ? 0 : f / HOLD;
    endfunction
    task automatic need_set(input int id);
        set_t z;
        while (sets.size() <= id) begin
            make_set($urandom % 3, z);
            sets.push_back(z);
        end
    endtask

    // The ids frame f may use per block: the distinct sets of frames f-1 .. f+1.
    task automatic cands(input int f, output int ids [2], output int n);
        int a, b, c;
        a = set_of(f - 1); b = set_of(f); c = set_of(f + 1);
        need_set(c);
        ids[0] = a; n = 1;
        if (b != a) begin ids[n] = b; n++; end
        if (c != ids[n-1] && c != ids[0]) begin
            if (n < 2) begin ids[n] = c; n++; end
            else begin
                ids[1] = c;      // HOLD < 3 would need three; can't happen with HOLD >= 3
                $error("tb_mixer_core: three sets in one frame's window (HOLD = %0d)", HOLD);
            end
        end
        if (n == 1) ids[1] = ids[0];
    endtask
    function automatic int pick(input int ids [2], input int combo, input int blk);
        return ids[(combo >> blk) & 1];
    endfunction

    // ----- per-frame tables of what each choice gives -----
    // in_tab[c][i]: input i after its level, choices of blocks 0..1 (c < 4);
    // bus_tab[c][b]: bus b after its level, blocks 0..3 (c < 16);
    // out_tab[c][o]: output channel o after its level, blocks 0..5 (c < 64).
    typedef logic [SW-1:0] in_tab_t  [4][N_IN];
    typedef logic [SW-1:0] bus_tab_t [16][N_BUS];
    typedef logic [SW-1:0] out_tab_t [64][N_OUT];
    pin_t     x_rec   [int];      // frame -> the ports captured at its strobe
    in_tab_t  in_tab  [int];
    bus_tab_t bus_tab [int];
    out_tab_t out_tab [int];
    int       n_ids   [int];      // frame -> 1 (exact) or 2 (a set changes nearby)
    int       ids_of  [int][2];

    task automatic build(input int f);
        int ids [2];
        int n, nc;
        chin_t x;
        in_tab_t ti; bus_tab_t tb; out_tab_t to;
        longint acc;
        if (in_tab.exists(f)) return;
        cands(f, ids, n);
        n_ids[f] = n; ids_of[f] = ids;
        for (int c = 0; c < 64; c++) begin
            if (n == 1 && c != 0) continue;
            x = chans(x_rec[f], sets[pick(ids, c, 0)].s);
            if (c < 4)
                for (int i = 0; i < N_IN; i++) ti[c][i] = model_in(x, sets[pick(ids, c, 1)].gi, i);
            if (c < 16)
                for (int b = 0; b < N_BUS; b++)
                    tb[c][b] = model_bus(x, sets[pick(ids, c, 1)].gi, sets[pick(ids, c, 2)].gm,
                                         sets[pick(ids, c, 3)].gb, b);
        end
        for (int c = 0; c < 64; c++) begin
            if (n == 1 && c != 0) continue;
            for (int o = 0; o < N_OUT; o++) begin
                acc = 0;
                for (int b = 0; b < N_BUS; b++)
                    acc += sx(tb[c & 15][b]) * gx(sets[pick(ids, c, 4)].gbm[(o*N_BUS + b)*GW +: GW]);
                acc = sat(acc >>> GF);
                acc = sat((acc * gx(sets[pick(ids, c, 5)].go[o*GW +: GW])) >>> GF);
                to[c][o] = acc[SW-1:0];
            end
        end
        in_tab[f] = ti; bus_tab[f] = tb; out_tab[f] = to;
    endtask

    // ----- presenting the sets and the samples -----
    int fr = -1;                  // the current frame: strobes seen - 1
    always @(negedge mclk) begin
        int id;
        if (cyc < 0 || cyc == 0) begin
            id = set_of(fr);
            need_set(id);
            t_src = sets[id].s;  t_dst = sets[id].d;
            g_in = sets[id].gi;  g_im = sets[id].gm;  g_bl = sets[id].gb;
            g_bm = sets[id].gbm; g_ol = sets[id].go;
            // samples are set a frame ahead of their capture, so they follow
            // the previous set's mode (harmless: the mode only shapes the
            // stimulus, the model checks all)
            for (int i = 0; i < P_IN; i++) in_flat[i*SW +: SW] = rsamp(sets[id].mode);
        end
    end

    // ----- check -----
    int err = 0;
    int f_ti = 0, f_tb = 0, f_to = 0, f_out = 0;     // each stream's current frame
    bit [3:0]  m_ti;  bit [15:0] m_tb;  bit [63:0] m_to; // choices still consistent with the frame

    function automatic bit [63:0] all_choices(input int f, input int width);
        return (n_ids[f] == 1) ? 64'd1 : ((width >= 64) ? '1 : ((64'd1 << width) - 1));
    endfunction

    // The table value of choice c (c < the table's size: the masks never
    // hold more), one branch per table: XSim crashed (kernel FATAL) on a
    // nested conditional over the three tables in the error path.
    function automatic logic [SW-1:0] tab(input int f, input int which, input int c, input int ch);
        if (which == 0) return in_tab[f][c & 3][ch];
        if (which == 1) return bus_tab[f][c & 15][ch];
        return out_tab[f][c & 63][ch];
    endfunction

    task automatic tap_beat(input string name, input int f, input int ch, input logic [SW-1:0] v,
                            input int which, inout bit [63:0] mask);
        bit [63:0] keep;
        string why;
        keep = '0;
        for (int c = 0; c < 64; c++)
            if (mask[c] && tab(f, which, c, ch) === v)
                keep[c] = 1'b1;
        if (keep == '0) begin
            err++;
            if (err < 10) begin
                if (n_ids[f] == 1) why = $sformatf("exact: %06h", tab(f, which, 0, ch));
                else               why = "two sets: torn?";
                $display("[%0t] %0d/%0d/%0d: %s frame %0d ch%0d = %06h: no single bank per block gives it (%s)",
                         $time, N_IN, N_BUS, N_OUT, name, f, ch, v, why);
            end
        end
        mask = keep;
    endtask

    always @(posedge mclk) begin
        bit [63:0] mk;
        if (rst_n) begin
            if (frame) begin
                fr++;
                x_rec[fr] = in_flat;
            end
            if (ti_v || tb_v || to_v || valid_o) begin
                // every stream's frame f was captured at strobe f, which is
                // before any of its beats
                if (ti_v && !x_rec.exists(f_ti) || tb_v && !x_rec.exists(f_tb) || to_v && !x_rec.exists(f_to)) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: a tap beat before its frame's strobe", $time,
                                           N_IN, N_BUS, N_OUT);
                end else begin
                    if (ti_v) begin
                        build(f_ti);
                        if (ti_c == '0) m_ti = 4'(all_choices(f_ti, 4));
                        mk = 64'(m_ti); tap_beat("tap in", f_ti, int'(ti_c), ti_d, 0, mk); m_ti = mk[3:0];
                        if (ti_c == CWI'(N_IN - 1)) f_ti++;
                    end
                    if (tb_v) begin
                        build(f_tb);
                        if (tb_c == '0) m_tb = 16'(all_choices(f_tb, 16));
                        mk = 64'(m_tb); tap_beat("tap bus", f_tb, int'(tb_c), tb_d, 1, mk); m_tb = mk[15:0];
                        if (tb_c == CWB'(N_BUS - 1)) f_tb++;
                    end
                    if (to_v) begin
                        build(f_to);
                        if (to_c == '0) m_to = all_choices(f_to, 64);
                        tap_beat("tap out", f_to, int'(to_c), to_d, 2, m_to);
                        if (to_c == CWO'(N_OUT - 1)) f_to++;
                    end
                end
            end
            if (err_o) begin
                err++;
                if (err < 10) $display("[%0t] %0d/%0d/%0d: err_o", $time, N_IN, N_BUS, N_OUT);
            end
            if (valid_o) begin
                int f, ids [2], nfound;
                bit ok;
                f = f_out;
                if (cyc != D % FRAME) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: output at cycle %0d, D = %0d (cycle %0d of a frame)",
                                           $time, N_IN, N_BUS, N_OUT, cyc, D, D % FRAME);
                end
                if (!x_rec.exists(f)) begin
                    err++;
                    if (err < 10) $display("[%0t] %0d/%0d/%0d: output for frame %0d before its strobe", $time,
                                           N_IN, N_BUS, N_OUT, f);
                end else begin
                    build(f);
                    ids = ids_of[f];
                    // some choice of one bank per block must give every port
                    nfound = 0;
                    for (int c = 0; c < 128; c++) begin
                        if (n_ids[f] == 1 && c != 0) continue;
                        ok = 1;
                        for (int p = 0; p < P_OUT && ok; p++) begin
                            int o;
                            logic [SW-1:0] want;
                            o = port_owner(sets[pick(ids, c, 6)].d, p);
                            want = (o < 0) ? '0 : out_tab[f][c & 63][o];
                            if (out_flat[p*SW +: SW] !== want) ok = 0;
                        end
                        if (ok) nfound++;
                    end
                    if (nfound == 0) begin
                        err++;
                        if (err < 10) $display("[%0t] %0d/%0d/%0d: output frame %0d (candidate sets: %0d): no single bank per block gives it",
                                               $time, N_IN, N_BUS, N_OUT, f, n_ids[f]);
                    end
                    // exactly-checked frames: the bus-clip count and the reset routing
                    if (n_ids[f] == 1) begin
                        set_t z;
                        chin_t x;
                        bit clipped;
                        z = sets[ids[0]];
                        x = chans(x_rec[f], z.s);
                        clipped = 0;
                        for (int o = 0; o < N_OUT; o++)
                            if (model(x, z.gi, z.gm, z.gb, z.gbm, z.go, o, 1'b0) !== model(x, z.gi, z.gm, z.gb, z.gbm, z.go, o, 1'b1))
                                clipped = 1;
                        if (clipped) bus_clips++;
                        if (z.mode == 2)
                            for (int p = 0; p < P_OUT; p++)
                                if (p < N_IN && p < N_BUS && p < N_OUT && p < P_IN
                                    && out_flat[p*SW +: SW] !== x_rec[f][p*SW +: SW]) begin
                                    err++;
                                    if (err < 10) $display("[%0t] %0d/%0d/%0d reset routing: port %0d = %06h, in %06h",
                                                           $time, N_IN, N_BUS, N_OUT, p, out_flat[p*SW +: SW],
                                                           x_rec[f][p*SW +: SW]);
                                end
                    end
                    // frames before this one are done with (taps run ahead of it)
                    if (in_tab.exists(f - 2)) begin
                        in_tab.delete(f - 2); bus_tab.delete(f - 2); out_tab.delete(f - 2);
                        x_rec.delete(f - 2); n_ids.delete(f - 2); ids_of.delete(f - 2);
                    end
                end
                f_out++;
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
        g_in = '0; g_im = '0; g_bl = '0; g_bm = '0; g_ol = '0; t_src = '0; t_dst = '0;
        wait (checked == FRAMES);
        done = 1;
    end

    assign errors = err + mon_err_b + mon_err_o + mon_err_ti + mon_err_tb +
                    ((done && (mon_frames_b < FRAMES || mon_frames_o < FRAMES ||
                               mon_frames_ti < FRAMES || mon_frames_tb < FRAMES)) ? 1 : 0);
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

    localparam int NH = 9;
    int  e [NH], k [NH], c [NH];
    bit  d [NH];

    core_harness #(.N_IN (20), .N_BUS (20), .N_OUT (20)) h0 (.mclk, .rst_n, .frame, .cyc, .errors (e[0]), .checked (k[0]), .bus_clips (c[0]), .done (d[0]));
    core_harness #(.N_IN (12), .N_BUS (12), .N_OUT (12), .P_IN (20), .P_OUT (20))
                                                         h1 (.mclk, .rst_n, .frame, .cyc, .errors (e[1]), .checked (k[1]), .bus_clips (c[1]), .done (d[1]));
    core_harness #(.N_IN (28), .N_BUS (28), .N_OUT (28), .P_IN (20), .P_OUT (20))
                                                         h2 (.mclk, .rst_n, .frame, .cyc, .errors (e[2]), .checked (k[2]), .bus_clips (c[2]), .done (d[2]));
    core_harness #(.N_IN (20), .N_BUS (8),  .N_OUT (20)) h3 (.mclk, .rst_n, .frame, .cyc, .errors (e[3]), .checked (k[3]), .bus_clips (c[3]), .done (d[3]));
    core_harness #(.N_IN (3),  .N_BUS (5),  .N_OUT (2), .P_IN (5), .P_OUT (4))
                                                         h4 (.mclk, .rst_n, .frame, .cyc, .errors (e[4]), .checked (k[4]), .bus_clips (c[4]), .done (d[4]));
    core_harness #(.N_IN (7),  .N_BUS (5),  .N_OUT (3), .L1 (3), .L2 (2))
                                                         h5 (.mclk, .rst_n, .frame, .cyc, .errors (e[5]), .checked (k[5]), .bus_clips (c[5]), .done (d[5]));
    core_harness #(.N_IN (1),  .N_BUS (1),  .N_OUT (1))  h6 (.mclk, .rst_n, .frame, .cyc, .errors (e[6]), .checked (k[6]), .bus_clips (c[6]), .done (d[6]));
    // LF1: chains longer than a frame (lanes forced below the chooser's pick)
    core_harness #(.N_IN (16), .N_BUS (16), .N_OUT (16), .L1 (2), .L2 (2))
                                                         h7 (.mclk, .rst_n, .frame, .cyc, .errors (e[7]), .checked (k[7]), .bus_clips (c[7]), .done (d[7]));
    core_harness #(.N_IN (16), .N_BUS (16), .N_OUT (16), .L1 (1), .L2 (16))
                                                         h8 (.mclk, .rst_n, .frame, .cyc, .errors (e[8]), .checked (k[8]), .bus_clips (c[8]), .done (d[8]));

    function automatic string row(input int ni, input int nb, input int no, input int l1, input int l2,
                                  input int ee, input int kk, input int cc);
        return $sformatf("  %2d -> %2d -> %2d  lanes %2d + %2d  D = %3d  %0d frames, %0d bus clips, %0d errors",
                         ni, nb, no, l1, l2, chain_latency(ni, nb, no, l1, l2), kk, cc, ee);
    endfunction

    initial begin
        int total, clips;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        wait (d[0] && d[1] && d[2] && d[3] && d[4] && d[5] && d[6] && d[7] && d[8]);
        repeat (2) @(posedge mclk);
        $display("  (I/O ports in/out, row by row: 20/20, 20/20, 20/20, 20/20, 5/4, 7/3, 1/1, 16/16, 16/16)");
        $display(row(20, 20, 20, h0.L1, h0.L2, e[0], k[0], c[0]));
        $display(row(12, 12, 12, h1.L1, h1.L2, e[1], k[1], c[1]));
        $display(row(28, 28, 28, h2.L1, h2.L2, e[2], k[2], c[2]));
        $display(row(20,  8, 20, h3.L1, h3.L2, e[3], k[3], c[3]));
        $display(row( 3,  5,  2, h4.L1, h4.L2, e[4], k[4], c[4]));
        $display(row( 7,  5,  3, h5.L1, h5.L2, e[5], k[5], c[5]));
        $display(row( 1,  1,  1, h6.L1, h6.L2, e[6], k[6], c[6]));
        $display(row(16, 16, 16, h7.L1, h7.L2, e[7], k[7], c[7]));
        $display(row(16, 16, 16, h8.L1, h8.L2, e[8], k[8], c[8]));
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
        #40ms;
        $display("FAIL: tb_mixer_core TIMEOUT");
        $finish;
    end
endmodule
