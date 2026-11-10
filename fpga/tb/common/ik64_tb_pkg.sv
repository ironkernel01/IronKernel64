// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_tb_pkg.sv
// Purpose: shared bench support for every IronKernel 64 testbench: the check
//   counters and the one verdict line.
// Behaviors:
//   * tb_check(cond, msg) counts a check and records a failure; tb_error(msg)
//     is an unconditional failure (a timeout). The counters tb_checks, tb_fails
//     and the first failure text tb_first_msg are package variables; a bench
//     may bump tb_checks / tb_fails directly (tb_c64_video does).
//   * tb_verdict(bench) prints exactly one anchored line
//       TEST PASS: <bench> checks=<n>
//       TEST FAIL: <bench> fails=<n> checks=<n> first=<msg>
//     and calls $finish. +INJECT_FAILURE adds a failed check first (the
//     negative control every bench carries). Zero checks is a failure.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
package ik64_tb_pkg;

  int    tb_checks    = 0;
  int    tb_fails     = 0;
  string tb_first_msg = "";

  function automatic void tb_check(input bit cond, input string msg);
    tb_checks++;
    if (!cond) begin
      tb_fails++;
      if (tb_first_msg == "") tb_first_msg = msg;
      $display("CHECK FAILED @%0t: %s", $time, msg);
    end
  endfunction

  function automatic void tb_error(input string msg);
    tb_check(1'b0, msg);
  endfunction

  task automatic tb_verdict(input string bench);
    if ($test$plusargs("INJECT_FAILURE")) tb_check(1'b0, "INJECT_FAILURE negative control");
    if (tb_fails == 0 && tb_checks > 0) begin
      $display("TEST PASS: %s checks=%0d", bench, tb_checks);
    end else begin
      $display("TEST FAIL: %s fails=%0d checks=%0d first=%s", bench, tb_fails, tb_checks,
               (tb_checks == 0) ? "no checks ran" : tb_first_msg);
    end
    $finish;
  endtask

endpackage
