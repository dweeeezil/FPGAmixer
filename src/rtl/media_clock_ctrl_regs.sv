// -----------------------------------------------------------------------------
// media_clock_ctrl_regs.sv
//
// Control-plane binding for one media_clock_steer: its rate register and
// status in an AXI4-Lite window. Holds only what is specific to the steerer --
// ID, CONFIG and the word list; the window is the generic axil_reg_window
// (docs/architecture_modules.md 4.1). The steerer runs on the AXI clock
// (pl_clk0 = PSCLK, decision S1), so there is no clock crossing here.
//
// Register map (window-relative byte offsets, 32-bit accesses):
//   0x000  ID          0x4D53_5001  ("MS", media-clock steering, rev 1)
//   0x004  CONFIG      PSCLK frequency in Hz (the rate's time base)
//   0x008  CTRL        0
//   0x00C  WRITES      register writes accepted
//   0x100  RATE        RW  signed, steps per PSCLK cycle in units of 2^-32.
//                          > 0: mclk slower, < 0: faster (see
//                          media_clock_steer). 0 after reset.
//   0x104  STEPS_INC   RO  completed phase increments (wraps)
//   0x108  STEPS_DEC   RO  completed phase decrements (wraps)
//   0x10C  DROPPED     RO  step requests discarded at the maximum slew
//   0x110  FLAGS       RO  bit0 = MMCM locked, bit1 = a step in flight
//   0x114  VCO_HZ      RO  the MMCM's VCO frequency in Hz
//   0x118  PS_DIV      RO  steps per VCO period (56)
// A rate in ppm converts as  RATE = ppm * 1e-6 * VCO_HZ * PS_DIV / CONFIG * 2^32
// (one step = 1 / (VCO_HZ * PS_DIV) seconds of phase).
// -----------------------------------------------------------------------------
module media_clock_ctrl_regs #(
    parameter int PSCLK_HZ   = 100_000_000,
    parameter int VCO_HZ     = 1_450_000_000,
    parameter int PS_DIV     = 56,
    parameter int ADDR_WIDTH = 12
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

    // ----- to/from media_clock_steer (aclk domain) -----
    output logic [31:0]           rate,
    input  logic [31:0]           steps_inc,
    input  logic [31:0]           steps_dec,
    input  logic [31:0]           dropped,
    input  logic                  busy,
    input  logic                  locked
);

    localparam int N_RO = 6;

    axil_reg_window #(
        .N_RW (1), .N_RO (N_RO), .ADDR_WIDTH (ADDR_WIDTH),
        .ID_VALUE (32'h4D53_5001), .CONFIG_VALUE (32'(PSCLK_HZ)),
        .RESET_RW ('0)
    ) u_window (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata (s_axi_wdata), .s_axi_wstrb (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid), .s_axi_wready (s_axi_wready),
        .s_axi_bresp (s_axi_bresp), .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata (s_axi_rdata), .s_axi_rresp (s_axi_rresp),
        .s_axi_rvalid (s_axi_rvalid), .s_axi_rready (s_axi_rready),
        .rw_flat (rate),
        .ro_flat ({32'(PS_DIV), 32'(VCO_HZ), {30'b0, busy, locked},
                   dropped, steps_dec, steps_inc})
    );

endmodule
