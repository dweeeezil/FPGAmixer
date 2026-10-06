// -----------------------------------------------------------------------------
// coef_bank_ram.sv
//
// Generic control-plane primitive (Phase 9, P9.A3): a coefficient bank kept in
// RAM, delivered to a time-shared core block through a READ PORT, with the
// coefficient contract's guarantee (docs/architecture_modules.md 3): the bank
// the block reads changes only at a frame strobe, all of it at once. It knows
// nothing about what the coefficients mean. Replaces the flat-vector pair
// axil_coef_window shadow + coef_bank_handoff for blocks whose banks are too
// big to carry as a vector (phase9_status_2026-09-26.md 5.1, decision C3).
//
// ----- Layout: rows distributed round-robin over lanes -----
// The coefficients are N_ROWS rows of ROW_LEN; register index
// k = r*ROW_LEN + c (row r, column c). A block with LANES parallel units reads
// one word per cycle holding one coefficient per lane:
//   row r is served by lane  r % LANES,  at word  (r / LANES)*ROW_LEN + c,
//   lane l at rd_data[l*W +: W].
// For the matrix, a row is an output (ROW_LEN = N_IN) and a lane is a DSP.
// Lane slots past the last row (N_ROWS not a multiple of LANES) are never
// written and read 0 from configuration; blocks must not rely on them.
//
// ----- aclk side: the store interface (used by axil_coef_window) -----
//   st_valid/st_ready : one request; st_we = write st_wdata to index st_idx,
//                       else read it: st_rdata is valid when st_rvalid pulses,
//                       one cycle after the transfer.
//   Reads and writes go to the SHADOW, which is what software sees.
//   commit            : pulse. The shadow is copied into the inactive bank,
//                       then the block swaps banks at its next frame strobe.
//   busy              : a copy or a swap is in progress (also during INIT).
//   queued            : a commit arrived while busy; it launches when busy
//                       clears. Back-to-back commits while busy merge into one.
//   commits           : software commits completed since aresetn (wraps).
// st_ready is low while the reset init or a copy runs (N_COEF cycles each)
// AND while a commit is queued, so a commit contains exactly the writes
// completed before it. (coef_bank_handoff differs: a queued commit takes the
// shadow as it is at launch, which can include writes made after the COMMIT.
// Found by tb_coef_bank_ram, phase9_status_2026-09-26.md 5.4.) The price: a
// write following a COMMIT that had to queue waits for the previous swap,
// at most about one frame (21 us) plus a copy.
//
// ----- mclk side -----
//   rd_addr -> rd_data one cycle later, from the active bank.
//   frame_i : the frame strobe. A pending swap takes effect on the strobe
//             edge: a read issued in the strobe cycle still sees the old bank,
//             every later read the new one. A block reads one frame's
//             coefficients between two strobes, so each frame sees one bank.
//
// ----- CDC: the only paths between the clocks -----
//   1. req_tgl (aclk) -> req_s1/req_s2 (mclk)   toggle: "bank req_tgl is ready"
//   2. ack_tgl (mclk) -> ack_s1/ack_s2 (aclk)   toggle: the bank in use
//   3. the lane RAMs: written on aclk (port A), read on mclk (port B). Never
//      the same bank at once: aclk only writes bank ~ack_s2 while not busy,
//      i.e. while mclk is known to be reading bank ack_s2.
// constraints/coef_bank_ram.xdc (SCOPED_TO_REF) bounds 1 and 2; keep the
// register names in step. ram_style "block" keeps 3 inside a BRAM, where no
// timing path crosses between the ports.
//
// ----- Resets -----
// The bank in use IS ack_tgl, and the last bank completely written is
// req_tgl. Neither toggle is reset (they start at 0 from configuration), so a
// reset of either domain alone can never select an older bank. After aresetn
// an init engine writes RESET_COEFS into the shadow and runs a normal commit
// (not counted in `commits`): "reset means the reset bank is in effect",
// through the ordinary path. The mclk side has no reset at all.
// -----------------------------------------------------------------------------
module coef_bank_ram #(
    parameter int W       = 18,     // coefficient width
    parameter int N_ROWS  = 12,
    parameter int ROW_LEN = 12,
    parameter int LANES   = 1,
    parameter logic [N_ROWS*ROW_LEN*W-1:0] RESET_COEFS = '0,
    localparam int N_COEF = N_ROWS * ROW_LEN,
    localparam int PASSES = (N_ROWS + LANES - 1) / LANES,
    localparam int DEPTH  = PASSES * ROW_LEN,
    localparam int IW     = (N_COEF > 1) ? $clog2(N_COEF) : 1,
    localparam int AW     = (DEPTH  > 1) ? $clog2(DEPTH)  : 1
) (
    // ----- aclk domain -----
    input  logic             aclk,
    input  logic             aresetn,

    input  logic             st_valid,
    output logic             st_ready,
    input  logic             st_we,
    input  logic [IW-1:0]    st_idx,
    input  logic [W-1:0]     st_wdata,
    output logic             st_rvalid,
    output logic [W-1:0]     st_rdata,

    input  logic             commit,
    output logic             busy,
    output logic             queued,
    output logic [31:0]      commits,

    // ----- mclk domain -----
    input  logic             mclk,
    input  logic             frame_i,
    input  logic [AW-1:0]    rd_addr,
    output logic [LANES*W-1:0] rd_data
);

    generate
        if (LANES < 1 || LANES > N_ROWS)
            $error("coef_bank_ram: LANES = %0d must be 1 .. N_ROWS (%0d)", LANES, N_ROWS);
    endgenerate

    // =========================================================================
    // Handshake toggles (no reset: see header)
    // =========================================================================
    logic req_tgl = 1'b0;                                   // aclk
    logic ack_tgl = 1'b0;                                   // mclk
    (* ASYNC_REG = "TRUE" *) logic req_s1 = 1'b0, req_s2 = 1'b0;   // mclk
    (* ASYNC_REG = "TRUE" *) logic ack_s1 = 1'b0, ack_s2 = 1'b0;   // aclk

    always_ff @(posedge aclk) begin
        ack_s1 <= ack_tgl;
        ack_s2 <= ack_s1;
    end

    always_ff @(posedge mclk) begin
        req_s1 <= req_tgl;
        req_s2 <= req_s1;
        if (frame_i && req_s2 != ack_tgl)
            ack_tgl <= req_s2;                              // the swap
    end

    // =========================================================================
    // aclk: shadow RAM, init, copy
    // =========================================================================
    logic [W-1:0] shadow [N_COEF];
    logic         sh_we;
    logic [IW-1:0] sh_wa, sh_ra;
    logic [W-1:0] sh_wd, sh_rd;

    initial for (int j = 0; j < N_COEF; j++) shadow[j] = '0;

    always_ff @(posedge aclk) begin
        if (sh_we) shadow[sh_wa] <= sh_wd;
        sh_rd <= shadow[sh_ra];
    end

    typedef enum logic [1:0] { S_INIT, S_IDLE, S_COPY } state_t;
    state_t state;

    logic [IW:0]   k;           // INIT / COPY index (read side of the copy)
    // copy write side, one cycle behind the shadow read
    logic          cp_we;
    logic [IW-1:0] cp_c;        // column of the word being read
    logic [AW-1:0] cp_base;     // (row / LANES) * ROW_LEN, kept incrementally
    logic [$clog2(LANES+1)-1:0] cp_lane;
    logic [AW-1:0] cp_word_d;
    logic [$clog2(LANES+1)-1:0] cp_lane_d;
    logic          bank_w;      // the inactive bank being written
    logic          count_it;    // the commit in flight is software's (counted)
    logic          sw_req;      // software committed since the last launch
    logic          hs_busy, hs_busy_q;

    assign hs_busy  = (req_tgl != ack_s2);
    assign busy     = (state != S_IDLE) || hs_busy;
    // Not ready while a copy runs or a commit waits: a commit then holds
    // exactly the writes completed before it (see header, "queued").
    assign st_ready = (state == S_IDLE) && !queued;

    // shadow port use: IDLE = the store interface, INIT = reset values, COPY = k
    always_comb begin
        sh_we = 1'b0;
        sh_wa = st_idx;
        sh_wd = st_wdata;
        sh_ra = st_idx;
        case (state)
            S_INIT: begin
                sh_we = 1'b1;
                sh_wa = k[IW-1:0];
                sh_wd = RESET_COEFS[k[IW-1:0]*W +: W];
            end
            S_IDLE: sh_we = st_valid && st_ready && st_we;
            S_COPY: sh_ra = k[IW-1:0];
            default: ;
        endcase
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state     <= S_INIT;
            k         <= '0;
            queued    <= 1'b0;
            commits   <= '0;
            count_it  <= 1'b0;
            sw_req    <= 1'b0;
            hs_busy_q <= 1'b0;
            st_rvalid <= 1'b0;
            cp_we     <= 1'b0;
            cp_c      <= '0;
            cp_base   <= '0;
            cp_lane   <= '0;
            bank_w    <= 1'b0;
        end else begin
            st_rvalid <= st_valid && st_ready && !st_we;
            cp_we     <= 1'b0;

            // a completed swap (the ack came back) is a completed commit
            hs_busy_q <= hs_busy;
            if (hs_busy_q && !hs_busy && count_it)
                commits <= commits + 1'b1;

            if (commit) begin
                queued <= 1'b1;
                sw_req <= 1'b1;
            end

            case (state)
                S_INIT: begin
                    if (k == (IW+1)'(N_COEF - 1)) begin
                        state    <= S_IDLE;
                        queued   <= 1'b1;       // commit the reset bank (not
                        k        <= '0;         // counted unless sw_req)
                    end else begin
                        k <= k + 1'b1;
                    end
                end

                S_IDLE: begin
                    if ((queued || commit) && !hs_busy) begin
                        state    <= S_COPY;
                        queued   <= 1'b0;
                        count_it <= sw_req || commit;
                        sw_req   <= 1'b0;
                        k        <= '0;
                        cp_c     <= '0;
                        cp_base  <= '0;
                        cp_lane  <= '0;
                        bank_w   <= ~ack_s2;
                    end
                end

                S_COPY: begin
                    // read shadow[k] this cycle; write it next cycle
                    if (k < (IW+1)'(N_COEF)) begin
                        cp_we     <= 1'b1;
                        cp_word_d <= cp_base + AW'(cp_c);
                        cp_lane_d <= cp_lane;
                        k         <= k + 1'b1;
                        if (cp_c == IW'(ROW_LEN - 1)) begin
                            cp_c <= '0;
                            if (cp_lane == LANES - 1) begin
                                cp_lane <= '0;
                                cp_base <= cp_base + AW'(ROW_LEN);
                            end else begin
                                cp_lane <= cp_lane + 1'b1;
                            end
                        end else begin
                            cp_c <= cp_c + 1'b1;
                        end
                    end else begin
                        // last write issued last cycle: hand the bank over
                        req_tgl <= bank_w;
                        state   <= S_IDLE;
                        k       <= '0;
                    end
                end

                default: state <= S_INIT;
            endcase
        end
    end

    assign st_rdata = sh_rd;

    // =========================================================================
    // Lane RAMs: two banks each, port A = aclk write, port B = mclk read
    // =========================================================================
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl++) begin : g_lane
            (* ram_style = "block" *) logic [W-1:0] lram [2**(AW+1)];
            logic [W-1:0] q;

            initial for (int j = 0; j < 2**(AW+1); j++) lram[j] = '0;

            always_ff @(posedge aclk)
                if (cp_we && cp_lane_d == gl)
                    lram[{bank_w, cp_word_d}] <= sh_rd;

            always_ff @(posedge mclk)
                q <= lram[{ack_tgl, rd_addr}];

            assign rd_data[gl*W +: W] = q;
        end
    endgenerate

endmodule
