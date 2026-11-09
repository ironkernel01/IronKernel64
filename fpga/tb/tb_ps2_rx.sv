// -----------------------------------------------------------------------------
// File: tb_ps2_rx.sv
// Purpose: self-checking bench for ps2_rx. A PS/2 device model (the PIC24
//   bridge's keyboard side) sends 11-bit device-to-host frames at 12 kHz with
//   PS/2 timing; the bench reads the FIFO and status over AXI4-Lite.
// Device model timing (PS/2 device-to-host): clock period 83.333 us
//   (12 kHz), the device changes data a quarter period before each falling
//   clock edge (inside the clock-high phase) and holds it through the
//   clock-low phase; idle gap between frames 250 us. The model's times are
//   not multiples of the 10 ns cpu_clk period.
// Cases:
//   1. Eight good bytes (0x1C 0xF0 0x1C 0xE0 0x75 0x00 0xFF 0xAA), several
//      of them carrying glitches shorter than the filter: low pulses on the
//      clock line during the clock-high phase, high pulses on the clock line
//      during the clock-low phase, and pulses on the data line around the
//      sampling instant. All eight bytes are read back in order, valid bit
//      set, no status bit set.
//   2. Bad parity: PARITY set, nothing queued; W1C clears it.
//   3. Missing stop bit (stop bit sent as 0): FRAME set, nothing queued; the
//      next good byte is received (resynchronisation).
//   4. Start bit 1 (falling edge with data high): FRAME set, nothing queued.
//   5. Stalled frame (start + 4 data bits, then no clock): FRAME is clear
//      1.8 ms after the last edge and set by 2.3 ms; nothing queued; the next
//      good byte is received.
//   6. FIFO overflow: PS2_FIFO_DEPTH + 1 bytes without reads. The first
//      PS2_FIFO_DEPTH bytes are read back in order, OVERFLOW is set, the
//      next read returns valid = 0.
//   7. Interrupt: irq follows AVAIL && IRQ_EN; PS2_CTRL reads back.
//   8. Empty read returns 0; undefined offset reads 0.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ps2_rx;

  import rtlnet_tb_pkg::*;
  import c64_pkg::*;

  localparam int      AW          = REG_ADDR_W;
  // Times in ns (the bench timescale unit).
  localparam real T_BIT       = 83_333.333;         // 12 kHz device clock
  localparam real T_QUARTER   = T_BIT / 4.0;
  localparam real T_HALF      = T_BIT / 2.0;
  localparam real T_GAP       = 250_000.0;          // idle between frames
  localparam real T_GLITCH    = 1_200.0;            // shorter than the 1.87 us filter
  localparam real T_GLITCH_SH = 400.0;
  localparam real T_DATA_GL0  = 500.0;              // first data glitch, after the falling edge
  localparam real T_DATA_GL1  = 1_000.0;            // gap to the second data glitch
  localparam real T_NO_TMO    = 1_800_000.0;        // before the 2 ms bit timeout
  localparam real T_TMO_SEEN  = 500_000.0;          // further wait: past the timeout
  localparam logic [15:0] UNDEF_OFS = 16'h0040;

  // Glitch selection per frame.
  localparam int GL_NONE      = 0;
  localparam int GL_CLK_LOW   = 1;  // low pulses on the clock while it is high
  localparam int GL_CLK_HIGH  = 2;  // high pulses on the clock while it is low
  localparam int GL_DATA      = 3;  // data pulses around the sampling instant
  localparam int GL_ALL       = 4;

  logic cpu_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;

  always #5.0 cpu_clk = ~cpu_clk;           // 100 MHz

  rtlnet_reset_sync u_rst (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));

  // Open-collector lines with pull-ups, modelled as driven levels (idle 1).
  logic ps2_clk  = 1'b1;
  logic ps2_data = 1'b1;
  logic irq;

  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  rtlnet_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  ps2_rx u_dut (
    .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .ps2_clk(ps2_clk), .ps2_data(ps2_data), .irq(irq));

  // ---------------------------------------------------------------------------
  // Device model.
  // ---------------------------------------------------------------------------
  // One pulse of width w on the clock line to level lvl, then back.
  task automatic clk_pulse(input logic lvl, input real w);
    logic keep;
    keep = ps2_clk;
    ps2_clk = lvl;
    #(w);
    ps2_clk = keep;
  endtask

  task automatic data_pulse(input real w);
    logic keep;
    keep = ps2_data;
    ps2_data = ~keep;
    #(w);
    ps2_data = keep;
  endtask

  // Send bits[0..nbits-1] (bit 0 first) as a device-to-host frame; the line
  // returns to idle after the last bit. glitch selects the injected pulses.
  task automatic send_bits(input logic [10:0] bits, input int nbits, input int glitch);
    for (int i = 0; i < nbits; i++) begin
      // Clock high phase: data changes a quarter period before the fall.
      ps2_data = bits[i];
      if (glitch == GL_CLK_LOW || glitch == GL_ALL) begin
        #(T_QUARTER / 3.0);
        clk_pulse(1'b0, T_GLITCH);
        #(T_QUARTER * 2.0 / 3.0 - T_GLITCH);
      end else begin
        #(T_QUARTER);
      end
      // Clock low phase: the receiver samples data here.
      ps2_clk = 1'b0;
      if (glitch == GL_DATA || glitch == GL_ALL) begin
        #(T_DATA_GL0);
        data_pulse(T_GLITCH);
        #(T_DATA_GL1);
        data_pulse(T_GLITCH_SH);
        #(T_HALF - T_DATA_GL0 - T_GLITCH - T_DATA_GL1 - T_GLITCH_SH);
      end else if (glitch == GL_CLK_HIGH) begin
        #(T_HALF / 2.0);
        clk_pulse(1'b1, T_GLITCH);
        #(T_HALF / 2.0 - T_GLITCH);
      end else begin
        #(T_HALF);
      end
      ps2_clk = 1'b1;
      #(T_QUARTER);
    end
    ps2_data = 1'b1;
    #(T_GAP);
  endtask

  // A complete frame for byte b; parity_ok = 0 sends even parity,
  // stop = 0 sends a 0 stop bit.
  function automatic logic [10:0] frame_bits(input logic [7:0] b, input bit parity_ok, input bit stop);
    logic par;
    par = ~^b;                                // odd parity over data + parity
    if (!parity_ok) par = ~par;
    return {stop, par, b, 1'b0};
  endfunction

  task automatic send_byte(input logic [7:0] b, input int glitch = GL_NONE);
    send_bits(frame_bits(b, 1'b1, 1'b1), 11, glitch);
  endtask

  // ---------------------------------------------------------------------------
  // Register helpers.
  // ---------------------------------------------------------------------------
  task automatic read_status(output logic [31:0] s);
    u_mst.rd(AW'(PS2_STATUS_OFS), s);
  endtask

  task automatic expect_byte(input logic [7:0] b, input string what);
    logic [31:0] r;
    u_mst.rd(AW'(PS2_DATA_OFS), r);
    tb_check(r === ((32'h1 << PS2_DATA_VALID_BIT) | 32'(b)),
             $sformatf("%s: PS2_DATA 0x%08x, expected byte 0x%02x valid", what, r, b));
  endtask

  task automatic expect_empty(input string what);
    logic [31:0] r;
    u_mst.rd(AW'(PS2_DATA_OFS), r);
    tb_check(r === 32'h0, $sformatf("%s: PS2_DATA 0x%08x, expected 0 (empty)", what, r));
  endtask

  task automatic expect_status(input logic [31:0] exp, input string what);
    logic [31:0] s;
    read_status(s);
    tb_check(s === exp, $sformatf("%s: PS2_STATUS 0x%08x, expected 0x%08x", what, s, exp));
  endtask

  localparam logic [31:0] ST_AVAIL    = 32'h1 << PS2_STATUS_AVAIL_BIT;
  localparam logic [31:0] ST_PARITY   = 32'h1 << PS2_STATUS_PARITY_BIT;
  localparam logic [31:0] ST_OVERFLOW = 32'h1 << PS2_STATUS_OVERFLOW_BIT;
  localparam logic [31:0] ST_FRAME    = 32'h1 << PS2_STATUS_FRAME_BIT;
  localparam logic [31:0] ST_ERRORS   = ST_PARITY | ST_OVERFLOW | ST_FRAME;

  initial begin : main
    logic [7:0]  good [8];
    int          gsel [8];
    logic [7:0]  burst [PS2_FIFO_DEPTH + 1];
    logic [31:0] r;
    int unsigned rng;

    good = '{8'h1C, 8'hF0, 8'h1C, 8'hE0, 8'h75, 8'h00, 8'hFF, 8'hAA};
    gsel = '{GL_NONE, GL_CLK_LOW, GL_CLK_HIGH, GL_DATA, GL_ALL, GL_ALL, GL_DATA, GL_CLK_LOW};
    rng  = 32'h2468_ACE1;

    #100 arstn = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // Case 8 (first half): empty FIFO, undefined offset, reset status.
    expect_empty("empty after reset");
    expect_status(32'h0, "status after reset");
    u_mst.rd(AW'(UNDEF_OFS), r);
    tb_check(r === 32'h0, "undefined offset reads 0");
    tb_check(irq === 1'b0, "irq low after reset");

    // Case 7 (setup): enable the interrupt, read back CTRL.
    u_mst.wr(AW'(PS2_CTRL_OFS), 32'h1 << PS2_CTRL_IRQ_EN_BIT);
    u_mst.rd(AW'(PS2_CTRL_OFS), r);
    tb_check(r === (32'h1 << PS2_CTRL_IRQ_EN_BIT), $sformatf("PS2_CTRL read-back 0x%08x", r));

    // Case 1: good bytes, with glitches.
    for (int i = 0; i < 8; i++) send_byte(good[i], gsel[i]);
    expect_status(ST_AVAIL, "after good bytes");
    tb_check(irq === 1'b1, "irq high with bytes queued and IRQ_EN");
    for (int i = 0; i < 8; i++) expect_byte(good[i], $sformatf("good byte %0d", i));
    expect_empty("after good bytes");
    @(posedge cpu_clk);
    tb_check(irq === 1'b0, "irq low after the FIFO is drained");

    // Case 2: bad parity.
    send_bits(frame_bits(8'h55, 1'b0, 1'b1), 11, GL_NONE);
    expect_status(ST_PARITY, "after bad parity");
    expect_empty("bad parity byte not queued");
    u_mst.wr(AW'(PS2_STATUS_OFS), ST_PARITY);
    expect_status(32'h0, "PARITY cleared by W1C");

    // Case 3: missing stop bit, then resynchronisation.
    send_bits(frame_bits(8'h3C, 1'b1, 1'b0), 11, GL_NONE);
    expect_status(ST_FRAME, "after missing stop bit");
    expect_empty("byte with a bad stop bit not queued");
    send_byte(8'h5A, GL_CLK_HIGH);
    expect_status(ST_FRAME | ST_AVAIL, "good byte after missing stop bit");
    expect_byte(8'h5A, "byte after missing stop bit");
    u_mst.wr(AW'(PS2_STATUS_OFS), ST_FRAME);
    expect_status(32'h0, "FRAME cleared by W1C");

    // Case 4: start bit 1.
    send_bits(11'h001, 1, GL_NONE);           // one falling edge with data high
    expect_status(ST_FRAME, "after a start bit of 1");
    expect_empty("nothing queued after a start bit of 1");
    u_mst.wr(AW'(PS2_STATUS_OFS), ST_FRAME);

    // Case 5: stalled frame (start + 4 data bits), bit timeout, resync.
    begin
      logic [10:0] fb;
      fb = frame_bits(8'hA5, 1'b1, 1'b1);
      for (int i = 0; i < 5; i++) begin
        ps2_data = fb[i];
        #(T_QUARTER);
        ps2_clk = 1'b0;
        #(T_HALF);
        ps2_clk = 1'b1;
        #(T_QUARTER);
      end
      ps2_data = 1'b1;
      // Last falling edge was T_HALF + T_QUARTER ago.
      #(T_NO_TMO - T_HALF - T_QUARTER);
      expect_status(32'h0, "no timeout 1.8 ms after the last edge");
      #(T_TMO_SEEN);
      expect_status(ST_FRAME, "timeout by 2.3 ms after the last edge");
      expect_empty("stalled frame not queued");
      u_mst.wr(AW'(PS2_STATUS_OFS), ST_FRAME);
      send_byte(8'hC3, GL_DATA);
      expect_status(ST_AVAIL, "good byte after the stall");
      expect_byte(8'hC3, "byte after the stall");
    end

    // Case 6: overflow, with the interrupt masked.
    u_mst.wr(AW'(PS2_CTRL_OFS), 32'h0);
    for (int i = 0; i <= PS2_FIFO_DEPTH; i++) begin
      rng = rng * 1664525 + 1013904223;
      burst[i] = rng[23:16];
      send_byte(burst[i], (i % 3 == 0) ? GL_CLK_LOW : GL_NONE);
    end
    expect_status(ST_AVAIL | ST_OVERFLOW, "after overflow");
    tb_check(irq === 1'b0, "irq masked by IRQ_EN = 0");
    u_mst.wr(AW'(PS2_CTRL_OFS), 32'h1 << PS2_CTRL_IRQ_EN_BIT);
    repeat (2) @(posedge cpu_clk);
    tb_check(irq === 1'b1, "irq high once IRQ_EN is set again");
    for (int i = 0; i < PS2_FIFO_DEPTH; i++) expect_byte(burst[i], $sformatf("burst byte %0d", i));
    expect_empty("byte after the full FIFO was dropped");
    expect_status(ST_OVERFLOW, "OVERFLOW stays until W1C");
    u_mst.wr(AW'(PS2_STATUS_OFS), ST_ERRORS);
    expect_status(32'h0, "all errors cleared");
    @(posedge cpu_clk);
    tb_check(irq === 1'b0, "irq low at the end");

    tb_verdict("tb_ps2_rx");
  end

  initial begin
    #200ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_ps2_rx");
  end

endmodule
