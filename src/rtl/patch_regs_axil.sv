// -----------------------------------------------------------------------------
// patch_regs_axil.sv
//
// Control-plane binding for one side of the I/O patch (Phase 15, decision
// CS10): an AXI4-Lite register window whose coefficients are the patch table,
// delivered to pcm_patch2stream (input patch: source per input channel) or
// pcm_stream2patch (output patch: destination per output channel) through
// its coefficient read port on the audio clock.
//
// Like gain_regs_axil, it holds only what is specific to the block -- its ID,
// its CONFIG word and the geometry of its bank -- over the generic parts
// (docs/architecture_modules.md 4.1):
//   axil_coef_window : AXI4-Lite slave, common header, WSTRB, store requests
//                      (unsigned entries: COEF_SIGNED = 0)
//   coef_bank_ram    : shadow + two banks in RAM, COMMIT = copy then swap at
//                      the next frame strobe, so a repatch lands whole on one
//                      frame
// The bank is N rows of length 1 on one lane: register index c IS the channel
// and the read port's word c is channel c's entry.
//
// An entry is the OSC value (standard "I/O patch"): 0 = None, p + 1 = I/O
// port p (p < P). Larger values are kept as written and mean None to the
// block; the server never writes them. DIR says which side this window is, so
// software can check it opened the window it meant to.
//
// Register map (window-relative byte offsets, 32-bit accesses):
//   0x000  ID        RO  0x5054_5001  ("PT", patch table, rev 1)
//   0x004  CONFIG    RO  [31:24] N (channels), [23:16] P (I/O ports),
//                        [15:8] DIR (0 input: sources, 1 output:
//                        destinations), [7:0] ENTRY_WIDTH
//   0x008  CTRL      W   bit0 = COMMIT (shadow -> active)
//                   R   bit0 = BUSY, bit1 = QUEUED
//   0x00C  COMMITS   RO  commits applied since aclk reset (wraps)
//   0x100  ENTRY[c]  RW  channel c, at 0x100 + 4*c; ENTRY_WIDTH bits,
//                        unsigned, read back zero-extended.
//
// Reset: after aresetn the store loads RESET_TABLE and commits it
// (fpgamixer_top: all None in PS builds, decision CS5).
// -----------------------------------------------------------------------------
module patch_regs_axil #(
    parameter int N          = 20,
    parameter int P          = 20,
    parameter int DIR        = 0,
    parameter int ADDR_WIDTH = 12,
    parameter logic [N*$clog2(P+1)-1:0] RESET_TABLE = '0,
    localparam int PW = $clog2(P + 1),          // an entry: 0 .. P
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

    // ----- coefficient read port (mclk domain), to the patch converter -----
    input  logic                  mclk,
    input  logic                  frame_i,
    input  logic [CW-1:0]         coef_addr,
    output logic [PW-1:0]         coef_data
);

    localparam logic [31:0] ID_VALUE = 32'h5054_5001;
    localparam logic [31:0] CONFIG_VALUE = {8'(N), 8'(P), 8'(DIR), 8'(PW)};

    generate
        if (N > 255 || P > 255)
            $error("patch_regs_axil: N = %0d, P = %0d do not fit CONFIG", N, P);
        if ('h100 + 4*N > 2**ADDR_WIDTH)
            $error("patch_regs_axil: %0d entries do not fit the window", N);
    endgenerate

    logic          st_valid, st_ready, st_we, st_rvalid;
    logic [CW-1:0] st_idx;
    logic [PW-1:0] st_wdata, st_rdata;
    logic          commit, busy, queued;
    logic [31:0]   commits;

    axil_coef_window #(
        .N_COEF (N), .COEF_WIDTH (PW), .ADDR_WIDTH (ADDR_WIDTH),
        .ID_VALUE (ID_VALUE), .CONFIG_VALUE (CONFIG_VALUE), .COEF_SIGNED (1'b0)
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
        .W (PW), .N_ROWS (N), .ROW_LEN (1), .LANES (1),
        .RESET_COEFS (RESET_TABLE)
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
