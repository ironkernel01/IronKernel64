// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: tb_ik64_gray_sync.sv
// Purpose: self-checking bench for ik64_gray_sync (Gray-coded counter crossing).
// Cases (each configuration in its own generate block):
//   cfg 0: src 10 ns, dst 23 ns, WIDTH 8,  STAGES 2   (slow reader)
//   cfg 1: src 23 ns, dst 10 ns, WIDTH 12, STAGES 3   (fast reader)
//   cfg 2: src 10 ns, dst 10 ns, WIDTH 6,  STAGES 2   (same clock)
//   1. Reset: dst_count is 0 while either reset is asserted and right after.
//   2. Count: src_count steps by 0 or +1 per source clock (pseudo-random holds
//      and runs at the full rate, through several wraps). At every destination
//      clock the destination value is an earlier source value: the modular
//      distance (src - dst) is between 0 and the latency bound; a torn Gray
//      value would show as a large or negative distance.
//   3. The destination never goes backwards (modular).
//   4. Settled: after the source stops, dst_count equals src_count exactly.
//   5. Same-clock configuration: dst_count shows a step exactly STAGES + 2
//      clocks after the source count changed.
// Negative control: +INJECT_FAILURE prints TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ik64_gray_sync;

  import ik64_tb_pkg::*;

  localparam int NCFG = 3;
  localparam real SRC_T [NCFG] = '{10.0, 23.0, 10.0};
  localparam real DST_T [NCFG] = '{23.0, 10.0, 10.0};
  localparam int  WID   [NCFG] = '{8, 12, 6};
  localparam int  STG   [NCFG] = '{2, 3, 2};

  int done_cnt = 0;

  for (genvar c = 0; c < NCFG; c++) begin : g_cfg
    localparam real TS = SRC_T[c];
    localparam real TD = DST_T[c];
    localparam int  W  = WID[c];
    localparam int  S  = STG[c];
    // Largest legal lag in source counts: source register + S + output register
    // destination clocks, plus one source clock of sampling slack each way.
    localparam int  LAG_MAX = int'(((S + 3) * TD + 2.0 * TS) / TS) + 1;
    localparam logic [W-1:0] LAG_V  = W'(LAG_MAX);
    localparam logic [W-1:0] HALF_V = W'(1) << (W - 1);

    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;
    logic src_resetn = 1'b0;
    logic dst_resetn = 1'b0;
    logic [W-1:0] src_count = '0;
    logic [W-1:0] dst_count;

    always #(TS / 2.0) src_clk = ~src_clk;
    always #(TD / 2.0) dst_clk = ~dst_clk;

    ik64_gray_sync #(.WIDTH(W), .STAGES(S)) u_dut (
      .src_clk(src_clk), .src_resetn(src_resetn), .src_count(src_count),
      .dst_clk(dst_clk), .dst_resetn(dst_resetn), .dst_count(dst_count));

    // Source driver state.
    int unsigned lfsr = 32'hACE1_1234 + c;
    logic        run_en = 1'b0;
    logic        full_rate = 1'b0;
    int          steps = 0;

    always @(posedge src_clk) begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (src_resetn && run_en && (full_rate || lfsr[3:2] != 2'b00)) begin
        src_count <= src_count + 1'b1;
        steps++;
      end
    end

    // Destination monitor.
    int           bad_lag  = 0;
    int           backward = 0;
    int           samples  = 0;
    logic [W-1:0] prev_dst = '0;
    logic         have_prev = 1'b0;
    always @(posedge dst_clk) begin
      if (dst_resetn && src_resetn && run_en) begin
        logic [W-1:0] lag;
        lag = src_count - dst_count;
        samples++;
        if (lag > LAG_V) bad_lag++;
        if (have_prev) begin
          logic [W-1:0] fwd;
          fwd = dst_count - prev_dst;
          if (fwd > HALF_V) backward++;   // modular backward step
        end
        prev_dst  <= dst_count;
        have_prev <= 1'b1;
      end
    end

    initial begin
      int rlimit;
      repeat (5) @(posedge src_clk);
      src_resetn = 1'b1;
      repeat (5) @(posedge dst_clk);
      dst_resetn = 1'b1;
      repeat (8) @(posedge dst_clk);
      tb_check(dst_count == '0, $sformatf("cfg%0d dst_count %0d after reset", c, dst_count));

      // Pseudo-random run, several wraps.
      run_en = 1'b1;
      rlimit = 3 * (1 << W) + 17;
      while (steps < rlimit) @(posedge src_clk);
      // Full-rate run, one more wrap.
      full_rate = 1'b1;
      rlimit = steps + 2 * (1 << W) + 5;
      while (steps < rlimit) @(posedge src_clk);
      run_en = 1'b0;
      repeat (S + 6) @(posedge dst_clk);
      repeat (4) @(posedge src_clk);
      tb_check(samples > 100, $sformatf("cfg%0d only %0d destination samples", c, samples));
      tb_check(bad_lag == 0, $sformatf("cfg%0d %0d destination samples outside the lag window 0..%0d", c, bad_lag, LAG_MAX));
      tb_check(backward == 0, $sformatf("cfg%0d %0d backward destination steps", c, backward));
      tb_check(dst_count == src_count, $sformatf("cfg%0d settled dst_count %0d != src_count %0d", c, dst_count, src_count));

      // Exact latency in the same-clock configuration.
      if (c == 2) begin
        logic [W-1:0] start_v;
        int n;
        @(negedge src_clk);
        start_v = dst_count;
        src_count = src_count + 1'b1;
        n = 0;
        while (dst_count == start_v && n < 20) begin
          @(negedge dst_clk);
          n++;
        end
        tb_check(n == S + 2, $sformatf("cfg%0d same-clock latency %0d clocks, expected %0d", c, n, S + 2));
      end

      done_cnt++;
    end
  end

  initial begin
    wait (done_cnt == NCFG);
    #100.0;
    tb_verdict("tb_ik64_gray_sync");
  end

  initial begin
    #5000000;
    tb_error("watchdog timeout");
    tb_verdict("tb_ik64_gray_sync");
  end

endmodule
