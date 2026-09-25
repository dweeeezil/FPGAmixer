// -----------------------------------------------------------------------------
// matrix_regs_axil.sv
//
// Phase 5: AXI4-Lite register block that lets the PS set the pcm_matrix
// crosspoint gains at runtime, and hands them across to the audio clock.
//
// Two clock domains:
//   aclk -- the AXI side (pl_clk0, 100 MHz, from the PS via M_AXI_HPM0_LPD)
//   mclk -- the audio side (12.288 MHz MMCM), where pcm_matrix lives
//
// Software model: write any number of SHADOW gains, then write CTRL.COMMIT.
// The whole shadow bank is then copied into the ACTIVE bank that pcm_matrix
// reads, in a single mclk edge. pcm_matrix samples gains on the frame edge, so
// every frame sees either the complete old bank or the complete new bank --
// multi-crosspoint changes (a route swap, a crossfade step) are atomic.
//
// Register map (byte offsets; 32-bit accesses):
//   0x000  ID       RO  0x4D58_5001  ("MX", phase 5, rev 1)
//   0x004  CONFIG   RO  [31:24] N outputs, [23:16] N inputs,
//                       [15:8] GAIN_WIDTH, [7:0] GAIN_FRAC
//   0x008  CTRL     W   bit0 = COMMIT (write 1: shadow -> active)
//                  R   bit0 = BUSY   (a commit is crossing to mclk)
//                       bit1 = QUEUED (a commit arrived while BUSY)
//   0x00C  COMMITS  RO  commits applied since aclk reset (wraps)
//   0x100  GAIN[k]  RW  k = o*N + i (output o, input i), at 0x100 + 4*k.
//                       Signed Q(GAIN_WIDTH-GAIN_FRAC).GAIN_FRAC in the low
//                       GAIN_WIDTH bits; reads return it sign-extended. With
//                       the defaults (18/16): 0x10000 = 1.0, 0x08000 = 0.5,
//                       0x3_0000 = -1.0, 0 = mute. Range [-2.0, 2.0).
// Unmapped addresses read 0 and ignore writes (OKAY response). WSTRB is
// honoured per byte.
//
// Software never has to poll: a COMMIT written while BUSY is remembered
// (QUEUED) and launched as soon as the previous one completes, snapshotting
// the shadow bank as it is at that moment.
//
// CDC -- the only paths between the domains:
//   1. req_tgl  (aclk) -> 2FF sync -> mclk       toggle request
//   2. ack_tgl  (mclk) -> 2FF sync -> aclk       toggle acknowledge
//   3. xfer_bank (aclk) -> active_bank (mclk)    multi-bit, captured by an
//      enable derived from the synchronized request (MCP formulation).
//      xfer_bank is loaded on the same aclk edge that flips req_tgl and holds
//      until the ack comes back, so it has been stable for >= 2 mclk periods
//      (> 160 ns) when mclk captures it. The XDC bounds this path with
//      set_max_delay -datapath_only; it must stay far below 160 ns.
// BUSY is DERIVED (req_tgl != synced ack_tgl) rather than stored, so the
// handshake heals itself if one domain is reset without the other: the mclk
// side just performs one extra copy and re-acks.
//
// Reset: active_bank resets to RESET_GAINS (in mclk), so audio passes with a
// known routing before any software runs. The shadow bank resets to the same
// values, so reading GAIN[k] before any write reports what is in effect.
// -----------------------------------------------------------------------------
module matrix_regs_axil #(
    parameter int N          = 4,
    parameter int GAIN_WIDTH = 18,
    parameter int GAIN_FRAC  = 16,
    parameter int ADDR_WIDTH = 12,
    parameter logic [N*N*GAIN_WIDTH-1:0] RESET_GAINS = '0
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

    // ----- Active gains (mclk domain) -----
    input  logic                  mclk,
    input  logic                  mrst_n,
    output logic [N*N*GAIN_WIDTH-1:0] gains_flat
);

    localparam int NG = N * N;

    localparam logic [31:0] ID_VALUE = 32'h4D58_5001;
    localparam logic [31:0] CONFIG_VALUE =
        {8'(N), 8'(N), 8'(GAIN_WIDTH), 8'(GAIN_FRAC)};

    localparam logic [ADDR_WIDTH-1:0] A_ID      = 'h000;
    localparam logic [ADDR_WIDTH-1:0] A_CONFIG  = 'h004;
    localparam logic [ADDR_WIDTH-1:0] A_CTRL    = 'h008;
    localparam logic [ADDR_WIDTH-1:0] A_COMMITS = 'h00C;
    localparam logic [ADDR_WIDTH-1:0] A_GAIN0   = 'h100;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // =========================================================================
    // aclk domain
    // =========================================================================
    logic [GAIN_WIDTH-1:0] shadow [NG];
    logic [NG*GAIN_WIDTH-1:0] shadow_flat;

    genvar gs;
    generate
        for (gs = 0; gs < NG; gs++)
            assign shadow_flat[gs*GAIN_WIDTH +: GAIN_WIDTH] = shadow[gs];
    endgenerate

    // Gain index for an address in the gain window, or -1 if outside it.
    function automatic int gain_index(input logic [ADDR_WIDTH-1:0] a);
        if (a >= A_GAIN0 && a < A_GAIN0 + 4*NG && a[1:0] == 2'b00)
            return int'((a - A_GAIN0) >> 2);
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

    // ----- Handshake state -----
    (* ASYNC_REG = "TRUE" *) logic ack_s1, ack_s2;
    logic req_tgl, queued, busy, busy_q;
    logic [NG*GAIN_WIDTH-1:0] xfer_bank;
    logic [31:0] commits;
    logic ack_tgl;  // mclk domain, declared here for the synchronizer

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            ack_s1 <= 1'b0;
            ack_s2 <= 1'b0;
        end else begin
            ack_s1 <= ack_tgl;
            ack_s2 <= ack_s1;
        end
    end

    assign busy = (req_tgl != ack_s2);

    // ----- AXI write channel + commit launcher -----
    logic commit_wr;

    always_ff @(posedge aclk) begin
        int k;
        logic [31:0] merged;

        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            for (int j = 0; j < NG; j++)
                shadow[j] <= RESET_GAINS[j*GAIN_WIDTH +: GAIN_WIDTH];
            commit_wr <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            commit_wr     <= 1'b0;

            // Accept a write when address and data are both present. The
            // !awready guard stops a second accept on the handshake cycle.
            if (!s_axi_bvalid && !s_axi_awready &&
                s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;

                k = gain_index(s_axi_awaddr);
                if (k >= 0) begin
                    merged = apply_strb(
                        32'(signed'(shadow[k])), s_axi_wdata, s_axi_wstrb);
                    shadow[k] <= merged[GAIN_WIDTH-1:0];
                end else if (s_axi_awaddr == A_CTRL &&
                             s_axi_wstrb[0] && s_axi_wdata[0]) begin
                    commit_wr <= 1'b1;
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // commit_wr is registered, so a launch always snapshots a shadow bank
    // that includes every write completed before the COMMIT.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            req_tgl   <= 1'b0;
            queued    <= 1'b0;
            busy_q    <= 1'b0;
            commits   <= '0;
            xfer_bank <= RESET_GAINS;
        end else begin
            busy_q <= busy;
            if (busy_q && !busy)
                commits <= commits + 1'b1;

            if (commit_wr || queued) begin
                if (!busy) begin
                    xfer_bank <= shadow_flat;
                    req_tgl   <= ~req_tgl;
                    queued    <= 1'b0;
                end else begin
                    queued    <= 1'b1;
                end
            end
        end
    end

    // ----- AXI read channel -----
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

                k = gain_index(s_axi_araddr);
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

    // =========================================================================
    // mclk domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic req_s1, req_s2;
    logic [NG*GAIN_WIDTH-1:0] active_bank;

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            req_s1      <= 1'b0;
            req_s2      <= 1'b0;
            ack_tgl     <= 1'b0;
            active_bank <= RESET_GAINS;
        end else begin
            req_s1 <= req_tgl;
            req_s2 <= req_s1;
            if (req_s2 != ack_tgl) begin
                active_bank <= xfer_bank;   // CDC capture, see header
                ack_tgl     <= req_s2;
            end
        end
    end

    assign gains_flat = active_bank;

endmodule
