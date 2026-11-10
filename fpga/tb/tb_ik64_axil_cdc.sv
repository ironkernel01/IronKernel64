// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_axil_cdc.sv
// Purpose: self-checking bench for ik64_axil_cdc (AXI4-Lite clock crossing).
// Configurations (each in its own generate block with its own clocks and resets):
//   cfg 0: s_clk 10 ns -> m_clk 30 ns (slow register clock), register slave behind it
//   cfg 1: s_clk 30 ns -> m_clk 10 ns (fast register clock), register slave behind it
//   cfg 2: s_clk 10 ns -> m_clk 10 ns shifted by 3 ns, behavioral slave that answers
//          SLVERR (write and read) for addresses >= 0x800
// Cases:
//   1. Idle after reset: no readies or valids.
//   2. cfg 0/1: all 16 words written and read back through the crossing.
//   3. Back-to-back: 120 write/read operations (random addresses, mixed order, no
//      idle clocks between operations) checked against a scoreboard.
//   4. A partial wstrb (0, 5, 14) is answered OKAY and the word is unchanged
//      (cfg 0/1); cfg 2: the slave sees the strobe unchanged.
//   5. Response propagation (cfg 2): OKAY below 0x800, SLVERR above, with the
//      read data of the slave.
//   6. awready / wready / arready are one clock wide: their high-clock counts
//      equal the transaction counts.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_axil_cdc;

  import ik64_tb_pkg::*;

  localparam int NCFG = 3;
  localparam real TS_OF [NCFG] = '{10.0, 30.0, 10.0};
  localparam real TM_OF [NCFG] = '{30.0, 10.0, 10.0};
  localparam real PH_OF [NCFG] = '{0.0, 0.0, 3.0};
  localparam int  AW = 12;

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam real TS = TS_OF[c];
    localparam real TM = TM_OF[c];
    localparam real PH = PH_OF[c];

    logic s_clk = 1'b0;
    logic m_clk = 1'b0;
    logic s_resetn = 1'b0;
    logic m_resetn = 1'b0;
    always #(TS / 2.0) s_clk = ~s_clk;
    initial begin
      #(PH + TM / 2.0);
      forever begin
        m_clk = ~m_clk;
        #(TM / 2.0);
      end
    end

    // Slave side bus (master model drives it).
    logic [AW-1:0] s_awaddr, s_araddr;
    logic [31:0]   s_wdata, s_rdata;
    logic [3:0]    s_wstrb;
    logic [1:0]    s_bresp, s_rresp;
    logic          s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready, s_arvalid, s_arready, s_rvalid, s_rready;

    // Master side bus (to the register slave).
    logic [AW-1:0] m_awaddr, m_araddr;
    logic [31:0]   m_wdata, m_rdata;
    logic [3:0]    m_wstrb;
    logic [1:0]    m_bresp, m_rresp;
    logic          m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;

    ik64_tb_axil_master #(.ADDR_W(AW)) u_mst (
      .aclk(s_clk), .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready), .wdata(s_wdata), .wstrb(s_wstrb),
      .wvalid(s_wvalid), .wready(s_wready), .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready), .araddr(s_araddr),
      .arvalid(s_arvalid), .arready(s_arready), .rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready));

    ik64_axil_cdc #(.ADDR_W(AW)) u_dut (
      .s_clk(s_clk), .s_resetn(s_resetn),
      .s_axi_awaddr(s_awaddr), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
      .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
      .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
      .s_axi_araddr(s_araddr), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
      .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
      .m_clk(m_clk), .m_resetn(m_resetn),
      .m_axi_awaddr(m_awaddr), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
      .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
      .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
      .m_axi_araddr(m_araddr), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
      .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));

    // Register slave in the m_clk domain.
    logic [31:0] regs [16];
    int          wr_events = 0;
    int          rd_events = 0;
    logic [3:0]  last_strb = 4'h0;
    logic [31:0] last_wdata = 32'h0;

    if (c < 2) begin : g_real
      logic          wr_en, rd_en;
      logic [AW-1:0] wr_addr, rd_addr;
      logic [31:0]   wr_data, rd_data;
      ik64_axil_slave #(.ADDR_W(AW)) u_slv (
        .s_axi_aclk(m_clk), .s_axi_aresetn(m_resetn),
        .s_axi_awaddr(m_awaddr), .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
        .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
        .s_axi_araddr(m_araddr), .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
        .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
        .reg_wr_en(wr_en), .reg_wr_addr(wr_addr), .reg_wr_data(wr_data),
        .reg_rd_en(rd_en), .reg_rd_addr(rd_addr), .reg_rd_data(rd_data));
      always @(posedge m_clk) begin
        if (wr_en) begin
          regs[wr_addr[5:2]] <= wr_data;
          wr_events <= wr_events + 1;
        end
        if (rd_en) begin
          rd_data <= regs[rd_addr[5:2]];
          rd_events <= rd_events + 1;
        end
      end
    end else begin : g_stub
      logic        aw_rdy = 1'b0, w_rdy = 1'b0, b_vld = 1'b0, ar_rdy = 1'b0, r_vld = 1'b0;
      logic [1:0]  b_rsp = 2'b00, r_rsp = 2'b00;
      logic [31:0] r_dat = 32'h0;
      assign m_awready = aw_rdy;
      assign m_wready  = w_rdy;
      assign m_bvalid  = b_vld;
      assign m_bresp   = b_rsp;
      assign m_arready = ar_rdy;
      assign m_rvalid  = r_vld;
      assign m_rresp   = r_rsp;
      assign m_rdata   = r_dat;
      always @(posedge m_clk) begin
        aw_rdy <= 1'b0;
        w_rdy  <= 1'b0;
        ar_rdy <= 1'b0;
        if (!m_resetn) begin
          b_vld <= 1'b0;
          r_vld <= 1'b0;
        end else begin
          if (m_awvalid && m_wvalid && !aw_rdy && !b_vld) begin
            aw_rdy <= 1'b1;
            w_rdy  <= 1'b1;
            b_vld  <= 1'b1;
            if (m_awaddr >= 12'h800) b_rsp <= 2'b10;
            else                     b_rsp <= 2'b00;
            last_strb  <= m_wstrb;
            last_wdata <= m_wdata;
            wr_events  <= wr_events + 1;
          end
          if (b_vld && m_bready) b_vld <= 1'b0;
          if (m_arvalid && !ar_rdy && !r_vld) begin
            ar_rdy <= 1'b1;
            r_vld  <= 1'b1;
            if (m_araddr >= 12'h800) begin
              r_rsp <= 2'b10;
              r_dat <= 32'hBAD0_0000 | {20'h0, m_araddr};
            end else begin
              r_rsp <= 2'b00;
              r_dat <= 32'hABCD_E000 | {20'h0, m_araddr};
            end
            rd_events <= rd_events + 1;
          end
          if (r_vld && m_rready) r_vld <= 1'b0;
        end
      end
    end

    // One-clock-wide readies on the slave side.
    int hi_aw = 0, hi_w = 0, hi_ar = 0;
    int n_wr = 0, n_rd = 0;
    always @(posedge s_clk) begin
      if (s_awready) hi_aw <= hi_aw + 1;
      if (s_wready)  hi_w  <= hi_w + 1;
      if (s_arready) hi_ar <= hi_ar + 1;
    end

    task automatic do_write(input logic [AW-1:0] a, input logic [31:0] d, input logic [3:0] st, output logic [1:0] r);
      u_mst.write32(a, d, st, r);
      n_wr++;
    endtask

    task automatic do_read(input logic [AW-1:0] a, output logic [31:0] d, output logic [1:0] r);
      u_mst.read32(a, d, r);
      n_rd++;
    endtask

    logic [31:0] v;
    logic [1:0]  r;
    logic [31:0] model [16];
    int unsigned lfsr = 32'hC0DE_0042 + c;

    function automatic int unsigned next_rand();
      lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      return lfsr;
    endfunction

    initial begin
      for (int i = 0; i < 16; i++) begin regs[i] = 32'h0; model[i] = 32'h0; end
      repeat (5) @(negedge s_clk);
      s_resetn = 1'b1;
      @(negedge m_clk);
      m_resetn = 1'b1;
      repeat (10) @(negedge s_clk);

      // 1. Idle.
      tb_check(!s_awready && !s_wready && !s_arready && !s_bvalid && !s_rvalid, $sformatf("cfg%0d outputs not idle after reset", c));
      tb_check(!m_awvalid && !m_wvalid && !m_arvalid && !m_bready && !m_rready, $sformatf("cfg%0d master side not idle after reset", c));

      if (c < 2) begin
        // 2. Write and read all words.
        for (int i = 0; i < 16; i++) begin
          model[i] = {4'(c + 1), 4'(i), 8'hC3, 16'h1000 + 16'(i * 17)};
          do_write(AW'(i * 4), model[i], 4'hF, r);
          tb_check(r == 2'b00, $sformatf("cfg%0d write %0d resp %0d", c, i, r));
        end
        for (int i = 0; i < 16; i++) begin
          do_read(AW'(i * 4), v, r);
          tb_check(r == 2'b00 && v === model[i], $sformatf("cfg%0d read %0d = %08x expected %08x resp %0d", c, i, v, model[i], r));
        end

        // 4. Partial strobes dropped.
        do_write(12'h004, 32'hFFFF_FFFF, 4'h0, r); tb_check(r == 2'b00, "strb 0 resp");
        do_write(12'h004, 32'hFFFF_FFFF, 4'h5, r); tb_check(r == 2'b00, "strb 5 resp");
        do_write(12'h004, 32'hFFFF_FFFF, 4'hE, r); tb_check(r == 2'b00, "strb E resp");
        do_read(12'h004, v, r);
        tb_check(v === model[1], $sformatf("cfg%0d partial write changed the word: %08x", c, v));

        // 3. Back-to-back random mix.
        for (int t = 0; t < 120; t++) begin
          int unsigned rv;
          int          idx;
          rv  = next_rand();
          idx = int'(rv[3:0]);
          if (rv[8]) begin
            logic [31:0] dv;
            dv = next_rand();
            do_write(AW'(idx * 4), dv, 4'hF, r);
            tb_check(r == 2'b00, $sformatf("cfg%0d random write resp %0d", c, r));
            model[idx] = dv;
          end else begin
            do_read(AW'(idx * 4), v, r);
            tb_check(r == 2'b00 && v === model[idx], $sformatf("cfg%0d random read %0d = %08x expected %08x", c, idx, v, model[idx]));
          end
        end
      end else begin
        // 5. Response propagation and strobe passthrough.
        do_write(12'h010, 32'h1234_5678, 4'hF, r);
        tb_check(r == 2'b00, $sformatf("cfg2 low write resp %0d", r));
        tb_check(last_wdata === 32'h1234_5678 && last_strb === 4'hF, "cfg2 slave write data/strobe");
        do_write(12'h810, 32'h8765_4321, 4'hA, r);
        tb_check(r == 2'b10, $sformatf("cfg2 high write resp %0d expected SLVERR", r));
        tb_check(last_wdata === 32'h8765_4321 && last_strb === 4'hA, "cfg2 slave write data/strobe (partial)");
        do_read(12'h020, v, r);
        tb_check(r == 2'b00 && v === 32'hABCD_E020, $sformatf("cfg2 low read resp %0d data %08x", r, v));
        do_read(12'h820, v, r);
        tb_check(r == 2'b10 && v === 32'hBAD0_0820, $sformatf("cfg2 high read resp %0d data %08x", r, v));
        for (int t = 0; t < 120; t++) begin
          int unsigned rv;
          logic [AW-1:0] a;
          rv = next_rand();
          a  = {rv[11:2], 2'b00};
          if (rv[14]) begin
            do_write(a, rv, 4'hF, r);
            tb_check(r == ((a >= 12'h800) ? 2'b10 : 2'b00), $sformatf("cfg2 random write 0x%03x resp %0d", a, r));
          end else begin
            do_read(a, v, r);
            tb_check(r == ((a >= 12'h800) ? 2'b10 : 2'b00) &&
                     v === ((a >= 12'h800) ? (32'hBAD0_0000 | a) : (32'hABCD_E000 | a)),
                     $sformatf("cfg2 random read 0x%03x resp %0d data %08x", a, r, v));
          end
        end
      end

      // 6. Every transaction reached the slave exactly once; ready pulses one clock wide.
      repeat (10) @(negedge s_clk);
      tb_check(wr_events == n_wr - ((c < 2) ? 3 : 0),
               $sformatf("cfg%0d slave saw %0d writes, expected %0d", c, wr_events, n_wr - ((c < 2) ? 3 : 0)));
      tb_check(rd_events == n_rd, $sformatf("cfg%0d slave saw %0d reads, expected %0d", c, rd_events, n_rd));
      tb_check(hi_aw == n_wr && hi_w == n_wr, $sformatf("cfg%0d awready/wready high %0d/%0d clocks for %0d writes", c, hi_aw, hi_w, n_wr));
      tb_check(hi_ar == n_rd, $sformatf("cfg%0d arready high %0d clocks for %0d reads", c, hi_ar, n_rd));

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    #200.0;
    tb_verdict("tb_ik64_axil_cdc");
  end

  initial begin
    #50000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_axil_cdc");
  end

endmodule
