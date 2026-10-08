// -----------------------------------------------------------------------------
// ps_sys_wrapper_stub.sv  (simulation only; never synthesized, and kept out
// of the Vivado project's sim fileset, where the real BD wrapper lives)
//
// A stand-in for the block design's ps_sys_wrapper in a PS build WITHOUT the
// links or the media clock (INCLUDE_PS only, as a phase5 build): the
// AXI4-Lite masters fpgamixer_top's register windows hang off, each driven by
// a small BFM, plus ctrl_aclk (100 MHz) and ctrl_aresetn. Lets a TB check the
// platform layer's window wiring (tb_top_windows) without Vivado.
//
// Masters (index for axi_write / axi_read):
//   0 M_AXI_CTRL   (input matrix)     1 M_AXI_BUSMX  (bus matrix)
//   2 M_AXI_INLVL  (input levels)     3 M_AXI_BUSLVL (bus levels)
//   4 M_AXI_OUTLVL (output levels)
//   5 M_AXI_INMTR / 6 M_AXI_BUSMTR / 7 M_AXI_OUTMTR (peak meters, Phase 13)
//   8 M_AXI_INPATCH / 9 M_AXI_OUTPATCH (the I/O patch, Phase 15)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`define AXIL_MASTER_PORTS(P) \
    output logic [31:0] P``_awaddr, output logic [2:0] P``_awprot, \
    output logic P``_awvalid, input logic P``_awready, \
    output logic [31:0] P``_wdata, output logic [3:0] P``_wstrb, \
    output logic P``_wvalid, input logic P``_wready, \
    input logic [1:0] P``_bresp, input logic P``_bvalid, output logic P``_bready, \
    output logic [31:0] P``_araddr, output logic [2:0] P``_arprot, \
    output logic P``_arvalid, input logic P``_arready, \
    input logic [31:0] P``_rdata, input logic [1:0] P``_rresp, \
    input logic P``_rvalid, output logic P``_rready

`define AXIL_MASTER_BIND(P, I) \
    assign P``_awaddr = awaddr[I]; assign P``_awprot = 3'b000; \
    assign P``_awvalid = awvalid[I]; assign awready[I] = P``_awready; \
    assign P``_wdata = wdata[I]; assign P``_wstrb = wstrb[I]; \
    assign P``_wvalid = wvalid[I]; assign wready[I] = P``_wready; \
    assign bresp[I] = P``_bresp; assign bvalid[I] = P``_bvalid; \
    assign P``_bready = bready[I]; \
    assign P``_araddr = araddr[I]; assign P``_arprot = 3'b000; \
    assign P``_arvalid = arvalid[I]; assign arready[I] = P``_arready; \
    assign rdata[I] = P``_rdata; assign rresp[I] = P``_rresp; \
    assign rvalid[I] = P``_rvalid; assign P``_rready = rready[I];

module ps_sys_wrapper (
    output logic ctrl_aclk,
    output logic ctrl_aresetn,
    `AXIL_MASTER_PORTS(M_AXI_CTRL),
    `AXIL_MASTER_PORTS(M_AXI_BUSMX),
    `AXIL_MASTER_PORTS(M_AXI_INLVL),
    `AXIL_MASTER_PORTS(M_AXI_BUSLVL),
    `AXIL_MASTER_PORTS(M_AXI_OUTLVL),
    `AXIL_MASTER_PORTS(M_AXI_INMTR),
    `AXIL_MASTER_PORTS(M_AXI_BUSMTR),
    `AXIL_MASTER_PORTS(M_AXI_OUTMTR),
    `AXIL_MASTER_PORTS(M_AXI_INPATCH),
    `AXIL_MASTER_PORTS(M_AXI_OUTPATCH)
);
    localparam int NM = 10;

    initial begin ctrl_aclk = 0; ctrl_aresetn = 0; #100 ctrl_aresetn = 1; end
    always #5 ctrl_aclk = ~ctrl_aclk;

    logic [31:0] awaddr [NM], wdata [NM], araddr [NM], rdata [NM];
    logic [3:0]  wstrb [NM];
    logic [1:0]  bresp [NM], rresp [NM];
    logic        awvalid [NM], awready [NM], wvalid [NM], wready [NM];
    logic        bvalid [NM], bready [NM], arvalid [NM], arready [NM];
    logic        rvalid [NM], rready [NM];

    initial
        for (int m = 0; m < NM; m++) begin
            awaddr[m] = 0; wdata[m] = 0; araddr[m] = 0; wstrb[m] = 0;
            awvalid[m] = 0; wvalid[m] = 0; bready[m] = 0; arvalid[m] = 0; rready[m] = 0;
        end

    `AXIL_MASTER_BIND(M_AXI_CTRL,   0)
    `AXIL_MASTER_BIND(M_AXI_BUSMX,  1)
    `AXIL_MASTER_BIND(M_AXI_INLVL,  2)
    `AXIL_MASTER_BIND(M_AXI_BUSLVL, 3)
    `AXIL_MASTER_BIND(M_AXI_OUTLVL, 4)
    `AXIL_MASTER_BIND(M_AXI_INMTR,  5)
    `AXIL_MASTER_BIND(M_AXI_BUSMTR, 6)
    `AXIL_MASTER_BIND(M_AXI_OUTMTR, 7)
    `AXIL_MASTER_BIND(M_AXI_INPATCH, 8)
    `AXIL_MASTER_BIND(M_AXI_OUTPATCH, 9)

    int bus_errors = 0;   // non-OKAY responses

    task automatic axi_write(input int m, input logic [31:0] a, input logic [31:0] d);
        @(posedge ctrl_aclk);
        awaddr[m] <= a; awvalid[m] <= 1; wdata[m] <= d; wstrb[m] <= 4'hF;
        wvalid[m] <= 1; bready[m] <= 1;
        do @(posedge ctrl_aclk); while (!(awready[m] && wready[m]));
        awvalid[m] <= 0; wvalid[m] <= 0;
        while (!bvalid[m]) @(posedge ctrl_aclk);
        if (bresp[m] !== 2'b00) bus_errors++;
        @(posedge ctrl_aclk);
        bready[m] <= 0;
    endtask

    task automatic axi_read(input int m, input logic [31:0] a, output logic [31:0] d);
        @(posedge ctrl_aclk);
        araddr[m] <= a; arvalid[m] <= 1; rready[m] <= 1;
        do @(posedge ctrl_aclk); while (!arready[m]);
        arvalid[m] <= 0;
        while (!rvalid[m]) @(posedge ctrl_aclk);
        d = rdata[m];
        if (rresp[m] !== 2'b00) bus_errors++;
        @(posedge ctrl_aclk);
        rready[m] <= 0;
    endtask

endmodule

`undef AXIL_MASTER_PORTS
`undef AXIL_MASTER_BIND
