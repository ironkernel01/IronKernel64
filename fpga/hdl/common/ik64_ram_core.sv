// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_ram_core.sv
// Purpose: simple-dual-port RAM: one write port (wr_clk), one read port
//   (rd_clk), common or independent clocks, synchronous read.
// Behaviors:
//   * Depth 2**ADDR_W words of DATA_W bits. The array is not reset.
//   * Write: wr_en high writes wr_data at wr_addr on the wr_clk edge.
//   * Read: rd_data shows the word READ_LATENCY (1 or 2) rd_clk edges after an
//     edge with rd_en high and holds until the next read. rd_resetn
//     (synchronous, active low) clears the output register(s) to zero only.
//     With READ_LATENCY = 2 the second register loads one clock after each
//     read, so after reset the output stays zero until a new read completes.
//   * Read and write of the same address in the same clock (block style,
//     independent clocks): the old word is read; callers must not rely on it.
//   * CLOCKING "COMMON" uses wr_clk for both ports (rd_clk is ignored).
//   * RAM_STYLE "block" or "distributed" selects the primitive.
//   * Implementation: AMD xpm_memory_sdpram (UG974) by default (synthesis and
//     simulation need the Vivado `xpm` library); defining IK64_RAM_BEHAVIORAL
//     selects an inferred-array model with the same behavior for simulators
//     without XPM.
//   * Parameter errors stop elaboration ($fatal).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: wr_clk (write port); rd_clk (read port; equals wr_clk for COMMON).
// -----------------------------------------------------------------------------
module ik64_ram_core #(
  parameter string RAM_STYLE    = "block",        // "block" | "distributed"
  parameter string CLOCKING     = "INDEPENDENT",  // "COMMON" | "INDEPENDENT"
  parameter int    DATA_W       = 64,             // word width in bits
  parameter int    ADDR_W       = 9,              // depth = 2**ADDR_W words
  parameter int    READ_LATENCY = 1               // output registers, 1 or 2
)(
  input  logic              wr_clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [DATA_W-1:0] wr_data,

  input  logic              rd_clk,
  input  logic              rd_resetn,
  input  logic              rd_en,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [DATA_W-1:0] rd_data
);

  localparam int DEPTH = 1 << ADDR_W;

  if (READ_LATENCY < 1 || READ_LATENCY > 2) begin : g_bad_latency
    $fatal(1, "ik64_ram_core: READ_LATENCY=%0d, must be 1 or 2", READ_LATENCY);
  end
  if (RAM_STYLE != "block" && RAM_STYLE != "distributed") begin : g_bad_style
    $fatal(1, "ik64_ram_core: RAM_STYLE=%s, must be \"block\" or \"distributed\"", RAM_STYLE);
  end
  if (CLOCKING != "COMMON" && CLOCKING != "INDEPENDENT") begin : g_bad_clocking
    $fatal(1, "ik64_ram_core: CLOCKING=%s, must be \"COMMON\" or \"INDEPENDENT\"", CLOCKING);
  end

  logic rclk;
  assign rclk = (CLOCKING == "COMMON") ? wr_clk : rd_clk;

  // Second-stage load enable: the read enable delayed one clock.
  logic regce2;
  if (READ_LATENCY == 2) begin : g_regce
    logic rd_en_d;
    always_ff @(posedge rclk) begin
      if (!rd_resetn) rd_en_d <= 1'b0;
      else            rd_en_d <= rd_en;
    end
    assign regce2 = rd_en_d;
  end else begin : g_no_regce
    assign regce2 = 1'b1;
  end

`ifndef IK64_RAM_BEHAVIORAL
  // XPM takes Verilog string literals (packed vectors).
  localparam [8*20-1:0] XPM_PRIMITIVE  = (RAM_STYLE == "distributed") ? "distributed" : "block";
  localparam [8*20-1:0] XPM_CLOCKING   = (CLOCKING == "COMMON") ? "common_clock" : "independent_clock";
  localparam [8*20-1:0] XPM_WRITE_MODE = (RAM_STYLE == "distributed") ? "read_first" : "no_change";

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A            (ADDR_W),
    .ADDR_WIDTH_B            (ADDR_W),
    .AUTO_SLEEP_TIME         (0),
    .BYTE_WRITE_WIDTH_A      (DATA_W),
    .CASCADE_HEIGHT          (0),
    .CLOCKING_MODE           (XPM_CLOCKING),
    .ECC_MODE                ("no_ecc"),
    .MEMORY_INIT_FILE        ("none"),
    .MEMORY_INIT_PARAM       ("0"),
    .MEMORY_OPTIMIZATION     ("true"),
    .MEMORY_PRIMITIVE        (XPM_PRIMITIVE),
    .MEMORY_SIZE             (DATA_W * DEPTH),
    .MESSAGE_CONTROL         (0),
    .READ_DATA_WIDTH_B       (DATA_W),
    .READ_LATENCY_B          (READ_LATENCY),
    .READ_RESET_VALUE_B      ("0"),
    .RST_MODE_A              ("SYNC"),
    .RST_MODE_B              ("SYNC"),
    .SIM_ASSERT_CHK          (0),
    .USE_EMBEDDED_CONSTRAINT (0),
    .USE_MEM_INIT            (0),
    .WAKEUP_TIME             ("disable_sleep"),
    .WRITE_DATA_WIDTH_A      (DATA_W),
    .WRITE_MODE_B            (XPM_WRITE_MODE)
  ) u_xpm (
    .clka           (wr_clk),
    .ena            (wr_en),
    .wea            (wr_en),
    .addra          (wr_addr),
    .dina           (wr_data),
    .injectsbiterra (1'b0),
    .injectdbiterra (1'b0),
    .clkb           (rclk),
    .rstb           (!rd_resetn),
    .enb            (rd_en),
    .regceb         (regce2),
    .addrb          (rd_addr),
    .doutb          (rd_data),
    .sleep          (1'b0),
    .sbiterrb       (),
    .dbiterrb       ()
  );
`else
  (* ram_style = RAM_STYLE *) logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [DATA_W-1:0] rd_q1;
  logic [DATA_W-1:0] rd_q2;

  always_ff @(posedge wr_clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end

  always_ff @(posedge rclk) begin
    if (!rd_resetn) begin
      rd_q1 <= '0;
      rd_q2 <= '0;
    end else begin
      if (rd_en)  rd_q1 <= mem[rd_addr];
      if (regce2) rd_q2 <= rd_q1;
    end
  end

  assign rd_data = (READ_LATENCY == 2) ? rd_q2 : rd_q1;
`endif

endmodule
