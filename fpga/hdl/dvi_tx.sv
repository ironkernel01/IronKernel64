// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// File: dvi_tx.sv
// Purpose: DVI 1.0 / HDMI-compatible transmitter core: RGB 8:8:8 plus syncs
//   and data enable in, four 10-bit TMDS characters per pixel clock out (three
//   data lanes and the clock lane pattern).
// Overview:
//   * Lane mapping (DVI 1.0 section 3.3, channel assignment):
//       tmds_ch0 = blue,  control {C1, C0} = {vsync, hsync};
//       tmds_ch1 = green, control {C1, C0} = {0, 0};
//       tmds_ch2 = red,   control {C1, C0} = {0, 0}.
//   * tmds_clk is NOT a clock: it is the constant 10-bit word that the clock
//     lane serializer sends every pixel clock (five ones, then five zeros), so
//     the TMDS clock lane carries the pixel clock with the same latency and
//     serializer as the data lanes.
//   * No I/O or clocking primitives here (fpga.md section 12): c64_top.sv
//     serializes each word 10:1 with OSERDESE2 (bit 0 first, at 371.25 MHz
//     DDR from the pixel MMCM) and drives OBUFDS TMDS_33 pins.
//   * Latency: 3 pixel clocks from rgb/hsync/vsync/de to the TMDS words (the
//     tmds_encoder pipeline), identical on all three lanes.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: pix_clk only (74.25 MHz); pix_resetn is synchronous to it.
// -----------------------------------------------------------------------------
module dvi_tx (
  // Pixel clock (74.25 MHz, pixel MMCM) and its synchronous active-low reset.
  input  logic        pix_clk,
  input  logic        pix_resetn,

  // Video input, pix_clk domain, one pixel per clock: rgb = {R[23:16],
  // G[15:8], B[7:0]} is sent while de is high; hsync/vsync are active high
  // levels sent as control characters on the blue lane while de is low.
  input  logic [23:0] rgb,
  input  logic        hsync,
  input  logic        vsync,
  input  logic        de,

  // TMDS characters, pix_clk domain, to the 10:1 serializers in c64_top.sv;
  // bit 0 of each word is transmitted first.
  output logic [9:0]  tmds_ch0,             // data lane 0, blue + hsync/vsync
  output logic [9:0]  tmds_ch1,             // data lane 1, green
  output logic [9:0]  tmds_ch2,             // data lane 2, red
  output logic [9:0]  tmds_clk              // clock lane word (constant, see header)
);

  localparam int          COLOR_W        = 8;
  localparam int          RED_LSB        = 2 * COLOR_W;
  localparam int          GREEN_LSB      = COLOR_W;
  localparam int          BLUE_LSB       = 0;
  localparam logic [9:0]  CLK_LANE_WORD  = 10'b0000011111;   // bits 0..4 high, 5..9 low

  assign tmds_clk = CLK_LANE_WORD;

  // Lane 0: blue pixel data; hsync and vsync travel as C0 and C1.
  tmds_encoder u_enc_blue (
    .clk    (pix_clk),
    .resetn (pix_resetn),
    .de     (de),
    .ctrl   ({vsync, hsync}),
    .data   (rgb[BLUE_LSB +: COLOR_W]),
    .symbol (tmds_ch0)
  );

  // Lane 1: green pixel data; control characters carry C0 = C1 = 0.
  tmds_encoder u_enc_green (
    .clk    (pix_clk),
    .resetn (pix_resetn),
    .de     (de),
    .ctrl   (2'b00),
    .data   (rgb[GREEN_LSB +: COLOR_W]),
    .symbol (tmds_ch1)
  );

  // Lane 2: red pixel data; control characters carry C0 = C1 = 0.
  tmds_encoder u_enc_red (
    .clk    (pix_clk),
    .resetn (pix_resetn),
    .de     (de),
    .ctrl   (2'b00),
    .data   (rgb[RED_LSB +: COLOR_W]),
    .symbol (tmds_ch2)
  );

endmodule
