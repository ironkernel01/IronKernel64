// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_pulse_sync.sv
// Purpose: self-checking bench for ik64_pulse_sync (toggle-based event carrier).
// Cases (each configuration in its own generate block with its own clocks):
//   cfg 0: src 10 ns -> dst 30 ns (slow destination), STAGES 3
//   cfg 1: src 40 ns -> dst 10 ns (fast destination), STAGES 3
//   cfg 2: src 10 ns -> dst 13 ns (unrelated clocks), STAGES 2
//   1. Quiet after reset: no dst_pulse while no event is sent.
//   2. 40 single-cycle events spaced well beyond STAGES + 1 destination
//      periods: exactly 40 destination pulses, each one dst_clk wide and
//      isolated, each arriving within (STAGES + 3) dst periods + 1 src period of
//      its event.
//   3. Events at the documented minimum spacing (STAGES + 2 destination periods,
//      rounded up in source clocks) are all delivered.
//   4. Nothing further arrives after the last event.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_pulse_sync;

  import ik64_tb_pkg::*;

  localparam int NCFG = 3;
  localparam real SRC_T [NCFG] = '{10.0, 40.0, 10.0};
  localparam real DST_T [NCFG] = '{30.0, 10.0, 13.0};
  localparam int  STG   [NCFG] = '{3, 3, 2};

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam real TS = SRC_T[c];
    localparam real TD = DST_T[c];
    localparam int  S  = STG[c];
    // Source clocks between events for the safe and the minimum-spacing runs.
    localparam int  GAP_SAFE = int'((TD * (S + 6)) / TS) + 2;
    localparam int  GAP_MIN  = int'((TD * (S + 2)) / TS) + 1;

    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;
    logic src_resetn = 1'b0;
    logic dst_resetn = 1'b0;
    logic src_pulse  = 1'b0;
    logic dst_pulse;

    always #(TS / 2.0) src_clk = ~src_clk;
    always #(TD / 2.0) dst_clk = ~dst_clk;

    ik64_pulse_sync #(.STAGES(S)) u_dut (
      .src_clk(src_clk), .src_resetn(src_resetn), .src_pulse(src_pulse),
      .dst_clk(dst_clk), .dst_resetn(dst_resetn), .dst_pulse(dst_pulse));

    // Destination-side monitor.
    int    got       = 0;
    int    wide      = 0;
    logic  prev_pulse = 1'b0;
    realtime t_last_pulse;
    always @(posedge dst_clk) begin
      if (dst_resetn) begin
        if (dst_pulse) begin
          got++;
          t_last_pulse = $realtime;
          if (prev_pulse) wide++;
        end
        prev_pulse <= dst_pulse;
      end
    end

    realtime t_event[$];
    int      next_check = 0;
    int      late = 0;

    // One-cycle event on the source clock.
    task automatic send_event();
      @(posedge src_clk);
      src_pulse <= 1'b1;
      t_event.push_back($realtime);
      @(posedge src_clk);
      src_pulse <= 1'b0;
    endtask

    // Send n events separated by `gap` source clocks (event cycle included).
    task automatic burst(input int n, input int gap);
      for (int i = 0; i < n; i++) begin
        send_event();
        repeat (gap - 2) @(posedge src_clk);
      end
    endtask

    // After a burst, compare the arrival of each pulse with its event time.
    always @(posedge dst_clk) begin
      if (dst_resetn && dst_pulse && next_check < t_event.size()) begin
        if (($realtime - t_event[next_check]) > ((S + 3) * TD + TS)) late++;
        next_check++;
      end
    end

    initial begin
      int base;
      repeat (4) @(posedge src_clk);
      src_resetn = 1'b1;
      repeat (4) @(posedge dst_clk);
      dst_resetn = 1'b1;

      // 1. Quiet.
      repeat (20) @(posedge dst_clk);
      tb_check(got == 0, $sformatf("cfg%0d spurious pulses after reset: %0d", c, got));

      // 2. Safe spacing.
      burst(40, GAP_SAFE);
      repeat (S + 8) @(posedge dst_clk);
      tb_check(got == 40, $sformatf("cfg%0d safe-spacing pulses %0d, expected 40", c, got));
      tb_check(wide == 0, $sformatf("cfg%0d %0d destination pulses wider than one clock", c, wide));
      tb_check(late == 0, $sformatf("cfg%0d %0d pulses later than the latency bound", c, late));

      // 3. Minimum documented spacing.
      base = got;
      burst(40, GAP_MIN);
      repeat (S + 8) @(posedge dst_clk);
      tb_check(got - base == 40, $sformatf("cfg%0d minimum-spacing pulses %0d, expected 40", c, got - base));
      tb_check(late == 0, $sformatf("cfg%0d %0d pulses later than the latency bound (min spacing)", c, late));

      // 4. Quiet again.
      base = got;
      repeat (30) @(posedge dst_clk);
      tb_check(got == base, $sformatf("cfg%0d pulses after the last event", c));

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    #100.0;
    tb_verdict("tb_ik64_pulse_sync");
  end

  initial begin
    #2000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_pulse_sync");
  end

endmodule
