// -----------------------------------------------------------------------------
// insert_router_pkg.sv
//
// The insert router's numbers and table format, in one place, so the router,
// its register binding, its TB and the server can't disagree.
// (docs/insert_architecture_proposal_2026-10-31.md sec. 2, 3, 11)
//
// ----- Timing, in frames -----
// Every pool runs once per frame: slot s's input beat leaves the router at
// POOL_IN_FIRST + s cycles after the strobe. A run reads the zones' PREVIOUS
// frame (history) and the pools' PREVIOUS run (their output buffers), so
// neither the pools' nor the zones' order matters. With two hand-offs
// (zone -> pool, pool -> zone):
//   every insert point delays every channel by delay_frames(K) = K + 1;
//   a dry channel returns its own sample from K + 1 frames ago;
//   a chain of n slots (n <= K) reads its head from head_age(K, n) = K - n
//   (frames before the previous one) and returns exactly K + 1 frames late.
// The history keeps hist_frames(K) = K + 2 frames per zone channel.
//
// ----- A table entry (EW = 18 bits; one register each) -----
//   [17:16] kind   0 = none / dry, 1 = a zone channel, 2 = a pool slot
//   [15:12] sel    kind 1: the zone (0 inputs, 1 buses, 2 outputs)
//                  kind 2: the pool
//   [11:8]  age    kind 1: frames before the previous one, 0 .. K
//   [7:0]   idx    kind 1: the channel; kind 2: the slot
// SOURCE (one per pool slot): kind 0 = silence, 1 = a zone channel's
// history, 2 = another slot's output (its previous run).
// RETURN (one per zone channel): kind 2 = the slot that ends the chain;
// anything else = dry. Out-of-range entries read as silence (SOURCE) or dry
// (RETURN): the hardware never reads outside its buffers.
//
// ----- Table layout (one bank, one COMMIT: insert_router_regs_axil) -----
//   RETURN inputs  0 .. N_I-1
//   RETURN buses   N_I .. N_I+N_B-1
//   RETURN outputs N_I+N_B .. N_I+N_B+N_O-1
//   SOURCE pool p  N_I+N_B+N_O + p*S + s
// -----------------------------------------------------------------------------
package insert_router_pkg;

    import mixer_core_pkg::*;     // FRAME, INS_LAT

    localparam int EW = 18;                  // a table entry
    localparam logic [1:0] KIND_NONE = 2'd0;
    localparam logic [1:0] KIND_ZONE = 2'd1;
    localparam logic [1:0] KIND_SLOT = 2'd2;
    localparam int ZONE_IN  = 0;
    localparam int ZONE_BUS = 1;
    localparam int ZONE_OUT = 2;
    localparam int POOL_IN_FIRST = 4;        // slot 0's input beat, cycles after the strobe

    function automatic int hist_frames(input int k);
        return k + 2;
    endfunction
    function automatic int delay_frames(input int k);
        return k + 1;
    endfunction
    function automatic int head_age(input int k, input int n);
        return k - n;
    endfunction

    function automatic logic [EW-1:0] ent_zone(input int zone, input int ch, input int age);
        return {KIND_ZONE, 4'(zone), 4'(age), 8'(ch)};
    endfunction
    function automatic logic [EW-1:0] ent_slot(input int pool, input int slot);
        return {KIND_SLOT, 4'(pool), 4'd0, 8'(slot)};
    endfunction
    localparam logic [EW-1:0] ENT_DRY = '0;

    // Whether the router's frame rules hold: each zone's send stream lies
    // inside its own frame (beats 1 .. FRAME cycles after the strobe; a chain
    // that spans frames, LF1, doesn't fit yet), and every pool is done with
    // its run, whose last output beat comes pool_lat cycles after its last
    // input beat, within the frame.
    function automatic bit router_fits(input int send_last_i, input int send_last_b,
                                       input int send_last_o, input int s,
                                       input int pool_lat, input int k);
        return send_last_i <= FRAME && send_last_b <= FRAME && send_last_o <= FRAME
            && POOL_IN_FIRST + (s - 1) + pool_lat <= FRAME
            && s >= 1 && s <= 256 && k >= 0 && k <= 15;
    endfunction

endpackage
