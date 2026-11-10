// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_axil_decoder.sv
// Purpose: self-checking bench for ik64_axil_decoder with four slaves:
//   s0 0x0000 size 0x1000, s1 0x2000 size 0x2000, s2 0x8000 size 0x4000 (each an
//   ik64_axil_slave with a 16-word register model), s3 0xC000 size 0x0100 (a
//   behavioral slave that accepts AW 3 clocks and W 6 clocks after valid and
//   answers every access SLVERR; read data 0xDEAD0000 | address).
// Cases:
//   1. Every word of s0..s2 written through the decoder and read back; no
//      cross-window contamination.
//   2. Window edges: first/last word of each window answers OKAY (SLVERR for
//      s3); the words just outside answer DECERR.
//   3. Unmapped write: DECERR, no slave sees a write strobe. Unmapped read: DECERR
//      and read data 0 (after a read of nonzero data, so a stale rdata shows).
//   4. A valid access straight after a DECERR works.
//   5. SLVERR from s3 passes through for write and read, with its data; the
//      split AW/W acceptance of s3 completes exactly one write.
//   6. A partial wstrb reaches the slave (which drops it): word unchanged.
//   7. 400 random mixed accesses (reads and writes to all windows and holes)
//      against a scoreboard.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_axil_decoder;

  import ik64_tb_pkg::*;

  localparam int N  = 4;
  localparam int AW = 16;
  localparam logic [N*AW-1:0] BASES = {16'hC000, 16'h8000, 16'h2000, 16'h0000};
  localparam logic [N*AW-1:0] SIZES = {16'h0100, 16'h4000, 16'h2000, 16'h1000};
  localparam logic [AW-1:0]   BASE_OF [N] = '{16'h0000, 16'h2000, 16'h8000, 16'hC000};

  logic clk = 1'b0;
  logic aresetn = 1'b0;
  always #5.0 clk = ~clk;

  // Master side.
  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  ik64_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // Slave side buses.
  wire [N*AW-1:0] d_awaddr, d_araddr;
  wire [N-1:0]    d_awvalid, d_wvalid, d_bready, d_arvalid, d_rready;
  wire [N-1:0]    d_awready, d_wready, d_bvalid, d_arready, d_rvalid;
  wire [N*32-1:0] d_wdata, d_rdata;
  wire [N*4-1:0]  d_wstrb;
  wire [N*2-1:0]  d_bresp, d_rresp;

  ik64_axil_decoder #(.N(N), .ADDR_W(AW), .SLAVE_BASE(BASES), .SLAVE_SIZE(SIZES)) u_dut (
    .aclk(clk), .aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_axi_awaddr(d_awaddr), .m_axi_awvalid(d_awvalid), .m_axi_awready(d_awready),
    .m_axi_wdata(d_wdata), .m_axi_wstrb(d_wstrb), .m_axi_wvalid(d_wvalid), .m_axi_wready(d_wready),
    .m_axi_bresp(d_bresp), .m_axi_bvalid(d_bvalid), .m_axi_bready(d_bready),
    .m_axi_araddr(d_araddr), .m_axi_arvalid(d_arvalid), .m_axi_arready(d_arready),
    .m_axi_rdata(d_rdata), .m_axi_rresp(d_rresp), .m_axi_rvalid(d_rvalid), .m_axi_rready(d_rready));

  // Real slaves s0..s2 with register models.
  logic [31:0] regs [3][16];
  int          wr_cnt [4];
  initial begin
    for (int k = 0; k < 4; k++) wr_cnt[k] = 0;
    for (int k = 0; k < 3; k++) for (int i = 0; i < 16; i++) regs[k][i] = 32'h0;
  end

  for (genvar k = 0; k < 3; k++) begin : g_slv
    logic          wr_en, rd_en;
    logic [AW-1:0] wr_addr, rd_addr;
    logic [31:0]   wr_data, rd_data;

    ik64_axil_slave #(.ADDR_W(AW)) u_slv (
      .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
      .s_axi_awaddr(d_awaddr[k*AW +: AW]), .s_axi_awvalid(d_awvalid[k]), .s_axi_awready(d_awready[k]),
      .s_axi_wdata(d_wdata[k*32 +: 32]), .s_axi_wstrb(d_wstrb[k*4 +: 4]), .s_axi_wvalid(d_wvalid[k]),
      .s_axi_wready(d_wready[k]),
      .s_axi_bresp(d_bresp[k*2 +: 2]), .s_axi_bvalid(d_bvalid[k]), .s_axi_bready(d_bready[k]),
      .s_axi_araddr(d_araddr[k*AW +: AW]), .s_axi_arvalid(d_arvalid[k]), .s_axi_arready(d_arready[k]),
      .s_axi_rdata(d_rdata[k*32 +: 32]), .s_axi_rresp(d_rresp[k*2 +: 2]), .s_axi_rvalid(d_rvalid[k]),
      .s_axi_rready(d_rready[k]),
      .reg_wr_en(wr_en), .reg_wr_addr(wr_addr), .reg_wr_data(wr_data),
      .reg_rd_en(rd_en), .reg_rd_addr(rd_addr), .reg_rd_data(rd_data));

    always @(posedge clk) begin
      if (wr_en) begin
        regs[k][wr_addr[5:2]] <= wr_data;
        wr_cnt[k] <= wr_cnt[k] + 1;
      end
      if (rd_en) rd_data <= regs[k][rd_addr[5:2]];
    end
  end

  // s3: behavioral slave, delayed AW (3 clocks) and W (6 clocks), SLVERR.
  logic        s3_awready = 1'b0, s3_wready = 1'b0, s3_bvalid = 1'b0, s3_arready = 1'b0, s3_rvalid = 1'b0;
  logic [31:0] s3_rdata = '0;
  int          aw_wait = 0, w_wait = 0, ar_wait = 0;
  logic        aw_d = 1'b0, w_d = 1'b0, ar_d = 1'b0;

  assign d_awready[3]    = s3_awready;
  assign d_wready[3]     = s3_wready;
  assign d_bvalid[3]     = s3_bvalid;
  assign d_bresp[7:6]    = 2'b10;
  assign d_arready[3]    = s3_arready;
  assign d_rvalid[3]     = s3_rvalid;
  assign d_rdata[127:96] = s3_rdata;
  assign d_rresp[7:6]    = 2'b10;

  always @(posedge clk) begin
    s3_awready <= 1'b0;
    s3_wready  <= 1'b0;
    s3_arready <= 1'b0;
    if (!aresetn) begin
      aw_wait = 0; w_wait = 0; ar_wait = 0; aw_d = 1'b0; w_d = 1'b0; ar_d = 1'b0;
      s3_bvalid <= 1'b0; s3_rvalid <= 1'b0;
    end else begin
      if (d_awvalid[3] && !aw_d) begin
        aw_wait++;
        if (aw_wait == 3) begin s3_awready <= 1'b1; aw_d = 1'b1; end
      end
      if (d_wvalid[3] && !w_d) begin
        w_wait++;
        if (w_wait == 6) begin s3_wready <= 1'b1; w_d = 1'b1; end
      end
      if (aw_d && w_d && !s3_bvalid) begin
        s3_bvalid <= 1'b1;
        wr_cnt[3] <= wr_cnt[3] + 1;
        aw_d = 1'b0; w_d = 1'b0; aw_wait = 0; w_wait = 0;
      end
      if (s3_bvalid && d_bready[3]) s3_bvalid <= 1'b0;

      if (d_arvalid[3] && !ar_d) begin
        ar_wait++;
        if (ar_wait == 2) begin s3_arready <= 1'b1; ar_d = 1'b1; end
      end
      if (ar_d && !s3_rvalid) begin
        s3_rvalid <= 1'b1;
        s3_rdata  <= 32'hDEAD0000 | d_araddr[3*AW +: AW];
        ar_d = 1'b0; ar_wait = 0;
      end
      if (s3_rvalid && d_rready[3]) s3_rvalid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Test helpers.
  // ---------------------------------------------------------------------------
  logic [31:0] v;
  logic [1:0]  r;

  // Window index of an address, -1 for a hole.
  function automatic int win_of(input logic [AW-1:0] a);
    for (int k = 0; k < N; k++) begin
      if ((a & ~(SIZES[k*AW +: AW] - 16'd1)) == BASES[k*AW +: AW]) return k;
    end
    return -1;
  endfunction

  function automatic int total_writes();
    return wr_cnt[0] + wr_cnt[1] + wr_cnt[2] + wr_cnt[3];
  endfunction

  logic [31:0] model [3][16];
  int unsigned lfsr = 32'h1BAD_CAFE;
  int          w0;

  function automatic int unsigned next_rand();
    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    return lfsr;
  endfunction

  initial begin
    for (int k = 0; k < 3; k++) for (int i = 0; i < 16; i++) model[k][i] = 32'h0;
    repeat (5) @(negedge clk);
    aresetn = 1'b1;
    repeat (3) @(negedge clk);

    // 1. Fill and read back.
    for (int k = 0; k < 3; k++) begin
      for (int i = 0; i < 16; i++) begin
        model[k][i] = {8'(k + 1), 8'(i), 16'(32'h5A00 + k * 16 + i)};
        u_mst.write32(BASE_OF[k] + AW'(i * 4), model[k][i], 4'hF, r);
        tb_check(r == 2'b00, $sformatf("fill s%0d[%0d] resp %0d", k, i, r));
      end
    end
    for (int k = 0; k < 3; k++) begin
      for (int i = 0; i < 16; i++) begin
        u_mst.read32(BASE_OF[k] + AW'(i * 4), v, r);
        tb_check(r == 2'b00 && v === model[k][i], $sformatf("readback s%0d[%0d] = %08x resp %0d", k, i, v, r));
      end
    end
    tb_check(wr_cnt[0] == 16 && wr_cnt[1] == 16 && wr_cnt[2] == 16 && wr_cnt[3] == 0,
             $sformatf("write strobes per slave %0d %0d %0d %0d", wr_cnt[0], wr_cnt[1], wr_cnt[2], wr_cnt[3]));

    // 2. Window edges.
    begin
      logic [AW-1:0] edge_ok [10]  = '{16'h0000, 16'h0FFC, 16'h2000, 16'h3FFC, 16'h8000, 16'hBFFC, 16'h0800, 16'h2800, 16'hA000, 16'h3000};
      logic [AW-1:0] edge_bad [10] = '{16'h1000, 16'h1FFC, 16'h4000, 16'h7FFC, 16'hC100, 16'hFFFC, 16'h5000, 16'hC0FF + 16'h1, 16'hD000, 16'h6000};
      foreach (edge_ok[i]) begin
        u_mst.read32(edge_ok[i], v, r);
        tb_check(r == 2'b00, $sformatf("edge 0x%04x expected OKAY, got resp %0d", edge_ok[i], r));
      end
      foreach (edge_bad[i]) begin
        u_mst.read32(edge_bad[i], v, r);
        tb_check(r == 2'b11 && v === 32'h0, $sformatf("hole 0x%04x expected DECERR/0, got resp %0d data %08x", edge_bad[i], r, v));
      end
      u_mst.read32(16'hC000, v, r);
      tb_check(r == 2'b10 && v === 32'hDEAD_C000, $sformatf("s3 first word resp %0d data %08x", r, v));
      u_mst.read32(16'hC0FC, v, r);
      tb_check(r == 2'b10 && v === 32'hDEAD_C0FC, $sformatf("s3 last word resp %0d data %08x", r, v));
    end

    // 3. Unmapped accesses.
    w0 = total_writes();
    u_mst.write32(16'h1000, 32'h1111_1111, 4'hF, r);
    tb_check(r == 2'b11, $sformatf("unmapped write resp %0d expected DECERR", r));
    u_mst.write32(16'hFFFC, 32'h2222_2222, 4'hF, r);
    tb_check(r == 2'b11, $sformatf("unmapped write (top) resp %0d expected DECERR", r));
    tb_check(total_writes() == w0, "a slave saw a write for an unmapped address");
    u_mst.read32(16'h2000, v, r);
    tb_check(r == 2'b00 && v === model[1][0], "read before hole");
    u_mst.read32(16'h1000, v, r);
    tb_check(r == 2'b11 && v === 32'h0, $sformatf("unmapped read resp %0d data %08x", r, v));

    // 4. Valid access after DECERR.
    u_mst.read32(16'h8004, v, r);
    tb_check(r == 2'b00 && v === model[2][1], "read after DECERR");
    model[0][3] = 32'h0F0F_0F0F;
    u_mst.write32(16'h000C, model[0][3], 4'hF, r);
    tb_check(r == 2'b00, "write after DECERR resp");
    u_mst.read32(16'h000C, v, r);
    tb_check(v === model[0][3], "write after DECERR readback");

    // 5. SLVERR passthrough, split AW/W acceptance.
    u_mst.write32(16'hC010, 32'h5555_AAAA, 4'hF, r);
    tb_check(r == 2'b10, $sformatf("s3 write resp %0d expected SLVERR", r));
    tb_check(wr_cnt[3] == 1, $sformatf("s3 saw %0d writes, expected 1", wr_cnt[3]));
    u_mst.read32(16'hC020, v, r);
    tb_check(r == 2'b10 && v === 32'hDEAD_C020, $sformatf("s3 read resp %0d data %08x", r, v));
    u_mst.read32(16'h0004, v, r);
    tb_check(r == 2'b00 && v === model[0][1], "OKAY after SLVERR");

    // 6. Partial strobe passes through and is dropped by the slave.
    w0 = total_writes();
    u_mst.write32(16'h2008, 32'hFFFF_FFFF, 4'h3, r);
    tb_check(r == 2'b00, "partial write resp");
    u_mst.read32(16'h2008, v, r);
    tb_check(total_writes() == w0 && v === model[1][2], $sformatf("partial write changed word: %08x", v));

    // 7. Random mix.
    for (int t = 0; t < 400; t++) begin
      logic [AW-1:0] a;
      int            w;
      int            idx;
      int unsigned   rv;
      rv  = next_rand();
      case (rv[3:0])
        4'd0, 4'd1, 4'd2, 4'd3, 4'd4: begin a = BASE_OF[0]; w = 0; end
        4'd5, 4'd6, 4'd7, 4'd8:       begin a = BASE_OF[1]; w = 1; end
        4'd9, 4'd10, 4'd11:           begin a = BASE_OF[2]; w = 2; end
        4'd12:                        begin a = BASE_OF[3]; w = 3; end
        default:                      begin a = 16'h1000 | {4'h0, rv[11:2], 2'b00}; w = -1; end
      endcase
      idx = int'(rv[19:16]);
      if (w >= 0) a = a + AW'(idx * 4);
      if (rv[24]) begin
        // write
        logic [31:0] dv;
        dv = next_rand();
        u_mst.write32(a, dv, 4'hF, r);
        if (w < 0) tb_check(r == 2'b11, $sformatf("random write hole 0x%04x resp %0d", a, r));
        else if (w == 3) tb_check(r == 2'b10, $sformatf("random write s3 resp %0d", r));
        else begin
          tb_check(r == 2'b00, $sformatf("random write 0x%04x resp %0d", a, r));
          model[w][idx] = dv;
        end
      end else begin
        u_mst.read32(a, v, r);
        if (w < 0)       tb_check(r == 2'b11 && v === 32'h0, $sformatf("random read hole 0x%04x resp %0d data %08x", a, r, v));
        else if (w == 3) tb_check(r == 2'b10 && v === (32'hDEAD0000 | a), $sformatf("random read s3 resp %0d data %08x", r, v));
        else             tb_check(r == 2'b00 && v === model[w][idx], $sformatf("random read 0x%04x = %08x expected %08x", a, v, model[w][idx]));
      end
    end

    repeat (5) @(negedge clk);
    tb_verdict("tb_ik64_axil_decoder");
  end

  initial begin
    #20000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_axil_decoder");
  end

endmodule
