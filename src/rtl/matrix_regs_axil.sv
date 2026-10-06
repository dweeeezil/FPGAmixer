// -----------------------------------------------------------------------------
// matrix_regs_axil.sv
//
// Control-plane binding for one pcm_matrix: an AXI4-Lite register window whose
// coefficients are the matrix gains, delivered to the time-shared matrix
// through its coefficient read port on the audio clock.
//
// This module holds only what is specific to the matrix -- its ID, its CONFIG
// word and the geometry of its bank. The machinery is generic and shared with
// every other core block (docs/architecture_modules.md 4.1):
//   axil_coef_window : AXI4-Lite slave, common header, WSTRB, store requests
//   coef_bank_ram    : shadow + two banks in RAM, COMMIT = copy then swap at
//                      the next frame strobe (Phase 9, P9.A3)
// The store's layout is "rows round-robin over lanes"; for the matrix a row
// is an output (ROW_LEN = N_IN), so register index k = o*N_IN + i IS the
// store index, and no address arithmetic lives here.
//
// Register map (window-relative byte offsets, 32-bit accesses), unchanged
// since Phase 5:
//   0x000  ID       RO  0x4D58_5001  ("MX", matrix, rev 1)
//   0x004  CONFIG   RO  [31:24] N_OUT, [23:16] N_IN,
//                       [15:8] GAIN_WIDTH, [7:0] GAIN_FRAC
//   0x008  CTRL     W   bit0 = COMMIT (shadow -> active)
//                  R   bit0 = BUSY, bit1 = QUEUED
//   0x00C  COMMITS  RO  commits applied since aclk reset (wraps)
//   0x100  GAIN[k]  RW  k = o*N_IN + i (output o, input i), at 0x100 + 4*k.
//                       Signed Q(GAIN_WIDTH-GAIN_FRAC).GAIN_FRAC, read back
//                       sign-extended. With 18/16: 0x10000 = 1.0,
//                       0x08000 = 0.5, 0x3_0000 = -1.0, 0 = mute.
//
// Software writes gains to the shadow, then COMMIT; the matrix then uses the
// complete new bank from one frame on. A COMMIT written while one is in
// flight is queued, so software never has to poll; accesses after a queued
// COMMIT wait until it has launched (axil_coef_window header).
//
// Reset: after aresetn the store loads RESET_GAINS and commits it, so audio
// passes with a known routing before any software runs, and reading GAIN[k]
// reports what is in effect. COMMITS reads 0 after reset.
// -----------------------------------------------------------------------------
module matrix_regs_axil
    import pcm_matrix_pkg::*;
#(
    parameter int N_IN       = 4,
    parameter int N_OUT      = 4,
    parameter int GAIN_WIDTH = 18,
    parameter int GAIN_FRAC  = 16,
    parameter int LANES      = matrix_lanes(N_IN, N_OUT),
    parameter int ADDR_WIDTH = 12,
    parameter logic [N_OUT*N_IN*GAIN_WIDTH-1:0] RESET_GAINS = '0,
    localparam int PASSES = matrix_passes(N_OUT, LANES),
    localparam int DEPTH  = PASSES * N_IN,
    localparam int AW     = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    // ----- AXI4-Lite slave (aclk domain) -----
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [31:0]           s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [31:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    // ----- coefficient read port (mclk domain), to pcm_matrix -----
    input  logic                  mclk,
    input  logic                  frame_i,
    input  logic [AW-1:0]         coef_addr,
    output logic [LANES*GAIN_WIDTH-1:0] coef_data
);

    localparam int NG = N_OUT * N_IN;
    localparam int IW = (NG > 1) ? $clog2(NG) : 1;

    localparam logic [31:0] ID_VALUE = 32'h4D58_5001;
    localparam logic [31:0] CONFIG_VALUE =
        {8'(N_OUT), 8'(N_IN), 8'(GAIN_WIDTH), 8'(GAIN_FRAC)};

    logic                  st_valid, st_ready, st_we, st_rvalid;
    logic [IW-1:0]         st_idx;
    logic [GAIN_WIDTH-1:0] st_wdata, st_rdata;
    logic                  commit, busy, queued;
    logic [31:0]           commits;

    axil_coef_window #(
        .N_COEF (NG), .COEF_WIDTH (GAIN_WIDTH), .ADDR_WIDTH (ADDR_WIDTH),
        .ID_VALUE (ID_VALUE), .CONFIG_VALUE (CONFIG_VALUE)
    ) u_window (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata (s_axi_wdata), .s_axi_wstrb (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid), .s_axi_wready (s_axi_wready),
        .s_axi_bresp (s_axi_bresp), .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata (s_axi_rdata), .s_axi_rresp (s_axi_rresp),
        .s_axi_rvalid (s_axi_rvalid), .s_axi_rready (s_axi_rready),
        .st_valid (st_valid), .st_ready (st_ready), .st_we (st_we),
        .st_idx (st_idx), .st_wdata (st_wdata),
        .st_rvalid (st_rvalid), .st_rdata (st_rdata),
        .commit (commit), .busy (busy), .queued (queued), .commits (commits)
    );

    coef_bank_ram #(
        .W (GAIN_WIDTH), .N_ROWS (N_OUT), .ROW_LEN (N_IN), .LANES (LANES),
        .RESET_COEFS (RESET_GAINS)
    ) u_bank (
        .aclk (aclk), .aresetn (aresetn),
        .st_valid (st_valid), .st_ready (st_ready), .st_we (st_we),
        .st_idx (st_idx), .st_wdata (st_wdata),
        .st_rvalid (st_rvalid), .st_rdata (st_rdata),
        .commit (commit), .busy (busy), .queued (queued), .commits (commits),
        .mclk (mclk), .frame_i (frame_i),
        .rd_addr (coef_addr), .rd_data (coef_data)
    );

endmodule
