// -----------------------------------------------------------------------------
// audio_clocking.sv
//
// Platform block: the core audio clock domain (docs/architecture_modules.md 2).
//
//   sysclk 25 MHz -> MMCM (clk_wiz_audio) -> mclk ~12.288 MHz
//                                          -> reset_sync -> rst_n
//                                          -> frame counter -> frame (48 kHz)
//
// Every PCM core block, the links and the media-clock meter run on this one
// mclk and this one frame strobe, so all channels are sample-synchronous and
// the core needs no audio CDC. Front doors with a foreign clock (USB, network,
// the USB-host interface) bridge into mclk themselves.
//
// The frame strobe: one mclk cycle in every 256 (mclk / 256 = 48 kHz). Until
// Phase 11 it was the Pmod JB I2S receiver's word strobe (from an
// i2s_clock_divider LRCK); the Pmods are gone (decision P1), so the counter
// lives here. A frame is exactly 256 cycles, as before, whatever mclk's
// steering does to a cycle's length (docs/architecture_modules.md 2.1).
//
// The MMCM runs 25 MHz x 58 / 118 (VCO 1450 MHz) = 12.28814 MHz, +11.03 ppm
// nominal, forced in scripts/create_project.tcl (Phase 9, P9.4a). The board
// XDC names the MMCM input net through this module's u_mmcm instance
// (CLOCK_DEDICATED_ROUTE on the HDIO sysclk pin).
// -----------------------------------------------------------------------------
module audio_clocking (
    input  logic sysclk,       // 25 MHz PL reference
    output logic mclk,         // core audio clock
    output logic rst_n,        // active-low, synchronous to mclk, released after lock
    output logic frame,        // one-mclk pulse per 256 cycles: the core's frame strobe
    output logic mmcm_locked,

    // ----- MMCM dynamic fine phase shift (Phase 9, P9.4b) -----
    // Drives mclk's phase: media_clock_steer turns a rate into steps here.
    // Builds without the steerer tie psen low (psclk may then be constant).
    input  logic psclk,
    input  logic psen,
    input  logic psincdec,
    output logic psdone
);

    clk_wiz_audio u_mmcm (
        .clk_in1  (sysclk),
        .reset    (1'b0),
        .clk_out1 (mclk),
        .locked   (mmcm_locked),
        .psclk    (psclk),
        .psen     (psen),
        .psincdec (psincdec),
        .psdone   (psdone)
    );

    reset_sync u_rst_sync (
        .clk         (mclk),
        .async_rst_n (mmcm_locked),
        .sync_rst_n  (rst_n)
    );

    logic [7:0] cnt;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= 8'd0;
            frame <= 1'b0;
        end else begin
            cnt   <= cnt + 8'd1;
            frame <= (cnt == 8'd255);
        end
    end

endmodule
