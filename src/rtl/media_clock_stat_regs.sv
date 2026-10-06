// -----------------------------------------------------------------------------
// media_clock_stat_regs.sv
//
// Control-plane binding for one media_clock_meter: its captures in a
// read-only AXI4-Lite window. Holds only what is specific to the meter -- ID,
// CONFIG and the word list; the machinery is generic
// (docs/architecture_modules.md 4.1), as in pcm_link_stat_regs:
//   coef_bank_handoff  (src = mclk, dst = aclk): one consistent snapshot per
//                      frame, all words from the same mclk edge
//   axil_stat_window   : AXI4-Lite slave, common header, read-only words
//
// Register map (window-relative byte offsets, 32-bit reads):
//   0x000  ID           0x4D43_5001  ("MC", media clock, rev 1)
//   0x004  CONFIG       NOMINAL: mclk cycles per reference second (12288000)
//   0x008  CTRL         0
//   0x00C  SNAPSHOTS    snapshot sequence (one per frame while mclk runs)
//   0x100  PPS_COUNT    reference edges seen
//   0x104  CYC_AT_PPS   mclk cycle count at the last edge
//   0x108  CYC_AT_PREV  ... at the edge before it
//   0x10C  FRAMES_AT_PPS frame strobes counted at the last edge
//   0x110  PHASE_AT_PPS mclk cycles since the last frame strobe, at the edge
//   0x114  IMPLAUSIBLE  intervals outside NOMINAL +/- 1000 ppm
//   0x118  CYC_NOW      the free-running mclk count at the snapshot (tells a
//                       live reference from a stopped one)
// Counts wrap; software takes differences modulo 2^32.
// -----------------------------------------------------------------------------
module media_clock_stat_regs #(
    parameter int NOMINAL    = 12_288_000,
    parameter int ADDR_WIDTH = 12
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

    // ----- from media_clock_meter (mclk domain) -----
    input  logic                  mclk,
    input  logic                  mrst_n,
    input  logic                  frame_i,
    input  logic [31:0]           pps_count,
    input  logic [31:0]           cyc_last,
    input  logic [31:0]           cyc_prev,
    input  logic [31:0]           frames_last,
    input  logic [15:0]           phase_last,
    input  logic [31:0]           implausible,
    input  logic [31:0]           cyc_now
);

    localparam int N_STAT = 7;
    localparam int BW     = (N_STAT + 1) * 32;     // words + sequence number

    localparam logic [31:0] ID_VALUE     = 32'h4D43_5001;
    localparam logic [31:0] CONFIG_VALUE = 32'(NOMINAL);

    logic [31:0] seq;
    logic        snap;

    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            seq  <= '0;
            snap <= 1'b0;
        end else begin
            snap <= frame_i;
            if (frame_i) seq <= seq + 1'b1;
        end
    end

    logic [BW-1:0] src_bank, dst_bank;
    assign src_bank = {
        seq,
        cyc_now, implausible, {16'b0, phase_last}, frames_last,
        cyc_prev, cyc_last, pps_count
    };

    logic        h_busy_unused, h_queued_unused;
    logic [31:0] h_commits_unused;

    coef_bank_handoff #(.WIDTH (BW), .RESET_VALUE ('0)) u_handoff (
        .src_clk (mclk), .src_rst_n (mrst_n),
        .src_bank (src_bank), .commit (snap),
        .busy (h_busy_unused), .queued (h_queued_unused),
        .commits (h_commits_unused),
        .dst_clk (aclk), .dst_rst_n (aresetn),
        .dst_bank (dst_bank)
    );

    axil_stat_window #(
        .N_STAT (N_STAT), .ADDR_WIDTH (ADDR_WIDTH),
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
        .stat_flat (dst_bank[N_STAT*32-1:0]),
        .snapshots (dst_bank[N_STAT*32 +: 32])
    );

endmodule
