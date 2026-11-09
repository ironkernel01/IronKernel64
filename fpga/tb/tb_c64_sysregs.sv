// -----------------------------------------------------------------------------
// File: tb_c64_sysregs.sv
// Purpose: self-checking bench for c64_sysregs: every register read, every
//   writable register written and read back, read-only registers proven
//   unwritable, clk_status and led ports checked against the registers.
// Cases:
//   1. Reset values: MAGIC, BUILD_ID, BUILD_FLAGS from the parameters; LED and
//      SCRATCH 0; led port 0.
//   2. SYS_CLK_STATUS follows every clk_status bit pattern (walking ones and
//      all ones), upper bits read 0.
//   3. SYS_LED: byte written, read back, led port follows; upper bits of the
//      write are dropped.
//   4. SYS_SCRATCH: 64 random values written and read back.
//   5. Writes to every read-only register and to an undefined offset change
//      nothing; undefined offsets read 0.
//   6. A partial write (wstrb != 4'hF) to SCRATCH and LED changes nothing.
//   7. A second instance with other parameters (core 1, clean tree) reads its
//      own BUILD_FLAGS and BUILD_ID.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_c64_sysregs;

  import rtlnet_tb_pkg::*;
  import c64_pkg::*;

  localparam int          AW           = REG_ADDR_W;
  localparam int          CLK_STATUS_W = SYS_CLK_ETH_LINK_BIT + 1;
  localparam logic [31:0] ID0          = 32'hA5C3_0F17;
  localparam logic [31:0] ID1          = 32'h1234_ABCD;
  localparam logic [15:0] UNDEF_OFS    = 16'h0100;

  logic cpu_clk = 1'b0;
  logic arstn   = 1'b0;
  logic cpu_resetn;

  always #5.0 cpu_clk = ~cpu_clk;           // 100 MHz

  rtlnet_reset_sync u_rst (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));

  logic [CLK_STATUS_W-1:0] clk_status = '0;
  logic [7:0]              led_port [2];

  // ---------------------------------------------------------------------------
  // Two instances (core 0 dirty, core 1 clean), one bench master each.
  // ---------------------------------------------------------------------------
  logic [AW-1:0] awaddr  [2];
  logic [AW-1:0] araddr  [2];
  logic [31:0]   wdata   [2];
  logic [31:0]   rdata   [2];
  logic [3:0]    wstrb   [2];
  logic [1:0]    bresp   [2];
  logic [1:0]    rresp   [2];
  logic          awvalid [2];
  logic          awready [2];
  logic          wvalid  [2];
  logic          wready  [2];
  logic          bvalid  [2];
  logic          bready  [2];
  logic          arvalid [2];
  logic          arready [2];
  logic          rvalid  [2];
  logic          rready  [2];

  genvar gi;
  generate
    for (gi = 0; gi < 2; gi++) begin : g_core
      rtlnet_tb_axil_master #(.ADDR_W(AW)) u_mst (
        .aclk(cpu_clk), .awaddr(awaddr[gi]), .awvalid(awvalid[gi]), .awready(awready[gi]), .wdata(wdata[gi]),
        .wstrb(wstrb[gi]), .wvalid(wvalid[gi]), .wready(wready[gi]), .bresp(bresp[gi]), .bvalid(bvalid[gi]),
        .bready(bready[gi]), .araddr(araddr[gi]), .arvalid(arvalid[gi]), .arready(arready[gi]), .rdata(rdata[gi]),
        .rresp(rresp[gi]), .rvalid(rvalid[gi]), .rready(rready[gi]));

      c64_sysregs #(
        .BUILD_ID    ((gi == 0) ? ID0 : ID1),
        .BUILD_DIRTY ((gi == 0) ? 1'b1 : 1'b0),
        .CORE_INDEX  (8'(gi))
      ) u_dut (
        .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
        .s_axi_awaddr(awaddr[gi]), .s_axi_awvalid(awvalid[gi]), .s_axi_awready(awready[gi]),
        .s_axi_wdata(wdata[gi]), .s_axi_wstrb(wstrb[gi]), .s_axi_wvalid(wvalid[gi]), .s_axi_wready(wready[gi]),
        .s_axi_bresp(bresp[gi]), .s_axi_bvalid(bvalid[gi]), .s_axi_bready(bready[gi]),
        .s_axi_araddr(araddr[gi]), .s_axi_arvalid(arvalid[gi]), .s_axi_arready(arready[gi]),
        .s_axi_rdata(rdata[gi]), .s_axi_rresp(rresp[gi]), .s_axi_rvalid(rvalid[gi]), .s_axi_rready(rready[gi]),
        .clk_status(clk_status),
        .led(led_port[gi]));
    end
  endgenerate

  // Read one register of core 0 and compare.
  task automatic expect0(input logic [15:0] ofs, input logic [31:0] exp, input string what);
    logic [31:0] r;
    g_core[0].u_mst.rd(AW'(ofs), r);
    tb_check(r === exp, $sformatf("%s: read 0x%08x, expected 0x%08x", what, r, exp));
  endtask

  initial begin : main
    logic [31:0] r;
    logic [31:0] v;
    logic [1:0]  resp;
    int unsigned rng;
    logic [15:0] ro_ofs [4];
    logic [7:0]  led_last;

    rng = 32'h1357_9BDF;
    #100 arstn = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // Case 1: reset values.
    expect0(SYS_MAGIC_OFS, SYS_MAGIC_VALUE, "MAGIC");
    expect0(SYS_BUILD_ID_OFS, ID0, "BUILD_ID core 0");
    expect0(SYS_BUILD_FLAGS_OFS, 32'h0000_0001, "BUILD_FLAGS core 0 (dirty, index 0)");
    expect0(SYS_LED_OFS, 32'h0, "LED reset");
    expect0(SYS_SCRATCH_OFS, 32'h0, "SCRATCH reset");
    tb_check(led_port[0] === 8'h00 && led_port[1] === 8'h00, "led ports reset");

    // Case 2: clock status, walking ones then all ones then zero.
    for (int b = 0; b < CLK_STATUS_W; b++) begin
      clk_status = CLK_STATUS_W'(1) << b;
      repeat (3) @(posedge cpu_clk);
      expect0(SYS_CLK_STATUS_OFS, 32'(clk_status), $sformatf("CLK_STATUS bit %0d", b));
    end
    clk_status = '1;
    repeat (3) @(posedge cpu_clk);
    expect0(SYS_CLK_STATUS_OFS, 32'(clk_status), "CLK_STATUS all ones");
    clk_status = '0;
    repeat (3) @(posedge cpu_clk);
    expect0(SYS_CLK_STATUS_OFS, 32'h0, "CLK_STATUS zero");

    // Case 3: LED byte, upper bits dropped, port follows.
    for (int k = 0; k < 8; k++) begin
      rng = rng * 1664525 + 1013904223;
      g_core[0].u_mst.wr(AW'(SYS_LED_OFS), rng);
      expect0(SYS_LED_OFS, {24'h0, rng[7:0]}, "LED read-back");
      tb_check(led_port[0] === rng[7:0], $sformatf("led port 0x%02x, expected 0x%02x", led_port[0], rng[7:0]));
    end
    led_last = rng[7:0];

    // Case 4: scratch.
    for (int k = 0; k < 64; k++) begin
      rng = rng * 1664525 + 1013904223;
      g_core[0].u_mst.wr(AW'(SYS_SCRATCH_OFS), rng);
      expect0(SYS_SCRATCH_OFS, rng, "SCRATCH read-back");
    end
    v = rng;

    // Case 5: read-only registers and an undefined offset ignore writes.
    ro_ofs[0] = SYS_MAGIC_OFS;
    ro_ofs[1] = SYS_BUILD_ID_OFS;
    ro_ofs[2] = SYS_BUILD_FLAGS_OFS;
    ro_ofs[3] = SYS_CLK_STATUS_OFS;
    for (int k = 0; k < 4; k++) g_core[0].u_mst.wr(AW'(ro_ofs[k]), 32'hFFFF_FFFF);
    g_core[0].u_mst.wr(AW'(UNDEF_OFS), 32'hFFFF_FFFF);
    expect0(SYS_MAGIC_OFS, SYS_MAGIC_VALUE, "MAGIC after write");
    expect0(SYS_BUILD_ID_OFS, ID0, "BUILD_ID after write");
    expect0(SYS_BUILD_FLAGS_OFS, 32'h0000_0001, "BUILD_FLAGS after write");
    expect0(SYS_CLK_STATUS_OFS, 32'h0, "CLK_STATUS after write");
    expect0(UNDEF_OFS, 32'h0, "undefined offset");
    expect0(SYS_SCRATCH_OFS, v, "SCRATCH after read-only writes");

    // Case 6: partial writes are ignored.
    g_core[0].u_mst.write32(AW'(SYS_SCRATCH_OFS), ~v, 4'h1, resp);
    tb_check(resp == 2'b00, "partial write response");
    g_core[0].u_mst.write32(AW'(SYS_LED_OFS), 32'h0000_005A, 4'h1, resp);
    expect0(SYS_SCRATCH_OFS, v, "SCRATCH after partial write");
    expect0(SYS_LED_OFS, {24'h0, led_last}, "LED after partial write");
    tb_check(led_port[0] === led_last, "led port after partial write");

    // Case 7: second instance.
    g_core[1].u_mst.rd(AW'(SYS_BUILD_FLAGS_OFS), r);
    tb_check(r === 32'h0000_0100, $sformatf("BUILD_FLAGS core 1 = 0x%08x, expected 0x00000100", r));
    g_core[1].u_mst.rd(AW'(SYS_BUILD_ID_OFS), r);
    tb_check(r === ID1, $sformatf("BUILD_ID core 1 = 0x%08x", r));
    g_core[1].u_mst.rd(AW'(SYS_MAGIC_OFS), r);
    tb_check(r === SYS_MAGIC_VALUE, "MAGIC core 1");
    g_core[1].u_mst.wr(AW'(SYS_LED_OFS), 32'h0000_00C3);
    @(posedge cpu_clk);
    tb_check(led_port[1] === 8'hC3, $sformatf("core 1 led port 0x%02x, expected 0xc3", led_port[1]));
    tb_check(led_port[0] === led_last, "core 0 led port unchanged by core 1 write");
    expect0(SYS_LED_OFS, {24'h0, led_last}, "core 0 LED unchanged by core 1 write");

    tb_verdict("tb_c64_sysregs");
  end

  initial begin
    #5ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_c64_sysregs");
  end

endmodule
