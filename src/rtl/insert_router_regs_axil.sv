// -----------------------------------------------------------------------------
// insert_router_regs_axil.sv
//
// The insert router's control-plane binding: ONE AXI4-Lite window for every
// routing table (all RETURN and SOURCE entries, insert_router_pkg), ONE
// COMMIT, so a whole edit -- several entries -- lands in one frame (the
// user's Q3, 2026-10-31). The library's generic parts:
//   axil_coef_window : AXI4-Lite slave, common header, WSTRB, store requests
//   coef_bank_ram    : shadow + two banks, COMMIT = copy, then swap on
//                      frame_i (the router's tab_swap); PORTS = 3 + NP read
//                      ports, one per table reader, all swapping together
//
// Register map (window-relative byte offsets, 32-bit accesses):
//   0x000  ID       RO  0x4952_5001  ("IR", insert router, rev 1)
//   0x004  CONFIG   RO  [31:24] K (most inserts per channel),
//                       [23:16] S (slots per pool), [15:8] NP (pools),
//                       [7:0] delay_frames(K) (every insert point's delay)
//   0x008  CTRL     W   bit0 = COMMIT; R bit0 = BUSY, bit1 = QUEUED
//   0x00C  COMMITS  RO  commits applied since aclk reset (wraps)
//   0x100  ENTRY[k] RW  k = 0 .. N_TAB-1, at 0x100 + 4*k: an 18-bit entry
//                       (insert_router_pkg: kind, sel, age, idx), read back
//                       zero-extended. Layout: RETURN inputs, buses, outputs
//                       (one per channel, the mixer's N each), then SOURCE
//                       pool 0 slots 0 .. S-1, pool 1, ...
// Reset: every entry 0 (all channels dry, all slots silent), committed.
// -----------------------------------------------------------------------------
module insert_router_regs_axil
    import insert_router_pkg::*;
#(
    parameter int N_I = 20,
    parameter int N_B = 20,
    parameter int N_O = 20,
    parameter int K   = 8,
    parameter int S   = 32,
    parameter int NP  = 1,
    parameter int ADDR_WIDTH = 12,
    localparam int NR    = 3 + NP,
    localparam int N_TAB = N_I + N_B + N_O + NP * S,
    localparam int TAW   = (N_TAB > 1) ? $clog2(N_TAB) : 1
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

    // ----- table read ports (mclk domain), to the router -----
    input  logic                  mclk,
    input  logic                  frame_i,      // the router's tab_swap
    input  logic [NR*TAW-1:0]     tab_addr,
    output logic [NR*EW-1:0]      tab_data
);

    localparam logic [31:0] ID_VALUE     = 32'h4952_5001;   // "IR", insert router, rev 1
    localparam logic [31:0] CONFIG_VALUE = {8'(K), 8'(S), 8'(NP), 8'(delay_frames(K))};

    generate
        if (K > 255 || S > 255 || NP > 255)
            $error("insert_router_regs_axil: K/S/NP must fit CONFIG's bytes");
        if ('h100 + 4*N_TAB > 2**ADDR_WIDTH)
            $error("insert_router_regs_axil: %0d entries do not fit the window", N_TAB);
    endgenerate

    logic           st_valid, st_ready, st_we, st_rvalid;
    logic [TAW-1:0] st_idx;
    logic [EW-1:0]  st_wdata, st_rdata;
    logic           commit, busy, queued;
    logic [31:0]    commits;

    axil_coef_window #(
        .N_COEF (N_TAB), .COEF_WIDTH (EW), .ADDR_WIDTH (ADDR_WIDTH),
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
        .W (EW), .N_ROWS (N_TAB), .ROW_LEN (1), .LANES (1), .PORTS (NR),
        .RESET_COEFS ('0)
    ) u_bank (
        .aclk (aclk), .aresetn (aresetn),
        .st_valid (st_valid), .st_ready (st_ready), .st_we (st_we),
        .st_idx (st_idx), .st_wdata (st_wdata),
        .st_rvalid (st_rvalid), .st_rdata (st_rdata),
        .commit (commit), .busy (busy), .queued (queued), .commits (commits),
        .mclk (mclk), .frame_i (frame_i),
        .rd_addr (tab_addr), .rd_data (tab_data)
    );

endmodule
