// -----------------------------------------------------------------------------
// reset_sync.sv
//
// Async-assert, sync-deassert reset synchronizer.
//
// The MMCM's `locked` signal is asynchronous to mclk. Using it directly as a
// reset creates a metastability risk when it deasserts (because that
// deassertion might land inside a mclk setup/hold window). This module drives
// `sync_rst_n` low the instant `async_rst_n` goes low, but delays deassertion
// through two flip-flops in the mclk domain, guaranteeing a clean rising edge
// on `sync_rst_n` that all downstream logic sees on the same mclk cycle.
//
// The ASYNC_REG attribute tells Vivado to place both flops physically adjacent
// so the metastability resolution time is maximized.
// -----------------------------------------------------------------------------
module reset_sync (
    input  logic clk,
    input  logic async_rst_n,   // async, active-low
    output logic sync_rst_n     // synced to clk, active-low
);

    (* ASYNC_REG = "TRUE" *) logic rst_meta;
    (* ASYNC_REG = "TRUE" *) logic rst_sync;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            rst_meta <= 1'b0;
            rst_sync <= 1'b0;
        end else begin
            rst_meta <= 1'b1;
            rst_sync <= rst_meta;
        end
    end

    assign sync_rst_n = rst_sync;

endmodule
