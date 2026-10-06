// -----------------------------------------------------------------------------
// peak_regs_axil.sv
//
// Control-plane binding for one pcm_peak meter (Phase 13, decision M4): an
// AXI4-Lite register window over the generic axil_coef_window, its store
// being the meter, whose stream input is a mixer_core tap port. The window's
// coefficient semantics read the other way round:
//
//   0x000  ID       RO  0x504B_5001  ("PK", peak meter, rev 1)
//   0x004  CONFIG   RO  [31:24] N (channels), [23:16] TAP (0 input, 1 bus,
//                       2 output: the zone, as the gain windows),
//                       [15:8] sample width (24), [7:0] 0
//   0x008  CTRL     W   bit0 = SNAP: close the current window at the next
//                       frame strobe (the window's COMMIT)
//                  R   bit0 = BUSY (a snapshot in flight), bit1 = QUEUED
//   0x00C  COMMITS  RO  snapshots completed since aclk reset (wraps)
//   0x100  PEAK[c]  RO  channel c's peak over the last closed window, at
//                       0x100 + 4*c: magnitude of the 24-bit sample in
//                       [22:0] (0x7F_FFFF = full scale), bit 23 = 0. Writes
//                       are ignored.
//
// Software: write SNAP, wait for BUSY to clear (at most about one frame,
// 21 us), read PEAK[0..N-1]. Each read covers the frames since the previous
// SNAP, the same frames for every channel, and loses none (pcm_peak.sv). One
// reader only (the OSC server); dB conversion is software's.
// -----------------------------------------------------------------------------
module peak_regs_axil #(
    parameter int N          = 4,
    parameter int TAP        = 0,
    parameter int SW         = 24,
    parameter int ADDR_WIDTH = 12,
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

    // ----- the tapped stream (mclk domain) -----
    input  logic                  mclk,
    input  logic                  frame_i,
    input  logic                  s_valid,
    input  logic [CW-1:0]         s_ch,
    input  logic [SW-1:0]         s_data
);

    localparam logic [31:0] ID_VALUE     = 32'h504B_5001;
    localparam logic [31:0] CONFIG_VALUE = {8'(N), 8'(TAP), 8'(SW), 8'd0};

    generate
        if (N > 255)
            $error("peak_regs_axil: N = %0d does not fit CONFIG[31:24]", N);
        if ('h100 + 4*N > 2**ADDR_WIDTH)
            $error("peak_regs_axil: %0d peaks do not fit the window", N);
    endgenerate

    logic           st_valid, st_ready, st_we, st_rvalid;
    logic [CW-1:0]  st_idx;
    logic [SW-1:0]  st_wdata, st_rdata;
    logic           commit, busy, queued;
    logic [31:0]    commits;

    axil_coef_window #(
        .N_COEF (N), .COEF_WIDTH (SW), .ADDR_WIDTH (ADDR_WIDTH),
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

    pcm_peak #(.N (N), .SW (SW)) u_peak (
        .aclk (aclk), .aresetn (aresetn),
        .st_valid (st_valid), .st_ready (st_ready), .st_we (st_we),
        .st_idx (st_idx), .st_wdata (st_wdata),
        .st_rvalid (st_rvalid), .st_rdata (st_rdata),
        .commit (commit), .busy (busy), .queued (queued), .commits (commits),
        .mclk (mclk), .frame_i (frame_i),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data)
    );

endmodule
