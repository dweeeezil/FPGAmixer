// -----------------------------------------------------------------------------
// tb_timecode_regs.sv
//
// timecode_regs_axil over AXI4-Lite, across two unrelated clocks (aclk 100 MHz,
// mclk ~12.288 MHz), fed the vectors of src/sim/ltc_gen.py. P = 5 ports: port 2
// carries one timecode (segment A, 30 fps), port 4 another (segment B, 25 fps),
// the rest silence, so reading the wrong port gives the wrong time.
//
// Checks:
//   - ID, CONFIG, the reset state (SOURCE 0, nothing decoded);
//   - SOURCE 0: LTC on the ports decodes nothing;
//   - SOURCE = port 2 + 1: locks; every whole frame read (FRAMES, TC_LOW,
//     TC_HIGH, FRAMES, retried if FRAMES moved) is one of A's frames, and
//     FRAME_SAMPLES is A's 1,600; FRAMES climbs; SNAPSHOTS is live;
//   - SOURCE = port 4 + 1: the lock drops at once, then locks onto B: B's frames
//     and B's 1,920;
//   - a silent port: no lock, no new frames;
//   - SOURCE above P is off;
//   - the read-only words ignore writes; SOURCE reads back; WRITES counts.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_timecode_regs;

    `include "ltc_params.svh"

    localparam int P = 5, SW = 24;
    localparam int SEG_A = 0, SEG_B = 6;     // ltc_gen.py: 30 fps and 25 fps
    localparam int PORT_A = 2, PORT_B = 4;
    localparam int STROBE = 16;              // mclk cycles per sample (256 on the board)

    localparam logic [11:0] A_ID = 12'h000, A_CONFIG = 12'h004, A_WRITES = 12'h00C,
                            A_SOURCE = 12'h100, A_LOW = 12'h104, A_HIGH = 12'h108,
                            A_FRAMES = 12'h10C, A_LEN = 12'h110, A_FLAGS = 12'h114,
                            A_SNAP = 12'h118;

    logic aclk = 0, mclk = 0;
    always #5     aclk = ~aclk;
    always #40.69 mclk = ~mclk;
    logic aresetn = 0, rst_n = 0;

    logic [11:0] awaddr = 0, araddr = 0;
    logic [31:0] wdata = 0, rdata;
    logic [3:0]  wstrb = 4'hF;
    logic [1:0]  bresp, rresp;
    logic awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 0;
    logic arvalid = 0, arready, rvalid, rready = 0;

    logic            frame = 0;
    logic [P*SW-1:0] in_flat = '0;

    timecode_regs_axil #(.P (P), .SW (SW)) dut (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame), .in_flat (in_flat));

    logic [23:0]  mem_samples [0:N_SAMPLES-1];
    logic [95:0]  mem_expect  [0:N_EXPECT-1];
    logic [127:0] mem_meta    [0:N_SEG-1];

    int errors = 0;
    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            errors++;
            if (errors <= 25) $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
        end
    endtask

    // ----- AXI4-Lite -----
    task automatic wr(input logic [11:0] a, input logic [31:0] d);
        @(posedge aclk);
        awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; bready <= 1;
        do @(posedge aclk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge aclk);
        check("write response", 32'(bresp), 0);
        @(posedge aclk);
        bready <= 0;
    endtask

    task automatic rd(input logic [11:0] a, output logic [31:0] d);
        @(posedge aclk);
        araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge aclk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge aclk);
        d = rdata;
        check("read response", 32'(rresp), 0);
        @(posedge aclk);
        rready <= 0;
    endtask

    // ----- the ports: two streams, each looping over its segment -----
    int a_first, a_last, b_first, b_last, a_i, b_i, ctr = 0;
    logic streams_on = 0;

    always @(posedge mclk) begin
        ctr   <= (ctr == STROBE - 1) ? 0 : ctr + 1;
        frame <= (ctr == STROBE - 1) && streams_on;
    end
    always @(negedge mclk) if (ctr == 0 && streams_on) begin
        in_flat[PORT_A*SW +: SW] = mem_samples[a_i];
        in_flat[PORT_B*SW +: SW] = mem_samples[b_i];
        a_i = (a_i == a_last) ? a_first : a_i + 1;
        b_i = (b_i == b_last) ? b_first : b_i + 1;
    end

    function automatic bit in_segment(input int seg, input logic [63:0] word);
        int base = 0, n, x1, x2, x3;
        for (int s = 0; s < seg; s++) begin
            {x1, x2, x3, n} = mem_meta[s];
            base += n;
        end
        {x1, x2, x3, n} = mem_meta[seg];
        for (int k = base; k < base + n; k++)
            if (mem_expect[k][63:0] === word) return 1'b1;
        return 1'b0;
    endfunction

    // a whole frame, by the window's rule
    task automatic read_frame(output logic [63:0] word, output logic [31:0] count);
        logic [31:0] f1, f2, lo, hi;
        do begin
            rd(A_FRAMES, f1); rd(A_LOW, lo); rd(A_HIGH, hi); rd(A_FRAMES, f2);
        end while (f1 !== f2);
        word  = {hi, lo};
        count = f2;
    endtask

    task automatic wait_lock(input string what);
        logic [31:0] r;
        int guard = 0;
        do begin
            repeat (STROBE * 50) @(posedge mclk);
            rd(A_FLAGS, r);
            guard++;
        end while (r !== 32'h3 && guard < 400);
        check({what, ": locked"}, r, 32'h3);
    endtask

    // reads frames for a while: each must be one of the segment's
    task automatic watch(input string what, input int seg, input int len);
        logic [63:0] w;
        logic [31:0] c0, c, r;
        read_frame(w, c0);
        for (int n = 0; n < 40; n++) begin
            repeat (STROBE * 97) @(posedge mclk);
            read_frame(w, c);
            if (!in_segment(seg, w)) begin
                errors++;
                if (errors <= 25) $display("  FAIL %s: read %016h, not one of its frames", what, w);
            end
            rd(A_LEN, r);
            check({what, ": FRAME_SAMPLES"}, r, 32'(len));
        end
        if (c == c0) begin errors++; $display("  FAIL %s: FRAMES didn't climb", what); end
    endtask

    logic [31:0] r, r2, count;
    logic [63:0] word;
    int x, y;

    initial begin
        $readmemh("ltc_samples.mem", mem_samples);
        $readmemh("ltc_expect.mem",  mem_expect);
        $readmemh("ltc_meta.mem",    mem_meta);
        {a_first, a_last, x, y} = mem_meta[SEG_A];
        {b_first, b_last, x, y} = mem_meta[SEG_B];
        a_i = a_first;
        b_i = b_first;

        repeat (10) @(posedge aclk);
        aresetn = 1;
        repeat (10) @(posedge mclk);
        rst_n = 1;
        repeat (10) @(posedge mclk);

        rd(A_ID, r);     check("ID", r, 32'h5443_5001);
        rd(A_CONFIG, r); check("CONFIG", r, 32'(P));
        rd(A_SOURCE, r); check("SOURCE after reset", r, 0);
        rd(A_FLAGS, r);  check("FLAGS after reset", r, 0);
        rd(A_FRAMES, r); check("FRAMES after reset", r, 0);

        streams_on = 1;

        // ----- off: LTC on the ports, nothing decoded -----
        repeat (STROBE * 6000) @(posedge mclk);
        rd(A_FLAGS, r);  check("off: FLAGS", r, 0);
        rd(A_FRAMES, r); check("off: FRAMES", r, 0);
        rd(A_SNAP, r); repeat (STROBE * 20) @(posedge mclk); rd(A_SNAP, r2);
        if (r2 == r) begin errors++; $display("  FAIL SNAPSHOTS isn't live"); end

        // ----- port A -----
        wr(A_SOURCE, 32'(PORT_A + 1));
        rd(A_SOURCE, r); check("SOURCE reads back", r, 32'(PORT_A + 1));
        wait_lock("port A");
        watch("port A", SEG_A, 1600);

        // ----- port B: the lock drops at once, and nothing of A carries over -----
        wr(A_SOURCE, 32'(PORT_B + 1));
        repeat (12) @(posedge mclk);
        rd(A_FLAGS, r); check("switching: the lock drops at once", r & 32'h2, 0);
        wait_lock("port B");
        watch("port B", SEG_B, 1920);

        // ----- a silent port: no lock, no new frames -----
        wr(A_SOURCE, 32'd1);
        repeat (STROBE * 5000) @(posedge mclk);
        rd(A_FLAGS, r); check("silent port: FLAGS", r, 0);
        read_frame(word, count);
        repeat (STROBE * 4000) @(posedge mclk);
        rd(A_FRAMES, r); check("silent port: FRAMES stands", r, count);

        // ----- above P is off, even with LTC on the port it would alias to -----
        wr(A_SOURCE, 32'(PORT_A + 1));
        wait_lock("port A again");
        wr(A_SOURCE, 32'h0001_0000 + 32'(PORT_A + 1));
        repeat (STROBE * 5000) @(posedge mclk);
        rd(A_FLAGS, r); check("above P: FLAGS", r, 0);
        wr(A_SOURCE, 32'(P + 1));
        repeat (STROBE * 5000) @(posedge mclk);
        rd(A_FLAGS, r); check("P + 1: FLAGS", r, 0);
        check("P + 1: hears nothing", 32'(dut.sample), 0);

        // ----- read-only words -----
        rd(A_FRAMES, r2);
        wr(A_FRAMES, 32'hDEAD_BEEF);
        wr(A_LOW,    32'hDEAD_BEEF);
        wr(A_ID,     32'hDEAD_BEEF);
        rd(A_FRAMES, r); check("FRAMES ignores writes", r, r2);
        rd(A_ID, r);     check("ID ignores writes", r, 32'h5443_5001);
        rd(A_WRITES, r); check("WRITES counts SOURCE only", r, 32'd6);

        if (errors == 0) $display("PASS: tb_timecode_regs");
        else             $display("FAIL: tb_timecode_regs - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #2s;
        $display("FAIL: tb_timecode_regs TIMEOUT");
        $finish;
    end

endmodule
