// -----------------------------------------------------------------------------
// pcm_insert_loop.sv
//
// Closes one of mixer_core's insert ports when nothing is inserted there:
// the send stream comes back unchanged, exactly INS_LAT cycles later
// (mixer_core_pkg::INS_LAT), as the core requires of every return. For
// builds without the insert router and for TBs of the core alone.
// (docs/insert_architecture_proposal_2026-10-31.md sec. 11.1)
// -----------------------------------------------------------------------------
module pcm_insert_loop
    import mixer_core_pkg::*;
#(
    parameter int N  = 4,       // channels
    parameter int SW = 24,
    localparam int CW = (N > 1) ? $clog2(N) : 1
) (
    input  logic          mclk,
    input  logic          rst_n,
    input  logic          send_valid,
    input  logic [CW-1:0] send_ch,
    input  logic [SW-1:0] send_data,
    output logic          ret_valid,
    output logic [CW-1:0] ret_ch,
    output logic [SW-1:0] ret_data
);

    logic          v [INS_LAT];
    logic [CW-1:0] c [INS_LAT];
    logic [SW-1:0] d [INS_LAT];

    always_ff @(posedge mclk) begin
        if (!rst_n) for (int j = 0; j < INS_LAT; j++) v[j] <= 1'b0;
        else begin
            v[0] <= send_valid;
            for (int j = 1; j < INS_LAT; j++) v[j] <= v[j-1];
        end
        c[0] <= send_ch;
        d[0] <= send_data;
        for (int j = 1; j < INS_LAT; j++) begin
            c[j] <= c[j-1];
            d[j] <= d[j-1];
        end
    end

    assign ret_valid = v[INS_LAT-1];
    assign ret_ch    = c[INS_LAT-1];
    assign ret_data  = d[INS_LAT-1];

endmodule
