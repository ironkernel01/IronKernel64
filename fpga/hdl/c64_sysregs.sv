// -----------------------------------------------------------------------------
// File: c64_sysregs.sv
// Purpose: per-core system registers: identity (magic, build ID, build
//   flags), clock/calibration status, this core's LED byte and a scratch
//   word. c64_top instantiates one per MicroBlaze V core.
// Overview:
//   * Registers (AXI4-Lite through rtlnet_axil_slave, REG_ADDR_W-bit address;
//     offsets and bits are c64_pkg SYS_*). Undefined offsets read 0 and
//     ignore writes; writes to read-only registers are ignored.
//       SYS_MAGIC       RO SYS_MAGIC_VALUE ("IK64")
//       SYS_BUILD_ID    RO BUILD_ID (git commit hash, first 8 hex digits)
//       SYS_BUILD_FLAGS RO [FLAGS_DIRTY_BIT] BUILD_DIRTY (tree had
//                          uncommitted changes), [FLAGS_CORE_LSB +: 8]
//                          CORE_INDEX (0 = "C64" core, 1 = "1541" core)
//       SYS_CLK_STATUS  RO clk_status, one bit per SYS_CLK_*_BIT, upper
//                          bits 0
//       SYS_LED         RW [7:0] drives led (reset 0)
//       SYS_SCRATCH     RW 32-bit scratch (reset 0)
//   * clk_status contract: every bit is a level that c64_top has ALREADY
//     brought into cpu_clk: an rtlnet_sync chain per bit for any signal born
//     in another clock domain or at a pin (MMCM locked outputs, MIG
//     init_calib_complete, HDMI HPD, Ethernet link). This module registers
//     the bus once more and adds no synchronizer; the bits are independent
//     levels and are read as such (no multi-bit coherence is implied).
//   * led is a cpu_clk register; c64_top maps it onto the board LEDs.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk (100 MHz) only; cpu_resetn is synchronous to it, active low.
// -----------------------------------------------------------------------------
module c64_sysregs #(
  parameter logic [31:0] BUILD_ID    = 32'h0000_0000, // git commit hash (8 hex digits), from the build script
  parameter bit          BUILD_DIRTY = 1'b0,          // 1: built from a tree with uncommitted changes
  parameter logic [7:0]  CORE_INDEX  = 8'd0           // 0: core 0 ("C64"), 1: core 1 ("1541")
)(
  // cpu_clk domain: CPU/AXI clock and its synchronous active-low reset.
  input  logic                                       cpu_clk,
  input  logic                                       cpu_resetn,

  // AXI4-Lite register slave, cpu_clk domain, 32-bit data, REG_ADDR_W-bit
  // byte address (64 KiB window); one outstanding transaction, all OKAY.
  input  logic [c64_pkg::REG_ADDR_W-1:0]             s_axi_awaddr,
  input  logic                                       s_axi_awvalid,
  output logic                                       s_axi_awready,
  input  logic [31:0]                                s_axi_wdata,
  input  logic [3:0]                                 s_axi_wstrb,
  input  logic                                       s_axi_wvalid,
  output logic                                       s_axi_wready,
  output logic [1:0]                                 s_axi_bresp,
  output logic                                       s_axi_bvalid,
  input  logic                                       s_axi_bready,
  input  logic [c64_pkg::REG_ADDR_W-1:0]             s_axi_araddr,
  input  logic                                       s_axi_arvalid,
  output logic                                       s_axi_arready,
  output logic [31:0]                                s_axi_rdata,
  output logic [1:0]                                 s_axi_rresp,
  output logic                                       s_axi_rvalid,
  input  logic                                       s_axi_rready,

  // Clock and calibration status levels, ALREADY synchronized to cpu_clk by
  // c64_top; bit n = c64_pkg SYS_CLK_*_BIT n (pixel MMCM locked, DDR3
  // calibrated, audio MMCM locked, HDMI HPD, Ethernet link). Active high.
  input  logic [c64_pkg::SYS_CLK_ETH_LINK_BIT:0]     clk_status,

  // This core's LED byte, cpu_clk register, 1 = LED on; c64_top maps it to
  // the board LEDs.
  output logic [7:0]                                 led
);

  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Register layout constants.
  // ---------------------------------------------------------------------------
  localparam int ADDR_W          = REG_ADDR_W;
  localparam int CLK_STATUS_W    = SYS_CLK_ETH_LINK_BIT + 1;   // highest defined status bit + 1
  localparam int LED_W           = 8;                          // SYS_LED is one byte
  localparam int FLAGS_DIRTY_BIT = 0;                          // SYS_BUILD_FLAGS bit 0
  localparam int FLAGS_CORE_LSB  = 8;                          // SYS_BUILD_FLAGS bits 15:8

  localparam logic [31:0] BUILD_FLAGS_VALUE = (32'(BUILD_DIRTY) << FLAGS_DIRTY_BIT) |
                                              (32'(CORE_INDEX)  << FLAGS_CORE_LSB);

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic                    reg_wr_en;
  logic [ADDR_W-1:0]       reg_wr_addr;
  logic [31:0]             reg_wr_data;
  logic                    reg_rd_en;
  logic [ADDR_W-1:0]       reg_rd_addr;
  logic [31:0]             reg_rd_data;

  logic [CLK_STATUS_W-1:0] clk_status_q;   // registered copy of the synchronized inputs
  logic [31:0]             scratch;

  // ---------------------------------------------------------------------------
  // AXI4-Lite to register strobes; read data is due one clock after reg_rd_en.
  // ---------------------------------------------------------------------------
  rtlnet_axil_slave #(.ADDR_W(ADDR_W)) u_axil (
    .s_axi_aclk    (cpu_clk),
    .s_axi_aresetn (cpu_resetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Writable registers and the status input register.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      led          <= '0;
      scratch      <= '0;
      clk_status_q <= '0;
    end else begin
      clk_status_q <= clk_status;
      if (reg_wr_en && (reg_wr_addr == SYS_LED_OFS))     led     <= reg_wr_data[LED_W-1:0];
      if (reg_wr_en && (reg_wr_addr == SYS_SCRATCH_OFS)) scratch <= reg_wr_data;
    end
  end

  // ---------------------------------------------------------------------------
  // Registered read mux.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        SYS_MAGIC_OFS:       reg_rd_data <= SYS_MAGIC_VALUE;
        SYS_BUILD_ID_OFS:    reg_rd_data <= BUILD_ID;
        SYS_BUILD_FLAGS_OFS: reg_rd_data <= BUILD_FLAGS_VALUE;
        SYS_CLK_STATUS_OFS:  reg_rd_data <= 32'(clk_status_q);
        SYS_LED_OFS:         reg_rd_data <= 32'(led);
        SYS_SCRATCH_OFS:     reg_rd_data <= scratch;
        default:             reg_rd_data <= '0;
      endcase
    end
  end

endmodule
