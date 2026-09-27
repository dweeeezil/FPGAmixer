// -----------------------------------------------------------------------------
// axil_reg_window.sv
//
// Generic control-plane primitive (Phase 9, P9.4b, decision S2): one AXI4-Lite
// register window of plain READ/WRITE words plus READ-ONLY words, for a block
// whose controls and status live in the AXI clock domain itself (the media
// clock steerer runs on pl_clk0). The third window type, next to
// axil_coef_window (a coefficient bank with COMMIT, crossing to the audio
// clock) and axil_stat_window (read-only snapshots from another clock). It
// knows the window layout, not what the words mean.
//
// Window layout (byte offsets, 32-bit accesses), same header as every window:
//   0x000  ID       RO  ID_VALUE      block type + version
//   0x004  CONFIG   RO  CONFIG_VALUE  block geometry (meaning is per block)
//   0x008  CTRL     RO  0 (reserved)
//   0x00C  WRITES   RO  register writes accepted since aresetn (wraps): lets
//                       software see that its writes landed
//   0x100  RW[k]    RW  k = 0 .. N_RW-1, at 0x100 + 4*k; WSTRB per byte;
//                       reset to RESET_RW
//   0x100 + 4*N_RW + 4*j
//          RO[j]    RO  j = 0 .. N_RO-1 (the binding's status words)
// Writes elsewhere are accepted and ignored (OKAY). Unmapped reads return 0.
//
// No commit and no clock crossing: rw_flat is registered in aclk and used
// there. A block in another clock domain needs axil_coef_window + a store,
// or its own synchronizer -- not this.
// -----------------------------------------------------------------------------
module axil_reg_window #(
    parameter int  N_RW         = 1,
    parameter int  N_RO         = 1,
    parameter int  ADDR_WIDTH   = 12,
    parameter logic [31:0] ID_VALUE     = 32'h0,
    parameter logic [31:0] CONFIG_VALUE = 32'h0,
    parameter logic [N_RW*32-1:0] RESET_RW = '0
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

    output logic [N_RW*32-1:0]    rw_flat,      // RW[k] at [k*32 +: 32]
    input  logic [N_RO*32-1:0]    ro_flat       // RO[j] at [j*32 +: 32]
);

    localparam logic [ADDR_WIDTH-1:0] A_ID     = 'h000;
    localparam logic [ADDR_WIDTH-1:0] A_CONFIG = 'h004;
    localparam logic [ADDR_WIDTH-1:0] A_CTRL   = 'h008;
    localparam logic [ADDR_WIDTH-1:0] A_WRITES = 'h00C;
    localparam int                    A_RW0    = 'h100;
    localparam int                    A_RO0    = 'h100 + 4*N_RW;

    generate
        if (A_RO0 + 4*N_RO > (1 << ADDR_WIDTH))
            $error("axil_reg_window: %0d + %0d words do not fit a %0d-bit window",
                   N_RW, N_RO, ADDR_WIDTH);
    endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    function automatic int rw_index(input logic [ADDR_WIDTH-1:0] a);
        if (int'(a) >= A_RW0 && int'(a) < A_RO0 && a[1:0] == 2'b00)
            return (int'(a) - A_RW0) >> 2;
        return -1;
    endfunction

    function automatic int ro_index(input logic [ADDR_WIDTH-1:0] a);
        if (int'(a) >= A_RO0 && int'(a) < A_RO0 + 4*N_RO && a[1:0] == 2'b00)
            return (int'(a) - A_RO0) >> 2;
        return -1;
    endfunction

    logic [31:0] writes;

    // ----- write channel -----
    always_ff @(posedge aclk) begin
        int k;
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            rw_flat       <= RESET_RW;
            writes        <= '0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            if (!s_axi_bvalid && !s_axi_awready &&
                s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
                k = rw_index(s_axi_awaddr);
                if (k >= 0) begin
                    for (int b = 0; b < 4; b++)
                        if (s_axi_wstrb[b])
                            rw_flat[k*32 + b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                    writes <= writes + 1'b1;
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ----- read channel -----
    always_ff @(posedge aclk) begin
        int k, j;
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
        end else begin
            s_axi_arready <= 1'b0;
            if (!s_axi_rvalid && !s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                k = rw_index(s_axi_araddr);
                j = ro_index(s_axi_araddr);
                if (k >= 0)
                    s_axi_rdata <= rw_flat[k*32 +: 32];
                else if (j >= 0)
                    s_axi_rdata <= ro_flat[j*32 +: 32];
                else case (s_axi_araddr)
                    A_ID:     s_axi_rdata <= ID_VALUE;
                    A_CONFIG: s_axi_rdata <= CONFIG_VALUE;
                    A_CTRL:   s_axi_rdata <= '0;
                    A_WRITES: s_axi_rdata <= writes;
                    default:  s_axi_rdata <= '0;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
