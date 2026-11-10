// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_reset_sync.sv
// Purpose: self-checking bench for ik64_reset_sync (asynchronous assertion,
//   synchronous release).
// Cases (STAGES 4 and STAGES 2, one generate block each with its own clock):
//   1. Power-up: resetn is low before any clock edge.
//   2. arstn low holds resetn low.
//   3. Release: resetn stays low for STAGES-1 rising edges after arstn rises and
//      goes high after the STAGES-th, aligned to the clock.
//   4. Asynchronous assertion with the clock STOPPED: resetn falls without an
//      edge; releasing arstn with the clock stopped does not raise resetn;
//      restarting the clock releases after STAGES edges.
//   5. Re-assertion in the middle of a release restarts the full release time.
//   6. A short arstn pulse (well under one clock period) between edges, with
//      resetn high, drops resetn immediately.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_reset_sync;

  import ik64_tb_pkg::*;

  localparam int NCFG = 2;
  localparam int S_OF [NCFG] = '{4, 2};

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam int S = S_OF[c];

    logic clk    = 1'b0;
    logic clk_en = 1'b1;
    logic arstn  = 1'b0;
    logic resetn;

    always begin
      #5.0;
      if (clk_en) clk = ~clk;
    end

    ik64_reset_sync #(.STAGES(S)) u_dut (.clk(clk), .arstn(arstn), .resetn(resetn));

    // Falling-edge samples: after n rising edges following a change made just
    // after a falling edge, resetn must still be low for n < S.
    task automatic expect_release(input string what);
      for (int e = 1; e < S; e++) begin
        @(negedge clk);
        tb_check(resetn === 1'b0, $sformatf("cfg%0d %s: resetn high after %0d edges (STAGES %0d)", c, what, e, S));
      end
      @(negedge clk);
      tb_check(resetn === 1'b1, $sformatf("cfg%0d %s: resetn low after %0d edges", c, what, S));
    endtask

    initial begin
      #1.0;
      tb_check(resetn === 1'b0, $sformatf("cfg%0d power-up resetn=%b", c, resetn));

      repeat (6) begin
        @(negedge clk);
        tb_check(resetn === 1'b0, $sformatf("cfg%0d held in reset resetn=%b", c, resetn));
      end

      // 3. Normal release.
      arstn = 1'b1;
      expect_release("release");
      repeat (3) begin
        @(negedge clk);
        tb_check(resetn === 1'b1, $sformatf("cfg%0d stays released", c));
      end

      // 4. Asynchronous assertion with the clock stopped (clock is low here).
      clk_en = 1'b0;
      #12.0;
      arstn = 1'b0;
      #1.0;
      tb_check(resetn === 1'b0, $sformatf("cfg%0d async assert without clock: resetn=%b", c, resetn));
      #20.0;
      arstn = 1'b1;
      #20.0;
      tb_check(resetn === 1'b0, $sformatf("cfg%0d release without clock: resetn=%b", c, resetn));
      clk_en = 1'b1;
      expect_release("release after clock restart");

      // 5. Re-assert halfway through a release.
      arstn = 1'b0;
      @(negedge clk);
      arstn = 1'b1;
      for (int e = 1; e < S - 1; e++) @(negedge clk);
      arstn = 1'b0;
      #1.0;
      tb_check(resetn === 1'b0, $sformatf("cfg%0d re-assert mid release", c));
      @(negedge clk);
      arstn = 1'b1;
      expect_release("release after mid-release re-assert");

      // 6. Short pulse between edges while resetn is high.
      #1.0;
      arstn = 1'b0;
      #0.5;
      arstn = 1'b1;
      #0.1;
      tb_check(resetn === 1'b0, $sformatf("cfg%0d short arstn pulse did not drop resetn", c));
      expect_release("release after short pulse");

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    #50.0;
    tb_verdict("tb_ik64_reset_sync");
  end

  initial begin
    #200000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_reset_sync");
  end

endmodule
