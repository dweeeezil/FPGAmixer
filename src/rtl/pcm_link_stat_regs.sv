// -----------------------------------------------------------------------------
// pcm_link_stat_regs.sv
//
// Control-plane binding for one pcm_link: its status counters in a read-only
// AXI4-Lite window. Holds only what is specific to the link -- ID, CONFIG, the
// word list and the fill watermarks. The machinery is generic
// (docs/architecture_modules.md 4.1):
//   coef_bank_handoff  (src = mclk, dst = aclk): one consistent snapshot per
//                      frame, all words from the same mclk edge
//   axil_stat_window   : AXI4-Lite slave, common header, read-only words
//
// Register map (window-relative byte offsets, 32-bit reads):
//   0x000  ID         0x4C4B_5001  ("LK", PS<->PL link, rev 1)
//   0x004  CONFIG     [31:24] channels PL->PS, [23:16] channels PS->PL,
//                     [15:0] PS->PL FIFO depth in words
//   0x008  CTRL       0
//   0x00C  SNAPSHOTS  snapshot sequence (one per frame while mclk runs)
//   0x100  FRAMES_RX    frames delivered to the core from the PS
//   0x104  FRAMES_TX    frames queued towards the PS
//   0x108  UNDERRUNS    interruptions of a running PS->PL stream
//   0x10C  STARVED      frames delivered as zeros (nothing ready)
//   0x110  OVERRUNS     frames dropped towards the PS
//   0x114  TID_ERRORS   AXIS beats discarded out of channel sequence
//   0x118  RX_FILL      words in the PS->PL FIFO at the snapshot
//   0x11C  RX_FILL_LOW  lowest RX_FILL seen at a frame strobe since the
//                       stream last started running (0xFFFF before that)
//   0x120  RX_FILL_HIGH highest, same period
//   0x124  FLAGS        bit0 = RX_RUNNING
// Counters are free-running and wrap; software takes differences (see
// axil_stat_window: there is no CLEAR).
// -----------------------------------------------------------------------------
module pcm_link_stat_regs #(
    parameter int N_CH_RX    = 8,     // PS -> PL channels
    parameter int N_CH_TX    = 8,     // PL -> PS channels
    parameter int FIFO_WORDS = 64,
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

    // ----- from pcm_link (mclk domain) -----
    input  logic                  mclk,
    input  logic                  mrst_n,
    input  logic                  frame_i,
    input  logic [31:0]           frames_rx,
    input  logic [31:0]           frames_tx,
    input  logic [31:0]           underruns,
    input  logic [31:0]           starved,
    input  logic [31:0]           overruns,
    input  logic [31:0]           tid_errors,
    input  logic [15:0]           rx_fill,
    input  logic                  rx_running
);

    localparam int N_STAT = 10;
    localparam int BW     = (N_STAT + 1) * 32;     // words + sequence number

    localparam logic [31:0] ID_VALUE     = 32'h4C4B_5001;
    localparam logic [31:0] CONFIG_VALUE =
        {8'(N_CH_TX), 8'(N_CH_RX), 16'(FIFO_WORDS)};

    // ----- mclk: watermarks, sequence, snapshot request -----
    logic [15:0] fill_low, fill_high;
    logic [31:0] seq;
    logic        snap, running_q;

    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            fill_low  <= 16'hFFFF;
            fill_high <= '0;
            seq       <= '0;
            snap      <= 1'b0;
            running_q <= 1'b0;
        end else begin
            snap <= 1'b0;
            // The link updates its counters on the strobe edge; snapshot one
            // cycle later so the words include that frame.
            if (frame_i) begin
                running_q <= rx_running;
                snap      <= 1'b1;
                seq       <= seq + 1'b1;
                if (rx_running && !running_q) begin
                    fill_low  <= rx_fill;
                    fill_high <= rx_fill;
                end else if (rx_running) begin
                    if (rx_fill < fill_low)  fill_low  <= rx_fill;
                    if (rx_fill > fill_high) fill_high <= rx_fill;
                end
            end
        end
    end

    logic [BW-1:0] src_bank, dst_bank;
    assign src_bank = {
        seq,
        {31'b0, rx_running},
        {16'b0, fill_high},
        {16'b0, fill_low},
        {16'b0, rx_fill},
        tid_errors, overruns, starved, underruns, frames_tx, frames_rx
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
