// -----------------------------------------------------------------------------
// axil_stat_window.sv
//
// Generic control-plane primitive: one AXI4-Lite register window of READ-ONLY
// status words for one block (docs/architecture_modules.md 4.1). The
// counterpart of axil_coef_window for data flowing the other way: it knows the
// window layout, not what the words mean. The block's binding supplies ID,
// CONFIG and the words, already brought into aclk as one consistent snapshot
// (coef_bank_handoff with src = the block's clock, dst = aclk).
//
// Window layout (byte offsets, 32-bit accesses), same header as every window:
//   0x000  ID         RO  ID_VALUE      block type + version
//   0x004  CONFIG     RO  CONFIG_VALUE  block geometry (meaning is per block)
//   0x008  CTRL       RO  0 (reserved: there is nothing to control)
//   0x00C  SNAPSHOTS  RO  snapshot sequence number (from the binding): a
//                         changing value proves the words below are live
//   0x100  STAT[k]    RO  k = 0 .. N_STAT-1, at 0x100 + 4*k
// Writes anywhere are accepted and ignored (OKAY). Unmapped reads return 0.
//
// No CLEAR on purpose: counters are free-running and wrap, and software takes
// differences. That needs no second CDC path, and two readers can't reset each
// other's view.
// -----------------------------------------------------------------------------
module axil_stat_window #(
    parameter int  N_STAT       = 8,
    parameter int  ADDR_WIDTH   = 12,
    parameter logic [31:0] ID_VALUE     = 32'h0,
    parameter logic [31:0] CONFIG_VALUE = 32'h0
) (
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

    // ----- status words (aclk domain, one consistent snapshot) -----
    input  logic [N_STAT*32-1:0]  stat_flat,
    input  logic [31:0]           snapshots
);

    localparam logic [ADDR_WIDTH-1:0] A_ID        = 'h000;
    localparam logic [ADDR_WIDTH-1:0] A_CONFIG    = 'h004;
    localparam logic [ADDR_WIDTH-1:0] A_CTRL      = 'h008;
    localparam logic [ADDR_WIDTH-1:0] A_SNAPSHOTS = 'h00C;
    localparam logic [ADDR_WIDTH-1:0] A_STAT0     = 'h100;

    generate
        if ('h100 + 4*N_STAT > (1 << ADDR_WIDTH))
            $error("axil_stat_window: %0d words do not fit a %0d-bit window",
                   N_STAT, ADDR_WIDTH);
    endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    function automatic int stat_index(input logic [ADDR_WIDTH-1:0] a);
        if (a >= A_STAT0 && a < A_STAT0 + 4*N_STAT && a[1:0] == 2'b00)
            return int'((a - A_STAT0) >> 2);
        return -1;
    endfunction

    // ----- write channel: accept and ignore -----
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            if (!s_axi_bvalid && !s_axi_awready &&
                s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ----- read channel -----
    always_ff @(posedge aclk) begin
        int k;
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
        end else begin
            s_axi_arready <= 1'b0;

            if (!s_axi_rvalid && !s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;

                k = stat_index(s_axi_araddr);
                if (k >= 0)
                    s_axi_rdata <= stat_flat[k*32 +: 32];
                else case (s_axi_araddr)
                    A_ID:        s_axi_rdata <= ID_VALUE;
                    A_CONFIG:    s_axi_rdata <= CONFIG_VALUE;
                    A_CTRL:      s_axi_rdata <= '0;
                    A_SNAPSHOTS: s_axi_rdata <= snapshots;
                    default:     s_axi_rdata <= '0;
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
