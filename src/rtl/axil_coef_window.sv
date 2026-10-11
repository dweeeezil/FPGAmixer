// -----------------------------------------------------------------------------
// axil_coef_window.sv
//
// Generic control-plane primitive: one AXI4-Lite register window for one core
// block's coefficient bank (docs/architecture_modules.md 4.1). It knows the
// window layout, not what the coefficients mean or where they are kept: the
// block binding supplies ID/CONFIG, and pairs this with a coefficient STORE
// (coef_bank_ram since Phase 9: shadow in RAM, two banks, swap at the frame).
//
// Window layout (byte offsets, 32-bit accesses) -- identical for every block,
// so software can discover and drive any of them the same way:
//   0x000  ID       RO  ID_VALUE      block type + version
//   0x004  CONFIG   RO  CONFIG_VALUE  block geometry (meaning is per block)
//   0x008  CTRL     W   bit0 = COMMIT (write 1: pulse `commit`)
//                  R   bit0 = BUSY, bit1 = QUEUED (from the store)
//   0x00C  COMMITS  RO  commits completed (from the store)
//   0x100  COEF[k]  RW  k = 0 .. N_COEF-1, at 0x100 + 4*k. COEF_WIDTH bits,
//                       signed: reads return the value sign-extended to 32
//                       (COEF_SIGNED = 0, Phase 15: unsigned, zero-extended,
//                       for tables such as the patch's port numbers).
// Unmapped addresses read 0 and ignore writes (OKAY response). WSTRB is
// honoured per byte.
//
// Phase 9 (P9.A4): the coefficients moved from a register bank in this module
// to the store, reached through its request interface (st_*). The register
// map above did not change. What software may notice is only timing:
//   - a COEF access takes a few cycles more (a write is a read-modify-write,
//     which is how WSTRB is kept);
//   - the store holds requests off while it copies a bank (N_COEF cycles) and
//     while a COMMIT is queued, so a COMMIT contains exactly the writes whose
//     responses came back before it. An AXI access simply waits that long
//     (at most about one frame plus a copy, ~22 us at 12 x 12).
// commit pulses for one cycle when the CTRL write is accepted; every earlier
// coefficient write has completed in the store by then (B responses are
// only sent once it has).
// -----------------------------------------------------------------------------
module axil_coef_window #(
    parameter int  N_COEF       = 16,
    parameter int  COEF_WIDTH   = 18,
    parameter int  ADDR_WIDTH   = 12,
    parameter logic [31:0] ID_VALUE     = 32'h0,
    parameter logic [31:0] CONFIG_VALUE = 32'h0,
    parameter bit  COEF_SIGNED  = 1'b1,
    localparam int IW = (N_COEF > 1) ? $clog2(N_COEF) : 1
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

    // ----- to/from the coefficient store (aclk domain) -----
    output logic                  st_valid,
    input  logic                  st_ready,
    output logic                  st_we,
    output logic [IW-1:0]         st_idx,
    output logic [COEF_WIDTH-1:0] st_wdata,
    input  logic                  st_rvalid,
    input  logic [COEF_WIDTH-1:0] st_rdata,

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

    // A stored coefficient as a 32-bit register value.
    function automatic logic [31:0] widen(input logic [COEF_WIDTH-1:0] v);
        return COEF_SIGNED ? 32'(signed'(v)) : 32'(v);
    endfunction

    // ----- one FSM for both channels: the store takes one request at a time --
    typedef enum logic [2:0] { S_IDLE, S_RD, S_RWAIT, S_WR } state_t;
    state_t        state;
    logic          op_write;          // the COEF access in flight is an AXI write
    logic [31:0]   w_data;
    logic [3:0]    w_strb;

    assign st_valid = (state == S_RD) || (state == S_WR);
    assign st_we    = (state == S_WR);

    always_ff @(posedge aclk) begin
        int k;
        logic [31:0] merged;

        if (!aresetn) begin
            state         <= S_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
            commit        <= 1'b0;
            op_write      <= 1'b0;
            st_idx        <= '0;
            st_wdata      <= '0;
            w_data        <= '0;
            w_strb        <= '0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;
            commit        <= 1'b0;

            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

            case (state)
                S_IDLE: begin
                    // Writes first. The !awready / !arready guards stop a
                    // second accept on the handshake cycle.
                    if (!s_axi_bvalid && !s_axi_awready &&
                        s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        k = coef_index(s_axi_awaddr);
                        if (k >= 0) begin
                            op_write <= 1'b1;
                            st_idx   <= IW'(k);
                            w_data   <= s_axi_wdata;
                            w_strb   <= s_axi_wstrb;
                            state    <= S_RD;
                        end else begin
                            if (s_axi_awaddr == A_CTRL &&
                                s_axi_wstrb[0] && s_axi_wdata[0])
                                commit <= 1'b1;
                            s_axi_bvalid <= 1'b1;
                        end
                    end else if (!s_axi_rvalid && !s_axi_arready && s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        k = coef_index(s_axi_araddr);
                        if (k >= 0) begin
                            op_write <= 1'b0;
                            st_idx   <= IW'(k);
                            state    <= S_RD;
                        end else begin
                            s_axi_rvalid <= 1'b1;
                            case (s_axi_araddr)
                                A_ID:      s_axi_rdata <= ID_VALUE;
                                A_CONFIG:  s_axi_rdata <= CONFIG_VALUE;
                                A_CTRL:    s_axi_rdata <= {30'b0, queued, busy};
                                A_COMMITS: s_axi_rdata <= commits;
                                default:   s_axi_rdata <= '0;
                            endcase
                        end
                    end
                end

                S_RD:                               // read the current value
                    if (st_ready) state <= S_RWAIT;

                S_RWAIT:
                    if (st_rvalid) begin
                        if (op_write) begin
                            merged   = apply_strb(widen(st_rdata), w_data, w_strb);
                            st_wdata <= merged[COEF_WIDTH-1:0];
                            state    <= S_WR;
                        end else begin
                            s_axi_rdata  <= widen(st_rdata);
                            s_axi_rvalid <= 1'b1;
                            state        <= S_IDLE;
                        end
                    end

                S_WR:                               // write the merged value
                    if (st_ready) begin
                        s_axi_bvalid <= 1'b1;
                        state        <= S_IDLE;
                    end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
