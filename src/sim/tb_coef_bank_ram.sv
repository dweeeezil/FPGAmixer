// -----------------------------------------------------------------------------
// tb_coef_bank_ram.sv
//
// P9.A3: coef_bank_ram (and coef_flat_reader) on unrelated clocks:
// aclk 100 MHz, mclk 12.2919 MHz, a frame strobe every 256 mclk.
//
// Every coefficient written is tagged: coef = {version[7:0], k[9:0]}, so one
// frame's reads tell exactly which bank(s) they came from. A reader on the
// mclk port reads all words of the bank in cycles 1..DEPTH after each strobe,
// as a time-shared block does, maps them back through the layout
// (row r -> lane r % LANES, word (r / LANES)*ROW_LEN + c) and checks:
//   - LAYOUT: coefficient k carries index k (idle lane slots read 0);
//   - ATOMIC: all coefficients of one frame carry the same version;
//   - ORDER: the version never goes back, except to 0 (the reset bank) after
//     an aclk reset, and only then.
// The aclk side, through the store interface:
//   1. after reset: the reset bank (version 0) in effect, COMMITS = 0;
//   2. readback of written values;
//   3. random bursts: write a whole new version, COMMIT, and immediately start
//      the next version (writes during the copy must stall, else a frame
//      would mix versions); sometimes several COMMITs back to back (QUEUED);
//      each committed version must appear at the port, and the last one must
//      end up in effect;
//   4. aclk reset alone mid-run: the reset bank comes back via the normal
//      path, never an older bank.
// Plus coef_flat_reader: fed a tagged flat vector, the same reader decodes
// the same bank (layout equivalence).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module bank_harness #(
    parameter int N_ROWS  = 5,
    parameter int ROW_LEN = 7,
    parameter int LANES   = 3,
    parameter int ROUNDS  = 30
) (
    input  logic aclk,
    input  logic mclk,
    input  logic frame,
    input  int   cyc,
    output int   errors,
    output bit   done
);
    localparam int W      = 18;
    localparam int N_COEF = N_ROWS * ROW_LEN;
    localparam int PASSES = (N_ROWS + LANES - 1) / LANES;
    localparam int DEPTH  = PASSES * ROW_LEN;
    localparam int IW     = (N_COEF > 1) ? $clog2(N_COEF) : 1;
    localparam int AW     = (DEPTH  > 1) ? $clog2(DEPTH)  : 1;

    function automatic logic [W-1:0] tag(input int v, input int k);
        return {v[7:0], k[9:0]};
    endfunction

    function automatic logic [N_COEF*W-1:0] bank_of(input int v);
        logic [N_COEF*W-1:0] b;
        for (int k = 0; k < N_COEF; k++) b[k*W +: W] = tag(v, k);
        return b;
    endfunction

    localparam logic [N_COEF*W-1:0] RESET_BANK = bank_of(0);

    // ----- DUT -----
    logic             aresetn = 0;
    logic             st_valid = 0, st_we = 0, st_ready, st_rvalid;
    logic [IW-1:0]    st_idx = '0;
    logic [W-1:0]     st_wdata = '0, st_rdata;
    logic             commit = 0, busy, queued;
    logic [31:0]      commits;
    logic [AW-1:0]    rd_addr;
    logic [LANES*W-1:0] rd_data, fr_data;

    coef_bank_ram #(.W (W), .N_ROWS (N_ROWS), .ROW_LEN (ROW_LEN), .LANES (LANES),
                    .RESET_COEFS (RESET_BANK)) dut (
        .aclk (aclk), .aresetn (aresetn),
        .st_valid (st_valid), .st_ready (st_ready), .st_we (st_we),
        .st_idx (st_idx), .st_wdata (st_wdata),
        .st_rvalid (st_rvalid), .st_rdata (st_rdata),
        .commit (commit), .busy (busy), .queued (queued), .commits (commits),
        .mclk (mclk), .frame_i (frame), .rd_addr (rd_addr), .rd_data (rd_data));

    // coef_flat_reader on the same addresses, fed a fixed tagged bank (v = 99)
    coef_flat_reader #(.W (W), .N_ROWS (N_ROWS), .ROW_LEN (ROW_LEN), .LANES (LANES)) u_flat (
        .mclk (mclk), .frame_i (frame), .coefs_flat (bank_of(99)),
        .rd_addr (rd_addr), .rd_data (fr_data));

    int err = 0;
    task automatic fail(input string s);
        err++;
        if (err <= 12) $display("[%0t] %0dx%0d/L%0d: %s", $time, N_ROWS, ROW_LEN, LANES, s);
    endtask

    // ----- mclk reader: words in cycles 1..DEPTH, data one cycle later -----
    assign rd_addr = (cyc >= 1 && cyc <= DEPTH) ? AW'(cyc - 1) : '0;

    int  last_v = 0;         // last version seen at the port
    int  frames_seen = 0;
    bit  expect_reset = 0;   // an aclk reset happened: only 0 (or inflight_v) may appear
    int  inflight_v = -1;
    int  seen_versions [$];
    logic [LANES*W-1:0] got   [DEPTH];
    logic [LANES*W-1:0] got_f [DEPTH];

    always @(posedge mclk) begin
        if (cyc >= 2 && cyc <= DEPTH + 1) begin
            got[cyc - 2]   = rd_data;
            got_f[cyc - 2] = fr_data;
        end
        if (cyc == DEPTH + 1) begin : check_frame
            int v0; bit mixed; bit bad_layout; bit bad_flat;
            v0 = -1; mixed = 0; bad_layout = 0; bad_flat = 0;
            for (int p = 0; p < PASSES; p++)
                for (int c = 0; c < ROW_LEN; c++)
                    for (int l = 0; l < LANES; l++) begin
                        int r; logic [W-1:0] x, xf;
                        r  = p*LANES + l;
                        x  = got  [p*ROW_LEN + c][l*W +: W];
                        xf = got_f[p*ROW_LEN + c][l*W +: W];
                        if (r >= N_ROWS) begin
                            if (x !== '0 || xf !== '0) bad_layout = 1;
                        end else begin
                            if (x[9:0] !== 10'(r*ROW_LEN + c)) bad_layout = 1;
                            if (v0 < 0) v0 = x[17:10];
                            else if (int'(x[17:10]) != v0) mixed = 1;
                            if (xf !== tag(99, r*ROW_LEN + c)) bad_flat = 1;
                        end
                    end
            if (bad_layout) fail("LAYOUT: a coefficient read at the wrong word/lane");
            if (bad_flat)   fail("coef_flat_reader: layout differs");
            if (mixed)      fail("ATOMIC: one frame read two banks");
            if (!mixed && v0 >= 0 && v0 != last_v) begin
                if (expect_reset) begin
                    // only the reset bank, or the commit that was in flight
                    if (v0 == 0)                expect_reset = 0;
                    else if (v0 != inflight_v)  fail($sformatf("after aclk reset: version %0d, want 0 (or %0d in flight)", v0, inflight_v));
                end else if (v0 < last_v) begin
                    fail($sformatf("ORDER: version %0d after %0d", v0, last_v));
                end
                last_v = v0;
                seen_versions.push_back(v0);
            end
            frames_seen++;
        end
    end

    int queued_cycles = 0;
    always @(posedge aclk) if (aresetn && queued) queued_cycles++;

    // ----- aclk side: store interface -----
    task automatic st_write(input int k, input logic [W-1:0] d);
        @(negedge aclk);
        st_valid = 1; st_we = 1; st_idx = IW'(k); st_wdata = d;
        forever begin @(posedge aclk); if (st_ready) break; end
        @(negedge aclk) st_valid = 0; st_we = 0;
    endtask

    task automatic st_read(input int k, output logic [W-1:0] d);
        @(negedge aclk);
        st_valid = 1; st_we = 0; st_idx = IW'(k);
        forever begin @(posedge aclk); if (st_ready) break; end
        @(negedge aclk) st_valid = 0;
        @(posedge aclk);
        if (!st_rvalid) fail("st_rvalid missing");
        d = st_rdata;
    endtask

    task automatic do_commit();
        @(negedge aclk) commit = 1;
        @(negedge aclk) commit = 0;
    endtask

    task automatic wait_idle();
        do @(posedge aclk); while (busy || queued);
    endtask

    task automatic wait_frames(input int n);
        int target;
        target = frames_seen + n;
        wait (frames_seen >= target);
    endtask

    task automatic write_version(input int v, input bit shuffle);
        int order [N_COEF];
        for (int k = 0; k < N_COEF; k++) order[k] = k;
        if (shuffle) order.shuffle();
        foreach (order[j]) st_write(order[j], tag(v, order[j]));
    endtask

    initial begin
        logic [W-1:0] d;
        automatic int v = 0;
        int commits0, launched;
        errors = 0; done = 0;

        // ----- 1. reset -----
        repeat (4) @(posedge aclk);
        aresetn = 1;
        wait_idle();
        wait_frames(2);
        if (last_v != 0 || seen_versions.size() != 0) fail("reset bank not in effect");
        if (commits != 0) fail($sformatf("COMMITS = %0d after reset, want 0", commits));

        // ----- 2. readback -----
        st_write(3 % N_COEF, 18'h2_A5A5);
        st_read (3 % N_COEF, d);
        if (d !== 18'h2_A5A5) fail($sformatf("readback %h", d));
        st_read (1, d);
        if (d !== tag(0, 1)) fail($sformatf("readback of the reset value %h", d));

        // ----- 3. random bursts -----
        commits0 = commits;
        launched = 0;
        for (int round = 0; round < ROUNDS; round++) begin
            automatic int n = 1 + ($urandom % 3); // commits back to back
            for (int j = 0; j < n; j++) begin
                v++;
                write_version(v, $urandom % 2);
                do_commit();                      // the next version starts at once
            end
            if ($urandom % 3 == 0) begin
                wait_idle();
                wait_frames(2);
                if (last_v != v) fail($sformatf("after idle: version %0d in effect, want %0d", last_v, v));
            end
        end
        wait_idle();
        wait_frames(2);
        if (last_v != v) fail($sformatf("final: version %0d in effect, want %0d", last_v, v));
        $display("  %0dx%0d/L%0d: %0d versions committed, %0d seen at the port, COMMITS +%0d, %0d aclk cycles with QUEUED",
                 N_ROWS, ROW_LEN, LANES, v, seen_versions.size(), commits - commits0, queued_cycles);
        // Writes stall while a commit is queued, so no two commits merge and
        // each bank is in effect for at least one frame: all must be seen.
        if (commits - commits0 != v)     fail("COMMITS: not one per commit");
        if (seen_versions.size() != v)   fail("a committed version never reached the port");
        if (queued_cycles == 0)          fail("QUEUED never exercised");

        // ----- 4. aclk reset alone, with a commit in flight, twice: the
        //          reset's own commit flips the bank, so the two passes cover
        //          both bank parities -----
        for (int rep = 0; rep < 2; rep++) begin
            v++;
            write_version(v, 0);
            do_commit();
            repeat (3) @(posedge aclk);  // the copy of v is running
            inflight_v   = v;
            expect_reset = 1;
            @(negedge aclk) aresetn = 0;
            repeat (3) @(negedge aclk);
            aresetn = 1;
            wait_idle();
            wait_frames(3);
            if (last_v != 0) fail($sformatf("after aclk reset %0d: version %0d in effect, want 0", rep, last_v));
            if (commits != 0) fail("COMMITS not 0 after aclk reset");
        end

        errors = err;
        done = 1;
    end
endmodule


module tb_coef_bank_ram;

    logic aclk = 0, mclk = 0;
    always #5      aclk = ~aclk;       // 100 MHz
    always #40.678 mclk = ~mclk;       // 12.2919 MHz, unrelated

    logic frame = 0;
    int   cyc = -1, ctr = 0;
    always @(posedge mclk) begin
        ctr   <= (ctr == 255) ? 0 : ctr + 1;
        frame <= (ctr == 255);
        cyc   <= frame ? 0 : (cyc >= 0 ? cyc + 1 : -1);
    end

    int e_a, e_b;
    bit d_a, d_b;
    bank_harness #(.N_ROWS (5),  .ROW_LEN (7),  .LANES (3), .ROUNDS (30)) u_a (
        .aclk, .mclk, .frame, .cyc, .errors (e_a), .done (d_a));
    bank_harness #(.N_ROWS (12), .ROW_LEN (12), .LANES (1), .ROUNDS (20)) u_b (
        .aclk, .mclk, .frame, .cyc, .errors (e_b), .done (d_b));

    initial begin
        wait (d_a && d_b);
        $display("5x7, 3 lanes : %0d errors", e_a);
        $display("12x12, 1 lane: %0d errors", e_b);
        if (e_a + e_b == 0) $display("PASS tb_coef_bank_ram");
        else                $display("FAIL tb_coef_bank_ram");
        $finish;
    end

    initial begin
        #200ms;
        $display("FAIL tb_coef_bank_ram: timeout (done %0d %0d)", d_a, d_b);
        $finish;
    end

endmodule
