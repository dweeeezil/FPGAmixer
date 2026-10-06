// -----------------------------------------------------------------------------
// audio_clocking.sv
//
// Platform block: the core audio clock domain (docs/architecture_modules.md 2).
//
//   sysclk 25 MHz -> MMCM (clk_wiz_audio) -> mclk ~12.288 MHz
//                                          -> reset_sync -> rst_n
//                                          -> i2s_clock_divider -> sclk, lrck
//
// Every PCM core block and every I2S port runs on this one mclk, and every I2S
// port uses this one sclk/lrck pair, so all channels are sample-synchronous and
// the core needs no audio CDC. Front doors with a foreign clock (USB, network)
// bridge into mclk themselves.
//
// The MMCM runs 25 MHz x 58 / 118 (VCO 1450 MHz) = 12.28814 MHz, +11.03 ppm
// nominal, forced in scripts/create_project.tcl (Phase 9, P9.4a). Until then
// it was 25 x 40.625 / 82.625 = 12.2919 MHz, +324 ppm (Roadmap 4); measured
// against gPTP that read +315.3 ppm, the PL crystal being -8.7 ppm vs the
// bench grandmaster. The board XDC names the MMCM input net through this
// module's u_mmcm instance (CLOCK_DEDICATED_ROUTE on the HDIO sysclk pin).
// -----------------------------------------------------------------------------
module audio_clocking (
    input  logic sysclk,       // 25 MHz PL reference
    output logic mclk,         // core audio clock
    output logic rst_n,        // active-low, synchronous to mclk, released after lock
    output logic sclk,         // mclk / 4   (bit clock for every I2S port)
    output logic lrck,         // mclk / 256 (frame clock for every I2S port)
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

    i2s_clock_divider u_div (
        .mclk (mclk), .rst_n (rst_n), .sclk (sclk), .lrck (lrck)
    );

endmodule
