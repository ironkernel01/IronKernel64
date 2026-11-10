// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_ddr_sim.sv
// Purpose: self-checking bench for the simulation path of ik64_ddr (IK64_DDR_SIM:
//   ik64_ddr_sim, the AXI4 memory model that stands in for the MIG).
// Cases:
//   1. Reset and calibration: ui_resetn releases before init_calib_complete; the
//      AXI readies stay low until calibration completes and rise after it.
//   2. INCR 4-beat and 16-beat bursts: write, read back; the first read beat
//      arrives at least 20 clocks after the AR handshake; RLAST on the last beat.
//   3. Narrow write (size 2, one beat, lane strobes 8..11): only those bytes
//      change; the read returns the whole 128-bit word.
//   4. WRAP reads: 4 beats from word 2 of a 64-byte container (order 2,3,0,1) and
//      2 beats from word 1 of a 32-byte container (order 1,0).
//   5. IDs: B returns the write ID; two reads issued back to back return their
//      data in order with their own IDs.
//   6. A partial-strobe wide write keeps the unselected bytes.
//   7. sys_rstn low drops init_calib_complete and ui_resetn; the model recovers.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_ddr_sim;

  import ik64_tb_pkg::*;

  localparam int AWD = 29;
  localparam int DW  = 128;
  localparam int IDW = 2;

  logic clk = 1'b0;
  always #5.0 clk = ~clk;

  logic sys_rstn = 1'b0;
  logic ui_clk, ui_resetn, init_calib_complete;

  logic [IDW-1:0]  awid = '0, arid = '0, bid, rid;
  logic [AWD-1:0]  awaddr = '0, araddr = '0;
  logic [7:0]      awlen = '0, arlen = '0;
  logic [2:0]      awsize = '0, arsize = '0;
  logic [1:0]      awburst = '0, arburst = '0;
  logic            awvalid = 1'b0, awready, wvalid = 1'b0, wready, bvalid, bready = 1'b0;
  logic            arvalid = 1'b0, arready, rvalid, rready = 1'b0, rlast, wlast = 1'b0;
  logic [DW-1:0]   wdata = '0, rdata;
  logic [DW/8-1:0] wstrb = '0;
  logic [1:0]      bresp, rresp;

  wire  [15:0] ddr3_dq;
  wire  [1:0]  ddr3_dqs_n, ddr3_dqs_p;
  logic [14:0] ddr3_addr;
  logic [2:0]  ddr3_ba;
  logic        ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n;
  logic [0:0]  ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_odt;
  logic [1:0]  ddr3_dm;

  ik64_ddr #(.ADDR_W(AWD), .DATA_W(DW), .ID_W(IDW)) u_dut (
    .sys_clk(clk), .ref_clk(1'b0), .sys_rstn(sys_rstn),
    .ui_clk(ui_clk), .ui_resetn(ui_resetn), .s_axi_aresetn(ui_resetn), .init_calib_complete(init_calib_complete),
    .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awburst(awburst),
    .s_axi_awlock(1'b0), .s_axi_awcache(4'b0011), .s_axi_awprot(3'b000), .s_axi_awqos(4'b0000),
    .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize), .s_axi_arburst(arburst),
    .s_axi_arlock(1'b0), .s_axi_arcache(4'b0011), .s_axi_arprot(3'b000), .s_axi_arqos(4'b0000),
    .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
    .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt));

  // Burst data for the master tasks (beat i of a burst).
  logic [DW-1:0]   wd [16];
  logic [DW/8-1:0] ws [16];
  logic [DW-1:0]   rd [16];
  logic [IDW-1:0]  rid_seen [16];
  int              rlast_seen;
  int              first_beat_clocks;

  function automatic logic [DW-1:0] pat(input int seed, input int i);
    logic [DW-1:0] x;
    for (int k = 0; k < 4; k++) x[32*k +: 32] = 32'h1000_0001 * (seed + 1) + 32'h0101_0101 * (i * 4 + k) + 32'h0000_00F3 * k;
    return x;
  endfunction

  task automatic do_write(input logic [IDW-1:0] id, input logic [AWD-1:0] addr, input int len, input int size, input int burst,
                          output logic [IDW-1:0] bid_seen, output logic [1:0] resp);
    @(posedge clk);
    awid <= id; awaddr <= addr; awlen <= 8'(len); awsize <= 3'(size); awburst <= 2'(burst); awvalid <= 1'b1;
    do @(posedge clk); while (!awready);
    awvalid <= 1'b0;
    for (int i = 0; i <= len; i++) begin
      wdata <= wd[i]; wstrb <= ws[i]; wlast <= (i == len); wvalid <= 1'b1;
      do @(posedge clk); while (!wready);
    end
    wvalid <= 1'b0; wlast <= 1'b0;
    bready <= 1'b1;
    do @(posedge clk); while (!bvalid);
    bid_seen = bid; resp = bresp;
    bready <= 1'b0;
  endtask

  task automatic do_read(input logic [IDW-1:0] id, input logic [AWD-1:0] addr, input int len, input int size, input int burst);
    int t;
    @(posedge clk);
    arid <= id; araddr <= addr; arlen <= 8'(len); arsize <= 3'(size); arburst <= 2'(burst); arvalid <= 1'b1;
    do @(posedge clk); while (!arready);
    arvalid <= 1'b0;
    rready <= 1'b1;
    t = 0;
    rlast_seen = -1;
    for (int i = 0; i <= len; i++) begin
      do begin @(posedge clk); t++; end while (!rvalid && t < 200);
      if (i == 0) first_beat_clocks = t;
      rd[i] = rdata; rid_seen[i] = rid;
      if (rlast) rlast_seen = i;
    end
    rready <= 1'b0;
  endtask

  logic [IDW-1:0] bs;
  logic [1:0]     rs;
  logic [DW-1:0]  oldw, neww;
  int             n;

  initial begin
    sys_rstn = 1'b0;
    repeat (5) @(posedge clk);
    sys_rstn = 1'b1;

    // 1. Calibration gating.
    n = 0;
    while (!ui_resetn && n < 100) begin @(posedge clk); n++; end
    tb_check(ui_resetn && !init_calib_complete, "ui_resetn must release before init_calib_complete");
    repeat (20) @(posedge clk);
    tb_check(!awready && !wready && !arready, "readies high before calibration");
    n = 0;
    while (!init_calib_complete && n < 4000) begin @(posedge clk); n++; end
    tb_check(init_calib_complete, "init_calib_complete never rose");
    repeat (4) @(posedge clk);
    tb_check(awready && arready, "awready/arready low after calibration");

    // 2. INCR 4 and 16 beats.
    for (int i = 0; i < 4; i++) begin wd[i] = pat(1, i); ws[i] = '1; end
    do_write(2'd3, 29'h000_0100, 3, 4, 1, bs, rs);
    tb_check(bs == 2'd3 && rs == 2'b00, $sformatf("B id %0d resp %0d", bs, rs));
    do_read(2'd1, 29'h000_0100, 3, 4, 1);
    for (int i = 0; i < 4; i++) tb_check(rd[i] === pat(1, i), $sformatf("INCR4 beat %0d = %h", i, rd[i]));
    tb_check(rlast_seen == 3, $sformatf("RLAST at beat %0d, expected 3", rlast_seen));
    tb_check(first_beat_clocks >= 20, $sformatf("first read beat after %0d clocks, expected at least 20", first_beat_clocks));
    for (int i = 0; i < 16; i++) begin wd[i] = pat(2, i); ws[i] = '1; end
    do_write(2'd0, 29'h000_1000, 15, 4, 1, bs, rs);
    do_read(2'd2, 29'h000_1000, 15, 4, 1);
    for (int i = 0; i < 16; i++) tb_check(rd[i] === pat(2, i), $sformatf("INCR16 beat %0d", i));
    tb_check(rlast_seen == 15 && rid_seen[15] == 2'd2, "INCR16 RLAST / RID");

    // 3. Narrow write, lanes 8..11 of the word at 0x200.
    wd[0] = pat(3, 0); ws[0] = '1;
    do_write(2'd0, 29'h000_0200, 0, 4, 1, bs, rs);
    oldw = pat(3, 0);
    neww = oldw;
    neww[8*8 +: 32] = 32'hDEAD_BEEF;
    wd[0] = '0; wd[0][8*8 +: 32] = 32'hDEAD_BEEF; ws[0] = 16'h0F00;
    do_write(2'd0, 29'h000_0208, 0, 2, 1, bs, rs);
    do_read(2'd0, 29'h000_0200, 0, 4, 1);
    tb_check(rd[0] === neww, $sformatf("narrow write: %h expected %h", rd[0], neww));

    // 4. WRAP reads.
    for (int i = 0; i < 4; i++) begin wd[i] = pat(4, i); ws[i] = '1; end
    do_write(2'd0, 29'h000_0300, 3, 4, 1, bs, rs);
    do_read(2'd0, 29'h000_0320, 3, 4, 2);
    tb_check(rd[0] === pat(4, 2) && rd[1] === pat(4, 3) && rd[2] === pat(4, 0) && rd[3] === pat(4, 1), "WRAP4 order 2,3,0,1");
    do_read(2'd0, 29'h000_0310, 1, 4, 2);
    tb_check(rd[0] === pat(4, 1) && rd[1] === pat(4, 0), "WRAP2 order 1,0");

    // 5. Back-to-back reads with different IDs.
    fork
      begin do_read(2'd1, 29'h000_0300, 0, 4, 1); end
    join
    tb_check(rid_seen[0] == 2'd1 && rd[0] === pat(4, 0), "read ID 1");
    @(posedge clk);
    arid <= 2'd2; araddr <= 29'h000_0310; arlen <= 8'd0; arsize <= 3'd4; arburst <= 2'd1; arvalid <= 1'b1;
    do @(posedge clk); while (!arready);
    arid <= 2'd3; araddr <= 29'h000_0320;
    do @(posedge clk); while (!arready);
    arvalid <= 1'b0;
    rready <= 1'b1;
    begin
      logic [IDW-1:0] ids [2];
      logic [DW-1:0]  dat [2];
      int             got;
      got = 0;
      n = 0;
      while (got < 2 && n < 200) begin
        @(posedge clk); n++;
        if (rvalid) begin ids[got] = rid; dat[got] = rdata; got++; end
      end
      tb_check(got == 2 && ids[0] == 2'd2 && ids[1] == 2'd3 && dat[0] === pat(4, 1) && dat[1] === pat(4, 2),
               $sformatf("back-to-back reads: got %0d ids %0d,%0d", got, ids[0], ids[1]));
    end
    rready <= 1'b0;

    // 6. Partial-strobe wide write keeps the other bytes.
    wd[0] = pat(5, 0); ws[0] = '1;
    do_write(2'd0, 29'h000_0400, 0, 4, 1, bs, rs);
    wd[0] = {DW{1'b1}}; ws[0] = 16'h00F0;
    do_write(2'd0, 29'h000_0400, 0, 4, 1, bs, rs);
    neww = pat(5, 0);
    neww[4*8 +: 32] = 32'hFFFF_FFFF;
    do_read(2'd0, 29'h000_0400, 0, 4, 1);
    tb_check(rd[0] === neww, "partial strobe write");

    // 7. Reset.
    sys_rstn = 1'b0;
    repeat (3) @(posedge clk);
    tb_check(!init_calib_complete && !ui_resetn, "calibration status after sys_rstn low");
    sys_rstn = 1'b1;
    n = 0;
    while (!init_calib_complete && n < 4000) begin @(posedge clk); n++; end
    tb_check(init_calib_complete, "recalibration after reset");
    repeat (4) @(posedge clk);
    do_read(2'd0, 29'h000_0300, 0, 4, 1);
    tb_check(rd[0] === pat(4, 0), "memory content survives a controller reset (model keeps data)");

    repeat (5) @(posedge clk);
    tb_verdict("tb_ik64_ddr_sim");
  end

  initial begin
    #5000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_ddr_sim");
  end

endmodule
