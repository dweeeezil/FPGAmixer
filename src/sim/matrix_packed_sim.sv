// -----------------------------------------------------------------------------
// matrix_packed_sim.sv  (simulation only)
//
// One pcm_matrix between the boundary converters, packed contract on both
// sides: what mixer_core was from Phase 9 (P9.A4) until Phase 12 made it the
// full chain (gain -> matrix -> gain -> matrix -> gain). The matrix TBs
// (tb_pcm_matrix, tb_pcm_matrix_rect, tb_matrix_regs) keep testing the matrix
// on its own through this wrapper, with their checks unchanged: out_flat
// updates D = pcm_matrix_pkg::core_latency(N_IN, N_OUT, LANES) cycles after
// the strobe. Never synthesized; mixer_core is the core.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module matrix_packed_sim
    import pcm_matrix_pkg::*;
#(
    parameter int N_IN  = 12,
    parameter int N_OUT = 12,
    parameter int SW    = 24,
    parameter int GW    = 18,
    parameter int GF    = 16,
    parameter int LANES = matrix_lanes(N_IN, N_OUT),
    localparam int PASSES = matrix_passes(N_OUT, LANES),
    localparam int DEPTH  = PASSES * N_IN,
    localparam int AW     = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                 mclk,
    input  logic                 rst_n,
    input  logic                 frame_i,

    input  logic [N_IN*SW-1:0]   in_flat,
    output logic [N_OUT*SW-1:0]  out_flat,
    output logic                 valid_o,
    output logic                 err_o,

    output logic [AW-1:0]        coef_addr,
    input  logic [LANES*GW-1:0]  coef_data
);

    localparam int CWI = (N_IN  > 1) ? $clog2(N_IN)  : 1;
    localparam int CWO = (N_OUT > 1) ? $clog2(N_OUT) : 1;

    logic           a_valid, b_valid;
    logic [CWI-1:0] a_ch;
    logic [CWO-1:0] b_ch;
    logic [SW-1:0]  a_data, b_data;

    pcm_pack2stream #(.N (N_IN), .SW (SW)) u_in (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i), .in_flat (in_flat),
        .s_valid (a_valid), .s_ch (a_ch), .s_data (a_data));

    pcm_matrix #(
        .N_IN (N_IN), .N_OUT (N_OUT), .SAMPLE_WIDTH (SW),
        .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (LANES)
    ) u_matrix (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (a_valid), .in_ch (a_ch), .in_data (a_data),
        .coef_addr (coef_addr), .coef_data (coef_data),
        .out_valid (b_valid), .out_ch (b_ch), .out_data (b_data));

    pcm_stream2pack #(.N (N_OUT), .SW (SW)) u_out (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i),
        .s_valid (b_valid), .s_ch (b_ch), .s_data (b_data),
        .out_flat (out_flat), .valid_o (valid_o), .err_o (err_o));

endmodule
