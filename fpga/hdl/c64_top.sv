// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 IronKernel
// -----------------------------------------------------------------------------
// File: c64_top.sv
// Purpose: the IronKernel 64 board top for the Digilent Nexys Video
//   (XC7A200T-1SBG484): pins, clock generation and global buffers, the reset
//   tree, the two-core MicroBlaze V block design c64_cpu, the fabric register
//   windows of both cores, the video, audio, SID, PS/2 and system-register blocks,
//   the DDR3 path and every I/O primitive (OSERDESE2, OBUFDS, ODDR, IOBUF).
// Overview:
//   * Common blocks are the ik64-owned ones (fpga/hdl/common, fpga/hdl/ddr): ik64_reset_sync,
//     ik64_sync, ik64_axil_cdc, ik64_axil_decoder and the DDR3 path ik64_axi_cdc -> ik64_ddr
//     (AMD axi_clock_converter and MIG IP). The Ethernet network core is the closed netlist
//     fpga/netlist/ik64_net_core.dcp (interface: fpga/netlist/ik64_net_core.md).
//   * Clocks:
//       u_mmcm_sys: 100 MHz in, VCO 1000 MHz;
//         CLKOUT2 clk200 (MIG IDELAY reference), CLKOUT4 sid_clk 50 MHz
//         (sid_player; also usable later by the network cores), CLKOUT5
//         cpu_clk 100 MHz, CLKOUT6 ddr_sys_clk 100 MHz (MIG PLL input).
//         CLKOUT0 clk125 (MAC transmit), CLKOUT1 clk125_90 (RGMII TXC forward),
//         CLKOUT3 axis_clk 62.5 MHz (MAC client side, protocol filter); sid_clk
//         doubles as the protocol leaf clock of the network core.
//       u_mmcm_pix: cpu_clk in, DIVCLK 5, MULT 37.125, VCO 742.5 MHz;
//         CLKOUT0 /10 = pix_clk 74.25 MHz (CEA-861 720p60, exact),
//         CLKOUT1 /2 = pix_clk_x5 371.25 MHz (TMDS 10:1 DDR serial clock).
//       u_mmcm_aud: cpu_clk in, DIVCLK 5, MULT 48, VCO 960 MHz;
//         CLKOUT0 /78.125 = aud_clk 12.288 MHz = 256 x 48 kHz (exact).
//       ui_clk: MIG user clock, 100 MHz.
//   * Resets: rst_arstn = cpu_resetn & system MMCM locked; one
//     ik64_reset_sync per domain (cpu, pixel, audio, sid, ui and the three network clocks). The pixel
//     and audio domains also wait for their own MMCM; the ui_clk reset is the chain AND the MIG ui reset.
//   * Register windows:
//       core 0 M_AXI_C64 (0x4400_0000, 512 KiB) -> u_dec0: SYS (c64_sysregs
//         core 0), AUD (sid_audio_out), VID (c64_video), PS2 (ps2_rx), SID
//         (sid_player on sid_clk behind u_sid_cdc), OLED (c64_oled), 64 KiB each at c64_pkg
//         WIN_*_OFS; the sample stream u_sid.strm_* crosses to cpu_clk in
//         u_sid_strm and feeds u_audio (CTRL.SRC = 1).
//       core 1 M_AXI_DRV (0x44A0_0000, 1 MiB) -> u_dec1:
//         SYS (c64_sysregs core 1), and the network core's MAC, MDIO and PROTOCOL
//         slots (u_net; the protocol slot holds the classifier and checksum offload).
//       Addresses outside every slot get DECERR from the decoder.
//   * Interrupts: core 0 irq0[0] audio, [1] vsync, [2] PS/2, [7:3] 0;
//     core 1 irq1[0] MDIO (PHY interrupt), [7:1] 0.
//   * Ethernet: u_net is one ik64_net_core (MAC with RGMII pin layer, MDIO core, protocol
//     wrapper; a netlist). The top adds the eth_mdio IOBUF and the output buffers and sets
//     IO_BUFFER_TYPE none on the six receive ports, whose input buffers sit in the core.
//     The core's CPU stream (cpu_clk) joins the block design's S_AXIS_ETH / M_AXIS_ETH.
//     eth_rst_b is the MDIO core's PHY reset output (low at power-up, firmware releases
//     it); SYS_CLK_ETH_LINK_BIT is the MAC's link flag, synchronized into cpu_clk by
//     u_sync_status.
//   * LEDs: led[0] system MMCM locked, led[1] DDR3 calibrated,
//     led[3:2] core 0 SYS_LED[1:0], led[7:4] core 1 SYS_LED[3:0].
// Language: SystemVerilog-2012 (synthesizable).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-09-2026: window 0 grows to 512 KiB; sid_player (u_sid, slot SID) and
//     its stream into sid_audio_out; CPU_CLK_HZ from c64_pkg.
//   * 11-09-2026: sid_player on the 50 MHz sid_clk (system MMCM CLKOUT4, u_rst_sid),
//     ik64_axil_cdc (u_sid_cdc) for its register slot and sid_strm_cdc for the sample
//     stream.
//   * 11-09-2026: Phase 4 network path on core 1's window; clk125, clk125_90 and axis_clk
//     BUFGs with their reset synchronizers; RGMII, MDIO and eth_int_b ports.
//   * 11-09-2026: OLED display driver c64_oled (u_oled, window 0 slot 5, 0x4405_0000) and the six
//     oled_* pins.
//   * 11-10-2026: release split: u_mac, u_mdio and u_protocol become one ik64_net_core (u_net, closed
//     netlist); RTLNet common blocks become ik64_*; the DDR3 path is ik64_axi_cdc (AMD axi_clock_converter,
//     ID_W 2, IDs tied 0) -> ik64_ddr (MIG), the arbiter and its register slot (WIN1_ARB_OFS) are gone
//     (one master reaches the DDR3 controller).
//   * 11-10-2026: QSPI boot: ports qspi_cs / qspi_dq[3:0] (configuration flash) with their IOBUFs; the Quad SPI
//     IP (core 1, axi_quad_spi_0) holds the STARTUPE2 for SCK.
//   * 11-10-2026: hdmi_tx_hpd is active low at the ball (Q5 on the board); inverted into SYS_CLK_HDMI_HPD_BIT.
// Clocks: sysclk (100 MHz pin) -> u_mmcm_sys; cpu_clk, clk200, ddr_sys_clk,
//   pix_clk, pix_clk_x5, aud_clk, ui_clk as above.
// Pins: names, balls, banks and I/O standards from the Digilent
//   Nexys-Video-Master.xdc (Rev. A); constraints in fpga/c64.xdc.
// -----------------------------------------------------------------------------
module c64_top
  import c64_pkg::*;
