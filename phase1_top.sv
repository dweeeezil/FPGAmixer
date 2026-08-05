// -----------------------------------------------------------------------------
// phase1_top.sv
//
// Phase 1: Pmod I2S2 loopback on JA.
//
// Signal flow (fabric-level):
//
//   sysclk (125 MHz) --> MMCM (clk_wiz_audio) --> mclk (~12.288 MHz)
//                                                    |
//                                                    +--> divider --> sclk, lrck
//                                                    |
//                                                    v
//                                     mclk / lrck / sclk driven to BOTH
//                                     the DAC side (pins 1..3) and the
//                                     ADC side (pins 7..9) of the Pmod
//
//   ja_ad_sdout (from ADC, JA10) ---------> ja_da_sdin (to DAC, JA4)
//                          (combinational passthrough - no reformatting)
//
// Pmod I2S2 header layout (see Digilent reference manual):
//   Pin 1  D/A MCLK    (FPGA out)   -- DAC side, bottom row
//   Pin 2  D/A LRCK    (FPGA out)
//   Pin 3  D/A SCLK    (FPGA out)
//   Pin 4  D/A SDIN    (FPGA out) <-- gets ADC data looped back into it
//   Pin 7  A/D MCLK    (FPGA out)   -- ADC side, top row
//   Pin 8  A/D LRCK    (FPGA out)
//   Pin 9  A/D SCLK    (FPGA out)
//   Pin 10 A/D SDOUT   (FPGA in)  --> ADC serial data output
//
// Hardware notes:
//   - Pmod I2S2 JP1 jumper must be in SLV (slave) position - the FPGA drives
//     LRCK and SCLK; the CS5343 does not generate them itself in this build.
//   - Line In (3.5mm jack) is the ADC input; Line Out is the DAC output.
// -----------------------------------------------------------------------------
module phase1_top (
    input  logic sysclk,      // 125 MHz, pin H16

    // Pmod JA - Pmod I2S2
    // DAC side (CS4344, "Line Out"), bottom row of Pmod
    output logic ja_da_mclk,  // JA1  -> Y18
    output logic ja_da_lrck,  // JA2  -> Y19
    output logic ja_da_sclk,  // JA3  -> Y16
    output logic ja_da_sdin,  // JA4  -> Y17 (FPGA drives DAC data)

    // ADC side (CS5343, "Line In"), top row of Pmod
    output logic ja_ad_mclk,  // JA7  -> U18
    output logic ja_ad_lrck,  // JA8  -> U19
    output logic ja_ad_sclk,  // JA9  -> W18
    input  logic ja_ad_sdout  // JA10 -> W19 (ADC drives, FPGA reads)
);

    // ----- Clocks -----
    logic mclk;
    logic mmcm_locked;
    logic sclk;
    logic lrck;

    // MMCM: 125 MHz sysclk -> ~12.288 MHz mclk
    // Configuration lives in scripts/create_project.tcl.
    clk_wiz_audio u_mmcm (
        .clk_in1  (sysclk),
        .reset    (1'b0),
        .clk_out1 (mclk),
        .locked   (mmcm_locked)
    );

    // Hold the divider in reset until the MMCM output is stable. mmcm_locked
    // is asynchronous to mclk, so this is an async-assert / async-deassert
    // reset - acceptable for a bring-up design; Phase 2 will add a proper
    // reset synchronizer.
    logic rst_n;
    assign rst_n = mmcm_locked;

    i2s_clock_divider u_div (
        .mclk  (mclk),
        .rst_n (rst_n),
        .sclk  (sclk),
        .lrck  (lrck)
    );

    // ----- Drive clocks to both sides of the Pmod -----
    // The DAC and ADC are separate chips on the Pmod; each gets its own
    // dedicated clock pin. We drive the same signal to both.
    assign ja_da_mclk = mclk;
    assign ja_da_lrck = lrck;
    assign ja_da_sclk = sclk;

    assign ja_ad_mclk = mclk;
    assign ja_ad_lrck = lrck;
    assign ja_ad_sclk = sclk;

    // ----- Loopback: ADC serial data -> DAC serial data -----
    // Combinational passthrough. No reformatting, no registering.
    // The ADC drives its SDOUT on the falling SCLK edge; the DAC samples
    // SDIN on the rising SCLK edge, half a bit period later, so there is
    // plenty of setup/hold margin even with fabric routing delay.
    assign ja_da_sdin = ja_ad_sdout;

endmodule
