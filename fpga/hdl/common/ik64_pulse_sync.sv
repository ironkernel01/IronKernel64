// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_pulse_sync.sv
// Purpose: carry one-cycle events from src_clk to dst_clk as one dst_clk pulse
//   per event.
// Behaviors:
//   * Source: each src_pulse flips a toggle. Destination: the toggle crosses
//     through ik64_sync (u_pulse_sync, STAGES deep); an XOR of the synchronized
//     level against its previous value, registered, gives dst_pulse.
//   * Open loop: two events closer than STAGES + 1 dst_clk periods can cancel
//     in the toggle and are both lost. The caller guarantees the spacing.
//   * src_pulse must be a single-cycle pulse; a held level toggles every clock.
//   * Latency: STAGES + 2 dst_clk edges after the toggle is registered.
//   * Both resets are synchronous to their own clock, active low.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: src_clk, dst_clk.
// -----------------------------------------------------------------------------
module ik64_pulse_sync #(
  parameter int STAGES = 3              // synchronizer depth, >= 2
)(
  input  logic src_clk,
  input  logic src_resetn,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_resetn,
  output logic dst_pulse
);

  logic src_toggle;
  logic dst_level;
  logic dst_level_d;

  always_ff @(posedge src_clk) begin
    if (!src_resetn)    src_toggle <= 1'b0;
    else if (src_pulse) src_toggle <= !src_toggle;
  end

  ik64_sync #(.WIDTH(1), .STAGES(STAGES)) u_pulse_sync (
    .clk(dst_clk), .resetn(dst_resetn), .d(src_toggle), .q(dst_level));

  always_ff @(posedge dst_clk) begin
    if (!dst_resetn) begin
      dst_level_d <= 1'b0;
      dst_pulse   <= 1'b0;
    end else begin
      dst_level_d <= dst_level;
      dst_pulse   <= dst_level ^ dst_level_d;
    end
  end

endmodule
