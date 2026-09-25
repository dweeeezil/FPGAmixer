// -----------------------------------------------------------------------------
// coef_bank_handoff.sv
//
// Generic control-plane primitive: carries a coefficient bank of any width from
// a source clock domain (the AXI side) to a destination clock domain (the audio
// side) so that the destination sees the WHOLE bank change on ONE edge.
// Satisfies the coefficient contract (docs/architecture_modules.md 3); it knows
// nothing about what the bits mean.
//
// Usage: present src_bank, pulse commit for one src_clk cycle. src_bank is
// snapshotted on that edge (or, if a transfer is already in flight, when it
// completes -- see QUEUED), and dst_bank takes the snapshot a few dst_clk
// cycles later, all bits on the same edge.
//
//   busy    : a snapshot is crossing to dst (derived, see below)
//   queued  : a commit arrived while busy; it launches when busy clears, with
//             src_bank as it is at that moment (latest wins)
//   commits : transfers completed since src reset (wraps)
//
// CDC -- the only paths between the domains:
//   1. req_tgl  (src) -> 2FF sync (req_s1, req_s2) -> dst     toggle request
//   2. ack_tgl  (dst) -> 2FF sync (ack_s1, ack_s2) -> src     toggle acknowledge
//   3. xfer_bank (src) -> active_bank (dst)   multi-bit, captured under an
//      enable derived from the synchronized request (MCP formulation).
//      xfer_bank is loaded on the same src edge that flips req_tgl and holds
//      until the ack returns, so it has been stable for >= 2 dst periods when
//      dst captures it.
// These are constrained by constraints/coef_bank_handoff.xdc, which is scoped
// to this module (SCOPED_TO_REF), so every instance is covered automatically.
// Keep the register names below in step with that file.
//
// busy is DERIVED (req_tgl != synced ack) rather than stored, so the handshake
// heals itself if one domain is reset without the other: dst performs one
// extra copy and re-acks.
//
// Resets: src_rst_n is synchronous (AXI style), dst_rst_n asynchronous. On
// reset both banks take RESET_VALUE, so the destination has a defined bank
// before any commit.
// -----------------------------------------------------------------------------
module coef_bank_handoff #(
    parameter int                 WIDTH       = 32,
    parameter logic [WIDTH-1:0]   RESET_VALUE = '0
) (
    // ----- source domain -----
    input  logic             src_clk,
    input  logic             src_rst_n,
    input  logic [WIDTH-1:0] src_bank,
    input  logic             commit,
    output logic             busy,
    output logic             queued,
    output logic [31:0]      commits,

    // ----- destination domain -----
    input  logic             dst_clk,
    input  logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_bank
);

    // =========================================================================
    // source domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic ack_s1, ack_s2;
    logic             req_tgl, busy_q;
    logic [WIDTH-1:0] xfer_bank;
    logic             ack_tgl;  // dst domain, declared here for the synchronizer

    always_ff @(posedge src_clk) begin
        if (!src_rst_n) begin
            ack_s1 <= 1'b0;
            ack_s2 <= 1'b0;
        end else begin
            ack_s1 <= ack_tgl;
            ack_s2 <= ack_s1;
        end
    end

    assign busy = (req_tgl != ack_s2);

    always_ff @(posedge src_clk) begin
        if (!src_rst_n) begin
            req_tgl   <= 1'b0;
            queued    <= 1'b0;
            busy_q    <= 1'b0;
            commits   <= '0;
            xfer_bank <= RESET_VALUE;
        end else begin
            busy_q <= busy;
            if (busy_q && !busy)
                commits <= commits + 1'b1;

            if (commit || queued) begin
                if (!busy) begin
                    xfer_bank <= src_bank;
                    req_tgl   <= ~req_tgl;
                    queued    <= 1'b0;
                end else begin
                    queued    <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // destination domain
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic req_s1, req_s2;
    logic [WIDTH-1:0] active_bank;

    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_s1      <= 1'b0;
            req_s2      <= 1'b0;
            ack_tgl     <= 1'b0;
            active_bank <= RESET_VALUE;
        end else begin
            req_s1 <= req_tgl;
            req_s2 <= req_s1;
            if (req_s2 != ack_tgl) begin
                active_bank <= xfer_bank;   // CDC capture, see header
                ack_tgl     <= req_s2;
            end
        end
    end

    assign dst_bank = active_bank;

endmodule
