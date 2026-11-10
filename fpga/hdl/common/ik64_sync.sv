// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_sync.sv
// Purpose: level synchronizer: STAGES flip-flops per bit in the destination
//   clock for asynchronous levels (one chain per bit).
// Behaviors:
//   * Each bit must hold a new value for at least two destination clock edges.
//     Pulses use ik64_pulse_sync, counters ik64_gray_sync.
//   * The chain register is named `sync_ff` in generate block g_bit[i]; the CDC
//     script scripts/ik64_constrain_cdc.tcl finds the first stage
//     g_bit[*].sync_ff_reg[0] by that name. Do not rename it.
//   * Reset (synchronous, active low) loads RESET_VALUE; the declaration
//     initializer is the same value so power-up equals reset.
//   * Latency: STAGES clk edges from d to q.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (destination); resetn is synchronous to clk, active low.
// -----------------------------------------------------------------------------
`include "ik64_sync_attr.svh"

module ik64_sync #(
  parameter int   WIDTH       = 1,    // levels carried, one chain each
  parameter int   STAGES      = 3,    // flip-flops per chain, >= 2
  parameter logic RESET_VALUE = 1'b0  // value every chain holds in reset
)(
  input  logic             clk,
  input  logic             resetn,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);

  if (STAGES < 2) begin : g_bad_stages
    $fatal(1, "ik64_sync: STAGES=%0d, must be at least 2", STAGES);
  end

  for (genvar b = 0; b < WIDTH; b++) begin : g_bit
    `IK64_SYNC_ATTR
    logic [STAGES-1:0] sync_ff = {STAGES{RESET_VALUE}};

    always_ff @(posedge clk) begin
      if (!resetn) sync_ff <= {STAGES{RESET_VALUE}};
      else         sync_ff <= {sync_ff[STAGES-2:0], d[b]};
    end

    assign q[b] = sync_ff[STAGES-1];
  end

endmodule
