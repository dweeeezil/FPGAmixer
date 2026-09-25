// -----------------------------------------------------------------------------
// axil_coef_window.sv
//
// Generic control-plane primitive: one AXI4-Lite register window for one core
// block's coefficient bank (docs/architecture_modules.md 4.1). It knows the
// window layout and the shadow bank, not what the coefficients mean: the block
// wrapper supplies ID/CONFIG and the reset bank, and pairs this with a
// coef_bank_handoff to reach the audio clock.
//
// Window layout (byte offsets, 32-bit accesses) -- identical for every block,
// so software can discover and drive any of them the same way:
//   0x000  ID       RO  ID_VALUE      block type + version
//   0x004  CONFIG   RO  CONFIG_VALUE  block geometry (meaning is per block)
//   0x008  CTRL     W   bit0 = COMMIT (write 1: pulse `commit`)
//                  R   bit0 = BUSY, bit1 = QUEUED (from the handoff)
//   0x00C  COMMITS  RO  commits completed (from the handoff)
//   0x100  COEF[k]  RW  k = 0 .. N_COEF-1, at 0x100 + 4*k. COEF_WIDTH bits,
//                       signed: reads return the value sign-extended to 32.
// Unmapped addresses read 0 and ignore writes (OKAY response). WSTRB is
// honoured per byte.
//
// shadow_flat packs COEF[k] at [k*COEF_WIDTH +: COEF_WIDTH]. commit pulses for
// one aclk cycle, one cycle after the CTRL write, so the shadow bank it
// accompanies already includes every write completed before the COMMIT.
// -----------------------------------------------------------------------------
module axil_coef_window #(
    parameter int  N_COEF       = 16,
    parameter int  COEF_WIDTH   = 18,
    parameter int  ADDR_WIDTH   = 12,
    parameter logic [31:0] ID_VALUE     = 32'h0,
    parameter logic [31:0] CONFIG_VALUE = 32'h0,
    parameter logic [N_COEF*COEF_WIDTH-1:0] RESET_COEFS = '0
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

    // ----- to/from the handoff (aclk domain) -----
    output logic [N_COEF*COEF_WIDTH-1:0] shadow_flat,
    output logic                  commit,
    input  logic                  busy,
    input  logic                  queued,
    input  logic [31:0]           commits
);

    localparam logic [ADDR_WIDTH-1:0] A_ID      = 'h000;
    localparam logic [ADDR_WIDTH-1:0] A_CONFIG  = 'h004;
    localparam logic [ADDR_WIDTH-1:0] A_CTRL    = 'h008;
    localparam logic [ADDR_WIDTH-1:0] A_COMMITS = 'h00C;
    localparam logic [ADDR_WIDTH-1:0] A_COEF0   = 'h100;

    // The coefficient array must fit in the window.
    generate
        if ('h100 + 4*N_COEF > (1 << ADDR_WIDTH))
            $error("axil_coef_window: %0d coefficients do not fit a %0d-bit window",
                   N_COEF, ADDR_WIDTH);
    endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    logic [COEF_WIDTH-1:0] shadow [N_COEF];

    genvar gs;
    generate
        for (gs = 0; gs < N_COEF; gs++)
            assign shadow_flat[gs*COEF_WIDTH +: COEF_WIDTH] = shadow[gs];
    endgenerate

    // Coefficient index for an address in the COEF array, or -1 if outside it.
    function automatic int coef_index(input logic [ADDR_WIDTH-1:0] a);
        if (a >= A_COEF0 && a < A_COEF0 + 4*N_COEF && a[1:0] == 2'b00)
            return int'((a - A_COEF0) >> 2);
        return -1;
    endfunction

    function automatic logic [31:0] apply_strb(input logic [31:0] old_v,
                                               input logic [31:0] new_v,
                                               input logic [3:0]  strb);
        logic [31:0] r;
        for (int b = 0; b < 4; b++)
            r[b*8 +: 8] = strb[b] ? new_v[b*8 +: 8] : old_v[b*8 +: 8];
        return r;
    endfunction

    // ----- write channel -----
    always_ff @(posedge aclk) begin
        int k;
        logic [31:0] merged;

        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            for (int j = 0; j < N_COEF; j++)
                shadow[j] <= RESET_COEFS[j*COEF_WIDTH +: COEF_WIDTH];
            commit <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            commit        <= 1'b0;

            // Accept a write when address and data are both present. The
            // !awready guard stops a second accept on the handshake cycle.
            if (!s_axi_bvalid && !s_axi_awready &&
                s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;

                k = coef_index(s_axi_awaddr);
                if (k >= 0) begin
                    merged = apply_strb(
                        32'(signed'(shadow[k])), s_axi_wdata, s_axi_wstrb);
                    shadow[k] <= merged[COEF_WIDTH-1:0];
                end else if (s_axi_awaddr == A_CTRL &&
                             s_axi_wstrb[0] && s_axi_wdata[0]) begin
                    commit <= 1'b1;
                end
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

                k = coef_index(s_axi_araddr);
                if (k >= 0)
                    s_axi_rdata <= 32'(signed'(shadow[k]));
                else case (s_axi_araddr)
                    A_ID:      s_axi_rdata <= ID_VALUE;
                    A_CONFIG:  s_axi_rdata <= CONFIG_VALUE;
                    A_CTRL:    s_axi_rdata <= {30'b0, queued, busy};
                    A_COMMITS: s_axi_rdata <= commits;
                    default:   s_axi_rdata <= '0;
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
