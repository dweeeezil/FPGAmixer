// -----------------------------------------------------------------------------
// gain_regs_axil.sv
//
// Control-plane binding for one pcm_gain (Phase 12): an AXI4-Lite register
// window whose coefficients are the stage's per-channel gains, delivered to
// the gain stage through its coefficient read port on the audio clock.
//
// Like matrix_regs_axil, it holds only what is specific to the block -- its
// ID, its CONFIG word and the geometry of its bank -- over the generic parts
// (docs/architecture_modules.md 4.1):
//   axil_coef_window : AXI4-Lite slave, common header, WSTRB, store requests
//   coef_bank_ram    : shadow + two banks in RAM, COMMIT = copy then swap at
//                      the next frame strobe
// The bank is N rows of length 1 on one lane, so register index c IS the
// channel and the read port's word c is channel c's gain (pcm_gain.sv).
//
// The core has three gain stages (input, bus, output levels) with the same
// binding. TAP says which one this window serves, so software can check it
// opened the window it meant to and not just a window of the right kind
// (decision L6).
//
// Register map (window-relative byte offsets, 32-bit accesses):
//   0x000  ID       RO  0x474E_5001  ("GN", gain stage, rev 1)
//   0x004  CONFIG   RO  [31:24] N (channels), [23:16] TAP (0 input,
//                       1 bus, 2 output), [15:8] GAIN_WIDTH, [7:0] GAIN_FRAC
//   0x008  CTRL     W   bit0 = COMMIT (shadow -> active)
//                  R   bit0 = BUSY, bit1 = QUEUED
//   0x00C  COMMITS  RO  commits applied since aclk reset (wraps)
//   0x100  GAIN[c]  RW  channel c, at 0x100 + 4*c. Signed
//                       Q(GAIN_WIDTH-GAIN_FRAC).GAIN_FRAC, read back
//                       sign-extended (18/16: 0x10000 = 1.0, 0 = mute).
//
// Reset: after aresetn the store loads RESET_GAINS (unity in fpgamixer_top)
// and commits it, so audio passes before any software runs.
// -----------------------------------------------------------------------------
module gain_regs_axil #(
    parameter int N          = 4,
    parameter int TAP        = 0,
    parameter int GAIN_WIDTH = 18,
    parameter int GAIN_FRAC  = 16,
    parameter int ADDR_WIDTH = 12,
    parameter logic [N*GAIN_WIDTH-1:0] RESET_GAINS = '0,
    localparam int CW = (N > 1) ? $clog2(N) : 1
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

    // ----- coefficient read port (mclk domain), to pcm_gain -----
    input  logic                  mclk,
    input  logic                  frame_i,
    input  logic [CW-1:0]         coef_addr,
    output logic [GAIN_WIDTH-1:0] coef_data
);

    localparam int IW = CW;

    localparam logic [31:0] ID_VALUE = 32'h474E_5001;
    localparam logic [31:0] CONFIG_VALUE =
        {8'(N), 8'(TAP), 8'(GAIN_WIDTH), 8'(GAIN_FRAC)};

    generate
        if (N > 255)
            $error("gain_regs_axil: N = %0d does not fit CONFIG[31:24]", N);
        if ('h100 + 4*N > 2**ADDR_WIDTH)
            $error("gain_regs_axil: %0d gains do not fit the window", N);
    endgenerate

    logic                  st_valid, st_ready, st_we, st_rvalid;
    logic [IW-1:0]         st_idx;
    logic [GAIN_WIDTH-1:0] st_wdata, st_rdata;
    logic                  commit, busy, queued;
    logic [31:0]           commits;

    axil_coef_window #(
        .N_COEF (N), .COEF_WIDTH (GAIN_WIDTH), .ADDR_WIDTH (ADDR_WIDTH),
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
        .W (GAIN_WIDTH), .N_ROWS (N), .ROW_LEN (1), .LANES (1),
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
