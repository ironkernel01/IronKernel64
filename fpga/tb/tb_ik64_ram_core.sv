// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_ram_core.sv
// Purpose: self-checking bench for ik64_ram_core (simple-dual-port RAM).
// Configurations (RAM_STYLE / CLOCKING / DATA_W / ADDR_W / READ_LATENCY, clocks):
//   cfg 0 block / INDEPENDENT / 12 / 5 / 1  (wr 10 ns, rd 14 ns)
//   cfg 1 block / INDEPENDENT / 12 / 5 / 2  (wr 10 ns, rd 14 ns)
//   cfg 2 distributed / COMMON / 16 / 4 / 1
//   cfg 3 distributed / COMMON / 16 / 4 / 2
//   cfg 4 block / COMMON / 8 / 6 / 1
//   cfg 5 block / INDEPENDENT / 32 / 8 / 2  (wr 10 ns, rd 7 ns)
// Cases:
//   1. After reset the read output is zero and stays zero with no read.
//   2. Every word written (wr_en pulses); a write attempt with wr_en low is ignored.
//   3. Single reads: the word appears exactly READ_LATENCY read clocks after the
//      clock with rd_en high (not earlier: the previous output holds until then),
//      and holds while rd_en is low even with the address changing.
//   4. Pipelined reads (rd_en high, a new address every clock, two sweeps): the
//      output stream is the address stream delayed by READ_LATENCY.
//   5. Overwrite: a word rewritten reads back the new value; a write to another
//      address while reading does not disturb the read.
//   6. rd_resetn pulse in the clock after a read clears the output to zero; it
//      stays zero until a new read completes.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Run twice by the regression: default (xpm_memory_sdpram) and
//   +define+IK64_RAM_BEHAVIORAL (inferred array) with the same checks.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_ram_core;

  import ik64_tb_pkg::*;

  localparam int NCFG = 6;

  function automatic string sty_of(input int i);
    return (i == 2 || i == 3) ? "distributed" : "block";
  endfunction
  function automatic string clk_of(input int i);
    return (i == 0 || i == 1 || i == 5) ? "INDEPENDENT" : "COMMON";
  endfunction
  function automatic int dw_of(input int i);
    int t [NCFG] = '{12, 12, 16, 16, 8, 32};
    return t[i];
  endfunction
  function automatic int aw_of(input int i);
    int t [NCFG] = '{5, 5, 4, 4, 6, 8};
    return t[i];
  endfunction
  function automatic int lat_of(input int i);
    int t [NCFG] = '{1, 2, 1, 2, 1, 2};
    return t[i];
  endfunction
  function automatic real trd_of(input int i);
    real t [NCFG] = '{14.0, 14.0, 10.0, 10.0, 10.0, 7.0};
    return t[i];
  endfunction

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam string STYLE = sty_of(c);
    localparam string CLKNG = clk_of(c);
    localparam int    DW    = dw_of(c);
    localparam int    AWD   = aw_of(c);
    localparam int    LAT   = lat_of(c);
    localparam int    DEPTH = 1 << AWD;
    localparam real   TWR   = 10.0;
    localparam real   TRD   = (CLKNG == "COMMON") ? 10.0 : trd_of(c);

    logic             wr_clk = 1'b0;
    logic             rd_clk = 1'b0;
    logic             wr_en = 1'b0;
    logic [AWD-1:0]   wr_addr = '0;
    logic [DW-1:0]    wr_data = '0;
    logic             rd_resetn = 1'b0;
    logic             rd_en = 1'b0;
    logic [AWD-1:0]   rd_addr = '0;
    logic [DW-1:0]    rd_data;

    always #(TWR / 2.0) wr_clk = ~wr_clk;
    if (CLKNG != "COMMON") begin : g_ic
      always #(TRD / 2.0) rd_clk = ~rd_clk;
    end

    logic rclk;
    assign rclk = (CLKNG == "COMMON") ? wr_clk : rd_clk;

    ik64_ram_core #(.RAM_STYLE(STYLE), .CLOCKING(CLKNG), .DATA_W(DW), .ADDR_W(AWD), .READ_LATENCY(LAT)) u_dut (
      .wr_clk(wr_clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
      .rd_clk(rclk), .rd_resetn(rd_resetn), .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data));

    logic [DW-1:0] exp_mem [DEPTH];

    // Injective pattern (odd multiplier) so neighbouring words differ.
    function automatic logic [DW-1:0] pat(input int a, input int gen);
      logic [DW-1:0] x;
      x = DW'(a * 32'h0000_0505 + gen * 32'h0000_1B3D + 32'h0000_00A7);
      return x;
    endfunction

    task automatic put(input int a, input logic [DW-1:0] d, input logic en);
      @(negedge wr_clk);
      wr_en = en; wr_addr = AWD'(a); wr_data = d;
      @(negedge wr_clk);
      wr_en = 1'b0;
    endtask

    initial begin
      logic [DW-1:0] prev;
      logic [DW-1:0] got;
      int            m;

      // 1. Reset, no read.
      repeat (6) @(negedge rclk);
      tb_check(rd_data === {DW{1'b0}}, $sformatf("cfg%0d output %0h in reset, expected 0", c, rd_data));
      rd_resetn = 1'b1;
      repeat (6) @(negedge rclk);
      tb_check(rd_data === {DW{1'b0}}, $sformatf("cfg%0d output %0h after reset with no read, expected 0", c, rd_data));

      // 2. Fill; a write with wr_en low is ignored.
      for (int a = 0; a < DEPTH; a++) begin
        exp_mem[a] = pat(a, 0);
        put(a, exp_mem[a], 1'b1);
      end
      put(3, ~exp_mem[3], 1'b0);
      repeat (4) @(negedge wr_clk);

      // 3. Single reads with exact latency, then hold.
      prev = {DW{1'b0}};
      foreach (exp_mem[a]) begin
        if (a % 3 == 0 || a < 6) begin
          @(negedge rclk);
          rd_en = 1'b1; rd_addr = AWD'(a);
          @(negedge rclk);            // one rising edge captured the read
          rd_en = 1'b0;
          rd_addr = AWD'(a + 1);       // address moves on; must not matter
          if (LAT == 1) begin
            tb_check(rd_data === exp_mem[a], $sformatf("cfg%0d read %0d = %0h expected %0h after 1 clock", c, a, rd_data, exp_mem[a]));
          end else begin
            tb_check(rd_data === prev, $sformatf("cfg%0d read %0d output changed after 1 clock (latency 2): %0h", c, a, rd_data));
            @(negedge rclk);
            tb_check(rd_data === exp_mem[a], $sformatf("cfg%0d read %0d = %0h expected %0h after 2 clocks", c, a, rd_data, exp_mem[a]));
          end
          prev = exp_mem[a];
          repeat (3) @(negedge rclk);
          tb_check(rd_data === prev, $sformatf("cfg%0d output did not hold: %0h expected %0h", c, rd_data, prev));
        end
      end

      // 4. Pipelined reads, two sweeps.
      @(negedge rclk);
      for (int j = 0; j < 2 * DEPTH + LAT + 1; j++) begin
        rd_en = (j < 2 * DEPTH);
        rd_addr = AWD'(j % DEPTH);
        @(negedge rclk);
        if (j >= LAT - 1 && (j - (LAT - 1)) < 2 * DEPTH) begin
          m = (j - (LAT - 1)) % DEPTH;
          tb_check(rd_data === exp_mem[m], $sformatf("cfg%0d stream: word %0d = %0h expected %0h", c, m, rd_data, exp_mem[m]));
        end
      end
      rd_en = 1'b0;
      repeat (3) @(negedge rclk);

      // 5. Overwrite, and a write elsewhere during a read.
      exp_mem[5 % DEPTH] = pat(5 % DEPTH, 7);
      put(5 % DEPTH, exp_mem[5 % DEPTH], 1'b1);
      repeat (3) @(negedge rclk);
      @(negedge rclk);
      rd_en = 1'b1; rd_addr = AWD'(5 % DEPTH);
      fork
        put(7 % DEPTH, pat(7 % DEPTH, 9), 1'b1);
      join_none
      @(negedge rclk);
      rd_en = 1'b0;
      if (LAT == 2) @(negedge rclk);
      tb_check(rd_data === exp_mem[5 % DEPTH], $sformatf("cfg%0d overwritten word read %0h expected %0h", c, rd_data, exp_mem[5 % DEPTH]));
      exp_mem[7 % DEPTH] = pat(7 % DEPTH, 9);
      repeat (4) @(negedge rclk);
      @(negedge rclk);
      rd_en = 1'b1; rd_addr = AWD'(7 % DEPTH);
      @(negedge rclk);
      rd_en = 1'b0;
      if (LAT == 2) @(negedge rclk);
      tb_check(rd_data === exp_mem[7 % DEPTH], $sformatf("cfg%0d word written during a read: %0h expected %0h", c, rd_data, exp_mem[7 % DEPTH]));

      // 6. Reset in the clock after a read.
      @(negedge rclk);
      rd_en = 1'b1; rd_addr = AWD'(2);
      @(negedge rclk);
      rd_en = 1'b0;
      rd_resetn = 1'b0;
      @(negedge rclk);
      rd_resetn = 1'b1;
      tb_check(rd_data === {DW{1'b0}}, $sformatf("cfg%0d output %0h after reset pulse, expected 0", c, rd_data));
      repeat (5) begin
        @(negedge rclk);
        tb_check(rd_data === {DW{1'b0}}, $sformatf("cfg%0d output %0h loaded after reset without a read", c, rd_data));
      end
      rd_en = 1'b1; rd_addr = AWD'(4);
      @(negedge rclk);
      rd_en = 1'b0;
      if (LAT == 2) @(negedge rclk);
      tb_check(rd_data === exp_mem[4], $sformatf("cfg%0d read after reset %0h expected %0h", c, rd_data, exp_mem[4]));

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    #100.0;
    tb_verdict("tb_ik64_ram_core");
  end

  initial begin
    #50000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_ram_core");
  end

endmodule
