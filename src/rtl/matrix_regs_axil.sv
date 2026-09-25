// -----------------------------------------------------------------------------
// matrix_regs_axil.sv
//
// Control-plane binding for one pcm_matrix: an AXI4-Lite register window whose
// coefficients are the matrix gains, handed across to the audio clock.
//
// This module holds only what is specific to the matrix -- its ID, its CONFIG
// word and its bank size. The machinery is generic and shared with every other
// core block (docs/architecture_modules.md 4.1):
//   axil_coef_window  : AXI4-Lite slave, common header, shadow bank
//   coef_bank_handoff : COMMIT + CDC, whole bank lands on one mclk edge
//
// Register map (window-relative byte offsets, 32-bit accesses):
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
// Software writes gains to the shadow bank, then COMMIT; pcm_matrix then sees
// the complete new bank from one frame on. A COMMIT written while one is in
// flight is queued, so software never has to poll.
//
// Reset: both banks take RESET_GAINS, so audio passes with a known routing
// before any software runs, and reading GAIN[k] reports what is in effect.
// -----------------------------------------------------------------------------
module matrix_regs_axil #(
    parameter int N_IN       = 4,
    parameter int N_OUT      = 4,
    parameter int GAIN_WIDTH = 18,
    parameter int GAIN_FRAC  = 16,
    parameter int ADDR_WIDTH = 12,
    parameter logic [N_OUT*N_IN*GAIN_WIDTH-1:0] RESET_GAINS = '0
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

    // ----- Active gains (mclk domain), to pcm_matrix.gains_flat -----
    input  logic                  mclk,
    input  logic                  mrst_n,
    output logic [N_OUT*N_IN*GAIN_WIDTH-1:0] gains_flat
);

    localparam int NG = N_OUT * N_IN;

    localparam logic [31:0] ID_VALUE = 32'h4D58_5001;
    localparam logic [31:0] CONFIG_VALUE =
        {8'(N_OUT), 8'(N_IN), 8'(GAIN_WIDTH), 8'(GAIN_FRAC)};

    logic [NG*GAIN_WIDTH-1:0] shadow;
    logic                     commit, busy, queued;
    logic [31:0]              commits;

    axil_coef_window #(
        .N_COEF (NG), .COEF_WIDTH (GAIN_WIDTH), .ADDR_WIDTH (ADDR_WIDTH),
        .ID_VALUE (ID_VALUE), .CONFIG_VALUE (CONFIG_VALUE),
        .RESET_COEFS (RESET_GAINS)
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
        .shadow_flat (shadow), .commit (commit),
        .busy (busy), .queued (queued), .commits (commits)
    );

    coef_bank_handoff #(
        .WIDTH (NG*GAIN_WIDTH), .RESET_VALUE (RESET_GAINS)
    ) u_handoff (
        .src_clk (aclk), .src_rst_n (aresetn),
        .src_bank (shadow), .commit (commit),
        .busy (busy), .queued (queued), .commits (commits),
        .dst_clk (mclk), .dst_rst_n (mrst_n),
        .dst_bank (gains_flat)
    );

endmodule