#(
  parameter logic [31:0] BUILD_ID    = 32'h0000_0000,  // git hash (build script: git rev-parse --short=8 HEAD)
  parameter bit          BUILD_DIRTY = 1'b0            // build tree had uncommitted changes
)(
  // System clock: 100 MHz oscillator, ball R4, net SYSCLK, bank 34 (3.3 V),
  // LVCMOS33, MRCC input; feeds only u_mmcm_sys.
  input  logic       sysclk,

  // CPU RESET push button: ball G4, net CPU_RESETN, bank 35 (1.5 V), LVCMOS15;
  // low while pressed, asynchronous.
  input  logic       cpu_resetn,

  // USB-UART bridge (FT232R), bank 14 (3.3 V), LVCMOS33, 115200 8N1, core 0
  // console (axi_uartlite_0), names from the bridge's point of view:
  // uart_tx_in ball V18 (bridge TXD -> FPGA receive, asynchronous, idle high);
  // uart_rx_out ball AA19 (FPGA transmit -> bridge RXD).
  input  logic       uart_tx_in,
  output logic       uart_rx_out,

  // User LEDs LD0..LD7, bank 13 (2.5 V), LVCMOS25, active high:
  // led[0] T14, [1] T15, [2] T16, [3] U16, [4] V15, [5] W16, [6] W15, [7] Y13.
  // Assignment in the header (MMCM, DDR3, SYS_LED of both cores).
  output logic [7:0] led,

  // HDMI source J8 (TMDS, DVI 1.0 signalling), bank 34 (3.3 V), TMDS_33,
  // driven by OSERDESE2 10:1 + OBUFDS below:
  // hdmi_tx_clk_p T1 / _n U1 (pixel clock lane), hdmi_tx_p[0] W1 / _n[0] Y1
  // (blue + syncs), [1] AA1 / AB1 (green), [2] AB3 / AB2 (red).
  output logic       hdmi_tx_clk_p,
  output logic       hdmi_tx_clk_n,
  output logic [2:0] hdmi_tx_p,
  output logic [2:0] hdmi_tx_n,

  // HDMI hot-plug detect: ball AB13, bank 13 (2.5 V), LVCMOS25, asynchronous.
  // Active LOW at the ball: J8 HPD drives the gate of Q5 (FDV301N), whose
  // drain is HDMI_TX_HPD with R135 10K to VCC2V5 (schematic sheet 5), so a
  // sink pulls the pin low. Inverted into SYS_CLK_STATUS bit
  // SYS_CLK_HDMI_HPD_BIT of both cores (1 = sink attached). The port keeps
  // the master-XDC name.
  input  logic       hdmi_tx_hpd,

  // ADAU1761 audio codec I2S, bank 34 (3.3 V), LVCMOS33; FPGA is the master:
  // ac_mclk U6 (12.288 MHz, ODDR-forwarded aud_clk), ac_bclk T5 (3.072 MHz),
  // ac_lrclk U5 (48 kHz, low = left), ac_dac_sdata W6 (FPGA -> codec DAC);
  // BCLK, LRCLK and data leave from IOB flip-flops on aud_clk.
  output logic       ac_mclk,
  output logic       ac_bclk,
  output logic       ac_lrclk,
  output logic       ac_dac_sdata,

  // Codec control I2C (ADAU1761 at 7-bit address 0x3B), bank 34 (3.3 V),
  // LVCMOS33, open drain with board pull-ups: scl W5, sda V5; driven by
  // axi_iic_0 (core 0) through the IOBUFs below.
  inout  wire        scl,
  inout  wire        sda,

  // PS/2 from the PIC24 USB-HID host on J15 (keyboard), bank 14 (3.3 V),
  // LVCMOS33, PULLUP, open collector, asynchronous: ps2_clk W17,
  // ps2_data N13; receive only (ps2_rx never drives them).
  input  logic       ps2_clk,
  input  logic       ps2_data,

  // OLED display (UG-2832HSWEG04, SSD1306, 4-wire SPI, write only), bank 14
  // (3.3 V), LVCMOS33, balls as in the Digilent master XDC, registered
  // outputs driven by c64_oled:
  // oled_dc W22 (high data, low command), oled_res U21 (active low reset),
  // oled_sclk W21 (6.25 MHz, idle low), oled_sdin Y22, oled_vbat P20 and
  // oled_vdd V22 (gates of P-channel switches, active low: low = on, high =
  // off; reset state high).
  output logic       oled_dc,
  output logic       oled_res,
  output logic       oled_sclk,
  output logic       oled_sdin,
  output logic       oled_vbat,
  output logic       oled_vdd,

  // RTL8211E RGMII receive (PHY -> FPGA), bank 13 (2.5 V), LVCMOS25:
  // eth_rxck V13 (MRCC, receive clock 125/25/2.5 MHz), eth_rxctl W10,
  // eth_rxd[0] AB16, [1] AA15, [2] AB15, [3] AB11 (balls from the Digilent master XDC;
  // schematic not re-checked here (VERIFY)). The input buffers are inside u_net, so
  // the top does not add a second one (IO_BUFFER_TYPE none).
  (* IO_BUFFER_TYPE = "none" *) input  logic       eth_rxck,
  (* IO_BUFFER_TYPE = "none" *) input  logic       eth_rxctl,
  (* IO_BUFFER_TYPE = "none" *) input  logic [3:0] eth_rxd,

  // RTL8211E RGMII transmit (FPGA -> PHY), bank 13 (2.5 V), LVCMOS25:
  // eth_txck AA14, eth_txctl V10, eth_txd[0] Y12, [1] W12, [2] W11, [3] Y11
  // (VERIFY against the schematic).
  output logic       eth_txck,
  output logic       eth_txctl,
  output logic [3:0] eth_txd,

  // RTL8211E management, bank 13 (2.5 V), LVCMOS25: eth_mdc AA16 (FPGA -> PHY
  // clock), eth_mdio Y16 (bidirectional, board pull-up; u_mdio_iobuf below is its
  // only driver), eth_int_b Y14 (PHY interrupt, active low, asynchronous).
  // (VERIFY against the schematic.)
  output logic       eth_mdc,
  inout  wire        eth_mdio,
  input  logic       eth_int_b,

  // RTL8211E reset: ball U7, bank 34 (3.3 V), LVCMOS33, active low; driven by
  // the MDIO core inside u_net, low (PHY in reset, its safe level) until the
  // firmware releases it.
  output logic       eth_rst_b,

  // Configuration QSPI flash (Spansion S25FL256S), bank 14 (3.3 V), LVCMOS33, core 1's AXI Quad
  // SPI (u_cpu axi_quad_spi_0): qspi_cs T19 (active low), qspi_dq[0] P22 (MOSI), [1] R22 (MISO),
  // [2] P21 (WP#), [3] R21 (HOLD#); u_qspi_*_iobuf below are the only drivers. SCK is the dedicated
  // CCLK pin, driven by the STARTUPE2 inside the Quad SPI IP (documented exception to the
  // I/O-primitives-in-top rule, like the MIG).
  inout  wire        qspi_cs,
  inout  wire  [3:0] qspi_dq,

  // DDR3 SDRAM MT41K256M16 (16 bit, one rank), banks 34 and 35 (1.5 V), SSTL15
  // (differential strobes and clock DIFF_SSTL15); balls and properties come
  // from the MIG project (fpga/ip/ik64_ddr_mig.prj).
  inout  wire  [15:0] ddr3_dq,
  inout  wire  [1:0]  ddr3_dqs_n,
  inout  wire  [1:0]  ddr3_dqs_p,
  output logic [14:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,
  output logic        ddr3_ras_n,
  output logic        ddr3_cas_n,
  output logic        ddr3_we_n,
  output logic        ddr3_reset_n,
  output logic [0:0]  ddr3_ck_p,
  output logic [0:0]  ddr3_ck_n,
  output logic [0:0]  ddr3_cke,
  output logic [1:0]  ddr3_dm,
  output logic [0:0]  ddr3_odt
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          AW          = 32;
  // Window bases: mirror fpga/bd/c64_bd.tcl (namespace c64_bd WIN0_BASE, WIN1_BASE).
  localparam logic [31:0] WIN0_BASE   = 32'h4400_0000;
  localparam logic [31:0] WIN1_BASE   = 32'h44A0_0000;
  // Window 0 slots.
  localparam int          NUM_SLV0    = 6;
  localparam int          S0_SYS      = 0;
  localparam int          S0_AUD      = 1;
  localparam int          S0_VID      = 2;
  localparam int          S0_PS2      = 3;
  localparam int          S0_SID      = 4;
  localparam int          S0_OLED     = 5;
  localparam logic [NUM_SLV0*AW-1:0] SLAVE0_BASE = {
    WIN0_BASE + WIN_OLED_OFS,        // 5 OLED
    WIN0_BASE + WIN_SID_OFS,         // 4 SID
    WIN0_BASE + WIN_PS2_OFS,         // 3 PS2
    WIN0_BASE + WIN_VID_OFS,         // 2 VID
    WIN0_BASE + WIN_AUD_OFS,         // 1 AUD
    WIN0_BASE + WIN_SYS_OFS          // 0 SYS
  };
  localparam logic [NUM_SLV0*AW-1:0] SLAVE0_SIZE = {NUM_SLV0{WIN_BLOCK_SIZE}};
  // Window 1 slots.
  localparam int          NUM_SLV1    = 4;
  localparam int          S1_SYS      = 0;
  localparam int          S1_MAC      = 1;
  localparam int          S1_MDIO     = 2;
  localparam int          S1_PROT     = 3;
  localparam logic [NUM_SLV1*AW-1:0] SLAVE1_BASE = {
    WIN1_BASE + WIN1_PROT_OFS,       // 3 PROTOCOL
    WIN1_BASE + WIN1_MDIO_OFS,       // 2 MDIO
    WIN1_BASE + WIN1_MAC_OFS,        // 1 MAC
    WIN1_BASE + WIN1_SYS_OFS         // 0 SYS
  };
  localparam logic [NUM_SLV1*AW-1:0] SLAVE1_SIZE = {
    WIN1_PROT_SIZE, WIN1_SLOT_SIZE, WIN1_SLOT_SIZE, WIN1_SLOT_SIZE};
  localparam int          MAC_ADDR_W  = 12;                 // ik64_net_core MAC and MDIO register port width
  localparam int          PROT_ADDR_W = 16;                 // ik64_net_core PROTOCOL register port width (64 KiB slot)
  // DDR3 path.
  localparam int          DDR_ADDR_W  = 29;                 // 512 MiB
  localparam int          DDR_DATA_W  = 128;
  localparam int          DDR_ID_W    = 2;                  // MIG AXI ID width; the one master ties its IDs to 0
  // Status levels into SYS_CLK_STATUS (bit n = c64_pkg SYS_CLK_*_BIT n).
  localparam int          CLK_STATUS_W = SYS_CLK_ETH_LINK_BIT + 1;
  // TMDS clock-lane word and serializer width.
  localparam int          TMDS_W      = 10;
  localparam int          TMDS_LANES  = 4;                  // 3 data + clock

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clkfb;
  logic clkfb_bufg;
  logic clk200_mmcm;
  logic cpu_clk_mmcm;
  logic ddr_sys_clk_mmcm;
  logic clk200;                // 200 MHz: MIG IDELAYCTRL reference
  logic cpu_clk;               // 100 MHz: both CPUs, register windows, system registers
  logic ddr_sys_clk;           // 100 MHz: MIG PLL input
  logic mmcm_locked;           // system MMCM, asynchronous
  logic pix_clkfb;
  logic pix_clkfb_bufg;
  logic pix_clk_mmcm;
  logic pix_clk_x5_mmcm;
  logic pix_clk;               // 74.25 MHz: video timing, scan-out, TMDS encoding
  logic pix_clk_x5;            // 371.25 MHz: OSERDESE2 CLK (DDR, 10 bits per pix_clk)
  logic pix_locked;            // pixel MMCM, asynchronous
  logic aud_clkfb;
  logic aud_clkfb_bufg;
  logic aud_clk_mmcm;
  logic aud_clk;               // 12.288 MHz: I2S transmitter, MCLK forwarding
  logic aud_locked;            // audio MMCM, asynchronous
  logic rst_arstn;             // board reset assertion: button or system MMCM unlocked
  logic pix_arstn;
  logic aud_arstn;
  logic cpu_resetn_sync;
  logic pix_resetn;
  logic aud_resetn;
  logic sid_clk_mmcm;
  logic clk125_mmcm;
  logic clk125_90_mmcm;
  logic axis_clk_mmcm;
  logic clk125;                // 125 MHz, 0 deg: MAC transmit, RXC rate detector
  logic clk125_90;             // 125 MHz, 90 deg: RGMII TXC forwarding only
  logic axis_clk;              // 62.5 MHz: MAC client side, protocol filter
  logic clk125_resetn;
  logic clk200_resetn;
  logic axis_resetn;
  logic sid_clk;               // 50 MHz: sid_player (reDIP-SID core), system MMCM CLKOUT4
  logic sid_resetn;
  logic ui_clk;                // 100 MHz: MIG user clock, DDR3 AXI4 side
  logic ui_resetn_mig;         // MIG ui reset, active low, synchronous to ui_clk
  logic ddr_resetn_sync;       // ui_clk reset chain of rst_arstn
  logic ddr_resetn;            // ui_clk reset: ddr_resetn_sync and the MIG ui reset
  logic ddr_calib;             // init_calib_complete, ui_clk domain

  // ---------------------------------------------------------------------------
  // Block design ports
  // ---------------------------------------------------------------------------
  logic [7:0]  irq0;
  logic [7:0]  irq1;
  logic        iic_scl_i;
  logic [3:0]  qspi_io_i, qspi_io_o, qspi_io_t;   // axi_quad_spi_0 data lines
  logic        qspi_ss_i, qspi_ss_o, qspi_ss_t;   // axi_quad_spi_0 chip select
  logic        iic_scl_o;
  logic        iic_scl_t;
  logic        iic_sda_i;
  logic        iic_sda_o;
  logic        iic_sda_t;
  logic [FB_WORD_ADDR_W+1:0] fb_bram_addr;   // byte address, 18 bits (BD FB_BRAM_addr[17:0])
  logic        fb_bram_en;
  logic [3:0]  fb_bram_we;
  logic [31:0] fb_bram_din;
  logic [31:0] fb_bram_dout;

  // Core 0 and core 1 register masters (AXI4-Lite, cpu_clk).
  logic [31:0] c0_awaddr;
  logic        c0_awvalid;
  logic        c0_awready;
  logic [31:0] c0_wdata;
  logic [3:0]  c0_wstrb;
  logic        c0_wvalid;
  logic        c0_wready;
  logic [1:0]  c0_bresp;
  logic        c0_bvalid;
  logic        c0_bready;
  logic [31:0] c0_araddr;
  logic        c0_arvalid;
  logic        c0_arready;
  logic [31:0] c0_rdata;
  logic [1:0]  c0_rresp;
  logic        c0_rvalid;
  logic        c0_rready;
  logic [31:0] c1_awaddr;
  logic        c1_awvalid;
  logic        c1_awready;
  logic [31:0] c1_wdata;
  logic [3:0]  c1_wstrb;
  logic        c1_wvalid;
  logic        c1_wready;
  logic [1:0]  c1_bresp;
  logic        c1_bvalid;
  logic        c1_bready;
  logic [31:0] c1_araddr;
  logic        c1_arvalid;
  logic        c1_arready;
  logic [31:0] c1_rdata;
  logic [1:0]  c1_rresp;
  logic        c1_rvalid;
  logic        c1_rready;

  // Decoder 0 slave side.
  logic [NUM_SLV0*AW-1:0] d0_awaddr;
  logic [NUM_SLV0-1:0]    d0_awvalid;
  logic [NUM_SLV0-1:0]    d0_awready;
  logic [NUM_SLV0*32-1:0] d0_wdata;
  logic [NUM_SLV0*4-1:0]  d0_wstrb;
  logic [NUM_SLV0-1:0]    d0_wvalid;
  logic [NUM_SLV0-1:0]    d0_wready;
  logic [NUM_SLV0*2-1:0]  d0_bresp;
  logic [NUM_SLV0-1:0]    d0_bvalid;
  logic [NUM_SLV0-1:0]    d0_bready;
  logic [NUM_SLV0*AW-1:0] d0_araddr;
  logic [NUM_SLV0-1:0]    d0_arvalid;
  logic [NUM_SLV0-1:0]    d0_arready;
  logic [NUM_SLV0*32-1:0] d0_rdata;
  logic [NUM_SLV0*2-1:0]  d0_rresp;
  logic [NUM_SLV0-1:0]    d0_rvalid;
  logic [NUM_SLV0-1:0]    d0_rready;
  // Decoder 1 slave side.
  logic [NUM_SLV1*AW-1:0] d1_awaddr;
  logic [NUM_SLV1-1:0]    d1_awvalid;
  logic [NUM_SLV1-1:0]    d1_awready;
  logic [NUM_SLV1*32-1:0] d1_wdata;
  logic [NUM_SLV1*4-1:0]  d1_wstrb;
  logic [NUM_SLV1-1:0]    d1_wvalid;
  logic [NUM_SLV1-1:0]    d1_wready;
  logic [NUM_SLV1*2-1:0]  d1_bresp;
  logic [NUM_SLV1-1:0]    d1_bvalid;
  logic [NUM_SLV1-1:0]    d1_bready;
  logic [NUM_SLV1*AW-1:0] d1_araddr;
  logic [NUM_SLV1-1:0]    d1_arvalid;
  logic [NUM_SLV1-1:0]    d1_arready;
  logic [NUM_SLV1*32-1:0] d1_rdata;
  logic [NUM_SLV1*2-1:0]  d1_rresp;
  logic [NUM_SLV1-1:0]    d1_rvalid;
  logic [NUM_SLV1-1:0]    d1_rready;

  // CPU DDR3 master (cpu_clk, 128-bit, no IDs) and the converter's ui_clk side into the MIG.
  logic [31:0]           cpu_ddr_awaddr;
  logic [7:0]            cpu_ddr_awlen;
  logic [2:0]            cpu_ddr_awsize;
  logic [1:0]            cpu_ddr_awburst;
  logic                  cpu_ddr_awlock;
  logic [3:0]            cpu_ddr_awcache;
  logic [2:0]            cpu_ddr_awprot;
  logic [3:0]            cpu_ddr_awqos;
  logic                  cpu_ddr_awvalid;
  logic                  cpu_ddr_awready;
  logic [127:0]          cpu_ddr_wdata;
  logic [15:0]           cpu_ddr_wstrb;
  logic                  cpu_ddr_wlast;
  logic                  cpu_ddr_wvalid;
  logic                  cpu_ddr_wready;
  logic [1:0]            cpu_ddr_bresp;
  logic                  cpu_ddr_bvalid;
  logic                  cpu_ddr_bready;
  logic [31:0]           cpu_ddr_araddr;
  logic [7:0]            cpu_ddr_arlen;
  logic [2:0]            cpu_ddr_arsize;
  logic [1:0]            cpu_ddr_arburst;
  logic                  cpu_ddr_arlock;
  logic [3:0]            cpu_ddr_arcache;
  logic [2:0]            cpu_ddr_arprot;
  logic [3:0]            cpu_ddr_arqos;
  logic                  cpu_ddr_arvalid;
  logic                  cpu_ddr_arready;
  logic [127:0]          cpu_ddr_rdata;
  logic [1:0]            cpu_ddr_rresp;
  logic                  cpu_ddr_rlast;
  logic                  cpu_ddr_rvalid;
  logic                  cpu_ddr_rready;

  logic [DDR_ID_W-1:0]     mem_awid;
  logic [DDR_ADDR_W-1:0]   mem_awaddr;
  logic [7:0]              mem_awlen;
  logic [2:0]              mem_awsize;
  logic [1:0]              mem_awburst;
  logic                    mem_awlock;
  logic [3:0]              mem_awcache;
  logic [2:0]              mem_awprot;
  logic [3:0]              mem_awqos;
  logic                    mem_awvalid;
  logic                    mem_awready;
  logic [DDR_DATA_W-1:0]   mem_wdata;
  logic [DDR_DATA_W/8-1:0] mem_wstrb;
  logic                    mem_wlast;
  logic                    mem_wvalid;
  logic                    mem_wready;
  logic [DDR_ID_W-1:0]     mem_bid;
  logic [1:0]              mem_bresp;
  logic                    mem_bvalid;
  logic                    mem_bready;
  logic [DDR_ID_W-1:0]     mem_arid;
  logic [DDR_ADDR_W-1:0]   mem_araddr;
  logic [7:0]              mem_arlen;
  logic [2:0]              mem_arsize;
  logic [1:0]              mem_arburst;
  logic                    mem_arlock;
  logic [3:0]              mem_arcache;
  logic [2:0]              mem_arprot;
  logic [3:0]              mem_arqos;
  logic                    mem_arvalid;
  logic                    mem_arready;
  logic [DDR_ID_W-1:0]     mem_rid;
  logic [DDR_DATA_W-1:0]   mem_rdata;
  logic [1:0]              mem_rresp;
  logic                    mem_rlast;
  logic                    mem_rvalid;
  logic                    mem_rready;

  // ---------------------------------------------------------------------------
  // Block status
  // ---------------------------------------------------------------------------
  logic                    aud_irq;
  logic                    vid_irq;
  logic                    ps2_irq;
  logic                    sid_strm_valid;   // sid_player output, sid_clk, 48 kHz
  logic signed [15:0]      sid_strm_sample;
  logic                    cpu_strm_valid;   // sid_strm_cdc output -> sid_audio_out, cpu_clk
  logic signed [15:0]      cpu_strm_sample;
  logic [REG_ADDR_W-1:0]   sx_awaddr, sx_araddr;   // u_sid_cdc master side (sid_clk)
  logic [31:0]             sx_wdata, sx_rdata;
  logic [3:0]              sx_wstrb;
  logic [1:0]              sx_bresp, sx_rresp;
  logic                    sx_awvalid, sx_awready, sx_wvalid, sx_wready, sx_bvalid, sx_bready;
  logic                    sx_arvalid, sx_arready, sx_rvalid, sx_rready;
  logic [CLK_STATUS_W-1:0] clk_status_async;
  logic [CLK_STATUS_W-1:0] clk_status;        // cpu_clk, synchronized
  // Network core CPU streams (cpu_clk): eth_tx = frames core 1 sends, eth_rx = frames to core 1.
  logic [63:0]             cpu_eth_tx_tdata, cpu_eth_rx_tdata;
  logic [7:0]              cpu_eth_tx_tkeep, cpu_eth_rx_tkeep;
  logic                    cpu_eth_tx_tvalid, cpu_eth_tx_tlast, cpu_eth_tx_tready;
  logic                    cpu_eth_rx_tvalid, cpu_eth_rx_tlast, cpu_eth_rx_tready;
  logic                    mac_stat_link_up;
  logic                    mdio_o, mdio_t, mdio_i;
  logic                    mdio_irq;
  logic [7:0]              led0;              // core 0 SYS_LED
  logic [7:0]              led1;              // core 1 SYS_LED
  logic [TMDS_W-1:0]       tmds_word [TMDS_LANES];   // 0 blue, 1 green, 2 red, 3 clock
  logic [TMDS_LANES-1:0]   tmds_ser;          // serializer outputs, lane order as tmds_word
  logic                    aud_bclk_q;
  logic                    aud_lrclk_q;
  logic                    aud_sdata_q;

  // ---------------------------------------------------------------------------
  // System MMCM: VCO = 100 MHz x 10 = 1000 MHz.
  // CLKOUT0 /8 = 125 MHz clk125, CLKOUT1 /8 at 90 deg (2 ns) = 125 MHz clk125_90,
  // CLKOUT2 /5 = 200 MHz, CLKOUT3 /16 = 62.5 MHz axis_clk, CLKOUT4 /20 = 50 MHz
  // sid_clk (sid_player and the protocol's proto_clk/app_clk), CLKOUT5 /10 = 100 MHz,
  // CLKOUT6 /10 = 100 MHz. RST tied low: the oscillator runs before
  // configuration ends, and the button resets logic, not the MMCM.
  // ---------------------------------------------------------------------------
  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE"),
    .DIVCLK_DIVIDE        (1),
    .CLKFBOUT_MULT_F      (10.000),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKIN1_PERIOD        (10.000),
    .CLKIN2_PERIOD        (10.000),
    .REF_JITTER1          (0.010),
    .REF_JITTER2          (0.010),
    .CLKOUT4_CASCADE      ("FALSE"),
    .CLKOUT0_DIVIDE_F     (8.000),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (8),
    .CLKOUT1_PHASE        (90.000),
    .CLKOUT1_DUTY_CYCLE   (0.500),
    .CLKOUT1_USE_FINE_PS  ("FALSE"),
    .CLKOUT2_DIVIDE       (5),
    .CLKOUT2_PHASE        (0.000),
    .CLKOUT2_DUTY_CYCLE   (0.500),
    .CLKOUT2_USE_FINE_PS  ("FALSE"),
    .CLKOUT3_DIVIDE       (16),
    .CLKOUT3_PHASE        (0.000),
    .CLKOUT3_DUTY_CYCLE   (0.500),
    .CLKOUT3_USE_FINE_PS  ("FALSE"),
    .CLKOUT4_DIVIDE       (20),
    .CLKOUT4_PHASE        (0.000),
    .CLKOUT4_DUTY_CYCLE   (0.500),
    .CLKOUT4_USE_FINE_PS  ("FALSE"),
    .CLKOUT5_DIVIDE       (10),
    .CLKOUT5_PHASE        (0.000),
    .CLKOUT5_DUTY_CYCLE   (0.500),
    .CLKOUT5_USE_FINE_PS  ("FALSE"),
    .CLKOUT6_DIVIDE       (10),
    .CLKOUT6_PHASE        (0.000),
    .CLKOUT6_DUTY_CYCLE   (0.500),
    .CLKOUT6_USE_FINE_PS  ("FALSE")
  ) u_mmcm_sys (
    .CLKIN1       (sysclk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_bufg),
    .CLKFBOUT     (clkfb),
    .CLKFBOUTB    (),
    .CLKOUT0      (clk125_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (clk125_90_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (clk200_mmcm),
    .CLKOUT2B     (),
    .CLKOUT3      (axis_clk_mmcm),
    .CLKOUT3B     (),
    .CLKOUT4      (sid_clk_mmcm),
    .CLKOUT5      (cpu_clk_mmcm),
    .CLKOUT6      (ddr_sys_clk_mmcm),
    .LOCKED       (mmcm_locked),
    .RST          (1'b0),
    .PWRDWN       (1'b0),
    .DADDR        (7'd0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DI           (16'd0),
    .DWE          (1'b0),
    .DO           (),
    .DRDY         (),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  BUFG u_bufg_fb     (.I(clkfb),            .O(clkfb_bufg));
  BUFG u_bufg_clk200 (.I(clk200_mmcm),      .O(clk200));
  BUFG u_bufg_clk125    (.I(clk125_mmcm),    .O(clk125));
  BUFG u_bufg_clk125_90 (.I(clk125_90_mmcm), .O(clk125_90));
  BUFG u_bufg_axis      (.I(axis_clk_mmcm),  .O(axis_clk));
  BUFG u_bufg_cpu    (.I(cpu_clk_mmcm),     .O(cpu_clk));
  BUFG u_bufg_ddrsys (.I(ddr_sys_clk_mmcm), .O(ddr_sys_clk));

  // ---------------------------------------------------------------------------
  // Pixel MMCM: cpu_clk in (10 ns), PFD 100/5 = 20 MHz, VCO 20 x 37.125 =
  // 742.5 MHz (600..1200 MHz for -1). CLKOUT0 742.5/10 = 74.25 MHz, CLKOUT1
  // 742.5/2 = 371.25 MHz: TMDS bit rate 742.5 Mb/s = 10 x 74.25 MHz, DDR on
  // CLK (inside the -1 HR-bank OSERDESE2 DDR limit). Held in reset while the
  // system MMCM (its input clock) is unlocked; RST is the primitive's
  // asynchronous reset (vendor primitive, fpga.md async-reset exception).
  // ---------------------------------------------------------------------------
  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE"),
    .DIVCLK_DIVIDE        (5),
    .CLKFBOUT_MULT_F      (37.125),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKIN1_PERIOD        (10.000),
    .CLKIN2_PERIOD        (10.000),
    .REF_JITTER1          (0.010),
    .REF_JITTER2          (0.010),
    .CLKOUT4_CASCADE      ("FALSE"),
    .CLKOUT0_DIVIDE_F     (10.000),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (2),
    .CLKOUT1_PHASE        (0.000),
    .CLKOUT1_DUTY_CYCLE   (0.500),
    .CLKOUT1_USE_FINE_PS  ("FALSE")
  ) u_mmcm_pix (
    .CLKIN1       (cpu_clk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (pix_clkfb_bufg),
    .CLKFBOUT     (pix_clkfb),
    .CLKFBOUTB    (),
    .CLKOUT0      (pix_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (pix_clk_x5_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (pix_locked),
    .RST          (~mmcm_locked),
    .PWRDWN       (1'b0),
    .DADDR        (7'd0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DI           (16'd0),
    .DWE          (1'b0),
    .DO           (),
    .DRDY         (),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  BUFG u_bufg_pix_fb (.I(pix_clkfb),       .O(pix_clkfb_bufg));
  BUFG u_bufg_pix    (.I(pix_clk_mmcm),    .O(pix_clk));
  BUFG u_bufg_pix_x5 (.I(pix_clk_x5_mmcm), .O(pix_clk_x5));

  // ---------------------------------------------------------------------------
  // Audio MMCM: cpu_clk in, PFD 20 MHz, VCO 20 x 48 = 960 MHz, CLKOUT0
  // 960/78.125 = 12.288 MHz exactly (fractional divide in 1/8 steps).
  // Reset as the pixel MMCM.
  // ---------------------------------------------------------------------------
  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE"),
    .DIVCLK_DIVIDE        (5),
    .CLKFBOUT_MULT_F      (48.000),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKIN1_PERIOD        (10.000),
    .CLKIN2_PERIOD        (10.000),
    .REF_JITTER1          (0.010),
    .REF_JITTER2          (0.010),
    .CLKOUT4_CASCADE      ("FALSE"),
    .CLKOUT0_DIVIDE_F     (78.125),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE")
  ) u_mmcm_aud (
    .CLKIN1       (cpu_clk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (aud_clkfb_bufg),
    .CLKFBOUT     (aud_clkfb),
    .CLKFBOUTB    (),
    .CLKOUT0      (aud_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (aud_locked),
    .RST          (~mmcm_locked),
    .PWRDWN       (1'b0),
    .DADDR        (7'd0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DI           (16'd0),
    .DWE          (1'b0),
    .DO           (),
    .DRDY         (),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  BUFG u_bufg_aud_fb (.I(aud_clkfb),    .O(aud_clkfb_bufg));
  BUFG u_bufg_aud    (.I(aud_clk_mmcm), .O(aud_clk));

  // 50 MHz SID clock from the system MMCM (CLKOUT4); also the network protocol's proto_clk.
  BUFG u_bufg_sid    (.I(sid_clk_mmcm), .O(sid_clk));

  // The one reset assertion: button pressed or system MMCM not locked. The
  // pixel and audio domains additionally wait for their own MMCM.
  assign rst_arstn = cpu_resetn & mmcm_locked;
  assign pix_arstn = rst_arstn & pix_locked;
  assign aud_arstn = rst_arstn & aud_locked;

  ik64_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(rst_arstn), .resetn(cpu_resetn_sync));
  ik64_reset_sync u_rst_pix (.clk(pix_clk), .arstn(pix_arstn), .resetn(pix_resetn));
  ik64_reset_sync u_rst_aud (.clk(aud_clk), .arstn(aud_arstn), .resetn(aud_resetn));
  ik64_reset_sync u_rst_sid (.clk(sid_clk), .arstn(rst_arstn), .resetn(sid_resetn));
  // Network domains: the core uses clk125_resetn for clk125 and clk125_90.
  ik64_reset_sync u_rst_clk125 (.clk(clk125),   .arstn(rst_arstn), .resetn(clk125_resetn));
  ik64_reset_sync u_rst_clk200 (.clk(clk200),   .arstn(rst_arstn), .resetn(clk200_resetn));
  ik64_reset_sync u_rst_axis   (.clk(axis_clk), .arstn(rst_arstn), .resetn(axis_resetn));

  // Reset release into ui_clk: the board reset assertion enters the
  // chain; the MIG ui reset (a ui_clk flop output) is ANDed into the released,
  // synchronous reset.
  ik64_reset_sync u_rst_ddr (.clk(ui_clk), .arstn(rst_arstn), .resetn(ddr_resetn_sync));
  assign ddr_resetn = ddr_resetn_sync & ui_resetn_mig;

  // Status levels into cpu_clk for both system-register instances: MMCM lock
  // outputs and the HPD pin are asynchronous, ddr_calib is a ui_clk flop.
  assign clk_status_async[SYS_CLK_PIX_LOCKED_BIT] = pix_locked;
  assign clk_status_async[SYS_CLK_DDR_CALIB_BIT]  = ddr_calib;
  assign clk_status_async[SYS_CLK_AUD_LOCKED_BIT] = aud_locked;
  assign clk_status_async[SYS_CLK_HDMI_HPD_BIT]   = ~hdmi_tx_hpd;      // Q5 inverts: low = sink attached
  assign clk_status_async[SYS_CLK_ETH_LINK_BIT]   = mac_stat_link_up;   // axis_clk flag of u_net, re-synchronized here
  ik64_sync #(
    .WIDTH (CLK_STATUS_W)
  ) u_sync_status (
    .clk    (cpu_clk),
    .resetn (cpu_resetn_sync),
    .d      (clk_status_async),
    .q      (clk_status)
  );

  // ---------------------------------------------------------------------------
  // Two-core MicroBlaze V block design (fpga/bd/c64_bd.tcl).
  // FB_BRAM_clk / FB_BRAM_rst are not used: the controller runs on clk
  // (cpu_clk), the clock of c64_video's port A, and c64_video has its own reset.
  // ---------------------------------------------------------------------------
  assign irq0 = {5'b0_0000, ps2_irq, vid_irq, aud_irq};
  assign irq1 = {7'd0, mdio_irq};

  c64_cpu u_cpu (
    .clk                (cpu_clk),
    .resetn             (cpu_resetn_sync),
    .uart_rxd           (uart_tx_in),
    .uart_txd           (uart_rx_out),
    .iic_scl_i          (iic_scl_i),
    .iic_scl_o          (iic_scl_o),
    .iic_scl_t          (iic_scl_t),
    .iic_sda_i          (iic_sda_i),
    .iic_sda_o          (iic_sda_o),
    .iic_sda_t          (iic_sda_t),
    .QSPI_io0_i         (qspi_io_i[0]),
    .QSPI_io0_o         (qspi_io_o[0]),
    .QSPI_io0_t         (qspi_io_t[0]),
    .QSPI_io1_i         (qspi_io_i[1]),
    .QSPI_io1_o         (qspi_io_o[1]),
    .QSPI_io1_t         (qspi_io_t[1]),
    .QSPI_io2_i         (qspi_io_i[2]),
    .QSPI_io2_o         (qspi_io_o[2]),
    .QSPI_io2_t         (qspi_io_t[2]),
    .QSPI_io3_i         (qspi_io_i[3]),
    .QSPI_io3_o         (qspi_io_o[3]),
    .QSPI_io3_t         (qspi_io_t[3]),
    .QSPI_ss_i          (qspi_ss_i),
    .QSPI_ss_o          (qspi_ss_o),
    .QSPI_ss_t          (qspi_ss_t),
    .irq0               (irq0),
    .irq1               (irq1),
    .FB_BRAM_addr       (fb_bram_addr),
    .FB_BRAM_clk        (),
    .FB_BRAM_din        (fb_bram_din),
    .FB_BRAM_dout       (fb_bram_dout),
    .FB_BRAM_en         (fb_bram_en),
    .FB_BRAM_rst        (),
    .FB_BRAM_we         (fb_bram_we),
    .M_AXI_C64_awaddr   (c0_awaddr),
    .M_AXI_C64_awprot   (),
    .M_AXI_C64_awvalid  (c0_awvalid),
    .M_AXI_C64_awready  (c0_awready),
    .M_AXI_C64_wdata    (c0_wdata),
    .M_AXI_C64_wstrb    (c0_wstrb),
    .M_AXI_C64_wvalid   (c0_wvalid),
    .M_AXI_C64_wready   (c0_wready),
    .M_AXI_C64_bresp    (c0_bresp),
    .M_AXI_C64_bvalid   (c0_bvalid),
    .M_AXI_C64_bready   (c0_bready),
    .M_AXI_C64_araddr   (c0_araddr),
    .M_AXI_C64_arprot   (),
    .M_AXI_C64_arvalid  (c0_arvalid),
    .M_AXI_C64_arready  (c0_arready),
    .M_AXI_C64_rdata    (c0_rdata),
    .M_AXI_C64_rresp    (c0_rresp),
    .M_AXI_C64_rvalid   (c0_rvalid),
    .M_AXI_C64_rready   (c0_rready),
    .M_AXI_DRV_awaddr   (c1_awaddr),
    .M_AXI_DRV_awprot   (),
    .M_AXI_DRV_awvalid  (c1_awvalid),
    .M_AXI_DRV_awready  (c1_awready),
    .M_AXI_DRV_wdata    (c1_wdata),
    .M_AXI_DRV_wstrb    (c1_wstrb),
    .M_AXI_DRV_wvalid   (c1_wvalid),
    .M_AXI_DRV_wready   (c1_wready),
    .M_AXI_DRV_bresp    (c1_bresp),
    .M_AXI_DRV_bvalid   (c1_bvalid),
    .M_AXI_DRV_bready   (c1_bready),
    .M_AXI_DRV_araddr   (c1_araddr),
    .M_AXI_DRV_arprot   (),
    .M_AXI_DRV_arvalid  (c1_arvalid),
    .M_AXI_DRV_arready  (c1_arready),
    .M_AXI_DRV_rdata    (c1_rdata),
    .M_AXI_DRV_rresp    (c1_rresp),
    .M_AXI_DRV_rvalid   (c1_rvalid),
    .M_AXI_DRV_rready   (c1_rready),
    .S_AXIS_ETH_tdata   (cpu_eth_rx_tdata),
    .S_AXIS_ETH_tkeep   (cpu_eth_rx_tkeep),
    .S_AXIS_ETH_tlast   (cpu_eth_rx_tlast),
    .S_AXIS_ETH_tvalid  (cpu_eth_rx_tvalid),
    .S_AXIS_ETH_tready  (cpu_eth_rx_tready),
    .M_AXIS_ETH_tdata   (cpu_eth_tx_tdata),
    .M_AXIS_ETH_tkeep   (cpu_eth_tx_tkeep),
    .M_AXIS_ETH_tlast   (cpu_eth_tx_tlast),
    .M_AXIS_ETH_tvalid  (cpu_eth_tx_tvalid),
    .M_AXIS_ETH_tready  (cpu_eth_tx_tready),
    .M_AXI_DDR_awaddr   (cpu_ddr_awaddr),
    .M_AXI_DDR_awlen    (cpu_ddr_awlen),
    .M_AXI_DDR_awsize   (cpu_ddr_awsize),
    .M_AXI_DDR_awburst  (cpu_ddr_awburst),
    .M_AXI_DDR_awlock   (cpu_ddr_awlock),
    .M_AXI_DDR_awcache  (cpu_ddr_awcache),
    .M_AXI_DDR_awprot   (cpu_ddr_awprot),
    .M_AXI_DDR_awqos    (cpu_ddr_awqos),
    .M_AXI_DDR_awvalid  (cpu_ddr_awvalid),
    .M_AXI_DDR_awready  (cpu_ddr_awready),
    .M_AXI_DDR_wdata    (cpu_ddr_wdata),
    .M_AXI_DDR_wstrb    (cpu_ddr_wstrb),
    .M_AXI_DDR_wlast    (cpu_ddr_wlast),
    .M_AXI_DDR_wvalid   (cpu_ddr_wvalid),
    .M_AXI_DDR_wready   (cpu_ddr_wready),
    .M_AXI_DDR_bresp    (cpu_ddr_bresp),
    .M_AXI_DDR_bvalid   (cpu_ddr_bvalid),
    .M_AXI_DDR_bready   (cpu_ddr_bready),
    .M_AXI_DDR_araddr   (cpu_ddr_araddr),
    .M_AXI_DDR_arlen    (cpu_ddr_arlen),
    .M_AXI_DDR_arsize   (cpu_ddr_arsize),
    .M_AXI_DDR_arburst  (cpu_ddr_arburst),
    .M_AXI_DDR_arlock   (cpu_ddr_arlock),
    .M_AXI_DDR_arcache  (cpu_ddr_arcache),
    .M_AXI_DDR_arprot   (cpu_ddr_arprot),
    .M_AXI_DDR_arqos    (cpu_ddr_arqos),
    .M_AXI_DDR_arvalid  (cpu_ddr_arvalid),
    .M_AXI_DDR_arready  (cpu_ddr_arready),
    .M_AXI_DDR_rdata    (cpu_ddr_rdata),
    .M_AXI_DDR_rresp    (cpu_ddr_rresp),
    .M_AXI_DDR_rlast    (cpu_ddr_rlast),
    .M_AXI_DDR_rvalid   (cpu_ddr_rvalid),
    .M_AXI_DDR_rready   (cpu_ddr_rready)
  );

  // Codec I2C pads: the only drivers of scl/sda; *_t = 1 releases the line.
  IOBUF u_scl_iobuf (.I(iic_scl_o), .T(iic_scl_t), .O(iic_scl_i), .IO(scl));
  IOBUF u_sda_iobuf (.I(iic_sda_o), .T(iic_sda_t), .O(iic_sda_i), .IO(sda));

  // Configuration flash pads (core 1's axi_quad_spi_0): the only drivers of qspi_dq and qspi_cs.
  // Chip select is driven (never released) after the IP leaves reset; qspi_ss_i is the pad level
  // the IP never uses in master mode.
  for (genvar q = 0; q < 4; q++) begin : g_qspi_dq
    IOBUF u_qspi_dq_iobuf (.I(qspi_io_o[q]), .T(qspi_io_t[q]), .O(qspi_io_i[q]), .IO(qspi_dq[q]));
  end
  IOBUF u_qspi_cs_iobuf (.I(qspi_ss_o), .T(qspi_ss_t), .O(qspi_ss_i), .IO(qspi_cs));

  // ---------------------------------------------------------------------------
  // Register window 0 (core 0): SYS, AUD, VID, PS2, SID, OLED.
  // ---------------------------------------------------------------------------
  ik64_axil_decoder #(
    .N          (NUM_SLV0),
    .ADDR_W     (AW),
    .SLAVE_BASE (SLAVE0_BASE),
    .SLAVE_SIZE (SLAVE0_SIZE)
  ) u_dec0 (
    .aclk          (cpu_clk),
    .aresetn       (cpu_resetn_sync),
    .s_axi_awaddr  (c0_awaddr),
    .s_axi_awvalid (c0_awvalid),
    .s_axi_awready (c0_awready),
    .s_axi_wdata   (c0_wdata),
    .s_axi_wstrb   (c0_wstrb),
    .s_axi_wvalid  (c0_wvalid),
    .s_axi_wready  (c0_wready),
    .s_axi_bresp   (c0_bresp),
    .s_axi_bvalid  (c0_bvalid),
    .s_axi_bready  (c0_bready),
    .s_axi_araddr  (c0_araddr),
    .s_axi_arvalid (c0_arvalid),
    .s_axi_arready (c0_arready),
    .s_axi_rdata   (c0_rdata),
    .s_axi_rresp   (c0_rresp),
    .s_axi_rvalid  (c0_rvalid),
    .s_axi_rready  (c0_rready),
    .m_axi_awaddr  (d0_awaddr),
    .m_axi_awvalid (d0_awvalid),
    .m_axi_awready (d0_awready),
    .m_axi_wdata   (d0_wdata),
    .m_axi_wstrb   (d0_wstrb),
    .m_axi_wvalid  (d0_wvalid),
    .m_axi_wready  (d0_wready),
    .m_axi_bresp   (d0_bresp),
    .m_axi_bvalid  (d0_bvalid),
    .m_axi_bready  (d0_bready),
    .m_axi_araddr  (d0_araddr),
    .m_axi_arvalid (d0_arvalid),
    .m_axi_arready (d0_arready),
    .m_axi_rdata   (d0_rdata),
    .m_axi_rresp   (d0_rresp),
    .m_axi_rvalid  (d0_rvalid),
    .m_axi_rready  (d0_rready)
  );

  // Core 0 system registers (window SYS).
  c64_sysregs #(
    .BUILD_ID    (BUILD_ID),
    .BUILD_DIRTY (BUILD_DIRTY),
    .CORE_INDEX  (8'd0)
  ) u_sysregs0 (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .s_axi_awaddr  (d0_awaddr[S0_SYS*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_SYS]),
    .s_axi_awready (d0_awready[S0_SYS]),
    .s_axi_wdata   (d0_wdata[S0_SYS*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_SYS*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_SYS]),
    .s_axi_wready  (d0_wready[S0_SYS]),
    .s_axi_bresp   (d0_bresp[S0_SYS*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_SYS]),
    .s_axi_bready  (d0_bready[S0_SYS]),
    .s_axi_araddr  (d0_araddr[S0_SYS*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_SYS]),
    .s_axi_arready (d0_arready[S0_SYS]),
    .s_axi_rdata   (d0_rdata[S0_SYS*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_SYS*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_SYS]),
    .s_axi_rready  (d0_rready[S0_SYS]),
    .clk_status    (clk_status),
    .led           (led0)
  );

  // Audio output (window AUD): sample FIFO and I2S transmitter.
  sid_audio_out u_audio (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .s_axi_awaddr  (d0_awaddr[S0_AUD*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_AUD]),
    .s_axi_awready (d0_awready[S0_AUD]),
    .s_axi_wdata   (d0_wdata[S0_AUD*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_AUD*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_AUD]),
    .s_axi_wready  (d0_wready[S0_AUD]),
    .s_axi_bresp   (d0_bresp[S0_AUD*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_AUD]),
    .s_axi_bready  (d0_bready[S0_AUD]),
    .s_axi_araddr  (d0_araddr[S0_AUD*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_AUD]),
    .s_axi_arready (d0_arready[S0_AUD]),
    .s_axi_rdata   (d0_rdata[S0_AUD*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_AUD*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_AUD]),
    .s_axi_rready  (d0_rready[S0_AUD]),
    .strm_valid    (cpu_strm_valid),
    .strm_sample   (cpu_strm_sample),
    .irq           (aud_irq),
    .aud_clk       (aud_clk),
    .aud_resetn    (aud_resetn),
    .aud_bclk_q    (aud_bclk_q),
    .aud_lrclk_q   (aud_lrclk_q),
    .aud_sdata_q   (aud_sdata_q)
  );

  // SID sound (window SID): reDIP-SID core and register replay on the 50 MHz sid_clk, 48 kHz
  // sample stream into u_audio. Two crossings: the register slot through ik64_axil_cdc
  // (cpu_clk -> sid_clk) and the sample stream through sid_strm_cdc (sid_clk -> cpu_clk).
  ik64_axil_cdc #(
    .ADDR_W (REG_ADDR_W)
  ) u_sid_cdc (
    .s_clk         (cpu_clk),
    .s_resetn      (cpu_resetn_sync),
    .s_axi_awaddr  (d0_awaddr[S0_SID*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_SID]),
    .s_axi_awready (d0_awready[S0_SID]),
    .s_axi_wdata   (d0_wdata[S0_SID*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_SID*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_SID]),
    .s_axi_wready  (d0_wready[S0_SID]),
    .s_axi_bresp   (d0_bresp[S0_SID*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_SID]),
    .s_axi_bready  (d0_bready[S0_SID]),
    .s_axi_araddr  (d0_araddr[S0_SID*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_SID]),
    .s_axi_arready (d0_arready[S0_SID]),
    .s_axi_rdata   (d0_rdata[S0_SID*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_SID*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_SID]),
    .s_axi_rready  (d0_rready[S0_SID]),
    .m_clk         (sid_clk),
    .m_resetn      (sid_resetn),
    .m_axi_awaddr  (sx_awaddr),
    .m_axi_awvalid (sx_awvalid),
    .m_axi_awready (sx_awready),
    .m_axi_wdata   (sx_wdata),
    .m_axi_wstrb   (sx_wstrb),
    .m_axi_wvalid  (sx_wvalid),
    .m_axi_wready  (sx_wready),
    .m_axi_bresp   (sx_bresp),
    .m_axi_bvalid  (sx_bvalid),
    .m_axi_bready  (sx_bready),
    .m_axi_araddr  (sx_araddr),
    .m_axi_arvalid (sx_arvalid),
    .m_axi_arready (sx_arready),
    .m_axi_rdata   (sx_rdata),
    .m_axi_rresp   (sx_rresp),
    .m_axi_rvalid  (sx_rvalid),
    .m_axi_rready  (sx_rready)
  );

  sid_player #(
    .CLK_HZ (SID_CLK_HZ)
  ) u_sid (
    .cpu_clk       (sid_clk),
    .cpu_resetn    (sid_resetn),
    .s_axi_awaddr  (sx_awaddr),
    .s_axi_awvalid (sx_awvalid),
    .s_axi_awready (sx_awready),
    .s_axi_wdata   (sx_wdata),
    .s_axi_wstrb   (sx_wstrb),
    .s_axi_wvalid  (sx_wvalid),
    .s_axi_wready  (sx_wready),
    .s_axi_bresp   (sx_bresp),
    .s_axi_bvalid  (sx_bvalid),
    .s_axi_bready  (sx_bready),
    .s_axi_araddr  (sx_araddr),
    .s_axi_arvalid (sx_arvalid),
    .s_axi_arready (sx_arready),
    .s_axi_rdata   (sx_rdata),
    .s_axi_rresp   (sx_rresp),
    .s_axi_rvalid  (sx_rvalid),
    .s_axi_rready  (sx_rready),
    .strm_valid    (sid_strm_valid),
    .strm_sample   (sid_strm_sample)
  );

  sid_strm_cdc u_sid_strm (
    .sid_clk    (sid_clk),
    .sid_resetn (sid_resetn),
    .in_valid   (sid_strm_valid),
    .in_sample  (sid_strm_sample),
    .cpu_clk    (cpu_clk),
    .out_valid  (cpu_strm_valid),
    .out_sample (cpu_strm_sample)
  );


  // Video (window VID) with framebuffer port A from the BD.
  c64_video u_video (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .pix_clk       (pix_clk),
    .pix_resetn    (pix_resetn),
    .s_axi_awaddr  (d0_awaddr[S0_VID*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_VID]),
    .s_axi_awready (d0_awready[S0_VID]),
    .s_axi_wdata   (d0_wdata[S0_VID*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_VID*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_VID]),
    .s_axi_wready  (d0_wready[S0_VID]),
    .s_axi_bresp   (d0_bresp[S0_VID*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_VID]),
    .s_axi_bready  (d0_bready[S0_VID]),
    .s_axi_araddr  (d0_araddr[S0_VID*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_VID]),
    .s_axi_arready (d0_arready[S0_VID]),
    .s_axi_rdata   (d0_rdata[S0_VID*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_VID*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_VID]),
    .s_axi_rready  (d0_rready[S0_VID]),
    .fb_bram_addr  (fb_bram_addr),
    .fb_bram_en    (fb_bram_en),
    .fb_bram_we    (fb_bram_we),
    .fb_bram_din   (fb_bram_din),
    .fb_bram_dout  (fb_bram_dout),
    .irq           (vid_irq),
    .tmds_ch0      (tmds_word[0]),
    .tmds_ch1      (tmds_word[1]),
    .tmds_ch2      (tmds_word[2]),
    .tmds_clk      (tmds_word[3]),
    .vid_de        (),
    .vid_hsync     (),
    .vid_vsync     (),
    .vid_rgb       ()
  );

  // PS/2 keyboard receiver (window PS2).
  ps2_rx #(
    .CLK_HZ (CPU_CLK_HZ)
  ) u_ps2 (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .s_axi_awaddr  (d0_awaddr[S0_PS2*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_PS2]),
    .s_axi_awready (d0_awready[S0_PS2]),
    .s_axi_wdata   (d0_wdata[S0_PS2*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_PS2*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_PS2]),
    .s_axi_wready  (d0_wready[S0_PS2]),
    .s_axi_bresp   (d0_bresp[S0_PS2*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_PS2]),
    .s_axi_bready  (d0_bready[S0_PS2]),
    .s_axi_araddr  (d0_araddr[S0_PS2*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_PS2]),
    .s_axi_arready (d0_arready[S0_PS2]),
    .s_axi_rdata   (d0_rdata[S0_PS2*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_PS2*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_PS2]),
    .s_axi_rready  (d0_rready[S0_PS2]),
    .ps2_clk       (ps2_clk),
    .ps2_data      (ps2_data),
    .irq           (ps2_irq)
  );

  // OLED display driver (window OLED, 4 KiB used of the 64 KiB slot).
  // The board check of 11-10-2026 showed the default orientation (0xA1 / 0xC8) upside down: the
  // board uses 0xA0 / 0xC0 (the hardware scroll follows the panel rotation).
  c64_oled #(
    .CPU_CLK_HZ  (CPU_CLK_HZ),
    .SEG_REMAP   (1'b0),
    .COM_REVERSE (1'b0)
  ) u_oled (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .s_axi_awaddr  (d0_awaddr[S0_OLED*AW +: OLED_ADDR_W]),
    .s_axi_awvalid (d0_awvalid[S0_OLED]),
    .s_axi_awready (d0_awready[S0_OLED]),
    .s_axi_wdata   (d0_wdata[S0_OLED*32 +: 32]),
    .s_axi_wstrb   (d0_wstrb[S0_OLED*4 +: 4]),
    .s_axi_wvalid  (d0_wvalid[S0_OLED]),
    .s_axi_wready  (d0_wready[S0_OLED]),
    .s_axi_bresp   (d0_bresp[S0_OLED*2 +: 2]),
    .s_axi_bvalid  (d0_bvalid[S0_OLED]),
    .s_axi_bready  (d0_bready[S0_OLED]),
    .s_axi_araddr  (d0_araddr[S0_OLED*AW +: OLED_ADDR_W]),
    .s_axi_arvalid (d0_arvalid[S0_OLED]),
    .s_axi_arready (d0_arready[S0_OLED]),
    .s_axi_rdata   (d0_rdata[S0_OLED*32 +: 32]),
    .s_axi_rresp   (d0_rresp[S0_OLED*2 +: 2]),
    .s_axi_rvalid  (d0_rvalid[S0_OLED]),
    .s_axi_rready  (d0_rready[S0_OLED]),
    .oled_dc       (oled_dc),
    .oled_res      (oled_res),
    .oled_sclk     (oled_sclk),
    .oled_sdin     (oled_sdin),
    .oled_vbat     (oled_vbat),
    .oled_vdd      (oled_vdd)
  );

  // ---------------------------------------------------------------------------
  // Register window 1 (core 1): SYS and the network core (below).
  // ---------------------------------------------------------------------------
  ik64_axil_decoder #(
    .N          (NUM_SLV1),
    .ADDR_W     (AW),
    .SLAVE_BASE (SLAVE1_BASE),
    .SLAVE_SIZE (SLAVE1_SIZE)
  ) u_dec1 (
    .aclk          (cpu_clk),
    .aresetn       (cpu_resetn_sync),
    .s_axi_awaddr  (c1_awaddr),
    .s_axi_awvalid (c1_awvalid),
    .s_axi_awready (c1_awready),
    .s_axi_wdata   (c1_wdata),
    .s_axi_wstrb   (c1_wstrb),
    .s_axi_wvalid  (c1_wvalid),
    .s_axi_wready  (c1_wready),
    .s_axi_bresp   (c1_bresp),
    .s_axi_bvalid  (c1_bvalid),
    .s_axi_bready  (c1_bready),
    .s_axi_araddr  (c1_araddr),
    .s_axi_arvalid (c1_arvalid),
    .s_axi_arready (c1_arready),
    .s_axi_rdata   (c1_rdata),
    .s_axi_rresp   (c1_rresp),
    .s_axi_rvalid  (c1_rvalid),
    .s_axi_rready  (c1_rready),
    .m_axi_awaddr  (d1_awaddr),
    .m_axi_awvalid (d1_awvalid),
    .m_axi_awready (d1_awready),
    .m_axi_wdata   (d1_wdata),
    .m_axi_wstrb   (d1_wstrb),
    .m_axi_wvalid  (d1_wvalid),
    .m_axi_wready  (d1_wready),
    .m_axi_bresp   (d1_bresp),
    .m_axi_bvalid  (d1_bvalid),
    .m_axi_bready  (d1_bready),
    .m_axi_araddr  (d1_araddr),
    .m_axi_arvalid (d1_arvalid),
    .m_axi_arready (d1_arready),
    .m_axi_rdata   (d1_rdata),
    .m_axi_rresp   (d1_rresp),
    .m_axi_rvalid  (d1_rvalid),
    .m_axi_rready  (d1_rready)
  );

  // Core 1 system registers (SYS slot, 4 KiB; the register file
  // decodes REG_ADDR_W bits, which inside a 4 KiB slot at a 64 KiB-aligned
  // base are the in-slot offset).
  c64_sysregs #(
    .BUILD_ID    (BUILD_ID),
    .BUILD_DIRTY (BUILD_DIRTY),
    .CORE_INDEX  (8'd1)
  ) u_sysregs1 (
    .cpu_clk       (cpu_clk),
    .cpu_resetn    (cpu_resetn_sync),
    .s_axi_awaddr  (d1_awaddr[S1_SYS*AW +: REG_ADDR_W]),
    .s_axi_awvalid (d1_awvalid[S1_SYS]),
    .s_axi_awready (d1_awready[S1_SYS]),
    .s_axi_wdata   (d1_wdata[S1_SYS*32 +: 32]),
    .s_axi_wstrb   (d1_wstrb[S1_SYS*4 +: 4]),
    .s_axi_wvalid  (d1_wvalid[S1_SYS]),
    .s_axi_wready  (d1_wready[S1_SYS]),
    .s_axi_bresp   (d1_bresp[S1_SYS*2 +: 2]),
    .s_axi_bvalid  (d1_bvalid[S1_SYS]),
    .s_axi_bready  (d1_bready[S1_SYS]),
    .s_axi_araddr  (d1_araddr[S1_SYS*AW +: REG_ADDR_W]),
    .s_axi_arvalid (d1_arvalid[S1_SYS]),
    .s_axi_arready (d1_arready[S1_SYS]),
    .s_axi_rdata   (d1_rdata[S1_SYS*32 +: 32]),
    .s_axi_rresp   (d1_rresp[S1_SYS*2 +: 2]),
    .s_axi_rvalid  (d1_rvalid[S1_SYS]),
    .s_axi_rready  (d1_rready[S1_SYS]),
    .clk_status    (clk_status),
    .led           (led1)
  );

  // ---------------------------------------------------------------------------
  // Network core (closed netlist fpga/netlist/ik64_net_core.dcp, interface in
  // ik64_net_core.md): RGMII MAC with pin layer, MDIO/PHY reset core and protocol
  // wrapper (ARP, ICMP, DHCP, iperf, CPU path with classifier and checksum offload).
  // The RGMII pin timing is fpga/constraints/ik64_rgmii.xdc. The core drives
  // eth_rst_b low until the firmware releases the PHY. The MDIO line is the top's
  // IOBUF below.
  // ---------------------------------------------------------------------------
  ik64_net_core u_net (
    .clk125               (clk125),
    .clk125_90            (clk125_90),
    .clk200               (clk200),
    .axis_clk             (axis_clk),
    .cpu_clk              (cpu_clk),
    .sid_clk              (sid_clk),
    .clk125_resetn        (clk125_resetn),
    .clk200_resetn        (clk200_resetn),
    .axis_resetn          (axis_resetn),
    .cpu_resetn_sync      (cpu_resetn_sync),
    .sid_resetn           (sid_resetn),
    .eth_rxck             (eth_rxck),
    .eth_rxctl            (eth_rxctl),
    .eth_rxd              (eth_rxd),
    .eth_txck             (eth_txck),
    .eth_txctl            (eth_txctl),
    .eth_txd              (eth_txd),
    .eth_mdc              (eth_mdc),
    .mdio_o               (mdio_o),
    .mdio_t               (mdio_t),
    .mdio_i               (mdio_i),
    .eth_rst_b            (eth_rst_b),
    .eth_int_b            (eth_int_b),
    .s_axi_mac_awaddr      (d1_awaddr[S1_MAC*AW +: MAC_ADDR_W]),
    .s_axi_mac_awvalid     (d1_awvalid[S1_MAC]),
    .s_axi_mac_awready     (d1_awready[S1_MAC]),
    .s_axi_mac_wdata       (d1_wdata[S1_MAC*32 +: 32]),
    .s_axi_mac_wstrb       (d1_wstrb[S1_MAC*4 +: 4]),
    .s_axi_mac_wvalid      (d1_wvalid[S1_MAC]),
    .s_axi_mac_wready      (d1_wready[S1_MAC]),
    .s_axi_mac_bresp       (d1_bresp[S1_MAC*2 +: 2]),
    .s_axi_mac_bvalid      (d1_bvalid[S1_MAC]),
    .s_axi_mac_bready      (d1_bready[S1_MAC]),
    .s_axi_mac_araddr      (d1_araddr[S1_MAC*AW +: MAC_ADDR_W]),
    .s_axi_mac_arvalid     (d1_arvalid[S1_MAC]),
    .s_axi_mac_arready     (d1_arready[S1_MAC]),
    .s_axi_mac_rdata       (d1_rdata[S1_MAC*32 +: 32]),
    .s_axi_mac_rresp       (d1_rresp[S1_MAC*2 +: 2]),
    .s_axi_mac_rvalid      (d1_rvalid[S1_MAC]),
    .s_axi_mac_rready      (d1_rready[S1_MAC]),
    .s_axi_mdio_awaddr     (d1_awaddr[S1_MDIO*AW +: MAC_ADDR_W]),
    .s_axi_mdio_awvalid    (d1_awvalid[S1_MDIO]),
    .s_axi_mdio_awready    (d1_awready[S1_MDIO]),
    .s_axi_mdio_wdata      (d1_wdata[S1_MDIO*32 +: 32]),
    .s_axi_mdio_wstrb      (d1_wstrb[S1_MDIO*4 +: 4]),
    .s_axi_mdio_wvalid     (d1_wvalid[S1_MDIO]),
    .s_axi_mdio_wready     (d1_wready[S1_MDIO]),
    .s_axi_mdio_bresp      (d1_bresp[S1_MDIO*2 +: 2]),
    .s_axi_mdio_bvalid     (d1_bvalid[S1_MDIO]),
    .s_axi_mdio_bready     (d1_bready[S1_MDIO]),
    .s_axi_mdio_araddr     (d1_araddr[S1_MDIO*AW +: MAC_ADDR_W]),
    .s_axi_mdio_arvalid    (d1_arvalid[S1_MDIO]),
    .s_axi_mdio_arready    (d1_arready[S1_MDIO]),
    .s_axi_mdio_rdata      (d1_rdata[S1_MDIO*32 +: 32]),
    .s_axi_mdio_rresp      (d1_rresp[S1_MDIO*2 +: 2]),
    .s_axi_mdio_rvalid     (d1_rvalid[S1_MDIO]),
    .s_axi_mdio_rready     (d1_rready[S1_MDIO]),
    .s_axi_prot_awaddr     (d1_awaddr[S1_PROT*AW +: PROT_ADDR_W]),
    .s_axi_prot_awvalid    (d1_awvalid[S1_PROT]),
    .s_axi_prot_awready    (d1_awready[S1_PROT]),
    .s_axi_prot_wdata      (d1_wdata[S1_PROT*32 +: 32]),
    .s_axi_prot_wstrb      (d1_wstrb[S1_PROT*4 +: 4]),
    .s_axi_prot_wvalid     (d1_wvalid[S1_PROT]),
    .s_axi_prot_wready     (d1_wready[S1_PROT]),
    .s_axi_prot_bresp      (d1_bresp[S1_PROT*2 +: 2]),
    .s_axi_prot_bvalid     (d1_bvalid[S1_PROT]),
    .s_axi_prot_bready     (d1_bready[S1_PROT]),
    .s_axi_prot_araddr     (d1_araddr[S1_PROT*AW +: PROT_ADDR_W]),
    .s_axi_prot_arvalid    (d1_arvalid[S1_PROT]),
    .s_axi_prot_arready    (d1_arready[S1_PROT]),
    .s_axi_prot_rdata      (d1_rdata[S1_PROT*32 +: 32]),
    .s_axi_prot_rresp      (d1_rresp[S1_PROT*2 +: 2]),
    .s_axi_prot_rvalid     (d1_rvalid[S1_PROT]),
    .s_axi_prot_rready     (d1_rready[S1_PROT]),
    .cpu_eth_rx_tdata     (cpu_eth_rx_tdata),
    .cpu_eth_rx_tkeep     (cpu_eth_rx_tkeep),
    .cpu_eth_rx_tvalid    (cpu_eth_rx_tvalid),
    .cpu_eth_rx_tlast     (cpu_eth_rx_tlast),
    .cpu_eth_rx_tready    (cpu_eth_rx_tready),
    .cpu_eth_tx_tdata     (cpu_eth_tx_tdata),
    .cpu_eth_tx_tkeep     (cpu_eth_tx_tkeep),
    .cpu_eth_tx_tvalid    (cpu_eth_tx_tvalid),
    .cpu_eth_tx_tlast     (cpu_eth_tx_tlast),
    .cpu_eth_tx_tready    (cpu_eth_tx_tready),
    .mdio_irq             (mdio_irq),
    .mac_stat_link_up     (mac_stat_link_up),
    .mac_stat_speed       (),
    .mac_stat_rx_clk_ok   (),
    .prot_stat_ip_valid   (),
    .prot_stat_dhcp_bound ()
  );

  // MDIO pad: the only driver of eth_mdio; mdio_t = 1 releases the line.
  IOBUF u_mdio_iobuf (
    .I  (mdio_o),
    .T  (mdio_t),
    .O  (mdio_i),
    .IO (eth_mdio)
  );

  // ---------------------------------------------------------------------------
  // DDR3 path: AXI clock converter cpu_clk -> ui_clk (AMD axi_clock_converter IP
  // ik64_ddr_cc), then the MIG (ik64_ddr). One master reaches the controller (both
  // cores' caches, merged by the BD's sc_ddr), so there is no arbiter. The BD port has
  // no IDs: the converter's 2-bit IDs are tied 0 and the MIG returns them unchanged.
  // ---------------------------------------------------------------------------
  ik64_axi_cdc #(
    .ADDR_W          (DDR_ADDR_W),
    .DATA_W          (DDR_DATA_W),
    .ID_W            (DDR_ID_W)
  ) u_ddr_cdc (
    .s_clk         (cpu_clk),
    .s_resetn      (cpu_resetn_sync),
    .s_axi_awid    (2'b0),
    .s_axi_awaddr  (cpu_ddr_awaddr[DDR_ADDR_W-1:0]),
    .s_axi_awlen   (cpu_ddr_awlen),
    .s_axi_awsize  (cpu_ddr_awsize),
    .s_axi_awburst (cpu_ddr_awburst),
    .s_axi_awlock  (cpu_ddr_awlock),
    .s_axi_awcache (cpu_ddr_awcache),
    .s_axi_awprot  (cpu_ddr_awprot),
    .s_axi_awqos   (cpu_ddr_awqos),
    .s_axi_awvalid (cpu_ddr_awvalid),
    .s_axi_awready (cpu_ddr_awready),
    .s_axi_wdata   (cpu_ddr_wdata),
    .s_axi_wstrb   (cpu_ddr_wstrb),
    .s_axi_wlast   (cpu_ddr_wlast),
    .s_axi_wvalid  (cpu_ddr_wvalid),
    .s_axi_wready  (cpu_ddr_wready),
    .s_axi_bid     (),
    .s_axi_bresp   (cpu_ddr_bresp),
    .s_axi_bvalid  (cpu_ddr_bvalid),
    .s_axi_bready  (cpu_ddr_bready),
    .s_axi_arid    (2'b0),
    .s_axi_araddr  (cpu_ddr_araddr[DDR_ADDR_W-1:0]),
    .s_axi_arlen   (cpu_ddr_arlen),
    .s_axi_arsize  (cpu_ddr_arsize),
    .s_axi_arburst (cpu_ddr_arburst),
    .s_axi_arlock  (cpu_ddr_arlock),
    .s_axi_arcache (cpu_ddr_arcache),
    .s_axi_arprot  (cpu_ddr_arprot),
    .s_axi_arqos   (cpu_ddr_arqos),
    .s_axi_arvalid (cpu_ddr_arvalid),
    .s_axi_arready (cpu_ddr_arready),
    .s_axi_rid     (),
    .s_axi_rdata   (cpu_ddr_rdata),
    .s_axi_rresp   (cpu_ddr_rresp),
    .s_axi_rlast   (cpu_ddr_rlast),
    .s_axi_rvalid  (cpu_ddr_rvalid),
    .s_axi_rready  (cpu_ddr_rready),
    .m_clk         (ui_clk),
    .m_resetn      (ddr_resetn),
    .m_axi_awid    (mem_awid),
    .m_axi_awaddr  (mem_awaddr),
    .m_axi_awlen   (mem_awlen),
    .m_axi_awsize  (mem_awsize),
    .m_axi_awburst (mem_awburst),
    .m_axi_awlock  (mem_awlock),
    .m_axi_awcache (mem_awcache),
    .m_axi_awprot  (mem_awprot),
    .m_axi_awqos   (mem_awqos),
    .m_axi_awvalid (mem_awvalid),
    .m_axi_awready (mem_awready),
    .m_axi_wdata   (mem_wdata),
    .m_axi_wstrb   (mem_wstrb),
    .m_axi_wlast   (mem_wlast),
    .m_axi_wvalid  (mem_wvalid),
    .m_axi_wready  (mem_wready),
    .m_axi_bid     (mem_bid),
    .m_axi_bresp   (mem_bresp),
    .m_axi_bvalid  (mem_bvalid),
    .m_axi_bready  (mem_bready),
    .m_axi_arid    (mem_arid),
    .m_axi_araddr  (mem_araddr),
    .m_axi_arlen   (mem_arlen),
    .m_axi_arsize  (mem_arsize),
    .m_axi_arburst (mem_arburst),
    .m_axi_arlock  (mem_arlock),
    .m_axi_arcache (mem_arcache),
    .m_axi_arprot  (mem_arprot),
    .m_axi_arqos   (mem_arqos),
    .m_axi_arvalid (mem_arvalid),
    .m_axi_arready (mem_arready),
    .m_axi_rid     (mem_rid),
    .m_axi_rdata   (mem_rdata),
    .m_axi_rresp   (mem_rresp),
    .m_axi_rlast   (mem_rlast),
    .m_axi_rvalid  (mem_rvalid),
    .m_axi_rready  (mem_rready)
  );

  // DDR3 controller: sys_clk ddr_sys_clk, ref_clk clk200; sys_rstn is the
  // board reset assertion (a button press recalibrates the memory).
  ik64_ddr #(
    .ADDR_W (DDR_ADDR_W),
    .DATA_W (DDR_DATA_W),
    .ID_W   (DDR_ID_W)
  ) u_ddr (
    .sys_clk             (ddr_sys_clk),
    .ref_clk             (clk200),
    .sys_rstn            (rst_arstn),
    .ui_clk              (ui_clk),
    .ui_resetn           (ui_resetn_mig),
    .s_axi_aresetn       (ddr_resetn),
    .init_calib_complete (ddr_calib),
    .s_axi_awid          (mem_awid),
    .s_axi_awaddr        (mem_awaddr),
    .s_axi_awlen         (mem_awlen),
    .s_axi_awsize        (mem_awsize),
    .s_axi_awburst       (mem_awburst),
    .s_axi_awlock        (mem_awlock),
    .s_axi_awcache       (mem_awcache),
    .s_axi_awprot        (mem_awprot),
    .s_axi_awqos         (mem_awqos),
    .s_axi_awvalid       (mem_awvalid),
    .s_axi_awready       (mem_awready),
    .s_axi_wdata         (mem_wdata),
    .s_axi_wstrb         (mem_wstrb),
    .s_axi_wlast         (mem_wlast),
    .s_axi_wvalid        (mem_wvalid),
    .s_axi_wready        (mem_wready),
    .s_axi_bid           (mem_bid),
    .s_axi_bresp         (mem_bresp),
    .s_axi_bvalid        (mem_bvalid),
    .s_axi_bready        (mem_bready),
    .s_axi_arid          (mem_arid),
    .s_axi_araddr        (mem_araddr),
    .s_axi_arlen         (mem_arlen),
    .s_axi_arsize        (mem_arsize),
    .s_axi_arburst       (mem_arburst),
    .s_axi_arlock        (mem_arlock),
    .s_axi_arcache       (mem_arcache),
    .s_axi_arprot        (mem_arprot),
    .s_axi_arqos         (mem_arqos),
    .s_axi_arvalid       (mem_arvalid),
    .s_axi_arready       (mem_arready),
    .s_axi_rid           (mem_rid),
    .s_axi_rdata         (mem_rdata),
    .s_axi_rresp         (mem_rresp),
    .s_axi_rlast         (mem_rlast),
    .s_axi_rvalid        (mem_rvalid),
    .s_axi_rready        (mem_rready),
    .ddr3_dq             (ddr3_dq),
    .ddr3_dqs_n          (ddr3_dqs_n),
    .ddr3_dqs_p          (ddr3_dqs_p),
    .ddr3_addr           (ddr3_addr),
    .ddr3_ba             (ddr3_ba),
    .ddr3_ras_n          (ddr3_ras_n),
    .ddr3_cas_n          (ddr3_cas_n),
    .ddr3_we_n           (ddr3_we_n),
    .ddr3_reset_n        (ddr3_reset_n),
    .ddr3_ck_p           (ddr3_ck_p),
    .ddr3_ck_n           (ddr3_ck_n),
    .ddr3_cke            (ddr3_cke),
    .ddr3_dm             (ddr3_dm),
    .ddr3_odt            (ddr3_odt)
  );

  // ---------------------------------------------------------------------------
  // HDMI TMDS output: per lane an OSERDESE2 master/slave pair, 10:1 DDR,
  // CLKDIV pix_clk, CLK pix_clk_x5, bit 0 first (master D1 = bit 0 ... D8 =
  // bit 7, slave D3/D4 = bits 8/9 through SHIFTIN), then OBUFDS (TMDS_33).
  // RST is the primitives' asynchronous reset, driven from pix_resetn, which
  // is synchronous to CLKDIV as UG471 requires (vendor primitive exception).
  // ---------------------------------------------------------------------------
  genvar gl;
  generate
    for (gl = 0; gl < TMDS_LANES; gl++) begin : g_tmds
      logic shift1;
      logic shift2;

      OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (TMDS_W),
        .SERDES_MODE    ("MASTER"),
        .TRISTATE_WIDTH (1),
        .TBYTE_CTL      ("FALSE"),
        .TBYTE_SRC      ("FALSE")
      ) u_ser_m (
        .OQ        (tmds_ser[gl]),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .SHIFTOUT1 (),
        .SHIFTOUT2 (),
        .TBYTEOUT  (),
        .CLK       (pix_clk_x5),
        .CLKDIV    (pix_clk),
        .D1        (tmds_word[gl][0]),
        .D2        (tmds_word[gl][1]),
        .D3        (tmds_word[gl][2]),
        .D4        (tmds_word[gl][3]),
        .D5        (tmds_word[gl][4]),
        .D6        (tmds_word[gl][5]),
        .D7        (tmds_word[gl][6]),
        .D8        (tmds_word[gl][7]),
        .OCE       (1'b1),
        .RST       (~pix_resetn),
        .SHIFTIN1  (shift1),
        .SHIFTIN2  (shift2),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
      );

      OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (TMDS_W),
        .SERDES_MODE    ("SLAVE"),
        .TRISTATE_WIDTH (1),
        .TBYTE_CTL      ("FALSE"),
        .TBYTE_SRC      ("FALSE")
      ) u_ser_s (
        .OQ        (),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .SHIFTOUT1 (shift1),
        .SHIFTOUT2 (shift2),
        .TBYTEOUT  (),
        .CLK       (pix_clk_x5),
        .CLKDIV    (pix_clk),
        .D1        (1'b0),
        .D2        (1'b0),
        .D3        (tmds_word[gl][8]),
        .D4        (tmds_word[gl][9]),
        .D5        (1'b0),
        .D6        (1'b0),
        .D7        (1'b0),
        .D8        (1'b0),
        .OCE       (1'b1),
        .RST       (~pix_resetn),
        .SHIFTIN1  (1'b0),
        .SHIFTIN2  (1'b0),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
      );
    end
  endgenerate

  OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_tmds0 (.I(tmds_ser[0]), .O(hdmi_tx_p[0]),  .OB(hdmi_tx_n[0]));
  OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_tmds1 (.I(tmds_ser[1]), .O(hdmi_tx_p[1]),  .OB(hdmi_tx_n[1]));
  OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_tmds2 (.I(tmds_ser[2]), .O(hdmi_tx_p[2]),  .OB(hdmi_tx_n[2]));
  OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_tmdsc (.I(tmds_ser[3]), .O(hdmi_tx_clk_p), .OB(hdmi_tx_clk_n));

  // ---------------------------------------------------------------------------
  // Audio pins: MCLK forwarded by ODDR (D1 1, D2 0 = aud_clk in phase); BCLK,
  // LRCLK and DAC data re-registered into IOB flip-flops on aud_clk. All three
  // take the same one-clock delay, so their relative timing is that of
  // sid_audio_out (data changes on the BCLK falling edge).
  // ---------------------------------------------------------------------------
  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"),
    .INIT         (1'b0),
    .SRTYPE       ("SYNC")
  ) u_oddr_mclk (
    .Q  (ac_mclk),
    .C  (aud_clk),
    .CE (1'b1),
    .D1 (1'b1),
    .D2 (1'b0),
    .R  (1'b0),
    .S  (1'b0)
  );

  (* IOB = "TRUE" *) logic ac_bclk_q;
  (* IOB = "TRUE" *) logic ac_lrclk_q;
  (* IOB = "TRUE" *) logic ac_dac_sdata_q;

  always_ff @(posedge aud_clk) begin
    if (!aud_resetn) begin
      ac_bclk_q      <= 1'b0;
      ac_lrclk_q     <= 1'b0;
      ac_dac_sdata_q <= 1'b0;
    end else begin
      ac_bclk_q      <= aud_bclk_q;
      ac_lrclk_q     <= aud_lrclk_q;
      ac_dac_sdata_q <= aud_sdata_q;
    end
  end

  assign ac_bclk      = ac_bclk_q;
  assign ac_lrclk     = ac_lrclk_q;
  assign ac_dac_sdata = ac_dac_sdata_q;

  // ---------------------------------------------------------------------------
  // LEDs.
  // ---------------------------------------------------------------------------
  assign led = {led1[3:0], led0[1:0], clk_status[SYS_CLK_DDR_CALIB_BIT], mmcm_locked};

endmodule
