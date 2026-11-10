// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_gray_sync.sv
// Purpose: carry a free-running binary counter into another clock as a
//   coherent value: Gray code in the source, synchronized per bit in the
//   destination, back to binary.
// Behaviors:
//   * src_count may change by 0 or +1 per src_clk; then every dst_count is the
//     old or the new count, never a torn mix.
//   * `gray_src` (source register) and `gray_dst_ff[0]` (first destination
//     stage) are the cells scripts/ik64_constrain_cdc.tcl bounds with
//     set_max_delay -datapath_only and set_bus_skew of one source period.
//     Do not rename them.
//   * Latency: 1 src_clk + STAGES dst_clk + 1 dst_clk (output register).
//   * Both resets are synchronous to their own clock, active low.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: src_clk, dst_clk.
// -----------------------------------------------------------------------------
`include "ik64_sync_attr.svh"

module ik64_gray_sync #(
  parameter int WIDTH  = 32,            // counter width
  parameter int STAGES = 2              // synchronizer depth, >= 2
)(
  input  logic             src_clk,
  input  logic             src_resetn,
  input  logic [WIDTH-1:0] src_count,
  input  logic             dst_clk,
  input  logic             dst_resetn,
  output logic [WIDTH-1:0] dst_count
);

  if (STAGES < 2) begin : g_bad_stages
    $fatal(1, "ik64_gray_sync: STAGES=%0d, must be at least 2", STAGES);
  end

  logic [WIDTH-1:0] gray_src;
  logic [WIDTH-1:0] gray_dst;
  logic [WIDTH-1:0] bin_dst;

  `IK64_SYNC_ATTR
  logic [WIDTH-1:0] gray_dst_ff [0:STAGES-1];

  always_ff @(posedge src_clk) begin
    if (!src_resetn) gray_src <= '0;
    else             gray_src <= src_count ^ (src_count >> 1);
  end

  always_ff @(posedge dst_clk) begin
    for (int s = 0; s < STAGES; s++) begin
      if (!dst_resetn) gray_dst_ff[s] <= '0;
      else if (s == 0) gray_dst_ff[s] <= gray_src;
      else             gray_dst_ff[s] <= gray_dst_ff[s-1];
    end
  end

  assign gray_dst = gray_dst_ff[STAGES-1];

  // Gray to binary: bit i = XOR of gray bits [WIDTH-1:i].
  always_comb begin
    bin_dst = gray_dst;
    for (int i = 1; i < WIDTH; i++) bin_dst = bin_dst ^ (gray_dst >> i);
  end

  always_ff @(posedge dst_clk) begin
    if (!dst_resetn) dst_count <= '0;
    else             dst_count <= bin_dst;
  end

endmodule
