// -----------------------------------------------------------------------------
// File: c64_oled.sv
// Purpose: driver for the Nexys Video 128x32 monochrome OLED (Univision
//   UG-2832HSWEG04, Solomon Systech SSD1306 controller, 4-wire SPI, write
//   only). The core runs the panel's power-up and power-down sequences and
//   refreshes the panel continuously from a 2 KiB framebuffer that core 0
//   writes over AXI4-Lite. Every page of the framebuffer has a hardware
//   horizontal scroll offset, so a text line scrolls with one register write.
// Overview:
//   * Board evidence (Digilent Nexys Video Reference Manual, section 15 OLED,
//     PDF pages 26-27; Nexys Video schematic, sheet 1 "OLED Display, PMOD,
//     General I/O", PDF page 1):
//       - RM p.26 Table 11 lists "VBAT# Power enable for internal power
//         supply, active-low, P20" and "VDD# Power enable for digital power,
//         active-low, V22"; RES# active-low U21; CS# hard-wired to ground;
//         D/C# W22 (high = data, low = command); SCLK W21; SDIN Y22.
//       - RM p.27 start-up sequence: 1 power up VDD by pulling OLED_VDD low,
//         wait 1 ms; 2 pulse RES# low for at least 3 us; 3 send the
//         initialization commands; 4 power up VBAT by pulling OLED_VBAT low,
//         wait 100 ms; 5 clear the screen by writing zero to the display
//         buffer; 6 send Display On (0xAF). The RM gives no power-down
//         sequence; this core uses the SSD1306 data sheet order (Display Off
//         0xAE, VBAT off, wait 100 ms for VBAT to discharge, VDD off).
//       - Schematic sheet 1: OLED_VBAT and OLED_VDD each drive the gate of a
//         P-channel MOSFET (Q1, Q2) whose source is VCC3V3 and whose drain
//         feeds the panel's VBAT / VDD pins, with a 10 K pull-up (R41, R46)
//         from the gate to VCC3V3. Gate high (pull-up, FPGA pin high or
//         tri-stated) = switch off; FPGA pin low = switch on. Both are
//         therefore active-low enables, and oled_vdd / oled_vbat are driven
//         HIGH when off.
//       - RM p.27 Table 12 lists the vendor example commands for a 128x32
//         panel with column inversion off (0xA0) and COM scan normal (0xC0)
//         and COM pins 0x00; this core uses the values requested by the
//         project (0xA1, 0xC8, 0xDA 0x02, parameters SEG_REMAP and
//         COM_REVERSE; VERIFY orientation on the board).
//   * Registers (AXI4-Lite through rtlnet_axil_slave, OLED_ADDR_W = 12 address
//     bits, a 4 KiB part of the 64 KiB window slot; offsets, bits and the
//     geometry are c64_pkg OLED_*). Undefined offsets read 0 and ignore
//     writes. Register writes need a full-word strobe (wstrb = 4'hF, RTLNet
//     rule); framebuffer writes honour wstrb per byte (see below).
//       ID        0x000 RO 32'h4F4C_4544.
//       VERSION   0x004 RO 32'h0001_0000.
//       CTRL      0x008 RW, reset 0. [0] POWER: 0->1 runs the power-up
//                   sequence and then refreshes continuously; 1->0 runs the
//                   power-down sequence. [1] INVERT: 0xA6 / 0xA7, sent at the
//                   next frame start when it changed.
//       STATUS    0x00C RO. [1:0] STATE 0 OFF, 1 POWERING_UP, 2 RUNNING,
//                   3 POWERING_DOWN; [31:16] FRAME, the number of frames
//                   started while RUNNING (wraps).
//       CONTRAST  0x010 RW [7:0], reset 8'h7F; sent as 0x81, value at the next
//                   frame start when it changed.
//       SCROLL0..3 0x020..0x02C RW [8:0], reset 0: column offset 0..511 of
//                   page 0..3. The display column x of page p shows virtual
//                   column (x + SCROLLp) mod 512. All four are latched together
//                   (with INVERT and CONTRAST) at frame start, so one frame
//                   never mixes two scroll positions.
//       FB        0x800..0xFFF RW, 512 words. Word = page*128 + (vcol >> 2),
//                   byte lane = vcol & 3 (lane 0 = bits [7:0]); each byte is
//                   one 8-pixel vertical column in SSD1306 page format (bit 0
//                   = top row of the page). Readable.
//     A POWER clear that arrives while the power-up sequence runs takes effect
//     when that sequence completes (about 105 ms at the default delays), and a
//     POWER set during the power-down sequence takes effect when the panel is
//     off.
//   * Framebuffer storage: four byte-lane arrays of 512 x 8 in DISTRIBUTED RAM
//     (no block RAM), each with one write port (CPU) and two asynchronous read
//     ports (the CPU read-back shares the write address, the refresh engine
//     has its own address register). The write path is registered: the AXI
//     write handshake (seen on the slave's own ports so that wstrb is
//     available) is captured and applied one clock later.
//   * SPI: mode 0, MSB first, no chip select (tied low on the board). SCLK =
//     cpu_clk / SPI_DIV (6.25 MHz), produced by a divider as registered
//     outputs (no derived clock). One byte = SPI_DIV clocks of lead-in (D/C and
//     SDIN stable, SCLK low), eight bit windows (SCLK rises in the middle of a
//     window, SDIN changes on the falling edge) and SPI_DIV clocks of trail,
//     so D/C and data meet the SSD1306 address and data setup / hold times.
//   * Refresh: every 1 / FRAME_HZ the engine latches SCROLL0..3, INVERT and
//     CONTRAST, sends 0x81 value and / or 0xA6 / 0xA7 only if they changed,
//     then 0x21 0x00 0x7F, 0x22 0x00 0x03 and 512 data bytes (horizontal
//     addressing, page 0 first). A frame takes about 0.8 ms; the rest of the
//     period is idle. The first frame after power-up is all zeros (RM step 5)
//     and is sent before Display On.
//   * Power-up init commands (after VDD on and the reset pulse): 0xAE; 0xD5
//     0x80; 0xA8 0x1F; 0xD3 0x00; 0x40; 0x8D 0x14; 0x20 0x00; 0xA0|SEG_REMAP;
//     0xC0|(COM_REVERSE<<3); 0xDA 0x02; 0x81 contrast; 0xD9 0xF1; 0xDB 0x40;
//     0xA4; 0xA6|invert. Then VBAT on, wait VBAT_WAIT_US, the blank frame, 0xAF.
//   * FSM: one registered state (S_ localparams, default S_OFF). All delays
//     are named parameters in microseconds, converted with CPU_CLK_HZ; the
//     bench overrides them. oled_res, oled_vdd and oled_vbat reset to the safe
//     state (reset asserted, VDD off, VBAT off); oled_dc, oled_sclk and
//     oled_sdin reset low. All six outputs are registers.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk (CPU_CLK_HZ, 100 MHz on the Nexys Video) only; cpu_resetn is
//   synchronous to it, active low. The OLED pins are outputs with no timing
//   relationship to any clock beyond the SPI pattern above (constrained as slow
//   outputs in fpga/c64.xdc).
// -----------------------------------------------------------------------------
module c64_oled #(
  parameter int CPU_CLK_HZ         = c64_pkg::CPU_CLK_HZ, // cpu_clk frequency, Hz
  parameter int SPI_DIV            = 16,       // cpu_clk clocks per SCLK period (even, >= 4)
  parameter int FRAME_HZ           = 60,       // refresh rate
  parameter bit SEG_REMAP          = 1'b1,     // 1: command 0xA1 (segment remap), 0: 0xA0
  parameter bit COM_REVERSE        = 1'b1,     // 1: command 0xC8 (COM scan reversed), 0: 0xC0
  parameter int VDD_WAIT_US        = 1_000,    // VDD on to reset pulse (RM: 1 ms)
  parameter int RES_LOW_US         = 10,       // reset pulse width (RM: >= 3 us)
  parameter int RES_HIGH_US        = 10,       // reset release to first command
  parameter int VBAT_WAIT_US       = 100_000,  // VBAT on to display on (RM: 100 ms)
  parameter int VBAT_OFF_WAIT_US   = 100_000,  // VBAT off to VDD off (SSD1306: VBAT discharge)
  parameter int OFF_SETTLE_US      = 10_000    // VDD off to a possible new power-up
)(
  // cpu_clk domain: CPU/AXI clock and its synchronous active-low reset.
  input  logic                              cpu_clk,
  input  logic                              cpu_resetn,

  // AXI4-Lite register slave, cpu_clk domain, 32-bit data, OLED_ADDR_W-bit
  // byte address (4 KiB); one outstanding transaction, all OKAY.
  input  logic [c64_pkg::OLED_ADDR_W-1:0]   s_axi_awaddr,
  input  logic                              s_axi_awvalid,
  output logic                              s_axi_awready,
  input  logic [31:0]                       s_axi_wdata,
  input  logic [3:0]                        s_axi_wstrb,
  input  logic                              s_axi_wvalid,
  output logic                              s_axi_wready,
  output logic [1:0]                        s_axi_bresp,
  output logic                              s_axi_bvalid,
  input  logic                              s_axi_bready,
  input  logic [c64_pkg::OLED_ADDR_W-1:0]   s_axi_araddr,
  input  logic                              s_axi_arvalid,
  output logic                              s_axi_arready,
  output logic [31:0]                       s_axi_rdata,
  output logic [1:0]                        s_axi_rresp,
  output logic                              s_axi_rvalid,
  input  logic                              s_axi_rready,

  // OLED pins (Nexys Video, all LVCMOS33), registered outputs.
  output logic                              oled_dc,    // W22, high = data, low = command
  output logic                              oled_res,   // U21, active-low reset
  output logic                              oled_sclk,  // W21, SPI clock, idle low
  output logic                              oled_sdin,  // Y22, SPI data
  output logic                              oled_vbat,  // P20, active-low VBAT switch enable (high = off)
  output logic                              oled_vdd    // V22, active-low VDD switch enable (high = off)
);

  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Constants.
  // ---------------------------------------------------------------------------
  localparam int ADDR_W      = OLED_ADDR_W;
  localparam int CLK_PER_US  = CPU_CLK_HZ / 1_000_000;
  localparam int DLY_VDD     = VDD_WAIT_US      * CLK_PER_US;
  localparam int DLY_RES_LOW = RES_LOW_US       * CLK_PER_US;
  localparam int DLY_RES_HI  = RES_HIGH_US      * CLK_PER_US;
  localparam int DLY_VBAT    = VBAT_WAIT_US     * CLK_PER_US;
  localparam int DLY_VBAT_OF = VBAT_OFF_WAIT_US * CLK_PER_US;
  localparam int DLY_SETTLE  = OFF_SETTLE_US    * CLK_PER_US;
  localparam int DLY_MAX_A   = (DLY_VBAT > DLY_VBAT_OF) ? DLY_VBAT : DLY_VBAT_OF;
  localparam int DLY_MAX_B   = (DLY_VDD > DLY_SETTLE) ? DLY_VDD : DLY_SETTLE;
  localparam int DLY_MAX_C   = (DLY_RES_LOW > DLY_RES_HI) ? DLY_RES_LOW : DLY_RES_HI;
  localparam int DLY_MAX_AB  = (DLY_MAX_A > DLY_MAX_B) ? DLY_MAX_A : DLY_MAX_B;
  localparam int DLY_MAX     = (DLY_MAX_AB > DLY_MAX_C) ? DLY_MAX_AB : DLY_MAX_C;
  localparam int DLY_W       = $clog2(DLY_MAX + 2);
  localparam int FRAME_CLKS  = CPU_CLK_HZ / FRAME_HZ;
  localparam int FRAME_W     = $clog2(FRAME_CLKS + 1);
  localparam int SPI_HALF    = SPI_DIV / 2;
  localparam int DIV_W       = $clog2(SPI_DIV);

  generate
    if (CLK_PER_US < 1 || DLY_VDD < 1 || DLY_RES_LOW < 1 || DLY_RES_HI < 1 || DLY_VBAT < 1 ||
        DLY_VBAT_OF < 1 || DLY_SETTLE < 1) begin : g_bad_delay
      $fatal(1, "c64_oled: delays must be at least one cpu_clk period");
    end
    if (SPI_DIV < 4 || (SPI_DIV % 2) != 0) begin : g_bad_div
      $fatal(1, "c64_oled: SPI_DIV=%0d must be even and >= 4", SPI_DIV);
    end
    if (FRAME_CLKS < 2) begin : g_bad_frame
      $fatal(1, "c64_oled: FRAME_HZ=%0d too high for CPU_CLK_HZ", FRAME_HZ);
    end
  endgenerate

  // Command list: one flat byte sequence with named segment entry points; the
  // segment end is detected from the next index (see S_CMD_WAIT).
  localparam int IDX_HDR  = 0;    // 0x21 0x00 0x7F 0x22 0x00 0x03
  localparam int IDX_ON   = 6;    // 0xAF
  localparam int IDX_OFF  = 7;    // 0xAE
  localparam int IDX_CTR  = 8;    // 0x81 contrast
  localparam int IDX_INV  = 10;   // 0xA6 / 0xA7
  localparam int IDX_INIT = 11;   // 24 init bytes
  localparam int IDX_END  = IDX_INIT + 24;
  localparam int IDX_W    = 6;

  // FSM states.
  localparam logic [3:0] S_OFF          = 4'd0;   // panel unpowered, waiting for POWER
  localparam logic [3:0] S_VDD_WAIT     = 4'd1;   // VDD on, wait before the reset pulse
  localparam logic [3:0] S_RES_LOW      = 4'd2;   // reset pulse
  localparam logic [3:0] S_RES_HIGH     = 4'd3;   // wait after the reset pulse
  localparam logic [3:0] S_CMD_TX       = 4'd4;   // start one command byte
  localparam logic [3:0] S_CMD_WAIT     = 4'd5;   // byte done, select the next step
  localparam logic [3:0] S_VBAT_WAIT    = 4'd6;   // VBAT on, wait for it to stabilize
  localparam logic [3:0] S_DATA_ADDR    = 4'd7;   // address of the next data byte
  localparam logic [3:0] S_DATA_RD      = 4'd8;   // capture the byte
  localparam logic [3:0] S_DATA_TX      = 4'd9;   // start one data byte
  localparam logic [3:0] S_DATA_WAIT    = 4'd10;  // byte done, advance
  localparam logic [3:0] S_RUN_IDLE     = 4'd11;  // display on, waiting for the next frame
  localparam logic [3:0] S_VBAT_OFF     = 4'd12;  // power-down: VBAT off, discharge wait
  localparam logic [3:0] S_VDD_OFF      = 4'd13;  // power-down: VDD off, settle wait

  // ---------------------------------------------------------------------------
  // Signals.
  // ---------------------------------------------------------------------------
  logic                reg_wr_en;           // slave write strobe (unused: see the write tap below)
  logic [ADDR_W-1:0]   reg_wr_addr;
  logic [31:0]         reg_wr_data;
  logic                reg_rd_en;
  logic [ADDR_W-1:0]   reg_rd_addr;
  logic [31:0]         reg_rd_data;

  // Captured write.
  logic                wr_pend;
  logic [ADDR_W-1:0]   wr_addr;
  logic [31:0]         wr_data;
  logic [3:0]          wr_strb;

  // Registers.
  logic                ctrl_power;
  logic                ctrl_invert;
  logic [7:0]          ctrl_contrast;
  logic [8:0]          ctrl_scroll [4];

  // Framebuffer.
  logic [8:0]          fb_addr;             // CPU port address (write, else read-back)
  logic [3:0]          fb_we;
  logic [31:0]         fb_cpu_q;            // CPU port read data (asynchronous)
  logic [31:0]         fb_eng_q;            // engine port read data (asynchronous)
  logic [8:0]          eng_addr;

  // Engine.
  logic [3:0]          state;
  logic [1:0]          st_status;           // STATUS.STATE
  logic [15:0]         frame_count;
  logic [DLY_W-1:0]    delay_cnt;
  logic [FRAME_W-1:0]  frame_timer;
  logic                frame_tick;
  logic [IDX_W-1:0]    cmd_idx;
  logic                blank;               // current frame is all zeros (power-up clear)
  logic [1:0]          pg;
  logic [6:0]          xc;
  logic [1:0]          lane;
  logic [7:0]          data_byte;
  logic [8:0]          scroll_lat [4];
  logic [7:0]          contrast_sent;
  logic                invert_sent;
  logic                inv_pend;

  // SPI shifter.
  logic                spi_start;
  logic [7:0]          spi_data;
  logic                spi_dc;
  logic                spi_busy;
  logic                spi_park;            // panel unpowered: drive SDIN and D/C low
  logic [DIV_W-1:0]    spi_div;
  logic [3:0]          spi_win;             // 0 lead-in, 1..8 bits, 9 trail
  logic [7:0]          spi_sh;

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
  // Write tap. rtlnet_axil_slave drops partial writes, but the framebuffer
  // needs wstrb, so this core captures the write itself in the clock where
  // both channels handshake (the master holds address, data and strobe stable
  // until then) and applies it one clock later. reg_wr_* are not used.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      wr_pend <= 1'b0;
      wr_addr <= '0;
      wr_data <= '0;
      wr_strb <= '0;
    end else begin
      wr_pend <= s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready;
      if (s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready) begin
        wr_addr <= s_axi_awaddr;
        wr_data <= s_axi_wdata;
        wr_strb <= s_axi_wstrb;
      end
    end
  end

  // Register file.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      ctrl_power    <= 1'b0;
      ctrl_invert   <= 1'b0;
      ctrl_contrast <= 8'(OLED_CONTRAST_RESET);
      for (int i = 0; i < 4; i++) ctrl_scroll[i] <= '0;
    end else if (wr_pend && !wr_addr[ADDR_W-1] && wr_strb == 4'hF) begin
      case (wr_addr)
        ADDR_W'(OLED_CTRL_OFS): begin
          ctrl_power  <= wr_data[OLED_CTRL_POWER_BIT];
          ctrl_invert <= wr_data[OLED_CTRL_INVERT_BIT];
        end
        ADDR_W'(OLED_CONTRAST_OFS): ctrl_contrast  <= wr_data[7:0];
        ADDR_W'(OLED_SCROLL0_OFS):  ctrl_scroll[0] <= wr_data[8:0];
        ADDR_W'(OLED_SCROLL1_OFS):  ctrl_scroll[1] <= wr_data[8:0];
        ADDR_W'(OLED_SCROLL2_OFS):  ctrl_scroll[2] <= wr_data[8:0];
        ADDR_W'(OLED_SCROLL3_OFS):  ctrl_scroll[3] <= wr_data[8:0];
        default: ;
      endcase
    end
  end

  // Read mux, registered: data is presented the clock after reg_rd_en.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      if (reg_rd_addr[ADDR_W-1]) begin
        reg_rd_data <= fb_cpu_q;
      end else begin
        case (reg_rd_addr)
          ADDR_W'(OLED_ID_OFS):       reg_rd_data <= OLED_ID_VALUE;
          ADDR_W'(OLED_VERSION_OFS):  reg_rd_data <= OLED_VERSION_VALUE;
          ADDR_W'(OLED_CTRL_OFS):     reg_rd_data <= {30'b0, ctrl_invert, ctrl_power};
          ADDR_W'(OLED_STATUS_OFS):   reg_rd_data <= {frame_count, 14'b0, st_status};
          ADDR_W'(OLED_CONTRAST_OFS): reg_rd_data <= {24'b0, ctrl_contrast};
          ADDR_W'(OLED_SCROLL0_OFS):  reg_rd_data <= {23'b0, ctrl_scroll[0]};
          ADDR_W'(OLED_SCROLL1_OFS):  reg_rd_data <= {23'b0, ctrl_scroll[1]};
          ADDR_W'(OLED_SCROLL2_OFS):  reg_rd_data <= {23'b0, ctrl_scroll[2]};
          ADDR_W'(OLED_SCROLL3_OFS):  reg_rd_data <= {23'b0, ctrl_scroll[3]};
          default:                    reg_rd_data <= '0;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Framebuffer: distributed RAM, one byte lane per array. The CPU port uses
  // the pending write address, else the read address.
  // ---------------------------------------------------------------------------
  assign fb_addr = wr_pend ? wr_addr[10:2] : reg_rd_addr[10:2];

  genvar gl;
  generate
    for (gl = 0; gl < 4; gl++) begin : g_fb
      (* ram_style = "distributed" *) logic [7:0] mem [OLED_FB_WORDS] = '{default: 8'h00};  // blank at power-up

      assign fb_we[gl] = wr_pend && wr_addr[ADDR_W-1] && wr_strb[gl];

      always_ff @(posedge cpu_clk) begin
        if (fb_we[gl]) mem[fb_addr] <= wr_data[8*gl +: 8];
      end

      assign fb_cpu_q[8*gl +: 8] = mem[fb_addr];
      assign fb_eng_q[8*gl +: 8] = mem[eng_addr];
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Command byte source.
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] cmd_byte(input logic [IDX_W-1:0] idx, input logic [7:0] contrast,
                                          input logic invert);
    logic [7:0] b;
    case (int'(idx))
      IDX_HDR + 0:  b = 8'h21;
      IDX_HDR + 1:  b = 8'h00;
      IDX_HDR + 2:  b = 8'h7F;
      IDX_HDR + 3:  b = 8'h22;
      IDX_HDR + 4:  b = 8'h00;
      IDX_HDR + 5:  b = 8'h03;
      IDX_ON:       b = 8'hAF;
      IDX_OFF:      b = 8'hAE;
      IDX_CTR + 0:  b = 8'h81;
      IDX_CTR + 1:  b = contrast;
      IDX_INV:      b = invert ? 8'hA7 : 8'hA6;
      IDX_INIT + 0:  b = 8'hAE;
      IDX_INIT + 1:  b = 8'hD5;
      IDX_INIT + 2:  b = 8'h80;
      IDX_INIT + 3:  b = 8'hA8;
      IDX_INIT + 4:  b = 8'h1F;
      IDX_INIT + 5:  b = 8'hD3;
      IDX_INIT + 6:  b = 8'h00;
      IDX_INIT + 7:  b = 8'h40;
      IDX_INIT + 8:  b = 8'h8D;
      IDX_INIT + 9:  b = 8'h14;
      IDX_INIT + 10: b = 8'h20;
      IDX_INIT + 11: b = 8'h00;
      IDX_INIT + 12: b = SEG_REMAP ? 8'hA1 : 8'hA0;
      IDX_INIT + 13: b = COM_REVERSE ? 8'hC8 : 8'hC0;
      IDX_INIT + 14: b = 8'hDA;
      IDX_INIT + 15: b = 8'h02;
      IDX_INIT + 16: b = 8'h81;
      IDX_INIT + 17: b = contrast;
      IDX_INIT + 18: b = 8'hD9;
      IDX_INIT + 19: b = 8'hF1;
      IDX_INIT + 20: b = 8'hDB;
      IDX_INIT + 21: b = 8'h40;
      IDX_INIT + 22: b = 8'hA4;
      IDX_INIT + 23: b = invert ? 8'hA7 : 8'hA6;
      default:       b = 8'hAE;
    endcase
    return b;
  endfunction

  logic [IDX_W-1:0] cmd_next;
  logic [8:0]       vcol;

  assign cmd_next  = cmd_idx + 1'b1;
  assign vcol      = 9'(xc) + scroll_lat[pg];
  assign spi_dc    = (state == S_DATA_TX);
  assign spi_data  = (state == S_DATA_TX) ? data_byte : cmd_byte(cmd_idx, contrast_sent, invert_sent);
  assign spi_start = (state == S_CMD_TX) || (state == S_DATA_TX);
  assign spi_park  = (state == S_OFF) || (state == S_VDD_OFF);

  // ---------------------------------------------------------------------------
  // SPI byte shifter: lead-in, eight bit windows, trail. Idle SCLK is low.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      spi_busy  <= 1'b0;
      spi_div   <= '0;
      spi_win   <= '0;
      spi_sh    <= '0;
      oled_sclk <= 1'b0;
      oled_sdin <= 1'b0;
      oled_dc   <= 1'b0;
    end else if (!spi_busy) begin
      oled_sclk <= 1'b0;
      if (spi_start) begin
        spi_busy  <= 1'b1;
        spi_sh    <= spi_data;
        oled_sdin <= spi_data[7];
        oled_dc   <= spi_dc;
        spi_div   <= '0;
        spi_win   <= '0;
      end else if (spi_park) begin
        oled_sdin <= 1'b0;
        oled_dc   <= 1'b0;
      end
    end else if (spi_div == DIV_W'(SPI_DIV - 1)) begin
      spi_div   <= '0;
      oled_sclk <= 1'b0;
      if (spi_win == 4'd9) begin
        spi_busy <= 1'b0;
        spi_win  <= '0;
      end else begin
        spi_win <= spi_win + 1'b1;
        if (spi_win >= 4'd1 && spi_win <= 4'd7) begin
          spi_sh    <= {spi_sh[6:0], 1'b0};
          oled_sdin <= spi_sh[6];
        end
      end
    end else begin
      spi_div <= spi_div + 1'b1;
      if (spi_win >= 4'd1 && spi_win <= 4'd8 && spi_div == DIV_W'(SPI_HALF - 1)) oled_sclk <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Sequencer.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      state         <= S_OFF;
      st_status     <= 2'(OLED_STATE_OFF);
      frame_count   <= '0;
      delay_cnt     <= '0;
      frame_timer   <= FRAME_W'(FRAME_CLKS - 1);
      frame_tick    <= 1'b0;
      cmd_idx       <= '0;
      blank         <= 1'b0;
      pg            <= '0;
      xc            <= '0;
      lane          <= '0;
      data_byte     <= '0;
      eng_addr      <= '0;
      contrast_sent <= 8'(OLED_CONTRAST_RESET);
      invert_sent   <= 1'b0;
      inv_pend      <= 1'b0;
      for (int i = 0; i < 4; i++) scroll_lat[i] <= '0;
      oled_res      <= 1'b0;
      oled_vdd      <= 1'b1;
      oled_vbat     <= 1'b1;
    end else begin
      if (delay_cnt != '0) delay_cnt <= delay_cnt - 1'b1;

      case (state)
        S_OFF: begin
          oled_res <= 1'b0;
          if (ctrl_power) begin
            oled_vdd      <= 1'b0;
            oled_res      <= 1'b1;
            delay_cnt     <= DLY_W'(DLY_VDD - 1);
            st_status     <= 2'(OLED_STATE_POWERING_UP);
            contrast_sent <= ctrl_contrast;
            invert_sent   <= ctrl_invert;
            state         <= S_VDD_WAIT;
          end
        end

        S_VDD_WAIT: begin
          if (delay_cnt == '0) begin
            oled_res  <= 1'b0;
            delay_cnt <= DLY_W'(DLY_RES_LOW - 1);
            state     <= S_RES_LOW;
          end
        end

        S_RES_LOW: begin
          if (delay_cnt == '0) begin
            oled_res  <= 1'b1;
            delay_cnt <= DLY_W'(DLY_RES_HI - 1);
            state     <= S_RES_HIGH;
          end
        end

        S_RES_HIGH: begin
          if (delay_cnt == '0) begin
            cmd_idx <= IDX_W'(IDX_INIT);
            state   <= S_CMD_TX;
          end
        end

        S_CMD_TX: begin
          if (!spi_busy) state <= S_CMD_WAIT;
        end

        S_CMD_WAIT: begin
          if (!spi_busy) begin
            cmd_idx <= cmd_next;
            state   <= S_CMD_TX;
            case (int'(cmd_next))
              IDX_HDR + 6: begin                      // header done: data
                pg    <= '0;
                xc    <= '0;
                state <= S_DATA_ADDR;
              end
              IDX_ON + 1: begin                       // display on: running
                blank      <= 1'b0;
                st_status  <= 2'(OLED_STATE_RUNNING);
                frame_tick <= 1'b1;
                state      <= S_RUN_IDLE;
              end
              IDX_OFF + 1: begin                      // display off: VBAT off
                oled_vbat <= 1'b1;
                delay_cnt <= DLY_W'(DLY_VBAT_OF - 1);
                state     <= S_VBAT_OFF;
              end
              IDX_CTR + 2: begin                      // contrast done: invert if pending
                if (!inv_pend) cmd_idx <= IDX_W'(IDX_HDR);
              end
              IDX_INV + 1: begin                      // invert done: header
                cmd_idx <= IDX_W'(IDX_HDR);
              end
              IDX_END: begin                          // init done: VBAT on
                oled_vbat <= 1'b0;
                delay_cnt <= DLY_W'(DLY_VBAT - 1);
                blank     <= 1'b1;
                state     <= S_VBAT_WAIT;
              end
              default: ;
            endcase
          end
        end

        S_VBAT_WAIT: begin
          if (delay_cnt == '0) begin
            cmd_idx <= IDX_W'(IDX_HDR);               // blank frame before display on
            state   <= S_CMD_TX;
          end
        end

        S_DATA_ADDR: begin
          eng_addr <= {pg, vcol[8:2]};
          lane     <= vcol[1:0];
          state    <= S_DATA_RD;
        end

        S_DATA_RD: begin
          data_byte <= blank ? 8'h00 : fb_eng_q[8*lane +: 8];
          state     <= S_DATA_TX;
        end

        S_DATA_TX: begin
          if (!spi_busy) state <= S_DATA_WAIT;
        end

        S_DATA_WAIT: begin
          if (!spi_busy) begin
            state <= S_DATA_ADDR;
            if (xc == 7'(OLED_COLS - 1)) begin
              xc <= '0;
              if (pg == 2'(OLED_PAGES - 1)) begin     // frame done
                if (blank) begin
                  cmd_idx <= IDX_W'(IDX_ON);
                  state   <= S_CMD_TX;
                end else begin
                  state <= S_RUN_IDLE;
                end
              end else begin
                pg <= pg + 1'b1;
              end
            end else begin
              xc <= xc + 1'b1;
            end
          end
        end

        S_RUN_IDLE: begin
          if (!ctrl_power) begin
            cmd_idx   <= IDX_W'(IDX_OFF);
            st_status <= 2'(OLED_STATE_POWERING_DOWN);
            state     <= S_CMD_TX;
          end else if (frame_tick) begin
            frame_tick  <= 1'b0;
            frame_count <= frame_count + 1'b1;
            for (int i = 0; i < 4; i++) scroll_lat[i] <= ctrl_scroll[i];
            inv_pend      <= (ctrl_invert != invert_sent);
            contrast_sent <= ctrl_contrast;
            invert_sent   <= ctrl_invert;
            if (ctrl_contrast != contrast_sent)   cmd_idx <= IDX_W'(IDX_CTR);
            else if (ctrl_invert != invert_sent)  cmd_idx <= IDX_W'(IDX_INV);
            else                                  cmd_idx <= IDX_W'(IDX_HDR);
            state <= S_CMD_TX;
          end
        end

        S_VBAT_OFF: begin
          if (delay_cnt == '0) begin
            oled_vdd  <= 1'b1;
            oled_res  <= 1'b0;
            delay_cnt <= DLY_W'(DLY_SETTLE - 1);
            state     <= S_VDD_OFF;
          end
        end

        S_VDD_OFF: begin
          if (delay_cnt == '0) begin
            st_status <= 2'(OLED_STATE_OFF);
            state     <= S_OFF;
          end
        end

        default: begin
          oled_vdd  <= 1'b1;
          oled_vbat <= 1'b1;
          oled_res  <= 1'b0;
          st_status <= 2'(OLED_STATE_OFF);
          state     <= S_OFF;
        end
      endcase

      // Frame timer: free running, sets a sticky tick (set wins over the clear above).
      if (frame_timer == '0) begin
        frame_timer <= FRAME_W'(FRAME_CLKS - 1);
        frame_tick  <= 1'b1;
      end else begin
        frame_timer <= frame_timer - 1'b1;
      end
    end
  end

endmodule
