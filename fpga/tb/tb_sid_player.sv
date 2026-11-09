// -----------------------------------------------------------------------------
// File: tb_sid_player.sv
// Purpose: self-checking bench for sid_player with the real reDIP-SID core:
//   AXI4-Lite pushes of timestamped SID writes on cpu_clk (100 MHz), bus-level
//   monitors on the core's input, OSC3 read-back and the 48 kHz stream.
// Cases:
//   A. Rates: phi2 falling edges in 1 ms = 985 +-1; 48 kHz ticks in 10 ms =
//      480 +-1 (both counted from the RUN write, monitor runs alongside B..D).
//   B. Timestamps: writes at T, T+1, T+50 appear on bus_i in the phi2 cycle
//      whose rising edge sees CYCLE == time; a write whose time is already
//      past plays in the next cycle. Every write on the bus holds addr, data,
//      r_w_n and cs_n for the whole cycle, and the core's data-bus latch
//      (sid_control dbus, probed) holds the written value 20 clocks after the
//      falling edge, which proves the core sampled the write.
//   C. Voice 3 sawtooth: OSC3 from SID_RDBK rises monotonically between wraps.
//   D. Voice 1 sawtooth about 1 kHz, volume 15: after the attack the stream is
//      not constant and its rising mean-crossings give 1 kHz +-5 %.
//   E. FIFO: 512 pushes fill it, 3 more set OVERFLOW (expected $error
//      suppressed through sim_expect_overflow), level saturates, W1C clears.
//   F. RESET: clears CYCLE, FIFO and OVERFLOW, holds res; queued future
//      writes are never played.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_sid_player;

  import rtlnet_tb_pkg::*;
  import c64_pkg::*;

  localparam int  AW         = REG_ADDR_W;
  localparam real T_CPU_HALF = 5.0;                      // 100 MHz
  localparam logic [31:0] C_RUN   = 32'h1 << SID_CTRL_RUN_BIT;
  localparam logic [31:0] C_RESET = 32'h1 << SID_CTRL_RESET_BIT;
  localparam logic [31:0] S_OVF   = 32'h1 << SID_STATUS_OVERFLOW_BIT;
  localparam logic [31:0] S_FULL  = 32'h1 << SID_STATUS_FULL_BIT;

  logic cpu_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;
  always #(T_CPU_HALF) cpu_clk = ~cpu_clk;
  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));

  logic [AW-1:0] awaddr, araddr;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic [1:0]    bresp, rresp;
  logic          awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic          strm_valid;
  logic signed [15:0] strm_sample;

  rtlnet_tb_axil_master #(.ADDR_W(AW)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  sid_player u_dut (
    .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready), .strm_valid(strm_valid), .strm_sample(strm_sample));

  // Probes of the core's input bus.
  wire        p_phi2 = u_dut.bus_i.phi2;
  wire        p_rwn  = u_dut.bus_i.r_w_n;
  wire [4:0]  p_addr = u_dut.bus_i.addr;
  wire [7:0]  p_data = u_dut.bus_i.data;
  wire        p_res  = u_dut.bus_i.res;
  wire        p_csn  = u_dut.cs_n;
  wire [31:0] p_cyc  = u_dut.cycle_cnt;
  wire [7:0]  p_dbus = u_dut.u_sid.control.dbus.value[0];

  // ---------------------------------------------------------------------------
  // Monitors.
  // ---------------------------------------------------------------------------
  typedef struct { int unsigned cyc; logic [4:0] addr; logic [7:0] data; } wr_t;
  wr_t wlog [$];
  int  falls = 0;
  int  ticks = 0;
  int  wr_landed = 0;
  int  wr_seen   = 0;
  logic prev_phi2 = 1'b0;
  bit   seen_rise = 1'b0;
  logic cur_wr = 1'b0;
  logic [4:0] cur_addr;
  logic [7:0] cur_data;
  logic       cur_rwn, cur_csn;
  int  since_fall = 0;
  bit  cap_en = 1'b0;
  int  aud [$];

  always @(posedge cpu_clk) begin
    if (strm_valid) begin
      ticks++;
      if (cap_en) aud.push_back(int'(strm_sample));
    end
    prev_phi2 <= p_phi2;
    if (p_phi2 && !prev_phi2) begin
      cur_addr = p_addr; cur_data = p_data; cur_rwn = p_rwn; cur_csn = p_csn;
      cur_wr   = !p_rwn && !p_csn;
      seen_rise = 1'b1;
      if (cur_wr) begin
        wlog.push_back('{cyc: p_cyc, addr: p_addr, data: p_data});
        wr_seen++;
      end
    end else if (p_phi2 && prev_phi2 || !p_phi2 && !prev_phi2) begin
      // The whole phi2 cycle holds the operation (res excepted).
      if (seen_rise && (p_addr !== cur_addr || p_data !== cur_data || p_rwn !== cur_rwn || p_csn !== cur_csn))
        tb_error("bus_i changed inside a phi2 cycle");
    end
    if (!p_phi2 && prev_phi2) begin
      falls++;
      since_fall = 0;
    end else begin
      since_fall++;
    end
    if (!p_phi2 && since_fall == 20 && cur_wr) begin
      wr_landed++;
      tb_check(p_dbus === cur_data, $sformatf("core did not latch write %0h <- %0h (data bus %0h)", cur_addr, cur_data, p_dbus));
    end
  end

  // ---------------------------------------------------------------------------
  // Bench helpers.
  // ---------------------------------------------------------------------------
  task automatic wr_reg(input logic [15:0] ofs, input logic [31:0] v);
    u_mst.wr(AW'(ofs), v);
  endtask

  task automatic rd_reg(input logic [15:0] ofs, output logic [31:0] r);
    u_mst.rd(AW'(ofs), r);
  endtask

  task automatic expect_reg(input logic [15:0] ofs, input logic [31:0] mask, input logic [31:0] exp, input string what);
    logic [31:0] r;
    u_mst.rd(AW'(ofs), r);
    tb_check((r & mask) === exp, $sformatf("%s: read 0x%08x (mask 0x%08x), expected 0x%08x", what, r, mask, exp));
  endtask

  task automatic push(input logic [31:0] t, input logic [4:0] reg5, input logic [7:0] val);
    wr_reg(SID_WTIME_OFS, t);
    wr_reg(SID_WDATA_OFS, {19'd0, reg5, val});
  endtask

  function automatic int find_wr(input logic [4:0] a, input logic [7:0] d);
    for (int i = 0; i < wlog.size(); i++) if (wlog[i].addr == a && wlog[i].data == d) return i;
    return -1;
  endfunction

  task automatic wait_cycles(input int n);
    repeat (n) @(negedge p_phi2);
  endtask

  task automatic now_cycle(output logic [31:0] c);
    rd_reg(SID_CYCLE_OFS, c);
  endtask

  // Case A monitor: counts from the RUN write.
  event run_ev;
  int   falls0, ticks0;
  bit   a_done = 1'b0;
  initial begin
    @(run_ev);
    #1ms;
    tb_check(falls - falls0 >= 984 && falls - falls0 <= 986, $sformatf("phi2 falling edges in 1 ms: %0d, expected 985 +-1", falls - falls0));
    #9ms;
    tb_check(ticks - ticks0 >= 479 && ticks - ticks0 <= 481, $sformatf("48 kHz ticks in 10 ms: %0d, expected 480 +-1", ticks - ticks0));
    a_done = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Test sequence.
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] r, c0, c1, t0;
    int          k;
    int          prev_osc, osc, up, wraps, bad, nsamp;
    int          idx_a, idx_b, idx_c, idx_d;
    int          mn, mx, xing [$];
    real         mean, period;
    realtime     t_start;

    #100 arstn = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // Reset state.
    expect_reg(SID_CTRL_OFS, '1, 32'h0, "CTRL reset");
    expect_reg(SID_STATUS_OFS, '1, 32'h0, "STATUS reset: empty, not full, no overflow");
    expect_reg(SID_CYCLE_OFS, '1, 32'h0, "CYCLE reset");
    expect_reg(SID_RDBK_OFS, '1, 32'h0, "RDBK reset");
    expect_reg(SID_WDATA_OFS, '1, 32'h0, "WDATA reads 0");
    expect_reg(16'h0080, '1, 32'h0, "undefined offset reads 0");
    wait_cycles(0);
    tb_check(p_phi2 === 1'b0 && p_csn === 1'b1, "idle before RUN");

    wr_reg(SID_CTRL_OFS, C_RUN);
    falls0 = falls;
    ticks0 = ticks;
    -> run_ev;
    expect_reg(SID_CTRL_OFS, '1, C_RUN, "CTRL RUN read-back");
    wait_cycles(30);

    // The core's $readmemh tables loaded (found from the simulation working directory).
    k = 0;
    for (int i = 0; i < 4096; i++) if (u_dut.u_sid.waveform.sid_waveform_PS__6581[i] !== 8'h00) k++;
    tb_check(k > 1000, $sformatf("sid_waveform_PS__6581.hex loaded: %0d non-zero entries", k));
    k = 0;
    for (int i = 0; i < 2048; i++) if (u_dut.u_sid.waveform.sid_waveform_P_T_6581[i] !== 8'h00) k++;
    tb_check(k > 100, $sformatf("sid_waveform_P_T_6581.hex loaded: %0d non-zero entries", k));

    // B. Timestamps.
    now_cycle(c0);
    t0 = c0 + 40;
    push(t0,      5'h1D, 8'hA5);
    push(t0 + 1,  5'h1E, 8'h5A);
    push(t0 + 50, 5'h1F, 8'hC3);
    expect_reg(SID_STATUS_OFS, 32'hFFFF_0000, 32'h3 << SID_STATUS_LEVEL_LSB, "level 3 after three pushes");
    wait_cycles(100);
    idx_a = find_wr(5'h1D, 8'hA5);
    idx_b = find_wr(5'h1E, 8'h5A);
    idx_c = find_wr(5'h1F, 8'hC3);
    tb_check(idx_a >= 0 && idx_b >= 0 && idx_c >= 0, "timed writes appeared on bus_i");
    if (idx_a >= 0) tb_check(wlog[idx_a].cyc == t0,      $sformatf("write T played at CYCLE %0d, expected %0d", wlog[idx_a].cyc, t0));
    if (idx_b >= 0) tb_check(wlog[idx_b].cyc == t0 + 1,  $sformatf("write T+1 played at CYCLE %0d, expected %0d", wlog[idx_b].cyc, t0 + 1));
    if (idx_c >= 0) tb_check(wlog[idx_c].cyc == t0 + 50, $sformatf("write T+50 played at CYCLE %0d, expected %0d", wlog[idx_c].cyc, t0 + 50));
    expect_reg(SID_STATUS_OFS, 32'hFFFF_0000, 32'h0, "FIFO empty after replay");
    // Late write: time already past.
    now_cycle(c0);
    push(c0 - 100, 5'h1D, 8'h3C);
    now_cycle(c1);
    wait_cycles(3);
    idx_d = find_wr(5'h1D, 8'h3C);
    tb_check(idx_d >= 0, "late write played");
    if (idx_d >= 0) tb_check(wlog[idx_d].cyc >= c0 && wlog[idx_d].cyc <= c1 + 1,
                             $sformatf("late write played at CYCLE %0d, pushed between %0d and %0d", wlog[idx_d].cyc, c0, c1));
    // At most one write per cycle: three writes with the same, past time.
    now_cycle(c0);
    push(c0, 5'h1D, 8'h11);
    push(c0, 5'h1E, 8'h22);
    push(c0, 5'h1F, 8'h33);
    wait_cycles(6);
    idx_a = find_wr(5'h1D, 8'h11);
    idx_b = find_wr(5'h1E, 8'h22);
    idx_c = find_wr(5'h1F, 8'h33);
    tb_check(idx_a >= 0 && idx_b == idx_a + 1 && idx_c == idx_b + 1, "equal-time writes play in order");
    if (idx_a >= 0 && idx_c >= 0)
      tb_check(wlog[idx_b].cyc == wlog[idx_a].cyc + 1 && wlog[idx_c].cyc == wlog[idx_b].cyc + 1,
               "one write per phi2 cycle");

    // C. Voice 3 sawtooth, OSC3 read-back.
    now_cycle(c0);
    push(c0, 5'h0E, 8'h00);   // freq 0x2000: OSC3 +1 per 8 phi2 cycles
    push(c0, 5'h0F, 8'h20);
    push(c0, 5'h10, 8'h00);
    push(c0, 5'h11, 8'h08);
    push(c0, 5'h13, 8'h00);
    push(c0, 5'h14, 8'hF0);
    push(c0, 5'h12, 8'h21);   // sawtooth, gate
    wait_cycles(40);
    prev_osc = -1; up = 0; wraps = 0; bad = 0; nsamp = 0;
    for (k = 0; k < 80; k++) begin
      rd_reg(SID_RDBK_OFS, r);
      osc = int'(r[7:0]);
      if (prev_osc >= 0) begin
        if (osc > prev_osc) up++;
        else if (osc < prev_osc) begin
          if (prev_osc > 200 && osc < 60) wraps++;
          else bad++;
        end
      end
      prev_osc = osc;
      nsamp++;
      repeat (2000) @(posedge cpu_clk);        // 20 us, about 20 phi2 cycles
    end
    tb_check(up >= 60 && bad == 0, $sformatf("OSC3: %0d increases, %0d non-wrap decreases in %0d samples (wraps %0d)", up, bad, nsamp, wraps));
    tb_check(r[15:8] === r[15:8] && ^r[15:8] !== 1'bx, "ENV3 read-back known");

    // D. Voice 1 sawtooth 1 kHz, volume 15. RESET first: silences voice 3 and
    // restarts CYCLE; the core sees res while phi2 runs.
    wr_reg(SID_CTRL_OFS, C_RUN | C_RESET);
    wait_cycles(5);
    tb_check(p_res === 1'b1, "res held while CTRL.RESET");
    wr_reg(SID_CTRL_OFS, C_RUN);
    wait_cycles(5);
    tb_check(p_res === 1'b0, "res released");
    now_cycle(c0);
    push(c0, 5'h18, 8'h0F);   // volume 15
    push(c0, 5'h00, 8'h84);   // freq 0x4284 = 1 kHz at 985248 Hz
    push(c0, 5'h01, 8'h42);
    push(c0, 5'h02, 8'h00);
    push(c0, 5'h03, 8'h08);
    push(c0, 5'h05, 8'h00);   // attack 2 ms, decay 6 ms
    push(c0, 5'h06, 8'hF0);   // sustain 15
    push(c0, 5'h04, 8'h21);   // sawtooth, gate
    #3ms;                      // attack done
    cap_en = 1'b1;
    #8ms;
    cap_en = 1'b0;
    nsamp = aud.size();
    tb_check(nsamp >= 380 && nsamp <= 388, $sformatf("captured %0d samples in 8 ms, expected 384", nsamp));
    mn = aud[0]; mx = aud[0]; mean = 0.0;
    foreach (aud[i]) begin
      if (aud[i] < mn) mn = aud[i];
      if (aud[i] > mx) mx = aud[i];
      mean += real'(aud[i]);
    end
    mean = mean / real'(nsamp);
    tb_check(mx - mn > 1000, $sformatf("stream non-constant: min %0d max %0d", mn, mx));
    tb_check(mx <= 32767 && mn >= -32768, "stream inside s16");
    for (k = 1; k < nsamp; k++) if (real'(aud[k-1]) < mean && real'(aud[k]) >= mean) xing.push_back(k);
    tb_check(xing.size() >= 6, $sformatf("rising mean crossings: %0d", xing.size()));
    if (xing.size() >= 2) begin
      period = real'(xing[xing.size()-1] - xing[0]) / real'(xing.size() - 1);   // samples
      $display("INFO: stream min %0d max %0d mean %0.1f, %0d crossings, period %0.2f samples = %0.1f Hz",
               mn, mx, mean, xing.size(), period, 48000.0 / period);
      tb_check(48000.0 / period > 950.0 && 48000.0 / period < 1050.0, $sformatf("stream frequency %0.1f Hz, expected 1000 +-5 %%", 48000.0 / period));
    end
    if (!a_done) @(posedge a_done);

    // E. FIFO overflow.
    expect_reg(SID_STATUS_OFS, '1, 32'h0, "STATUS clean before the fill");
    now_cycle(c0);
    wr_reg(SID_WTIME_OFS, c0 + 32'h4000_0000);       // far in the future: never due
    for (k = 0; k < SID_FIFO_DEPTH; k++) wr_reg(SID_WDATA_OFS, {19'd0, 5'h1D, 8'hEE});
    expect_reg(SID_STATUS_OFS, '1, 32'(SID_FIFO_DEPTH) << SID_STATUS_LEVEL_LSB | S_FULL, "512 pushes: level 512, FULL, no overflow");
    u_dut.sim_expect_overflow = 1'b1;
    for (k = 0; k < 3; k++) wr_reg(SID_WDATA_OFS, {19'd0, 5'h1D, 8'hEE});
    expect_reg(SID_STATUS_OFS, '1, 32'(SID_FIFO_DEPTH) << SID_STATUS_LEVEL_LSB | S_FULL | S_OVF, "overflow set, level saturated at 512");
    wr_reg(SID_STATUS_OFS, S_OVF);
    expect_reg(SID_STATUS_OFS, '1, 32'(SID_FIFO_DEPTH) << SID_STATUS_LEVEL_LSB | S_FULL, "W1C clears OVERFLOW, level kept");
    wr_reg(SID_WDATA_OFS, {19'd0, 5'h1D, 8'hEE});
    expect_reg(SID_STATUS_OFS, S_OVF, S_OVF, "overflow set again");
    u_dut.sim_expect_overflow = 1'b0;

    // F. RESET clears CYCLE, FIFO and OVERFLOW; the queued writes never play.
    wr_reg(SID_CTRL_OFS, C_RUN | C_RESET);
    repeat (20) @(posedge cpu_clk);
    expect_reg(SID_STATUS_OFS, '1, 32'h0, "RESET: FIFO empty, OVERFLOW clear");
    expect_reg(SID_CYCLE_OFS, '1, 32'h0, "RESET: CYCLE 0");
    wr_reg(SID_WDATA_OFS, {19'd0, 5'h1D, 8'hEE});
    expect_reg(SID_STATUS_OFS, '1, 32'h0, "push during RESET dropped");
    wr_reg(SID_CTRL_OFS, C_RUN);
    wait_cycles(100);
    tb_check(find_wr(5'h1D, 8'hEE) < 0, "writes queued before RESET were never played");
    now_cycle(c0);
    tb_check(c0 >= 95 && c0 <= 105, $sformatf("CYCLE counts again after RESET: %0d", c0));
    push(c0 + 10, 5'h1F, 8'h77);
    wait_cycles(15);
    tb_check(find_wr(5'h1F, 8'h77) >= 0, "write after RESET plays");

    tb_check(wr_landed >= 10 && wr_landed == wr_seen, $sformatf("every write latched by the core: %0d of %0d", wr_landed, wr_seen));
    tb_verdict("tb_sid_player");
  end

  initial begin
    #60ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_sid_player");
  end

endmodule
