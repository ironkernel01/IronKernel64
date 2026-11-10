// -----------------------------------------------------------------------------
// File: tb_c64_oled.sv
// Purpose: self-checking bench for c64_oled. An SPI decoder (the SSD1306 side)
//   samples oled_sdin on the rising edges of oled_sclk and groups the bits into
//   bytes tagged with oled_dc; a bench AXI4-Lite master plays core 0.
// Delays are shortened through the DUT parameters (VDD 5 us, reset pulse 4 us,
// VBAT 50 us, ...); FRAME_HZ = 500 gives a 2 ms frame period, longer than the
// 0.83 ms a frame takes, so the idle gap between frames is visible.
// Cases:
//   1. Reset state: VDD and VBAT switches off (pins high), RES# low, SPI low.
//      ID, VERSION, CTRL, STATUS, CONTRAST and SCROLL read their reset values;
//      an undefined offset reads 0.
//   2. Framebuffer: 512 words written with full strobes and read back; a
//      byte-strobe write merges per byte lane; a partial-strobe register write
//      (CONTRAST) is ignored.
//   3. Power-up (POWER 0 -> 1): VDD falls, then (>= VDD_WAIT) the RES# pulse
//      (>= 3 us), no SPI byte before the pulse ends, then the 24 init command
//      bytes, only then VBAT falls, (>= VBAT_WAIT later) the all-zero frame
//      (6 command + 512 data bytes), then 0xAF; STATUS.STATE POWERING_UP then
//      RUNNING. SCLK only toggles while VDD is on; D/C is stable around each
//      SCLK rising edge (>= 100 ns before the first edge of a byte, held >=
//      100 ns after the last).
//   4. Frames with nonzero SCROLL0..3 (5, 130, 509 wrapping, 300): header
//      0x21 0x00 0x7F 0x22 0x00 0x03 and 512 data bytes equal to the bench's
//      own model of the framebuffer.
//   5. Mid-frame: SCROLL0..3, CONTRAST and INVERT are written after 100 data
//      bytes of a frame; that frame still uses the old scroll values, the next
//      frame starts with 0x81 0x40, 0xA7 and uses the new scroll values.
//   6. A CONTRAST write of the unchanged value sends no command; a framebuffer
//      write between frames shows in the next frame; the frame period is
//      1 / FRAME_HZ; STATUS.FRAME counts frames.
//   7. Power-down (POWER 1 -> 0): 0xAE, then VBAT off, (>= VBAT_OFF_WAIT later)
//      VDD off, RES# low, STATE POWERING_DOWN then OFF, no further SPI bytes.
//   8. Second power-up: init bytes carry the current contrast (0x40) and
//      inverse (0xA7); blank frame and 0xAF follow.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_c64_oled;

  import ik64_tb_pkg::*;
  import c64_pkg::*;

  localparam int AW = OLED_ADDR_W;

  // Shortened DUT delays (us) and frame rate.
  localparam int VDD_WAIT_US      = 5;
  localparam int RES_LOW_US       = 4;
  localparam int RES_HIGH_US      = 3;
  localparam int VBAT_WAIT_US     = 50;
  localparam int VBAT_OFF_WAIT_US = 40;
  localparam int OFF_SETTLE_US    = 10;
  localparam int FRAME_HZ         = 500;

  localparam int  NBYTE_TMO   = 500_000;   // clocks to wait for one SPI byte (> one frame period)
  localparam real T_FRAME_NS  = 1.0e9 / FRAME_HZ;
  localparam logic [11:0] UNDEF_OFS = 12'h040;

  logic cpu_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;

  always #5.0 cpu_clk = ~cpu_clk;           // 100 MHz

  ik64_reset_sync u_rst (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));

  logic oled_dc, oled_res, oled_sclk, oled_sdin, oled_vbat, oled_vdd;

  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  ik64_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  c64_oled #(
    .FRAME_HZ         (FRAME_HZ),
    .VDD_WAIT_US      (VDD_WAIT_US),
    .RES_LOW_US       (RES_LOW_US),
    .RES_HIGH_US      (RES_HIGH_US),
    .VBAT_WAIT_US     (VBAT_WAIT_US),
    .VBAT_OFF_WAIT_US (VBAT_OFF_WAIT_US),
    .OFF_SETTLE_US    (OFF_SETTLE_US)
  ) u_dut (
    .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .oled_dc(oled_dc), .oled_res(oled_res), .oled_sclk(oled_sclk), .oled_sdin(oled_sdin),
    .oled_vbat(oled_vbat), .oled_vdd(oled_vdd));

  // ---------------------------------------------------------------------------
  // SPI decoder: bytes {dc, data} and their completion times.
  // ---------------------------------------------------------------------------
  logic [8:0] byte_q [$];
  real        time_q [$];
  int         bytes_total = 0;
  logic [7:0] dec_sh;
  int         dec_nbits   = 0;
  logic       dec_dc;
  real        t_dc_chg    = -1.0e9;
  real        t_sdin_chg  = -1.0e9;
  real        t_last_rise = -1.0e9;
  int         spi_errors  = 0;
  string      spi_err_msg = "";

  task automatic spi_error(input string m);
    spi_errors++;
    if (spi_err_msg == "") spi_err_msg = m;
  endtask

  always @(posedge oled_sclk) begin
    if (oled_vdd !== 1'b0) spi_error("SCLK rising edge while VDD is off");
    if (dec_nbits == 0) begin
      dec_dc = oled_dc;
      if ($realtime - t_dc_chg < 100.0) spi_error("D/C changed less than 100 ns before the first SCLK edge");
    end else if (oled_dc !== dec_dc) begin
      spi_error("D/C changed inside a byte");
    end
    if ($realtime - t_sdin_chg < 50.0) spi_error("SDIN changed less than 50 ns before an SCLK edge");
    dec_sh    = {dec_sh[6:0], oled_sdin};
    dec_nbits = dec_nbits + 1;
    t_last_rise = $realtime;
    if (dec_nbits == 8) begin
      byte_q.push_back({dec_dc, dec_sh});
      time_q.push_back($realtime);
      bytes_total = bytes_total + 1;
      dec_nbits = 0;
    end
  end

  always @(oled_dc) begin
    t_dc_chg = $realtime;
    if (dec_nbits != 0) spi_error("D/C changed inside a byte");
    if ($realtime - t_last_rise < 100.0) spi_error("D/C changed less than 100 ns after an SCLK edge");
  end

  always @(oled_sdin) t_sdin_chg = $realtime;

  // ---------------------------------------------------------------------------
  // Power pin event log.
  // ---------------------------------------------------------------------------
  real t_vdd_on, t_vdd_off, t_res_fall, t_res_rise, t_vbat_on, t_vbat_off;
  int  n_vdd_on, n_res_fall, n_res_rise, n_vbat_on;       // bytes decoded at the event
  int  n_vdd_off, n_vbat_off;
  always @(negedge oled_vdd)  begin t_vdd_on   = $realtime; n_vdd_on   = bytes_total; end
  always @(posedge oled_vdd)  begin t_vdd_off  = $realtime; n_vdd_off  = bytes_total; end
  always @(negedge oled_res)  begin t_res_fall = $realtime; n_res_fall = bytes_total; end
  always @(posedge oled_res)  begin t_res_rise = $realtime; n_res_rise = bytes_total; end
  always @(negedge oled_vbat) begin t_vbat_on  = $realtime; n_vbat_on  = bytes_total; end
  always @(posedge oled_vbat) begin t_vbat_off = $realtime; n_vbat_off = bytes_total; end

  // ---------------------------------------------------------------------------
  // Framebuffer model and expected data.
  // ---------------------------------------------------------------------------
  logic [31:0] model [OLED_FB_WORDS];
  int unsigned rng;

  function automatic logic [7:0] model_byte(input int page, input int x, input int sc[4]);
    int vcol;
    logic [31:0] w;
    vcol = (x + sc[page]) % OLED_VCOLS;
    w    = model[page * OLED_COLS + (vcol >> 2)];
    return w[8 * (vcol & 3) +: 8];
  endfunction

  function automatic logic [31:0] next_rand();
    rng = rng * 1664525 + 1013904223;
    return {rng[15:0], rng[31:16]} ^ rng;
  endfunction

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------
  real t_got;

  task automatic get_byte(output logic dc, output logic [7:0] b);
    int t;
    logic [8:0] v;
    t = 0;
    while (byte_q.size() == 0 && t < NBYTE_TMO) begin
      @(posedge cpu_clk);
      t++;
    end
    if (byte_q.size() == 0) begin
      tb_error("timeout waiting for an SPI byte");
      dc = 1'b0; b = 8'h00; t_got = 0.0;
    end else begin
      v = byte_q.pop_front();
      t_got = time_q.pop_front();
      dc = v[8]; b = v[7:0];
    end
  endtask

  task automatic expect_cmd(input logic [7:0] e, input string what);
    logic dc; logic [7:0] b;
    get_byte(dc, b);
    tb_check(dc === 1'b0 && b === e, $sformatf("%s: got dc=%0d byte 0x%02x, expected command 0x%02x", what, dc, b, e));
  endtask

  task automatic expect_hdr(input string what);
    logic [7:0] h [6];
    h = '{8'h21, 8'h00, 8'h7F, 8'h22, 8'h00, 8'h03};
    for (int i = 0; i < 6; i++) expect_cmd(h[i], $sformatf("%s header[%0d]", what, i));
  endtask

  // Header plus 512 data bytes against the model; optional mid-frame action.
  task automatic check_frame(input int sc[4], input bit blank, input bit mid, input string what);
    logic dc; logic [7:0] b; logic [7:0] e;
    int bad;
    string first;
    expect_hdr(what);
    bad = 0; first = "";
    for (int p = 0; p < OLED_PAGES; p++) begin
      for (int x = 0; x < OLED_COLS; x++) begin
        if (mid && p == 0 && x == 100) mid_writes();
        get_byte(dc, b);
        e = blank ? 8'h00 : model_byte(p, x, sc);
        if (dc !== 1'b1 || b !== e) begin
          if (bad == 0) first = $sformatf("page %0d x %0d got dc=%0d 0x%02x expected 0x%02x", p, x, dc, b, e);
          bad++;
        end
      end
    end
    tb_check(bad == 0, $sformatf("%s: %0d bad data bytes, first: %s", what, bad, first));
  endtask

  // Writes issued in the middle of a frame.
  task automatic mid_writes();
    u_mst.wr(AW'(OLED_SCROLL0_OFS), 32'd77);
    u_mst.wr(AW'(OLED_SCROLL1_OFS), 32'd3);
    u_mst.wr(AW'(OLED_SCROLL2_OFS), 32'd128);
    u_mst.wr(AW'(OLED_SCROLL3_OFS), 32'd511);
    u_mst.wr(AW'(OLED_CONTRAST_OFS), 32'h40);
    u_mst.wr(AW'(OLED_CTRL_OFS), (32'h1 << OLED_CTRL_POWER_BIT) | (32'h1 << OLED_CTRL_INVERT_BIT));
  endtask

  // Init sequence, VBAT, blank frame, display on; with the pin-order checks.
  task automatic check_powerup(input logic [7:0] contrast, input logic invert, input int base, input string what);
    logic [7:0] ini [24];
    int sc0 [4];
    real t_af;
    logic dc; logic [7:0] b;
    ini = '{8'hAE, 8'hD5, 8'h80, 8'hA8, 8'h1F, 8'hD3, 8'h00, 8'h40, 8'h8D, 8'h14, 8'h20, 8'h00,
            8'hA1, 8'hC8, 8'hDA, 8'h02, 8'h81, contrast, 8'hD9, 8'hF1, 8'hDB, 8'h40, 8'hA4,
            invert ? 8'hA7 : 8'hA6};
    sc0 = '{0, 0, 0, 0};
    for (int i = 0; i < 24; i++) expect_cmd(ini[i], $sformatf("%s init[%0d]", what, i));
    check_frame(sc0, 1'b1, 1'b0, {what, " blank frame"});
    get_byte(dc, b);
    t_af = t_got;
    tb_check(dc === 1'b0 && b === 8'hAF, $sformatf("%s: display on: got dc=%0d 0x%02x", what, dc, b));
    tb_check(oled_vdd === 1'b0 && oled_vbat === 1'b0, {what, ": VDD and VBAT on"});
    tb_check(t_res_fall - t_vdd_on >= VDD_WAIT_US * 1000.0 - 20.0,
             $sformatf("%s: VDD on to RES# low %0.0f ns", what, t_res_fall - t_vdd_on));
    tb_check(t_res_rise - t_res_fall >= 3000.0,
             $sformatf("%s: RES# low for %0.0f ns, need >= 3 us", what, t_res_rise - t_res_fall));
    tb_check(n_vdd_on == base && n_res_fall == base && n_res_rise == base,
             {what, ": SPI bytes before the reset pulse ended"});
    tb_check(n_vbat_on - base == 24, $sformatf("%s: VBAT on after %0d bytes, expected 24 init bytes", what, n_vbat_on - base));
    tb_check(t_vbat_on > t_res_rise && t_vdd_on < t_res_fall, {what, ": pin order VDD, RES#, VBAT"});
    tb_check(t_af - t_vbat_on >= VBAT_WAIT_US * 1000.0,
             $sformatf("%s: VBAT on to display on %0.0f ns, need >= %0d ns", what, t_af - t_vbat_on, VBAT_WAIT_US * 1000));
    tb_check(spi_errors == 0, $sformatf("%s: SPI protocol error: %s", what, spi_err_msg));
  endtask

  task automatic read_status(output logic [31:0] s);
    u_mst.rd(AW'(OLED_STATUS_OFS), s);
  endtask

  task automatic expect_reg(input logic [AW-1:0] a, input logic [31:0] e, input string what);
    logic [31:0] r;
    u_mst.rd(a, r);
    tb_check(r === e, $sformatf("%s: read 0x%08x, expected 0x%08x", what, r, e));
  endtask

  // ---------------------------------------------------------------------------
  // Main sequence.
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] r;
    logic [1:0]  resp;
    logic        dc;
    logic [7:0]  b;
    int          sc [4];
    int          bad;
    int          cnt_base;

    rng = 32'h1357_9BDF;
    for (int i = 0; i < OLED_FB_WORDS; i++) model[i] = '0;

    #100 arstn = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // Case 1: reset state and registers.
    tb_check(oled_vdd === 1'b1 && oled_vbat === 1'b1, "VDD and VBAT switches off after reset");
    tb_check(oled_res === 1'b0 && oled_sclk === 1'b0 && oled_dc === 1'b0 && oled_sdin === 1'b0,
             "RES# asserted, SPI low after reset");
    expect_reg(AW'(OLED_ID_OFS),       OLED_ID_VALUE,      "ID");
    expect_reg(AW'(OLED_VERSION_OFS),  OLED_VERSION_VALUE, "VERSION");
    expect_reg(AW'(OLED_CTRL_OFS),     32'h0,              "CTRL");
    expect_reg(AW'(OLED_STATUS_OFS),   32'h0,              "STATUS");
    expect_reg(AW'(OLED_CONTRAST_OFS), 32'h7F,             "CONTRAST");
    expect_reg(AW'(OLED_SCROLL0_OFS),  32'h0,              "SCROLL0");
    expect_reg(AW'(OLED_SCROLL3_OFS),  32'h0,              "SCROLL3");
    expect_reg(UNDEF_OFS,              32'h0,              "undefined offset");

    // Case 2: framebuffer write, read-back, byte strobes, register partial write.
    for (int i = 0; i < OLED_FB_WORDS; i++) begin
      model[i] = next_rand();
      u_mst.wr(AW'(OLED_FB_OFS) + AW'(4 * i), model[i]);
    end
    bad = 0;
    for (int i = 0; i < OLED_FB_WORDS; i++) begin
      u_mst.rd(AW'(OLED_FB_OFS) + AW'(4 * i), r);
      if (r !== model[i]) bad++;
    end
    tb_check(bad == 0, $sformatf("framebuffer read-back: %0d words differ", bad));
    u_mst.write32(AW'(OLED_FB_OFS) + AW'(12), 32'hAABB_CCDD, 4'b0101, resp);
    tb_check(resp == 2'b00, "partial FB write answered OKAY");
    model[3] = {model[3][31:24], 8'hBB, model[3][15:8], 8'hDD};
    expect_reg(AW'(OLED_FB_OFS) + AW'(12), model[3], "byte-strobe FB write");
    u_mst.write32(AW'(OLED_CONTRAST_OFS), 32'h55, 4'h3, resp);
    expect_reg(AW'(OLED_CONTRAST_OFS), 32'h7F, "partial-strobe CONTRAST write ignored");

    // Scroll registers.
    sc = '{5, 130, 509, 300};
    u_mst.wr(AW'(OLED_SCROLL0_OFS), 32'(sc[0]));
    u_mst.wr(AW'(OLED_SCROLL1_OFS), 32'(sc[1]));
    u_mst.wr(AW'(OLED_SCROLL2_OFS), 32'(sc[2]));
    u_mst.wr(AW'(OLED_SCROLL3_OFS), 32'(sc[3]));
    expect_reg(AW'(OLED_SCROLL2_OFS), 32'd509, "SCROLL2 read-back");
    tb_check(bytes_total == 0, "no SPI byte before POWER");

    // Case 3: power-up.
    u_mst.wr(AW'(OLED_CTRL_OFS), 32'h1 << OLED_CTRL_POWER_BIT);
    repeat (10) @(posedge cpu_clk);
    read_status(r);
    tb_check(r[1:0] === 2'(OLED_STATE_POWERING_UP) && r[31:16] === 16'h0, $sformatf("STATUS during power-up 0x%08x", r));
    check_powerup(8'h7F, 1'b0, 0, "power-up 1");
    repeat (400) @(posedge cpu_clk);
    read_status(r);
    tb_check(r[1:0] === 2'(OLED_STATE_RUNNING), $sformatf("STATUS after display on 0x%08x", r));
    tb_check(r[31:16] <= 16'h1, $sformatf("FRAME count right after display on 0x%08x", r));

    // Case 4: frame with scroll values.
    check_frame(sc, 1'b0, 1'b0, "frame 1");

    // Case 5: mid-frame writes.
    check_frame(sc, 1'b0, 1'b1, "frame 2 (old scroll)");
    sc = '{77, 3, 128, 511};
    expect_cmd(8'h81, "frame 3 contrast command");
    expect_cmd(8'h40, "frame 3 contrast value");
    expect_cmd(8'hA7, "frame 3 invert command");
    check_frame(sc, 1'b0, 1'b0, "frame 3 (new scroll)");

    // Case 6: unchanged CONTRAST, FB write between frames, period, frame count.
    u_mst.wr(AW'(OLED_CONTRAST_OFS), 32'h40);
    model[10] = 32'hDEAD_BEEF;
    u_mst.wr(AW'(OLED_FB_OFS) + AW'(40), model[10]);
    check_frame(sc, 1'b0, 1'b0, "frame 4");
    read_status(r);
    tb_check(r[31:16] === 16'd4, $sformatf("FRAME count 0x%08x, expected 4", r));
    check_frame(sc, 1'b0, 1'b0, "frame 5");
    // Frame period: completion times of the first header byte of frames 6 and 7.
    begin
      real ta, tb2;
      logic dcx; logic [7:0] bx;
      get_byte(dcx, bx); ta = t_got;           // frame 6 header byte 0 (0x21)
      tb_check(dcx === 1'b0 && bx === 8'h21, "frame 6 starts with the header");
      for (int i = 0; i < 5; i++) expect_cmd((i == 0) ? 8'h00 : (i == 1) ? 8'h7F : (i == 2) ? 8'h22 : (i == 3) ? 8'h00 : 8'h03,
                                             "frame 6 header");
      for (int i = 0; i < 512; i++) get_byte(dcx, bx);
      get_byte(dcx, bx); tb2 = t_got;          // frame 7 header byte 0
      tb_check(dcx === 1'b0 && bx === 8'h21, "frame 7 starts with the header");
      tb_check((tb2 - ta) > T_FRAME_NS - 50.0 && (tb2 - ta) < T_FRAME_NS + 50.0,
               $sformatf("frame period %0.0f ns, expected %0.0f ns", tb2 - ta, T_FRAME_NS));
      for (int i = 0; i < 5; i++) get_byte(dcx, bx);
      for (int i = 0; i < 512; i++) get_byte(dcx, bx);
    end

    // Case 7: power-down.
    u_mst.wr(AW'(OLED_CTRL_OFS), 32'h0);
    expect_cmd(8'hAE, "power-down display off");
    repeat (50) @(posedge cpu_clk);
    read_status(r);
    tb_check(r[1:0] === 2'(OLED_STATE_POWERING_DOWN), $sformatf("STATUS during power-down 0x%08x", r));
    tb_check(oled_vbat === 1'b0 || oled_vbat === 1'b1, "VBAT known");
    wait (oled_vdd === 1'b1);
    #1;
    tb_check(t_vbat_off > 0.0 && t_vdd_off - t_vbat_off >= VBAT_OFF_WAIT_US * 1000.0,
             $sformatf("VBAT off to VDD off %0.0f ns, need >= %0d ns", t_vdd_off - t_vbat_off, VBAT_OFF_WAIT_US * 1000));
    tb_check(n_vbat_off == n_vdd_off, "no SPI byte between VBAT off and VDD off");
    repeat (100) @(posedge cpu_clk);
    tb_check(oled_vbat === 1'b1 && oled_vdd === 1'b1 && oled_res === 1'b0, "pins in the off state after power-down");
    repeat (3000) @(posedge cpu_clk);
    read_status(r);
    tb_check(r[1:0] === 2'(OLED_STATE_OFF), $sformatf("STATUS after power-down 0x%08x", r));
    repeat (400_000) @(posedge cpu_clk);        // 4 ms, two frame periods
    tb_check(byte_q.size() == 0, "no SPI bytes after power-down");
    tb_check(oled_sclk === 1'b0, "SCLK low while off");

    // Case 8: second power-up with the current contrast and invert.
    cnt_base = bytes_total;
    u_mst.wr(AW'(OLED_CTRL_OFS), (32'h1 << OLED_CTRL_POWER_BIT) | (32'h1 << OLED_CTRL_INVERT_BIT));
    check_powerup(8'h40, 1'b1, cnt_base, "power-up 2");

    tb_verdict("tb_c64_oled");
  end

  initial begin
    #100ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_c64_oled");
  end

endmodule
