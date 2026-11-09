// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// File: tb_c64_video.sv
// Purpose: self-checking bench for c64_video (with dvi_tx and tmds_encoder):
//   720p60 timing, 3x scan-out of both framebuffer pages through the palette,
//   the TMDS characters, page flip, vsync interrupt and enable bit.
// Cases:
//   1. Reset values: VID_CTRL, VID_STATUS, VID_FRAME read 0; the palette span
//      reads 0 (write-only).
//   2. Palette load through AXI4-Lite (bits 31:24 written as garbage and
//      dropped); page 0 loaded through framebuffer port A with full-word
//      writes, page 1 with garbage words then two byte-enable passes; writes
//      to unbacked words are dropped. Port A read-back is pipelined and
//      checks the 1-clock read latency.
//   3. Frame 0 end: VID_STATUS.VSYNC sets with IRQ_EN = 0 and irq stays low;
//      writing 0 leaves it set, W1C clears it; VID_FRAME steps by one.
//   4. Frame 1 (ENABLE = 0): black picture while de/hsync/vsync keep the
//      exact CEA-861 720p60 timing.
//   5. Frame 2 (ENABLE = 1, page 0): every pixel equals
//      palette[fb[(x - 64) / 3, y / 3]] inside the 1152-pixel window and is
//      black in the pillarbox. A PAGE = 1 request written at line 360 does not
//      change frame 2; VID_STATUS.PAGE still reads 0; VID_LINE tracks the
//      output line.
//   6. The irq rises at the start of vertical blanking; VID_STATUS shows
//      VSYNC and PAGE = 1; writing 0 keeps irq high, W1C drops it.
//   7. Frame 3 shows page 1 everywhere; its vertical blanking raises the irq
//      again at the same raster position.
//   Throughout, an independent bench model of the 1650 x 750 raster checks
//   de/hsync/vsync on every pixel clock, interval counters check the hsync
//   and vsync periods, widths and de count, and an independent TMDS decoder
//   turns the three data lanes back into RGB and sync controls, checks them
//   against vid_* (3 clocks earlier), checks the clock-lane word, and checks
//   that the running disparity of every data period stays within +/-8.
//   +INJECT_FAILURE flips one palette entry in the pixel expectation (and
//   tb_verdict forces a failure); the run must end in TEST FAIL.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk 100 MHz, pix_clk 74.25 MHz (13.468 ns), unrelated.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_c64_video;

  import rtlnet_tb_pkg::*;
  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Bench constants
  // ---------------------------------------------------------------------------
  localparam real CPU_HALF_NS   = 5.0;              // 100 MHz
  localparam real PIX_HALF_NS   = 6.734;            // 74.25 MHz
  localparam int  TMDS_LAT      = 3;                // vid_* to tmds_* pipeline depth
  localparam int  RD_BOUND      = 8;                // |running disparity| bound (tmds_encoder header)
  localparam int  MAX_PRINT     = 20;               // failure messages printed before counting silently
  localparam int  INJECT_IDX    = 8'h5A;            // palette entry corrupted by +INJECT_FAILURE
  localparam int  FB_BYTE_AW    = FB_WORD_ADDR_W + 2;
  localparam int  FB_PAGE_WORDS = FB_PAGE_BYTES / 4;
  localparam int  FRAME_CLKS    = VID_H_TOTAL * VID_V_TOTAL;
  localparam int  HS_START      = VID_H_ACTIVE + VID_H_FRONT;
  localparam int  HS_END        = HS_START + VID_H_SYNC;
  // vsync leading edge: the hsync leading edge VID_V_FRONT lines after the
  // first hsync that follows the last active line (CEA-861 progressive).
  localparam int  VS_START_POS  = (VID_V_ACTIVE - 1) * VID_H_TOTAL + HS_START + VID_V_FRONT * VID_H_TOTAL;
  localparam int  VS_END_POS    = VS_START_POS + VID_V_SYNC * VID_H_TOTAL;
  localparam int  VBLANK_POS    = VID_V_ACTIVE * VID_H_TOTAL;
  localparam int  POLL_CLKS     = 200;              // cpu clocks between status polls

  localparam logic [9:0] TOK_00 = 10'b1101010100;   // DVI 1.0 control characters, {C1, C0}
  localparam logic [9:0] TOK_01 = 10'b0010101011;
  localparam logic [9:0] TOK_10 = 10'b0101010100;
  localparam logic [9:0] TOK_11 = 10'b1010101011;
  localparam logic [9:0] CLK_WORD = 10'b0000011111;

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic cpu_clk = 1'b0;
  logic pix_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;
  logic pix_resetn;

  always #(CPU_HALF_NS) cpu_clk = ~cpu_clk;
  always #(PIX_HALF_NS) pix_clk = ~pix_clk;

  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));
  rtlnet_reset_sync u_rst_pix (.clk(pix_clk), .arstn(arstn), .resetn(pix_resetn));

  // ---------------------------------------------------------------------------
  // AXI4-Lite master, framebuffer port A driver, DUT
  // ---------------------------------------------------------------------------
  logic [REG_ADDR_W-1:0] awaddr;
  logic [REG_ADDR_W-1:0] araddr;
  logic [31:0]           wdata;
  logic [31:0]           rdata;
  logic [3:0]            wstrb;
  logic [1:0]            bresp;
  logic [1:0]            rresp;
  logic                  awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  rtlnet_tb_axil_master #(.ADDR_W(REG_ADDR_W)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  logic [FB_BYTE_AW-1:0] fb_addr = '0;
  logic                  fb_en   = 1'b0;
  logic [3:0]            fb_we   = '0;
  logic [31:0]           fb_din  = '0;
  logic [31:0]           fb_dout;
  logic                  irq;
  logic [9:0]            tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
  logic                  vid_de, vid_hsync, vid_vsync;
  logic [23:0]           vid_rgb;

  c64_video u_dut (
    .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn), .pix_clk(pix_clk), .pix_resetn(pix_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .fb_bram_addr(fb_addr), .fb_bram_en(fb_en), .fb_bram_we(fb_we), .fb_bram_din(fb_din), .fb_bram_dout(fb_dout),
    .irq(irq),
    .tmds_ch0(tmds_ch0), .tmds_ch1(tmds_ch1), .tmds_ch2(tmds_ch2), .tmds_clk(tmds_clk),
    .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync), .vid_rgb(vid_rgb));

  // ---------------------------------------------------------------------------
  // Bench model
  // ---------------------------------------------------------------------------
  logic [23:0]  pal_model [0:VID_PALETTE_ENTRIES-1];
  byte unsigned fb_model  [0:FB_PAGES*FB_PAGE_BYTES-1];
  bit           inject;

  bit model_en        = 1'b0;    // applied at each frame start (line 0, pixel 0)
  bit model_en_next   = 1'b0;
  bit model_page      = 1'b0;
  bit model_page_next = 1'b0;
  bit irq_en_model    = 1'b0;

  int n_printed = 0;

  // Palette entry i: all 256 entries distinct (blue = i ^ 0x5C) and non-zero.
  function automatic logic [23:0] pal_value(input int i);
    return {8'(i * 37 + 11), 8'(i * 91 + 3), 8'(i ^ 8'h5C)};
  endfunction

  // Native pixel (x, y) of each page; neighbours differ in x and in y.
  function automatic byte unsigned pattern(input int page, input int x, input int y);
    if (page == 0) return byte'((x * 5 + y * 3) & 8'hFF);
    return byte'(((x ^ (y * 7)) + 8'h5A) & 8'hFF);
  endfunction

  function automatic logic [31:0] model_word(input int w);
    return {fb_model[4*w + 3], fb_model[4*w + 2], fb_model[4*w + 1], fb_model[4*w]};
  endfunction

  // A failed check with its message (first MAX_PRINT only; later ones counted).
  function automatic void note_fail(input string msg);
    if (n_printed < MAX_PRINT) begin
      n_printed++;
      tb_check(1'b0, msg);
    end else begin
      tb_checks++;
      tb_fails++;
    end
  endfunction

  function automatic void note_pass();
    tb_checks++;
  endfunction

  // ---------------------------------------------------------------------------
  // Independent TMDS decoder (DVI 1.0 section 3.2, decode flow chart).
  // ---------------------------------------------------------------------------
  function automatic int tmds_ctrl(input logic [9:0] s);
    case (s)
      TOK_00:  return 0;
      TOK_01:  return 1;
      TOK_10:  return 2;
      TOK_11:  return 3;
      default: return -1;
    endcase
  endfunction

  function automatic logic [7:0] tmds_data(input logic [9:0] s);
    logic [7:0] d;
    logic [7:0] q;
    d = s[9] ? ~s[7:0] : s[7:0];
    q[0] = d[0];
    for (int i = 1; i < 8; i++) q[i] = s[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
    return q;
  endfunction

  function automatic int ones10(input logic [9:0] s);
    int n;
    n = 0;
    for (int i = 0; i < 10; i++) n += s[i];
    return n;
  endfunction

  // ---------------------------------------------------------------------------
  // Pixel-clock monitor: raster model, interval counters, TMDS decode.
  // ---------------------------------------------------------------------------
  bit          locked      = 1'b0;
  bit          seen_vs_end = 1'b0;
  int          tb_h        = 0;
  int          tb_v        = 0;
  int          tb_frame    = 0;      // 1 = first locked frame
  int          frames_done = 0;      // completely checked frames
  int          px_checked  = 0;
  int          rgb_nonblack = 0;
  bit          prev_de     = 1'b0;
  bit          prev_hs     = 1'b0;
  bit          prev_vs     = 1'b0;
  longint      pclk_n      = 0;
  longint      hs_rise     = -1;
  longint      vs_rise     = -1;
  int          de_cnt      = 0;
  int          nsamp       = 0;
  bit          h_de  [0:TMDS_LAT];
  bit          h_hs  [0:TMDS_LAT];
  bit          h_vs  [0:TMDS_LAT];
  logic [23:0] h_rgb [0:TMDS_LAT];
  int          rd    [0:2];
  int          rd_max      = 0;
  int          tmds_data_n = 0;

  // Compare the three TMDS lanes with the vid_* sample TMDS_LAT clocks back.
  function automatic void check_tmds();
    logic [9:0] sym [0:2];
    int         c;
    sym[0] = tmds_ch0;
    sym[1] = tmds_ch1;
    sym[2] = tmds_ch2;
    if (tmds_clk !== CLK_WORD) note_fail($sformatf("clock lane word %b", tmds_clk));
    else                       note_pass();
    for (int l = 0; l < 3; l++) begin
      c = tmds_ctrl(sym[l]);
      if (h_de[TMDS_LAT]) begin
        if (c >= 0) begin
          note_fail($sformatf("lane %0d: control character %b during de", l, sym[l]));
        end else if (tmds_data(sym[l]) !== h_rgb[TMDS_LAT][8*l +: 8]) begin
          note_fail($sformatf("lane %0d: TMDS decodes to %02x, vid_rgb lane was %02x", l, tmds_data(sym[l]),
                              h_rgb[TMDS_LAT][8*l +: 8]));
        end else begin
          note_pass();
        end
        rd[l] += 2 * ones10(sym[l]) - 10;
        if (rd[l] > rd_max)  rd_max = rd[l];
        if (-rd[l] > rd_max) rd_max = -rd[l];
        if (rd[l] > RD_BOUND || rd[l] < -RD_BOUND) note_fail($sformatf("lane %0d: running disparity %0d", l, rd[l]));
        if (l == 0) tmds_data_n++;
      end else begin
        rd[l] = 0;
        if (c != ((l == 0) ? int'({h_vs[TMDS_LAT], h_hs[TMDS_LAT]}) : 0)) begin
          note_fail($sformatf("lane %0d: blanking character %b, expected C1C0=%0d", l, sym[l],
                              (l == 0) ? int'({h_vs[TMDS_LAT], h_hs[TMDS_LAT]}) : 0));
        end else begin
          note_pass();
        end
      end
    end
  endfunction

  // Raster model expectation for the current (tb_h, tb_v) and comparison.
  function automatic void check_pixel();
    int          pos;
    bit          e_de;
    bit          e_hs;
    bit          e_vs;
    logic [23:0] e_rgb;
    int          fx;
    int          fy;
    int          idx;
    pos   = tb_v * VID_H_TOTAL + tb_h;
    e_de  = (tb_h < VID_H_ACTIVE) && (tb_v < VID_V_ACTIVE);
    e_hs  = (tb_h >= HS_START) && (tb_h < HS_END);
    e_vs  = (pos >= VS_START_POS) && (pos < VS_END_POS);
    e_rgb = 24'h0;
    idx   = -1;
    if (e_de && model_en && (tb_h >= VID_X_OFFSET) && (tb_h < VID_X_OFFSET + FB_WIDTH * FB_SCALE)) begin
      fx    = (tb_h - VID_X_OFFSET) / FB_SCALE;
      fy    = tb_v / FB_SCALE;
      idx   = fb_model[model_page * FB_PAGE_BYTES + fy * FB_WIDTH + fx];
      e_rgb = pal_model[idx];
      if (inject && idx == INJECT_IDX) e_rgb = e_rgb ^ 24'h000001;
    end
    if (vid_de !== e_de || vid_hsync !== e_hs || vid_vsync !== e_vs) begin
      note_fail($sformatf("frame %0d (h %0d, v %0d): de/hs/vs = %b%b%b, expected %b%b%b", tb_frame, tb_h, tb_v,
                          vid_de, vid_hsync, vid_vsync, e_de, e_hs, e_vs));
    end else if (vid_rgb !== e_rgb) begin
      note_fail($sformatf("frame %0d (h %0d, v %0d): rgb %06x, expected %06x (page %0d, index %0d)", tb_frame,
                          tb_h, tb_v, vid_rgb, e_rgb, model_page, idx));
    end else begin
      note_pass();
    end
    px_checked++;
    if (vid_rgb != 24'h0) rgb_nonblack++;
  endfunction

  always @(posedge pix_clk) begin : monitor
    if (!pix_resetn) begin
      nsamp = 0;
      for (int l = 0; l < 3; l++) rd[l] = 0;
    end else begin
      nsamp++;
      pclk_n++;
      for (int i = TMDS_LAT; i > 0; i--) begin
        h_de[i]  = h_de[i-1];
        h_hs[i]  = h_hs[i-1];
        h_vs[i]  = h_vs[i-1];
        h_rgb[i] = h_rgb[i-1];
      end
      h_de[0]  = vid_de;
      h_hs[0]  = vid_hsync;
      h_vs[0]  = vid_vsync;
      h_rgb[0] = vid_rgb;
      if (nsamp > TMDS_LAT + 1) check_tmds();

      // Lock the raster model on the first de rising edge after a vsync pulse.
      if (!locked) begin
        if (prev_vs && !vid_vsync) seen_vs_end = 1'b1;
        if (seen_vs_end && vid_de && !prev_de) begin
          locked     = 1'b1;
          tb_h       = 0;
          tb_v       = 0;
          tb_frame   = 1;
          model_en   = model_en_next;
          model_page = model_page_next;
        end
      end else begin
        tb_h++;
        if (tb_h == VID_H_TOTAL) begin
          tb_h = 0;
          tb_v++;
          if (tb_v == VID_V_TOTAL) begin
            tb_v = 0;
            tb_frame++;
            frames_done++;
            model_en   = model_en_next;
            model_page = model_page_next;
          end
        end
      end

      if (locked) begin
        check_pixel();
        // Interval counters, independent of the raster model.
        if (vid_de) de_cnt++;
        if (vid_hsync && !prev_hs) begin
          if (hs_rise >= 0) begin
            if (pclk_n - hs_rise != VID_H_TOTAL) note_fail($sformatf("hsync period %0d", pclk_n - hs_rise));
            else                                 note_pass();
          end
          hs_rise = pclk_n;
        end
        if (!vid_hsync && prev_hs && hs_rise >= 0) begin
          if (pclk_n - hs_rise != VID_H_SYNC) note_fail($sformatf("hsync width %0d", pclk_n - hs_rise));
          else                                note_pass();
        end
        if (vid_vsync && !prev_vs) begin
          if (vs_rise >= 0) begin
            if (pclk_n - vs_rise != FRAME_CLKS) note_fail($sformatf("vsync period %0d", pclk_n - vs_rise));
            else                                note_pass();
            if (de_cnt != VID_H_ACTIVE * VID_V_ACTIVE) note_fail($sformatf("de count per frame %0d", de_cnt));
            else                                       note_pass();
          end
          vs_rise = pclk_n;
          de_cnt  = 0;
        end
        if (!vid_vsync && prev_vs && vs_rise >= 0) begin
          if (pclk_n - vs_rise != VID_V_SYNC * VID_H_TOTAL) note_fail($sformatf("vsync width %0d", pclk_n - vs_rise));
          else                                              note_pass();
        end
      end
      prev_de = vid_de;
      prev_hs = vid_hsync;
      prev_vs = vid_vsync;
    end
  end

  // ---------------------------------------------------------------------------
  // CPU-clock monitor: irq only with IRQ_EN set; position of each irq rise.
  // ---------------------------------------------------------------------------
  bit irq_d      = 1'b0;
  int irq_rises  = 0;
  int irq_pos    = 0;                // raster position of the latest rise
  int irq_frame  = 0;                // model frame of the latest rise

  always @(posedge cpu_clk) begin
    if (cpu_resetn) begin
      if (irq && !irq_en_model) note_fail("irq high with VID_CTRL.IRQ_EN = 0");
      if (irq && !irq_d) begin
        irq_rises++;
        irq_pos   = tb_v * VID_H_TOTAL + tb_h;
        irq_frame = tb_frame;
      end
      irq_d = irq;
    end
  end

  // ---------------------------------------------------------------------------
  // Register helpers
  // ---------------------------------------------------------------------------
  task automatic rd_check(input logic [REG_ADDR_W-1:0] a, input logic [31:0] exp, input string what);
    logic [31:0] r;
    u_mst.rd(a, r);
    tb_check(r === exp, $sformatf("%s: read 0x%08x, expected 0x%08x", what, r, exp));
  endtask

  task automatic wait_vsync_pending();
    logic [31:0] r;
    r = '0;
    while (!r[VID_STATUS_VSYNC_BIT]) begin
      repeat (POLL_CLKS) @(posedge cpu_clk);
      u_mst.rd(VID_STATUS_OFS, r);
    end
  endtask

  // One framebuffer port A write per clock.
  task automatic fb_write(input int word, input logic [31:0] data, input logic [3:0] we);
    @(posedge cpu_clk);
    fb_en   <= 1'b1;
    fb_we   <= we;
    fb_addr <= FB_BYTE_AW'(word * 4);
    fb_din  <= data;
  endtask

  task automatic fb_idle();
    @(posedge cpu_clk);
    fb_en <= 1'b0;
    fb_we <= '0;
  endtask

  // ---------------------------------------------------------------------------
  // Main sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] r;
    logic [31:0] w;
    logic [31:0] frame0;
    int          words [$];
    int          a;

    inject = $test$plusargs("INJECT_FAILURE");
    for (int i = 0; i < VID_PALETTE_ENTRIES; i++) pal_model[i] = pal_value(i);
    for (int p = 0; p < FB_PAGES; p++)
      for (int y = 0; y < FB_HEIGHT; y++)
        for (int x = 0; x < FB_WIDTH; x++) fb_model[p * FB_PAGE_BYTES + y * FB_WIDTH + x] = pattern(p, x, y);

    #100 arstn = 1'b1;
    wait (cpu_resetn && pix_resetn);
    repeat (10) @(posedge cpu_clk);

    // Case 1: reset values.
    rd_check(VID_CTRL_OFS,   32'h0, "VID_CTRL after reset");
    rd_check(VID_STATUS_OFS, 32'h0, "VID_STATUS after reset");
    rd_check(VID_FRAME_OFS,  32'h0, "VID_FRAME after reset");
    u_mst.rd(VID_LINE_OFS, r);
    tb_check(r < VID_V_TOTAL, $sformatf("VID_LINE %0d out of range", r));

    // Case 2a: palette, upper byte garbage.
    for (int i = 0; i < VID_PALETTE_ENTRIES; i++) begin
      u_mst.wr(VID_PALETTE_OFS + 16'(4 * i), {8'hA5, pal_model[i]});
    end
    rd_check(VID_PALETTE_OFS + 16'h10, 32'h0, "palette reads 0 (write-only)");

    // Case 2b: page 0 full words; page 1 garbage, then lanes 0/2, then 1/3.
    for (int k = 0; k < FB_PAGE_WORDS; k++) fb_write(k, model_word(k), 4'hF);
    for (int k = FB_PAGE_WORDS; k < 2 * FB_PAGE_WORDS; k++) fb_write(k, 32'hDEAD_BEEF ^ k, 4'hF);
    for (int k = FB_PAGE_WORDS; k < 2 * FB_PAGE_WORDS; k++) fb_write(k, model_word(k) ^ 32'hFF00_FF00, 4'b0101);
    for (int k = FB_PAGE_WORDS; k < 2 * FB_PAGE_WORDS; k++) fb_write(k, model_word(k) ^ 32'h00FF_00FF, 4'b1010);
    // Unbacked words above FB_WORDS: dropped.
    fb_write(FB_WORDS, 32'h1234_5678, 4'hF);
    fb_write((1 << FB_WORD_ADDR_W) - 1, 32'h9ABC_DEF0, 4'hF);
    fb_idle();

    // Case 2c: pipelined port A reads, data due one clock after the address.
    words = {0, 1, FB_PAGE_WORDS - 1, FB_PAGE_WORDS, FB_PAGE_WORDS + 1, FB_WORDS - 1};
    for (int k = 0; k < 40; k++) words.push_back((k * 1153 + 17) % FB_WORDS);
    for (int k = 0; k < words.size() + 2; k++) begin
      @(posedge cpu_clk);
      if (k >= 2) begin
        tb_check(fb_dout === model_word(words[k-2]),
                 $sformatf("port A word %0d: 0x%08x, expected 0x%08x", words[k-2], fb_dout, model_word(words[k-2])));
      end
      if (k < words.size()) begin
        fb_en   <= 1'b1;
        fb_we   <= '0;
        fb_addr <= FB_BYTE_AW'(words[k] * 4);
      end else begin
        fb_en <= 1'b0;
      end
    end

    // Case 3: end of frame 0, IRQ disabled.
    wait_vsync_pending();
    tb_check(irq === 1'b0, "irq high with IRQ_EN = 0");
    u_mst.rd(VID_FRAME_OFS, frame0);
    tb_check(frame0 == 32'd1, $sformatf("VID_FRAME after first vblank = %0d", frame0));
    u_mst.wr(VID_STATUS_OFS, 32'h0);
    rd_check(VID_STATUS_OFS, 32'h1 << VID_STATUS_VSYNC_BIT, "VSYNC kept after writing 0");
    u_mst.wr(VID_STATUS_OFS, 32'h1 << VID_STATUS_VSYNC_BIT);
    rd_check(VID_STATUS_OFS, 32'h0, "VSYNC cleared by W1C");

    // Case 4 runs in frame 1 (enable 0, model black). End of frame 1:
    wait_vsync_pending();
    tb_check(locked && tb_frame == 1 && tb_v >= VID_V_ACTIVE,
             $sformatf("end of frame 1 expected in vertical blanking (locked %0d, frame %0d, v %0d)",
                       locked, tb_frame, tb_v));
    u_mst.wr(VID_STATUS_OFS, 32'h1 << VID_STATUS_VSYNC_BIT);
    w = (32'h1 << VID_CTRL_ENABLE_BIT) | (32'h1 << VID_CTRL_IRQ_EN_BIT);
    model_en_next = 1'b1;
    irq_en_model  = 1'b1;
    u_mst.wr(VID_CTRL_OFS, w);
    tb_check(tb_frame == 1 && tb_v >= VID_V_ACTIVE, $sformatf("enable written outside vblank (v %0d)", tb_v));
    rd_check(VID_CTRL_OFS, w, "VID_CTRL read-back");
    rd_check(VID_FRAME_OFS, frame0 + 1, "VID_FRAME after second vblank");

    // Case 5: frame 2 shows page 0; request page 1 at line 360.
    wait (tb_frame == 2 && tb_v == VID_V_ACTIVE / 2);
    w = w | (32'h1 << VID_CTRL_PAGE_BIT);
    model_page_next = 1'b1;
    u_mst.wr(VID_CTRL_OFS, w);
    rd_check(VID_STATUS_OFS, 32'h0, "STATUS mid-frame: page 0 shown, no vsync");
    u_mst.rd(VID_LINE_OFS, r);
    tb_check((int'(r) - tb_v <= 1) && (tb_v - int'(r) <= 1), $sformatf("VID_LINE %0d, raster at line %0d", r, tb_v));
    rd_check(VID_CTRL_OFS, w, "VID_CTRL read-back with PAGE");

    // Case 6: irq at the start of vertical blanking of frame 2.
    wait (irq_rises == 1);
    tb_check(irq_frame == 2 && irq_pos >= VBLANK_POS - 16 && irq_pos <= VBLANK_POS + 64,
             $sformatf("irq rose at raster position %0d (frame %0d), expected near %0d", irq_pos, irq_frame,
                       VBLANK_POS));
    rd_check(VID_STATUS_OFS, (32'h1 << VID_STATUS_VSYNC_BIT) | (32'h1 << VID_STATUS_PAGE_BIT), "STATUS after flip");
    u_mst.wr(VID_STATUS_OFS, 32'h0);
    repeat (4) @(posedge cpu_clk);
    tb_check(irq === 1'b1, "irq dropped after writing 0 to STATUS");
    u_mst.wr(VID_STATUS_OFS, 32'h1 << VID_STATUS_VSYNC_BIT);
    repeat (4) @(posedge cpu_clk);
    tb_check(irq === 1'b0, "irq still high after W1C");
    rd_check(VID_STATUS_OFS, 32'h1 << VID_STATUS_PAGE_BIT, "STATUS after W1C");
    rd_check(VID_FRAME_OFS, frame0 + 2, "VID_FRAME after third vblank");

    // Case 7: frame 3 (page 1) checked to its end; its vertical blanking
    // raises the irq once more.
    wait (frames_done == 3);
    tb_check(irq_rises == 2 && irq_frame == 3 && irq_pos >= VBLANK_POS - 16 && irq_pos <= VBLANK_POS + 64,
             $sformatf("%0d irq rises, last at raster position %0d of frame %0d; expected 2, the last near %0d of 3",
                       irq_rises, irq_pos, irq_frame, VBLANK_POS));
    tb_check(px_checked >= 3 * FRAME_CLKS, $sformatf("only %0d pixel clocks checked", px_checked));
    tb_check(rgb_nonblack > 2 * FB_WIDTH * FB_SCALE * VID_V_ACTIVE / 2,
             $sformatf("only %0d non-black pixels seen", rgb_nonblack));
    tb_check(tmds_data_n >= 3 * VID_H_ACTIVE * VID_V_ACTIVE, $sformatf("only %0d TMDS data characters", tmds_data_n));
    $display("tb_c64_video: %0d pixel clocks checked, %0d TMDS data characters, max |disparity| %0d",
             px_checked, tmds_data_n, rd_max);
    tb_verdict("tb_c64_video");
  end

  initial begin
    #150ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_c64_video");
  end

endmodule
