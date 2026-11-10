// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_sync.sv
// Purpose: self-checking bench for ik64_sync (level synchronizer).
// Cases (three configurations, each in its own generate block with its own
//   reset):  cfg 0: WIDTH 4, STAGES 3, RESET_VALUE 0   cfg 1: WIDTH 1, STAGES 2,
//   RESET_VALUE 1   cfg 2: WIDTH 2, STAGES 5, RESET_VALUE 1
//   1. Power-up: q equals RESET_VALUE before any clock edge.
//   2. In reset, q holds RESET_VALUE whatever d does.
//   3. After release with d = ~RESET_VALUE, q holds RESET_VALUE for STAGES-1
//      edges and flips at edge STAGES (exact latency).
//   4. Pattern changes (bit 0 back to the reset level, then all bits back):
//      q follows after exactly STAGES edges, never earlier.
//   5. A one-clock synchronous reset pulse returns q to RESET_VALUE at once.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_sync;

  import ik64_tb_pkg::*;

  localparam int NCFG = 3;
  localparam int W_OF  [NCFG] = '{4, 1, 2};
  localparam int S_OF  [NCFG] = '{3, 2, 5};
  localparam int RV_OF [NCFG] = '{0, 1, 1};

  logic clk = 1'b0;
  always #5.0 clk = ~clk;

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam int W  = W_OF[c];
    localparam int S  = S_OF[c];
    localparam int RV = RV_OF[c];

    logic         resetn = 1'b0;
    logic [W-1:0] d;
    logic [W-1:0] q;
    logic [W-1:0] rvec;
    logic [W-1:0] nrvec;
    logic [W-1:0] mixed;

    ik64_sync #(.WIDTH(W), .STAGES(S), .RESET_VALUE(RV[0])) u_dut (.clk(clk), .resetn(resetn), .d(d), .q(q));

    // d changes just after a falling edge: q must hold `old_q` for S-1 rising
    // edges and equal `new_q` following the S-th.
    task automatic expect_latency(input logic [W-1:0] old_q, input logic [W-1:0] new_q, input string what);
      d = new_q;
      for (int e = 1; e < S; e++) begin
        @(negedge clk);
        tb_check(q === old_q, $sformatf("cfg%0d %s: q=%b moved before edge %0d", c, what, q, S));
      end
      @(negedge clk);
      tb_check(q === new_q, $sformatf("cfg%0d %s: q=%b expected %b after %0d edges", c, what, q, new_q, S));
    endtask

    initial begin
      rvec  = {W{RV[0]}};
      nrvec = ~rvec;
      mixed = nrvec;
      mixed[0] = rvec[0];
      d     = nrvec;
      #1.0;
      tb_check(q === rvec, $sformatf("cfg%0d power-up q=%b expected %b", c, q, rvec));

      repeat (6) begin
        @(negedge clk);
        tb_check(q === rvec, $sformatf("cfg%0d in reset q=%b expected %b", c, q, rvec));
      end

      // Release at a falling edge; d already differs from the reset value.
      resetn = 1'b1;
      for (int e = 1; e < S; e++) begin
        @(negedge clk);
        tb_check(q === rvec, $sformatf("cfg%0d edge %0d after release q=%b, still reset value expected", c, e, q));
      end
      @(negedge clk);
      tb_check(q === nrvec, $sformatf("cfg%0d edge %0d after release q=%b expected %b", c, S, q, nrvec));

      expect_latency(nrvec, mixed, "pattern");
      expect_latency(mixed, rvec, "back to reset pattern");
      expect_latency(rvec, nrvec, "all bits");

      repeat (2) @(negedge clk);
      resetn = 1'b0;
      @(negedge clk);
      tb_check(q === rvec, $sformatf("cfg%0d reset pulse q=%b expected %b", c, q, rvec));
      resetn = 1'b1;

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    repeat (4) @(negedge clk);
    tb_verdict("tb_ik64_sync");
  end

  initial begin
    #200000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_sync");
  end

endmodule
