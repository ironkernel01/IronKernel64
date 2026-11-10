// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_axil_slave.sv
// Purpose: self-checking bench for ik64_axil_slave (AXI4-Lite to register
//   strobes). The register file is a 16-word model with a registered read mux.
// Cases:
//   1. Full-word writes to all 16 words, read back through the bridge: data
//      and OKAY responses; reg_wr_en / reg_rd_en are one clock wide.
//   2. Partial writes (wstrb 0, 1, 7, 14): OKAY response, no reg_wr_en, the
//      word is unchanged.
//   3. Timing from the accept: reg_wr_en and bvalid rise one clock after
//      awready; for reads reg_rd_en rises one clock after arready and rvalid
//      three clocks after arready.
//   4. AW before W (W 5 clocks late): no accept before both are valid; bvalid
//      is held with bready low for 8 clocks and bresp stays OKAY.
//   5. rready held low for 8 clocks: rvalid and rdata hold.
//   6. Write and read pending together: the write goes first, the read returns
//      the value just written.
//   7. Reset in the middle of a transaction clears readies/valids/strobes; the
//      next transactions work.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_axil_slave;

  import ik64_tb_pkg::*;

  localparam int AW = 8;

  logic clk = 1'b0;
  logic aresetn = 1'b0;
  always #5.0 clk = ~clk;

  // Bus from the master model (m_*), the manual driver (h_*), selected by use_h.
  logic          use_h = 1'b0;
  logic [AW-1:0] m_awaddr, m_araddr, h_awaddr = '0, h_araddr = '0;
  logic [31:0]   m_wdata, h_wdata = '0;
  logic [3:0]    m_wstrb, h_wstrb = '0;
  logic          m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
  logic          h_awvalid = 1'b0, h_wvalid = 1'b0, h_bready = 1'b0, h_arvalid = 1'b0, h_rready = 1'b0;

  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  assign awaddr  = use_h ? h_awaddr  : m_awaddr;
  assign awvalid = use_h ? h_awvalid : m_awvalid;
  assign wdata   = use_h ? h_wdata   : m_wdata;
  assign wstrb   = use_h ? h_wstrb   : m_wstrb;
  assign wvalid  = use_h ? h_wvalid  : m_wvalid;
  assign bready  = use_h ? h_bready  : m_bready;
  assign araddr  = use_h ? h_araddr  : m_araddr;
  assign arvalid = use_h ? h_arvalid : m_arvalid;
  assign rready  = use_h ? h_rready  : m_rready;

  ik64_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(clk), .awaddr(m_awaddr), .awvalid(m_awvalid), .awready(awready), .wdata(m_wdata), .wstrb(m_wstrb),
    .wvalid(m_wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(m_bready), .araddr(m_araddr),
    .arvalid(m_arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(m_rready));

  logic          reg_wr_en, reg_rd_en;
  logic [AW-1:0] reg_wr_addr, reg_rd_addr;
  logic [31:0]   reg_wr_data, reg_rd_data;

  ik64_axil_slave #(.ADDR_W(AW)) u_dut (
    .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data));

  // Register file model: write on reg_wr_en, registered read on reg_rd_en.
  logic [31:0] regs [16];
  initial for (int i = 0; i < 16; i++) regs[i] = 32'h0;
  int wr_strobes = 0;
  int rd_strobes = 0;
  always @(posedge clk) begin
    if (reg_wr_en) begin
      regs[reg_wr_addr[5:2]] <= reg_wr_data;
      wr_strobes <= wr_strobes + 1;
    end
    if (reg_rd_en) begin
      reg_rd_data <= regs[reg_rd_addr[5:2]];
      rd_strobes <= rd_strobes + 1;
    end
  end

  // Monitors: cycle counter, rising-edge cycles, high-cycle counts.
  int cyc = 0;
  int rise_awready = -1, rise_wr_en = -1, rise_bvalid = -1, rise_arready = -1, rise_rd_en = -1, rise_rvalid = -1;
  int hi_wr_en = 0, hi_rd_en = 0;
  logic p_awready = 1'b0, p_wr_en = 1'b0, p_bvalid = 1'b0, p_arready = 1'b0, p_rd_en = 1'b0, p_rvalid = 1'b0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (awready && !p_awready) rise_awready <= cyc;
    if (reg_wr_en && !p_wr_en) rise_wr_en   <= cyc;
    if (bvalid && !p_bvalid)   rise_bvalid  <= cyc;
    if (arready && !p_arready) rise_arready <= cyc;
    if (reg_rd_en && !p_rd_en) rise_rd_en   <= cyc;
    if (rvalid && !p_rvalid)   rise_rvalid  <= cyc;
    if (reg_wr_en) hi_wr_en <= hi_wr_en + 1;
    if (reg_rd_en) hi_rd_en <= hi_rd_en + 1;
    p_awready <= awready; p_wr_en <= reg_wr_en; p_bvalid <= bvalid;
    p_arready <= arready; p_rd_en <= reg_rd_en; p_rvalid <= rvalid;
  end

  // Manual driver helpers (valid only while use_h = 1).
  task automatic h_idle();
    h_awvalid = 1'b0; h_wvalid = 1'b0; h_arvalid = 1'b0; h_bready = 1'b0; h_rready = 1'b0;
  endtask

  logic [31:0] v;
  logic [1:0]  r;
  int          n0;
  int          wr0;

  initial begin
    repeat (5) @(negedge clk);
    aresetn = 1'b1;
    repeat (3) @(negedge clk);

    // After reset every output is idle.
    tb_check(!awready && !wready && !arready && !bvalid && !rvalid && !reg_wr_en && !reg_rd_en,
             "outputs not idle after reset");

    // 1. Write all words, read back.
    for (int i = 0; i < 16; i++) u_mst.wr(AW'(i * 4), 32'hA5000000 + (i * 32'h01010101));
    for (int i = 0; i < 16; i++) begin
      u_mst.rd(AW'(i * 4), v);
      tb_check(v === 32'hA5000000 + (i * 32'h01010101), $sformatf("word %0d read %08x", i, v));
    end
    tb_check(wr_strobes == 16, $sformatf("reg_wr_en strobes %0d expected 16", wr_strobes));
    tb_check(hi_wr_en == 16, $sformatf("reg_wr_en high %0d clocks for 16 writes (must be one clock each)", hi_wr_en));
    tb_check(rd_strobes == 16 && hi_rd_en == 16, $sformatf("reg_rd_en strobes %0d / high clocks %0d, expected 16", rd_strobes, hi_rd_en));

    // 2. Partial writes: acknowledged, dropped.
    wr0 = wr_strobes;
    u_mst.write32(8'h08, 32'hFFFF_FFFF, 4'h0, r); tb_check(r == 2'b00, "strb 0 response");
    u_mst.write32(8'h08, 32'hFFFF_FFFF, 4'h1, r); tb_check(r == 2'b00, "strb 1 response");
    u_mst.write32(8'h08, 32'hFFFF_FFFF, 4'h7, r); tb_check(r == 2'b00, "strb 7 response");
    u_mst.write32(8'h08, 32'hFFFF_FFFF, 4'hE, r); tb_check(r == 2'b00, "strb E response");
    tb_check(wr_strobes == wr0, "partial write produced reg_wr_en");
    u_mst.rd(8'h08, v);
    tb_check(v === 32'hA5000000 + (2 * 32'h01010101), $sformatf("word 2 changed by a partial write: %08x", v));

    // 3. Timing from the accept.
    u_mst.wr(8'h10, 32'h1234_5678);
    @(negedge clk);
    tb_check(rise_wr_en == rise_awready + 1, $sformatf("reg_wr_en rise %0d vs awready rise %0d", rise_wr_en, rise_awready));
    tb_check(rise_bvalid == rise_awready + 1, $sformatf("bvalid rise %0d vs awready rise %0d", rise_bvalid, rise_awready));
    u_mst.rd(8'h10, v);
    @(negedge clk);
    tb_check(v === 32'h1234_5678, "timing read data");
    tb_check(rise_rd_en == rise_arready + 1, $sformatf("reg_rd_en rise %0d vs arready rise %0d", rise_rd_en, rise_arready));
    tb_check(rise_rvalid == rise_arready + 3, $sformatf("rvalid rise %0d vs arready rise %0d", rise_rvalid, rise_arready));
    tb_check(bresp == 2'b00 && rresp == 2'b00, "bresp / rresp not OKAY");

    // 4. AW first, W five clocks later; B held with bready low.
    use_h = 1'b1;
    @(negedge clk);
    h_awaddr = 8'h14; h_awvalid = 1'b1;
    repeat (5) begin
      @(negedge clk);
      tb_check(!awready && !wready, "accepted AW without W");
    end
    h_wdata = 32'hCAFE_0001; h_wstrb = 4'hF; h_wvalid = 1'b1;
    n0 = 0;
    while (!(awready && wready) && n0 < 10) begin @(negedge clk); n0++; end
    tb_check(awready && wready, "AW/W not accepted when both valid");
    h_awvalid = 1'b0; h_wvalid = 1'b0;
    n0 = 0;
    while (!bvalid && n0 < 10) begin @(negedge clk); n0++; end
    tb_check(bvalid, "no bvalid");
    repeat (8) begin
      @(negedge clk);
      tb_check(bvalid && bresp == 2'b00, "bvalid dropped or bresp changed with bready low");
    end
    h_bready = 1'b1;
    @(negedge clk);
    h_bready = 1'b0;
    @(negedge clk);
    tb_check(!bvalid, "bvalid stuck after bready");
    tb_check(regs[5] === 32'hCAFE_0001, $sformatf("late-W write lost: %08x", regs[5]));

    // 5. R held with rready low.
    h_araddr = 8'h14; h_arvalid = 1'b1;
    n0 = 0;
    while (!arready && n0 < 10) begin @(negedge clk); n0++; end
    h_arvalid = 1'b0;
    n0 = 0;
    while (!rvalid && n0 < 10) begin @(negedge clk); n0++; end
    tb_check(rvalid, "no rvalid");
    repeat (8) begin
      @(negedge clk);
      tb_check(rvalid && rdata === 32'hCAFE_0001 && rresp == 2'b00, "rvalid/rdata not held with rready low");
    end
    h_rready = 1'b1;
    @(negedge clk);
    h_rready = 1'b0;
    @(negedge clk);
    tb_check(!rvalid, "rvalid stuck after rready");

    // 6. Write and read pending together: write first, read sees the new value.
    h_awaddr = 8'h18; h_wdata = 32'h0BAD_F00D; h_wstrb = 4'hF; h_araddr = 8'h18;
    h_awvalid = 1'b1; h_wvalid = 1'b1; h_arvalid = 1'b1; h_bready = 1'b1; h_rready = 1'b1;
    n0 = 0;
    while (!(awready && wready) && n0 < 10) begin @(negedge clk); n0++; end
    tb_check(!arready, "read accepted before the write");
    h_awvalid = 1'b0; h_wvalid = 1'b0;
    n0 = 0;
    while (!arready && n0 < 30) begin @(negedge clk); n0++; end
    tb_check(arready, "pending read never accepted");
    h_arvalid = 1'b0;
    n0 = 0;
    while (!rvalid && n0 < 10) begin @(negedge clk); n0++; end
    tb_check(rvalid && rdata === 32'h0BAD_F00D, $sformatf("read after write returned %08x", rdata));
    @(negedge clk);
    h_idle();
    repeat (3) @(negedge clk);

    // 7. Reset in the middle of a write and of a read.
    h_awaddr = 8'h1C; h_wdata = 32'h1111_2222; h_wstrb = 4'hF; h_awvalid = 1'b1; h_wvalid = 1'b1;
    n0 = 0;
    while (!awready && n0 < 10) begin @(negedge clk); n0++; end
    h_awvalid = 1'b0; h_wvalid = 1'b0;
    aresetn = 1'b0;
    @(negedge clk);
    tb_check(!awready && !wready && !bvalid && !reg_wr_en && !arready && !rvalid && !reg_rd_en,
             "outputs active during reset");
    @(negedge clk);
    aresetn = 1'b1;
    repeat (4) @(negedge clk);
    tb_check(!bvalid && !rvalid, "stale response after reset");
    h_idle();
    use_h = 1'b0;
    u_mst.wr(8'h20, 32'h3333_4444);
    u_mst.rd(8'h20, v);
    tb_check(v === 32'h3333_4444, "write/read after mid-transaction reset");

    repeat (5) @(negedge clk);
    tb_verdict("tb_ik64_axil_slave");
  end

  initial begin
    #2000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_axil_slave");
  end

endmodule
