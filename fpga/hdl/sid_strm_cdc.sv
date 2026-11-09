// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// Copyright (C) 2026 IronKernel
// -----------------------------------------------------------------------------
// File: sid_strm_cdc.sv
// Purpose: carry the 48 kHz SID sample stream (strm_valid, strm_sample) from
//   sid_clk (sid_player) into cpu_clk (sid_audio_out) through a dual-clock FIFO.
// Overview:
//   * xpm_fifo_async, 16 deep x 16 bit, block RAM (a distributed-RAM FIFO raises CDC-15 warnings in report_cdc, which the build gates), first-word-fall-through.
//     Why: a 16-bit sample is a multi-bit value crossing between two clocks
//     that are not phase-related for timing (both come from the one system
//     MMCM), so a Gray-pointer FIFO is the coherent crossing (fpga.md
//     section 6). The macro carries its own CDC constraints.
//   * Write side (sid_clk): a strm_valid pulse writes one word, ANDed with !full
//     and !wr_rst_busy; a pulse into a full FIFO is dropped and, in simulation,
//     raises $error. At 48 kHz against a cpu_clk drain it never fills.
//   * Read side (cpu_clk): one pop per available word; out_valid is a one-clock
//     pulse per word (the FWFT head is popped on the clock it is presented).
//   * Reset: rst = !sid_resetn, synchronous to sid_clk; both resets come from
//     one assertion (c64_top rst_arstn). The read side idles while rd_rst_busy.
//   * Kept in its own module (not inline in c64_top) so the FIFO, its gating and
//     its sim check are reviewed in one place.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
//   * 11-09-2026: dual SPDX expression (c64demo.md Licensing); port group comments.
// Clocks: sid_clk (50 MHz, write), cpu_clk (100 MHz, read); asynchronous pair.
// -----------------------------------------------------------------------------
module sid_strm_cdc #(
  parameter int XPM_SIM_ASSERT = 0          // 1: enable xpm_fifo_async usage assertions (simulation)
)(
  // Write side, sid_clk domain (sid_player output), reset active low and
  // synchronous to sid_clk; it also resets the read side inside the macro.
  input  logic                 sid_clk,
  input  logic                 sid_resetn,   // synchronous to sid_clk, active low
  input  logic                 in_valid,     // sid_clk, one clock per sample
  input  logic signed [15:0]   in_sample,

  // Read side, cpu_clk domain (to sid_audio_out); no reset port of its own.
  input  logic                 cpu_clk,
  output logic                 out_valid,    // cpu_clk, one clock per sample
  output logic signed [15:0]   out_sample
);

  localparam int DEPTH      = 16;
  localparam int CDC_STAGES = 3;

  logic        full, empty, wr_rst_busy, rd_rst_busy, wr_en, rd_en;
  logic [15:0] dout;

  assign wr_en = in_valid && !full && !wr_rst_busy;
  assign rd_en = !empty && !rd_rst_busy;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .ECC_MODE            ("no_ecc"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (XPM_SIM_ASSERT),
    .FIFO_WRITE_DEPTH    (DEPTH),
    .WRITE_DATA_WIDTH    (16),
    .WR_DATA_COUNT_WIDTH (1),
    .PROG_FULL_THRESH    (10),
    .FULL_RESET_VALUE    (0),
    .USE_ADV_FEATURES    ("0000"),
    .READ_MODE           ("fwft"),
    .FIFO_READ_LATENCY   (0),
    .READ_DATA_WIDTH     (16),
    .RD_DATA_COUNT_WIDTH (1),
    .PROG_EMPTY_THRESH   (10),
    .DOUT_RESET_VALUE    ("0"),
    .CDC_SYNC_STAGES     (CDC_STAGES),
    .WAKEUP_TIME         (0)
  ) u_fifo (
    .sleep         (1'b0),
    .rst           (!sid_resetn),
    .wr_clk        (sid_clk),
    .wr_en         (wr_en),
    .din           (in_sample),
    .full          (full),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (cpu_clk),
    .rd_en         (rd_en),
    .dout          (dout),
    .empty         (empty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  assign out_valid  = rd_en;
  assign out_sample = $signed(dout);

  // synthesis translate_off
  always @(posedge sid_clk) begin
    if (sid_resetn && !wr_rst_busy && in_valid && full)
      $error("%m: sample dropped, FIFO full");
  end
  // synthesis translate_on

endmodule
