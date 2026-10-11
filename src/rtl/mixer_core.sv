// -----------------------------------------------------------------------------
// mixer_core.sv
//
// The PCM core (docs/architecture_modules.md 1, 2, 2.1): everything between
// the front doors, as one block with the PACKED PCM contract on both sides.
// Inside, blocks are chained by the PCM stream contract (2.1). Since Phase 12
// the core is the console's signal flow (decisions L1-L5):
//
//   in_flat -patch2stream-> pcm_gain -> pcm_matrix -> pcm_gain -> pcm_matrix -> pcm_gain -stream2patch-> out_flat
//   P_IN     input patch    input      input matrix   bus        bus matrix     output    output patch   P_OUT
//   I/O ports               levels     N_IN -> N_BUS  levels     N_BUS -> N_OUT levels                 I/O ports
//              ^              ^             ^            ^            ^            ^           ^
//          in_patch_*      in_lvl_*     in_mx_*      bus_lvl_*    bus_mx_*     out_lvl_*   out_patch_*
//
// Phase 15 (decision CS1): the packed sides are the I/O PORTS (P_IN in,
// P_OUT out), and the converters at the ends are the patch: input channel k
// takes the port its source entry names, output channel c feeds the port its
// destination entry names (0 = None; pcm_patch2stream.sv, pcm_stream2patch.sv).
// The core still doesn't know what the ports are (the platform's map).
//
// Seven coefficient read ports, one per block, each served by the control
// plane's coef_bank_ram (one register window per block) or by a
// coef_flat_reader (non-PS builds, TBs); the core can't tell which:
//   *_lvl_* : ROW_LEN 1, N_ROWS = the stage's channels, LANES 1 (pcm_gain.sv)
//   in_mx_* : ROW_LEN N_IN,  N_ROWS N_BUS, LANES L1  (row = bus,    pcm_matrix.sv)
//   bus_mx_*: ROW_LEN N_BUS, N_ROWS N_OUT, LANES L2  (row = output)
//   *_patch_*: ROW_LEN 1, N_ROWS = the channels, LANES 1, W = $clog2(P+1)
// so a matrix's register index is k = destination*N_source + source, as
// before. Every block saturates its output to SW bits (L5): a bus sum clips at
// the bus, as on a console.
//
// Tap ports (Phase 13, decision M1): the three level stages' output streams
// leave the core as copies (stream contract), the zones' post-DSP points the
// OSC standard meters; the peak meters (pcm_peak) attach there, outside the
// chain. Last beats (cycles after the strobe): tap_in = chain_in_last +
// GAIN_LAT, tap_bus = chain_bus_last + GAIN_LAT, tap_out = D - OUT_PATCH_LAT.
//
// Phase 7 DSP blocks go into this chain the same way, between the converters,
// so the platform layer and the front doors never change when the core grows.
// (Phase 9, P9.A4: the core was pack2stream -> pcm_matrix -> stream2pack.)
//
// Timing: in_flat is captured on the strobe (frame_i). out_flat changes on one
// edge, D = mixer_core_pkg::chain_latency(N_IN, N_BUS, N_OUT, L1, L2) cycles
// after the strobe (20/20/20 on 4 + 4 lanes: 251), valid_o pulsing on that
// edge's cycle. L1/L2 default to the package's chooser (the fewest lanes with
// D <= D_MAX); the core refuses to elaborate past D_MAX. err_o pulses on a
// malformed internal stream (never expected; for a status counter).
// -----------------------------------------------------------------------------
module mixer_core
    import pcm_matrix_pkg::*;
    import mixer_core_pkg::*;
