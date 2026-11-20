// -----------------------------------------------------------------------------
// timecode_regs_axil.sv
//
// Control-plane binding for the timecode display
// (docs/timecode_proposal_2026-11-18.md): picks one I/O port, feeds it to an
// ltc_decoder, and shows the result in one AXI4-Lite window. A listener: it
// only reads the core's input ports and drives nothing in the audio path.
// The machinery is generic:
//   axil_reg_window    : AXI4-Lite slave, common header, RW + RO words
//   coef_bank_handoff  : twice, its scoped XDC covering both instances:
//                        SOURCE aclk -> mclk, the status words mclk -> aclk
//                        (one consistent snapshot per audio frame)
//
// Register map (window-relative byte offsets, 32-bit accesses):
//   0x000  ID             0x5443_5001  ("TC", rev 1)
//   0x004  CONFIG         [7:0] I/O ports
//   0x008  CTRL           0
//   0x00C  WRITES         writes accepted since aresetn (wraps)
//   0x100  SOURCE    RW   0 = off, p + 1 = I/O port p (the patch's convention);
//                         anything above P is off. Reset 0
//   0x104  TC_LOW         LTC bits 31:0 of the last frame decoded
//   0x108  TC_HIGH        LTC bits 63:32
//   0x10C  FRAMES         frames decoded since reset (wraps)
//   0x110  FRAME_SAMPLES  samples between the last two sync words
//   0x114  FLAGS          bit 0 signal present, bit 1 locked
//   0x118  SNAPSHOTS      snapshot sequence: a changing value proves it is live
//
// A frame takes three 32-bit reads, and a new one can land between them. To get
// a whole frame: read FRAMES, TC_LOW, TC_HIGH, FRAMES, and retry if FRAMES moved.
//
// Changing SOURCE restarts the decoder, so nothing from the previous port is
// carried into the new one.
// -----------------------------------------------------------------------------
module timecode_regs_axil #(
    parameter int P          = 20,    // I/O ports
    parameter int SW         = 24,
    parameter int ADDR_WIDTH = 12
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

    // ----- the core's input ports (mclk domain), read only -----
    input  logic                  mclk,
    input  logic                  rst_n,
    input  logic                  frame_i,      // the ports are stable on this edge
    input  logic [P*SW-1:0]       in_flat       // port p at [p*SW +: SW]
);

    localparam logic [31:0] ID_VALUE     = 32'h5443_5001;
    localparam logic [31:0] CONFIG_VALUE = 32'(P);
    localparam int          N_RO         = 6;
    localparam int          SELW         = $clog2(P + 1);

    // ----- aclk: SOURCE, made safe, sent over when it changes -----
    logic [31:0]        source;
    logic [N_RO*32-1:0] ro_flat;
    logic [SELW-1:0]    sel_a, sel_a_q;
    logic               sel_commit;

    assign sel_a = (source <= 32'(P)) ? SELW'(source) : '0;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            sel_a_q    <= '0;
            sel_commit <= 1'b0;
        end else begin
            sel_a_q    <= sel_a;
            sel_commit <= (sel_a != sel_a_q);
        end
    end

    logic [SELW-1:0] sel_m;
    logic            sel_busy_unused, sel_queued_unused;
    logic [31:0]     sel_commits_unused;

    coef_bank_handoff #(.WIDTH (SELW), .RESET_VALUE ('0)) u_sel_handoff (
        .src_clk (aclk), .src_rst_n (aresetn),
        .src_bank (sel_a_q), .commit (sel_commit),
        .busy (sel_busy_unused), .queued (sel_queued_unused),
        .commits (sel_commits_unused),
        .dst_clk (mclk), .dst_rst_n (rst_n),
        .dst_bank (sel_m)
    );

    // ----- mclk: the selected port, one sample per frame, into the decoder -----
    logic [SELW-1:0]      sel_q;
    logic                 clear, sample_valid, snap;
    logic signed [SW-1:0] sample;
    logic [31:0]          seq;

    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            sel_q        <= '0;
            clear        <= 1'b0;
            sample_valid <= 1'b0;
            sample       <= '0;
            snap         <= 1'b0;
            seq          <= '0;
        end else begin
            sel_q        <= sel_m;
            clear        <= (sel_m != sel_q);
            sample_valid <= frame_i;
            if (frame_i)
                sample <= (sel_m == '0) ? '0 : in_flat[(int'(sel_m) - 1) * SW +: SW];
            // the decoder's outputs change on the edge that takes the sample,
            // so the snapshot is one cycle behind it
            snap <= sample_valid;
            if (snap) seq <= seq + 32'd1;
        end
    end

    logic [63:0] tc_data;
    logic [31:0] frames;
    logic [15:0] frame_samples;
    logic        signal, locked;

    ltc_decoder #(.SW (SW)) u_decoder (
        .mclk (mclk), .rst_n (rst_n), .clear (clear),
        .sample_valid (sample_valid), .sample (sample),
        .tc_data (tc_data), .frames (frames), .frame_samples (frame_samples),
        .signal (signal), .locked (locked)
    );

    // ----- the status words, one snapshot per frame, mclk -> aclk -----
    logic [N_RO*32-1:0] status;
    assign status = { seq,
                      {30'b0, locked, signal},
                      {16'b0, frame_samples},
                      frames,
                      tc_data[63:32],
                      tc_data[31:0] };

    logic        st_busy_unused, st_queued_unused;
    logic [31:0] st_commits_unused;

    coef_bank_handoff #(.WIDTH (N_RO * 32), .RESET_VALUE ('0)) u_status_handoff (
        .src_clk (mclk), .src_rst_n (rst_n),
        .src_bank (status), .commit (snap),
        .busy (st_busy_unused), .queued (st_queued_unused),
        .commits (st_commits_unused),
        .dst_clk (aclk), .dst_rst_n (aresetn),
        .dst_bank (ro_flat)
    );

    axil_reg_window #(
        .N_RW (1), .N_RO (N_RO), .ADDR_WIDTH (ADDR_WIDTH),
        .ID_VALUE (ID_VALUE), .CONFIG_VALUE (CONFIG_VALUE)
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
        .rw_flat (source), .ro_flat (ro_flat)
    );

endmodule
