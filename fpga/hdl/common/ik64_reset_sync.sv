// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_reset_sync.sv
// Purpose: reset synchronizer: asynchronous assertion, synchronous release.
//   Every clock domain's reset comes from one instance.
// Behaviors:
//   * arstn low clears the chain at once (no clock needed); after arstn rises,
//     resetn rises STAGES clk edges later.
//   * NAMED EXCEPTION to the synchronous-reset rule (fpga.md): this is the only
//     ik64 RTL file with an asynchronous edge in a sensitivity list. The
//     reset-policy gate in scripts/ik64_regression.ps1 must list this file
//     name in $ResetExceptions.
//   * The chain register is named `pipe`; build_bitstream.tcl matches
//     `/pipe_reg[N]$` and scripts/ik64_constrain_cdc.tcl false-paths the CLR
//     pins of pipe_reg[*] by that name. Do not rename it.
//   * Power-up value of the chain is 0 (reset asserted).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (destination); arstn asynchronous; resetn synchronous to clk.
// -----------------------------------------------------------------------------
`include "ik64_sync_attr.svh"

module ik64_reset_sync #(
  parameter int STAGES = 4              // flip-flops before release, >= 2
)(
  input  logic clk,
  input  logic arstn,                   // asynchronous assertion, active low
  output logic resetn                   // synchronous release, active low
);

  if (STAGES < 2) begin : g_bad_stages
    $fatal(1, "ik64_reset_sync: STAGES=%0d, must be at least 2", STAGES);
  end

  `IK64_SYNC_ATTR
  logic [STAGES-1:0] pipe = '0;

  always_ff @(posedge clk or negedge arstn) begin
    if (!arstn) pipe <= '0;
    else        pipe <= {pipe[STAGES-2:0], 1'b1};
  end

  assign resetn = pipe[STAGES-1];

endmodule