#(
    parameter int N_IN  = 12,
    parameter int N_BUS = 12,
    parameter int N_OUT = 12,
    parameter int P_IN  = N_IN,     // I/O ports in (Phase 15)
    parameter int P_OUT = N_OUT,    // I/O ports out
    parameter int SW    = 24,
    parameter int GW    = 18,
    parameter int GF    = 16,
    parameter int L1    = chain_l1(N_IN, N_BUS, N_OUT),
    parameter int L2    = chain_l2(N_IN, N_BUS, N_OUT),
    localparam int CWI  = (N_IN  > 1) ? $clog2(N_IN)  : 1,
    localparam int CWB  = (N_BUS > 1) ? $clog2(N_BUS) : 1,
    localparam int CWO  = (N_OUT > 1) ? $clog2(N_OUT) : 1,
    localparam int PWI  = $clog2(P_IN + 1),     // a patch entry: 0 = None, 1 .. P
    localparam int PWO  = $clog2(P_OUT + 1),
    localparam int DEPTH1 = matrix_passes(N_BUS, (L1 > 0) ? L1 : 1) * N_IN,
    localparam int DEPTH2 = matrix_passes(N_OUT, (L2 > 0) ? L2 : 1) * N_BUS,
    localparam int AW1  = (DEPTH1 > 1) ? $clog2(DEPTH1) : 1,
    localparam int AW2  = (DEPTH2 > 1) ? $clog2(DEPTH2) : 1
) (
    input  logic                 mclk,
    input  logic                 rst_n,
    input  logic                 frame_i,

    input  logic [P_IN*SW-1:0]   in_flat,       // the I/O ports
    output logic [P_OUT*SW-1:0]  out_flat,
    output logic                 valid_o,
    output logic                 err_o,

    // coefficient read ports (address -> data one cycle later)
    output logic [CWI-1:0]       in_patch_addr,
    input  logic [PWI-1:0]       in_patch_data,
    output logic [CWI-1:0]       in_lvl_addr,
    input  logic [GW-1:0]        in_lvl_data,
    output logic [AW1-1:0]       in_mx_addr,
    input  logic [L1*GW-1:0]     in_mx_data,
    output logic [CWB-1:0]       bus_lvl_addr,
    input  logic [GW-1:0]        bus_lvl_data,
    output logic [AW2-1:0]       bus_mx_addr,
    input  logic [L2*GW-1:0]     bus_mx_data,
    output logic [CWO-1:0]       out_lvl_addr,
    input  logic [GW-1:0]        out_lvl_data,
    output logic [CWO-1:0]       out_patch_addr,
    input  logic [PWO-1:0]       out_patch_data,

    // tap ports (Phase 13): copies of the three level stages' output streams
    // (the zones' post-DSP points), for listeners such as the peak meters
    output logic                 tap_in_valid,
    output logic [CWI-1:0]       tap_in_ch,
    output logic [SW-1:0]        tap_in_data,
    output logic                 tap_bus_valid,
    output logic [CWB-1:0]       tap_bus_ch,
    output logic [SW-1:0]        tap_bus_data,
    output logic                 tap_out_valid,
    output logic [CWO-1:0]       tap_out_ch,
    output logic [SW-1:0]        tap_out_data
);

    localparam int D = chain_latency(N_IN, N_BUS, N_OUT, L1, L2);

    generate
        if (L1 < 1 || L2 < 1)
            $error("mixer_core: %0d -> %0d -> %0d does not fit the frame budget",
                   N_IN, N_BUS, N_OUT);
        else if (D > D_MAX)
            $error("mixer_core: lanes %0d + %0d give D = %0d > D_MAX = %0d",
                   L1, L2, D, D_MAX);
    endgenerate

    // ----- streams between the blocks (a..f, in chain order) -----
    logic           a_valid, b_valid, c_valid, d_valid, e_valid, f_valid;
    logic [CWI-1:0] a_ch, b_ch;
    logic [CWB-1:0] c_ch, d_ch;
    logic [CWO-1:0] e_ch, f_ch;
    logic [SW-1:0]  a_data, b_data, c_data, d_data, e_data, f_data;

    pcm_patch2stream #(.P (P_IN), .N (N_IN), .SW (SW)) u_in (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i), .in_flat (in_flat),
        .coef_addr (in_patch_addr), .coef_data (in_patch_data),
        .s_valid (a_valid), .s_ch (a_ch), .s_data (a_data));

    pcm_gain #(.N (N_IN), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_in_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (a_valid), .in_ch (a_ch), .in_data (a_data),
        .coef_addr (in_lvl_addr), .coef_data (in_lvl_data),
        .out_valid (b_valid), .out_ch (b_ch), .out_data (b_data));

    pcm_matrix #(
        .N_IN (N_IN), .N_OUT (N_BUS), .SAMPLE_WIDTH (SW),
        .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L1)
    ) u_in_mx (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (b_valid), .in_ch (b_ch), .in_data (b_data),
        .coef_addr (in_mx_addr), .coef_data (in_mx_data),
        .out_valid (c_valid), .out_ch (c_ch), .out_data (c_data));

    pcm_gain #(.N (N_BUS), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_bus_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (c_valid), .in_ch (c_ch), .in_data (c_data),
        .coef_addr (bus_lvl_addr), .coef_data (bus_lvl_data),
        .out_valid (d_valid), .out_ch (d_ch), .out_data (d_data));

    pcm_matrix #(
        .N_IN (N_BUS), .N_OUT (N_OUT), .SAMPLE_WIDTH (SW),
        .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L2)
    ) u_bus_mx (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (d_valid), .in_ch (d_ch), .in_data (d_data),
        .coef_addr (bus_mx_addr), .coef_data (bus_mx_data),
        .out_valid (e_valid), .out_ch (e_ch), .out_data (e_data));

    pcm_gain #(.N (N_OUT), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_out_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (e_valid), .in_ch (e_ch), .in_data (e_data),
        .coef_addr (out_lvl_addr), .coef_data (out_lvl_data),
        .out_valid (f_valid), .out_ch (f_ch), .out_data (f_data));

    // ----- taps: listen only; the chain doesn't know they exist -----
    assign tap_in_valid  = b_valid;
    assign tap_in_ch     = b_ch;
    assign tap_in_data   = b_data;
    assign tap_bus_valid = d_valid;
    assign tap_bus_ch    = d_ch;
    assign tap_bus_data  = d_data;
    assign tap_out_valid = f_valid;
    assign tap_out_ch    = f_ch;
    assign tap_out_data  = f_data;

    pcm_stream2patch #(.N (N_OUT), .P (P_OUT), .SW (SW)) u_out (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i),
        .s_valid (f_valid), .s_ch (f_ch), .s_data (f_data),
        .coef_addr (out_patch_addr), .coef_data (out_patch_data),
        .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o));

endmodule
