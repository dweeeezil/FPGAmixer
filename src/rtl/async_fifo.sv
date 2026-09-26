// -----------------------------------------------------------------------------
// async_fifo.sv
//
// Generic dual-clock FIFO: Gray-coded pointers, 2FF synchronizers, a
// power-of-two depth, first-word-fall-through read. It knows nothing about
// audio; pcm_link uses two of them for its clock crossing (Phase 8).
//
//   write side (wclk): wr_en while !full pushes wdata; wr_level = words held,
//                      as seen from the write side (may over-report, never under)
//   read side  (rclk): rdata is the head word whenever !empty; rd_en pops it;
//                      rd_level = words held, as seen from the read side (may
//                      under-report, never over)
//
// A write while full and a read while empty are ignored.
//
// CDC -- the only paths between the domains:
//   1. wptr_gray (wclk) -> rsync_wptr1 (rclk)   2FF synchronizer
//   2. rptr_gray (rclk) -> wsync_rptr1 (wclk)   2FF synchronizer
//   3. mem (written in wclk) -> rdata (read combinationally in rclk). A word is
//      read only after its write pointer has crossed path 1, i.e. >= 2 rclk
//      cycles after it was written, so it is stable when read.
// Constrained by constraints/async_fifo.xdc, scoped to this module
// (SCOPED_TO_REF), so every instance is covered. Keep the register names below
// in step with that file.
//
// Resets: wrst_n and rrst_n are asynchronous, active low, and must be asserted
// TOGETHER (as at power-up): resetting one side alone while the other runs
// corrupts the pointer relationship. Both sides come up empty.
// -----------------------------------------------------------------------------
module async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16    // power of two, >= 4
) (
    // ----- write side -----
    input  logic                     wclk,
    input  logic                     wrst_n,
    input  logic                     wr_en,
    input  logic [WIDTH-1:0]         wdata,
    output logic                     full,
    output logic [$clog2(DEPTH):0]   wr_level,

    // ----- read side -----
    input  logic                     rclk,
    input  logic                     rrst_n,
    input  logic                     rd_en,
    output logic [WIDTH-1:0]         rdata,
    output logic                     empty,
    output logic [$clog2(DEPTH):0]   rd_level
);

    localparam int AW = $clog2(DEPTH);

    // synthesis translate_off
    initial begin
        if (DEPTH < 4 || (1 << AW) != DEPTH)
            $fatal(1, "async_fifo: DEPTH (%0d) must be a power of two >= 4", DEPTH);
    end
    // synthesis translate_on

    function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
        logic [AW:0] b;
        b[AW] = g[AW];
        for (int i = AW - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Distributed RAM: written in wclk, read asynchronously in rclk.
    logic [WIDTH-1:0] mem [DEPTH];

    // The Gray pointers are the CDC launch registers named by async_fifo.xdc.
    // DONT_TOUCH: a Gray code's MSB equals the binary MSB, and without it
    // synthesis merges *_gray_reg[MSB] into *_bin_reg[MSB], so that bit leaves
    // the constraint's -from list and crosses unbounded (caught by the
    // methodology gate as TIMING-6/7/8 in the first Phase 8 build).
    logic [AW:0] wptr_bin, rptr_bin;
    (* DONT_TOUCH = "TRUE" *) logic [AW:0] wptr_gray;   // write side
    (* DONT_TOUCH = "TRUE" *) logic [AW:0] rptr_gray;   // read side

    // =========================================================================
    // write side
    // =========================================================================

    (* ASYNC_REG = "TRUE" *) logic [AW:0] wsync_rptr1, wsync_rptr2;
    logic [AW:0] rptr_bin_w;

    assign rptr_bin_w = gray2bin(wsync_rptr2);
    assign wr_level   = wptr_bin - rptr_bin_w;
    assign full       = (wr_level == (AW+1)'(DEPTH));

    always_ff @(posedge wclk) begin
        if (wr_en && !full) mem[wptr_bin[AW-1:0]] <= wdata;
    end

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin    <= '0;
            wptr_gray   <= '0;
            wsync_rptr1 <= '0;
            wsync_rptr2 <= '0;
        end else begin
            wsync_rptr1 <= rptr_gray;
            wsync_rptr2 <= wsync_rptr1;
            if (wr_en && !full) begin
                wptr_bin  <= wptr_bin + 1'b1;
                wptr_gray <= bin2gray(wptr_bin + 1'b1);
            end
        end
    end

    // =========================================================================
    // read side
    // =========================================================================

    (* ASYNC_REG = "TRUE" *) logic [AW:0] rsync_wptr1, rsync_wptr2;
    logic [AW:0] wptr_bin_r;

    assign wptr_bin_r = gray2bin(rsync_wptr2);
    assign rd_level   = wptr_bin_r - rptr_bin;
    assign empty      = (rd_level == '0);
    assign rdata      = mem[rptr_bin[AW-1:0]];

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin    <= '0;
            rptr_gray   <= '0;
            rsync_wptr1 <= '0;
            rsync_wptr2 <= '0;
        end else begin
            rsync_wptr1 <= wptr_gray;
            rsync_wptr2 <= rsync_wptr1;
            if (rd_en && !empty) begin
                rptr_bin  <= rptr_bin + 1'b1;
                rptr_gray <= bin2gray(rptr_bin + 1'b1);
            end
        end
    end

endmodule
