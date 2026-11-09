// -----------------------------------------------------------------------------
// File: tb_sid_audio_out.sv
// Purpose: self-checking bench for sid_audio_out: AXI4-Lite writes of known
//   stereo frames on cpu_clk (100 MHz), an independent I2S decoder on the
//   pin flip-flops (aud_clk 12.288 MHz; the two clock periods have no common
//   multiple at the 1 ps resolution used here, so the phase drifts through
//   every alignment), and a scoreboard of the exact frame sequence.
// Decoder (written from the Philips I2S definition, not from the RTL):
//   * BCLK period = 4 aud_clk periods, high and low half each 2 periods;
//   * LRCLK and SDATA change only at BCLK falling edges;
//   * every LRCLK half period is exactly 32 BCLK periods (LRCLK = 64 BCLK);
//   * at BCLK rising edges after an LRCLK edge: edge 0 carries the last bit
//     of the previous slot (must be 0, padding), edges 1..16 the 16-bit
//     sample MSB first, edges 17..31 padding (must be 0);
//   * LRCLK low = left; a frame is a left slot followed by a right slot and
//     is compared as {right, left} with the AUD_SAMPLE word.
// Scoreboard: every non-zero decoded frame must equal the oldest written
//   frame not yet played or flushed; written frames are never 0, so zero
//   frames are silence (disabled, underrun or after flush).
// Cases:
//   A. Reset: register defaults, start-up FIFO reset completes, zeros sent
//      while disabled, no underruns counted while disabled.
//   B. Disabled: LEVEL counts written frames exactly; the FIFO is not read.
//   C. Play two batches with an underrun gap: exact sequence, no gap inside a
//      batch, UNDERRUNS equals the number of zero frames sent between the
//      batches, STATUS.UNDERRUN set and W1C.
//   D. Interrupt: THRESH read-back and width, STATUS.IRQ level rule (W1C
//      ineffective while LEVEL <= THRESH, effective above it), irq pin rises
//      when LEVEL reaches THRESH, IRQ_EN masks the pin.
//   E. Disable mid-stream: zeros sent, LEVEL frozen, no underruns counted,
//      re-enable resumes the exact sequence.
//   F. Flush while disabled: CTRL.FLUSH reads 1 then self-clears, LEVEL 0,
//      flushed frames never appear, the FIFO works afterwards.
//   G. FULL: AUD_FIFO_DEPTH - 1 frames fill the FIFO (xpm_fifo_async
//      independent-clock capacity), FULL clear one frame earlier.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_sid_audio_out;

  import rtlnet_tb_pkg::*;
  import c64_pkg::*;

  localparam int  AW            = REG_ADDR_W;
  localparam real T_CPU_HALF    = 5.0;                                  // 100 MHz
  localparam real T_AUD         = 1.0e9 / (AUD_SAMPLE_RATE_HZ * AUD_MCLK_PER_FS); // 81.380 ns
  localparam real T_AUD_HALF    = T_AUD / 2.0;
  localparam real T_FRAME       = T_AUD * AUD_MCLK_PER_FS;              // 20.833 us
  localparam real TOL           = 0.01;                                 // ns, timing comparisons
  localparam int  MCLK_PER_BCLK = AUD_MCLK_PER_FS / AUD_BCLK_PER_FS;
  localparam int  SLOT_BCLKS    = AUD_BCLK_PER_FS / 2;
  localparam int  FIFO_CAPACITY = AUD_FIFO_DEPTH - 1;                   // xpm_fifo_async, independent clocks
  localparam int  CYC_PER_FRAME = 2084;                                 // cpu_clk cycles per frame, rounded up
  localparam logic [15:0] UNDEF_OFS = 16'h0080;

  localparam logic [31:0] C_ENABLE = 32'h1 << AUD_CTRL_ENABLE_BIT;
  localparam logic [31:0] C_FLUSH  = 32'h1 << AUD_CTRL_FLUSH_BIT;
  localparam logic [31:0] C_IRQ_EN = 32'h1 << AUD_CTRL_IRQ_EN_BIT;
  localparam logic [31:0] S_IRQ    = 32'h1 << AUD_STATUS_IRQ_BIT;
  localparam logic [31:0] S_UNDER  = 32'h1 << AUD_STATUS_UNDERRUN_BIT;
  localparam logic [31:0] S_FULL   = 32'h1 << AUD_STATUS_FULL_BIT;

  logic cpu_clk = 1'b0;
  logic aud_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;
  logic aud_resetn;

  always #(T_CPU_HALF) cpu_clk = ~cpu_clk;
  always #(T_AUD_HALF) aud_clk = ~aud_clk;

  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));
  rtlnet_reset_sync u_rst_aud (.clk(aud_clk), .arstn(arstn), .resetn(aud_resetn));

  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic          irq;
  logic          aud_bclk_q;
  logic          aud_lrclk_q;
  logic          aud_sdata_q;

  rtlnet_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  sid_audio_out #(.XPM_SIM_ASSERT(1)) u_dut (
    .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready), .irq(irq),
    .aud_clk(aud_clk), .aud_resetn(aud_resetn),
    .aud_bclk_q(aud_bclk_q), .aud_lrclk_q(aud_lrclk_q), .aud_sdata_q(aud_sdata_q));

  // ---------------------------------------------------------------------------
  // Scoreboard state.
  // ---------------------------------------------------------------------------
  logic [31:0] exp_q [$];      // written frames not yet played or flushed
  int          gap_before [$]; // zero frames decoded before each played frame
  int          played    = 0;  // non-zero frames decoded
  int          zero_run  = 0;  // zero frames since the last non-zero frame
  int          zeros     = 0;  // zero frames decoded in total
  int          dec_slots = 0;  // complete slots decoded
  int          irq_falls = 0;  // falling edges of the irq pin

  always @(negedge irq) irq_falls++;

  function automatic void dec_emit(input logic [31:0] f);
    logic [31:0] e;
    if (f == 32'h0) begin
      zero_run++;
      zeros++;
    end else begin
      gap_before.push_back(zero_run);
      zero_run = 0;
      if (exp_q.size() == 0) begin
        tb_error($sformatf("unexpected frame 0x%08x (nothing written is pending)", f));
      end else begin
        e = exp_q.pop_front();
        tb_check(f === e, $sformatf("frame %0d = 0x%08x, expected 0x%08x", played, f, e));
      end
      played++;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Independent I2S decoder and pin timing checker.
  // ---------------------------------------------------------------------------
  bit      dec_armed = 1'b0;    // set once aud_resetn is released
  realtime t_rise    = 0.0;
  realtime t_fall    = 0.0;
  realtime t_change  = 0.0;

  always @(aud_lrclk_q or aud_sdata_q) t_change = $realtime;

  always @(negedge aud_bclk_q) begin
    if (dec_armed && t_rise > 0.0) begin
      tb_check(($realtime - t_rise - 2.0 * T_AUD) < TOL && ($realtime - t_rise - 2.0 * T_AUD) > -TOL,
               $sformatf("BCLK high time %0.3f ns, expected %0.3f", $realtime - t_rise, 2.0 * T_AUD));
      tb_check(!(t_change > t_rise && t_change < $realtime), "LRCLK/SDATA changed while BCLK was high");
    end
    t_fall = $realtime;
  end

  always @(posedge aud_bclk_q) begin : decoder
    static bit                    sync    = 1'b0;
    static bit                    lr_prev = 1'b0;
    static int                    k       = 0;
    static logic [AUD_SAMPLE_W-1:0] cur   = '0;
    static logic [AUD_SAMPLE_W-1:0] left  = '0;
    static bit                    left_ok = 1'b0;
    logic lr;
    logic sd;
    lr = aud_lrclk_q;
    sd = aud_sdata_q;
    if (dec_armed) begin
      if (t_rise > 0.0) begin
        tb_check(($realtime - t_rise - MCLK_PER_BCLK * T_AUD) < TOL && ($realtime - t_rise - MCLK_PER_BCLK * T_AUD) > -TOL,
                 $sformatf("BCLK period %0.3f ns, expected %0.3f", $realtime - t_rise, MCLK_PER_BCLK * T_AUD));
        if (t_change > t_rise)
          tb_check((t_change - t_fall) < TOL && (t_change - t_fall) > -TOL, "LRCLK/SDATA changed away from a BCLK fall");
      end
      if (lr != lr_prev) begin
        if (sync) begin
          tb_check(sd === 1'b0, "slot bit 31 (sampled after the LRCLK edge) not zero");
          tb_check(k == SLOT_BCLKS - 1, $sformatf("slot of %0d BCLK periods, expected %0d", k + 1, SLOT_BCLKS));
          dec_slots++;
          if (!lr_prev) begin
            left    = cur;
            left_ok = 1'b1;
          end else if (left_ok) begin
            dec_emit({cur, left});
            left_ok = 1'b0;
          end
        end
        sync    = 1'b1;
        lr_prev = lr;
        k       = 0;
        cur     = '0;
      end else begin
        k++;
        if (sync) begin
          if (k <= AUD_SAMPLE_W) cur = {cur[AUD_SAMPLE_W-2:0], sd};
          else                   tb_check(sd === 1'b0, $sformatf("padding bit %0d not zero", k - 1));
        end
      end
    end else begin
      lr_prev = lr;
    end
    t_rise = $realtime;
  end

  // ---------------------------------------------------------------------------
  // Bench helpers.
  // ---------------------------------------------------------------------------
  int unsigned rng = 32'hC0DE_5EED;

  function automatic logic [31:0] next_frame();
    logic [31:0] v;
    rng = rng * 1664525 + 1013904223;
    v   = rng;
    if (v[15:0] == 16'h0)  v[0]  = 1'b1;     // both halves non-zero
    if (v[31:16] == 16'h0) v[16] = 1'b1;
    return v;
  endfunction

  task automatic push_frames(input int n);
    logic [31:0] v;
    for (int i = 0; i < n; i++) begin
      v = next_frame();
      u_mst.wr(AW'(AUD_SAMPLE_OFS), v);
      exp_q.push_back(v);
    end
  endtask

  task automatic rd_reg(input logic [15:0] ofs, output logic [31:0] r);
    u_mst.rd(AW'(ofs), r);
  endtask

  task automatic expect_reg(input logic [15:0] ofs, input logic [31:0] mask, input logic [31:0] exp, input string what);
    logic [31:0] r;
    u_mst.rd(AW'(ofs), r);
    tb_check((r & mask) === exp, $sformatf("%s: read 0x%08x (mask 0x%08x), expected 0x%08x", what, r, mask, exp));
  endtask

  task automatic wait_frames(input real n);
    #(n * T_FRAME);
  endtask

  task automatic wait_played(input int n, input string what);
    int t;
    int limit;
    t     = 0;
    limit = (n - played + 4) * CYC_PER_FRAME * 2;
    while (played < n && t < limit) begin
      @(posedge cpu_clk);
      t++;
    end
    tb_check(played >= n, $sformatf("%s: %0d frames played, expected %0d", what, played, n));
  endtask

  task automatic wait_flush_done(input string what);
    logic [31:0] r;
    int t;
    t = 0;
    do begin
      u_mst.rd(AW'(AUD_CTRL_OFS), r);
      t++;
    end while (r[AUD_CTRL_FLUSH_BIT] && t < 1000);
    tb_check(!r[AUD_CTRL_FLUSH_BIT], $sformatf("%s: CTRL.FLUSH did not self-clear", what));
  endtask

  task automatic wait_irq(input int frames, input string what);
    int t;
    t = 0;
    while (irq !== 1'b1 && t < frames * CYC_PER_FRAME) begin
      @(posedge cpu_clk);
      t++;
    end
    tb_check(irq === 1'b1, $sformatf("%s: irq did not rise", what));
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence.
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] r;
    int          z;
    int          u1;
    int          l1;
    int          p1;
    int          base;
    int          thr;

    #100 arstn = 1'b1;
    @(posedge aud_resetn);
    dec_armed = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // A. Reset state.
    wait_flush_done("start-up FIFO reset");
    expect_reg(AUD_CTRL_OFS, '1, 32'h0, "CTRL reset");
    expect_reg(AUD_LEVEL_OFS, '1, 32'h0, "LEVEL reset");
    expect_reg(AUD_UNDERRUNS_OFS, '1, 32'h0, "UNDERRUNS reset");
    expect_reg(AUD_THRESH_OFS, '1, 32'(AUD_FIFO_DEPTH / 2), "THRESH reset (half full)");
    expect_reg(AUD_STATUS_OFS, '1, S_IRQ, "STATUS reset: IRQ (level 0 <= THRESH), not full, no underrun");
    expect_reg(AUD_SAMPLE_OFS, '1, 32'h0, "AUD_SAMPLE reads 0");
    expect_reg(UNDEF_OFS, '1, 32'h0, "undefined offset reads 0");
    tb_check(irq === 1'b0, "irq low with IRQ_EN clear");
    wait_frames(6);
    tb_check(played == 0 && zeros >= 4, $sformatf("disabled after reset: %0d frames, %0d zero frames", played, zeros));
    expect_reg(AUD_UNDERRUNS_OFS, '1, 32'h0, "no underruns counted while disabled");

    // B. LEVEL while disabled; the FIFO is not read.
    push_frames(40);
    repeat (10) @(posedge cpu_clk);
    expect_reg(AUD_LEVEL_OFS, '1, 32'd40, "LEVEL after 40 writes");
    wait_frames(5);
    expect_reg(AUD_LEVEL_OFS, '1, 32'd40, "LEVEL unchanged while disabled");
    tb_check(played == 0, "nothing played while disabled");

    // C. Two batches with an underrun gap.
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    wait_played(40, "batch 1");
    while (zero_run < 10) @(posedge cpu_clk);
    push_frames(32);
    wait_played(41, "batch 2 start");
    z = gap_before[40];
    rd_reg(AUD_UNDERRUNS_OFS, r);
    tb_check(r == 32'(z) && z >= 10, $sformatf("UNDERRUNS %0d, zero frames sent between the batches %0d", r, z));
    expect_reg(AUD_STATUS_OFS, S_UNDER, S_UNDER, "STATUS.UNDERRUN set");
    u_mst.wr(AW'(AUD_STATUS_OFS), S_UNDER);
    expect_reg(AUD_STATUS_OFS, S_UNDER, 32'h0, "STATUS.UNDERRUN cleared by W1C while playing");
    wait_played(72, "batch 2");
    for (int i = 1; i < 72; i++)
      if (i != 40) tb_check(gap_before[i] == 0, $sformatf("zero frame inside a batch before frame %0d", i));

    // D. Interrupt.
    u_mst.wr(AW'(AUD_CTRL_OFS), 32'h0);
    wait_frames(3);
    u_mst.wr(AW'(AUD_THRESH_OFS), 32'hFFFF_FFFF);
    expect_reg(AUD_THRESH_OFS, '1, 32'((1 << AUD_LEVEL_W) - 1), "THRESH is AUD_LEVEL_W bits wide");
    thr = 8;
    u_mst.wr(AW'(AUD_THRESH_OFS), 32'(thr));
    expect_reg(AUD_THRESH_OFS, '1, 32'(thr), "THRESH read-back");
    expect_reg(AUD_STATUS_OFS, S_IRQ, S_IRQ, "IRQ pending with an empty FIFO");
    u_mst.wr(AW'(AUD_STATUS_OFS), S_IRQ);
    expect_reg(AUD_STATUS_OFS, S_IRQ, S_IRQ, "W1C of IRQ ineffective while LEVEL <= THRESH");
    push_frames(20);
    repeat (10) @(posedge cpu_clk);
    expect_reg(AUD_LEVEL_OFS, '1, 32'd20, "LEVEL 20");
    expect_reg(AUD_STATUS_OFS, S_IRQ, S_IRQ, "IRQ stays latched above THRESH until W1C");
    u_mst.wr(AW'(AUD_STATUS_OFS), S_IRQ);
    expect_reg(AUD_STATUS_OFS, S_IRQ, 32'h0, "W1C of IRQ effective above THRESH");
    tb_check(irq === 1'b0, "irq low before the threshold");
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE | C_IRQ_EN);
    wait_irq(30, "first threshold crossing");
    rd_reg(AUD_LEVEL_OFS, r);
    tb_check(r <= 32'(thr) && r + 1 >= 32'(thr), $sformatf("LEVEL %0d at the interrupt, THRESH %0d", r, thr));
    expect_reg(AUD_STATUS_OFS, S_IRQ, S_IRQ, "STATUS.IRQ set at the interrupt");
    z = irq_falls;
    u_mst.wr(AW'(AUD_STATUS_OFS), S_IRQ);
    expect_reg(AUD_STATUS_OFS, S_IRQ, S_IRQ, "W1C ineffective at the threshold");
    tb_check(irq_falls == z && irq === 1'b1, "irq pin held through a W1C at the threshold (set wins)");
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    repeat (3) @(posedge cpu_clk);
    tb_check(irq === 1'b0, "IRQ_EN = 0 masks the pin");
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE | C_IRQ_EN);
    repeat (3) @(posedge cpu_clk);
    tb_check(irq === 1'b1, "pin follows STATUS.IRQ again with IRQ_EN = 1");
    push_frames(40);
    repeat (10) @(posedge cpu_clk);
    u_mst.wr(AW'(AUD_STATUS_OFS), S_IRQ);
    expect_reg(AUD_STATUS_OFS, S_IRQ, 32'h0, "W1C effective after refilling above THRESH");
    repeat (3) @(posedge cpu_clk);
    tb_check(irq === 1'b0, "irq low after refill and W1C");
    wait_irq(60, "second threshold crossing");
    rd_reg(AUD_LEVEL_OFS, r);
    tb_check(r <= 32'(thr), $sformatf("LEVEL %0d at the second interrupt", r));
    u_mst.wr(AW'(AUD_CTRL_OFS), 32'h0);
    wait_frames(3);
    rd_reg(AUD_LEVEL_OFS, r);
    tb_check(r == 32'(exp_q.size()), $sformatf("LEVEL %0d equals frames still pending %0d", r, exp_q.size()));

    // E. Disable mid-stream.
    push_frames(60);
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    wait_played(played + 10, "before mid-stream disable");
    u_mst.wr(AW'(AUD_CTRL_OFS), 32'h0);
    wait_frames(3);
    rd_reg(AUD_LEVEL_OFS, r);
    l1 = r;
    tb_check(l1 == exp_q.size() && l1 > 0, $sformatf("LEVEL %0d after disable, pending %0d", l1, exp_q.size()));
    rd_reg(AUD_UNDERRUNS_OFS, r);
    u1 = r;
    p1 = played;
    z  = zeros;
    wait_frames(10);
    expect_reg(AUD_LEVEL_OFS, '1, 32'(l1), "LEVEL frozen while disabled");
    expect_reg(AUD_UNDERRUNS_OFS, '1, 32'(u1), "no underruns while disabled");
    tb_check(played == p1 && zeros >= z + 9, $sformatf("disabled: %0d frames played, %0d zero frames", played - p1, zeros - z));
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    wait_played(p1 + l1, "resume after disable");
    tb_check(exp_q.size() == 0, "all frames played after resume");
    wait_frames(4);
    rd_reg(AUD_UNDERRUNS_OFS, r);
    tb_check(r > 32'(u1), "underruns counted again once enabled and empty");

    // F. Flush while disabled.
    u_mst.wr(AW'(AUD_CTRL_OFS), 32'h0);
    wait_frames(3);
    push_frames(30);
    repeat (10) @(posedge cpu_clk);
    expect_reg(AUD_LEVEL_OFS, '1, 32'd30, "LEVEL 30 before flush");
    u_mst.wr(AW'(AUD_CTRL_OFS), C_FLUSH);
    expect_reg(AUD_CTRL_OFS, C_FLUSH | C_ENABLE, C_FLUSH, "CTRL.FLUSH reads 1 during the flush");
    expect_reg(AUD_STATUS_OFS, S_FULL, S_FULL, "STATUS.FULL reads 1 during the flush");
    wait_flush_done("flush");
    exp_q.delete();
    expect_reg(AUD_LEVEL_OFS, '1, 32'h0, "LEVEL 0 after flush");
    expect_reg(AUD_STATUS_OFS, S_FULL, 32'h0, "STATUS.FULL clear after flush");
    p1 = played;
    rd_reg(AUD_UNDERRUNS_OFS, r);
    u1 = r;
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    wait_frames(6);
    tb_check(played == p1, "flushed frames never sent");
    rd_reg(AUD_UNDERRUNS_OFS, r);
    tb_check(r >= 32'(u1 + 4), $sformatf("underruns after flush: %0d -> %0d", u1, r));
    push_frames(5);
    wait_played(p1 + 5, "frames written after flush");

    // G. FULL.
    u_mst.wr(AW'(AUD_CTRL_OFS), 32'h0);
    wait_frames(3);
    tb_check(exp_q.size() == 0, "nothing pending before the fill");
    push_frames(FIFO_CAPACITY - 1);
    repeat (10) @(posedge cpu_clk);
    expect_reg(AUD_LEVEL_OFS, '1, 32'(FIFO_CAPACITY - 1), "LEVEL one below capacity");
    expect_reg(AUD_STATUS_OFS, S_FULL, 32'h0, "not FULL one below capacity");
    push_frames(1);
    repeat (10) @(posedge cpu_clk);
    expect_reg(AUD_LEVEL_OFS, '1, 32'(FIFO_CAPACITY), "LEVEL at capacity");
    expect_reg(AUD_STATUS_OFS, S_FULL, S_FULL, "FULL at capacity");
    u_mst.wr(AW'(AUD_CTRL_OFS), C_FLUSH);
    wait_flush_done("flush of a full FIFO");
    exp_q.delete();
    expect_reg(AUD_LEVEL_OFS, '1, 32'h0, "LEVEL 0 after flushing a full FIFO");
    expect_reg(AUD_STATUS_OFS, S_FULL, 32'h0, "FULL clear after flushing a full FIFO");
    base = played;
    push_frames(3);
    u_mst.wr(AW'(AUD_CTRL_OFS), C_ENABLE);
    wait_played(base + 3, "frames after the full flush");
    tb_check(dec_slots > 0, "decoder saw slots");

    tb_verdict("tb_sid_audio_out");
  end

  initial begin
    #60ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_sid_audio_out");
  end

endmodule
