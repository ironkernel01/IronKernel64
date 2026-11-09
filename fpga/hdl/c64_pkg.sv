// -----------------------------------------------------------------------------
// File: c64_pkg.sv
// Purpose: single source of the IronKernel 64 register maps, geometry and
//   timing constants shared by the RTL, the testbenches and (by mirror) the
//   core 0 firmware.
// Overview:
//   * Register offsets are byte offsets inside each block's 64 KiB AXI4-Lite
//     window; base addresses are owned by fpga/bd/c64_bd.tcl and reach the
//     firmware through the XSA (xparameters.h), never through this file.
//   * fw_c64/src/c64_regs.h mirrors every offset, bit and geometry constant of
//     this package under the same name with a C64_ prefix. The firmware build
//     (fw_c64/build.ps1, step "regs check") compares the two files and fails on
//     any difference. Change both files in the same commit.
//   * Failure mode of drift: firmware writes land in the wrong register (for
//     example a palette write landing in CTRL blanks the display), and reads
//     return another register's value; nothing in hardware detects it.
//   * Every register is 32 bits; partial (wstrb != 4'hF) writes are ignored by
//     rtlnet_axil_slave and answered OKAY.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 11-09-2026
//   * 11-09-2026: initial version (sysregs, audio, video, PS/2 maps; video and
//     audio geometry).
//   * 11-09-2026: SID player map, CPU_CLK_HZ / SID_CLK_HZ, AUD_CTRL_SRC_BIT,
//     WIN_SID_OFS and the 512 KiB window 0.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package c64_pkg;

  // ---------------------------------------------------------------------------
  // Common
  // ---------------------------------------------------------------------------
  localparam int REG_ADDR_W = 16;                      // 64 KiB AXI4-Lite window per block
  localparam int CPU_CLK_HZ = 100_000_000;             // cpu_clk: core 0 AXI and register blocks
  localparam int SID_CLK_HZ = 50_000_000;              // sid_clk: sid_player, the reDIP-SID core (needs >= 20 clocks per phi2)

  // Core 0 fabric window: the BD exports one AXI4-Lite master (M_AXI_C64,
  // base C64_WINDOW_BASE owned by fpga/bd/c64_bd.tcl); c64_top splits it with
  // rtlnet_axil_decoder into these 64 KiB blocks at these offsets.
  localparam logic [31:0] WIN_SYS_OFS  = 32'h0000_0000; // c64_sysregs (core 0 instance)
  localparam logic [31:0] WIN_AUD_OFS  = 32'h0001_0000; // sid_audio_out
  localparam logic [31:0] WIN_VID_OFS  = 32'h0002_0000; // c64_video registers
  localparam logic [31:0] WIN_PS2_OFS  = 32'h0003_0000; // ps2_rx
  localparam logic [31:0] WIN_SID_OFS  = 32'h0004_0000; // sid_player (64 KiB slot, sid_player.sv)
  localparam logic [31:0] WIN_BLOCK_SIZE = 32'h0001_0000;
  localparam logic [31:0] WIN_SIZE     = 32'h0008_0000; // whole window, 512 KiB

  // Core 1 fabric window (M_AXI_DRV, 1 MiB): RTLNet's register-window layout, so
  // the RTLNet network drivers reused by fw_1541 see their blocks at RTLNet's
  // offsets. The IronKernel 64 core 1 c64_sysregs instance takes RTLNet's SYS
  // slot at offset 0. The MAC, MDIO and PROTOCOL slots are filled in Phase 4
  // (network path); until then c64_top answers them with stubs (read 0).
  localparam logic [31:0] WIN1_SYS_OFS   = 32'h0000_0000; // c64_sysregs (core 1 instance)
  localparam logic [31:0] WIN1_MAC_OFS   = 32'h0000_1000; // rtlnet_eth_mac (Phase 4)
  localparam logic [31:0] WIN1_MDIO_OFS  = 32'h0000_2000; // rtlnet MDIO master (Phase 4)
  localparam logic [31:0] WIN1_ARB_OFS   = 32'h0000_4000; // rtlnet_axi_arbiter register port (DDR3)
  localparam logic [31:0] WIN1_PROT_OFS  = 32'h0001_0000; // rtlnet_eth_protocol (Phase 4)
  localparam logic [31:0] WIN1_SLOT_SIZE = 32'h0000_1000; // SYS, MAC, MDIO, ARB slots
  localparam logic [31:0] WIN1_PROT_SIZE = 32'h0001_0000; // PROTOCOL slot
  localparam logic [31:0] WIN1_SIZE      = 32'h0010_0000; // whole window, 1 MiB

  // ---------------------------------------------------------------------------
  // System registers (c64_sysregs), cpu_clk domain, one instance per core.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] SYS_MAGIC_OFS       = 16'h0000; // RO 'IK64'
  localparam logic [15:0] SYS_BUILD_ID_OFS    = 16'h0004; // RO git hash (8 hex digits)
  localparam logic [15:0] SYS_BUILD_FLAGS_OFS = 16'h0008; // RO bit 0 tree dirty, bits 15:8 core index
  localparam logic [15:0] SYS_CLK_STATUS_OFS  = 16'h000C; // RO status bits below
  localparam logic [15:0] SYS_LED_OFS         = 16'h0010; // RW LED byte (this core's LED field)
  localparam logic [15:0] SYS_SCRATCH_OFS     = 16'h0014; // RW scratch

  localparam logic [31:0] SYS_MAGIC_VALUE     = 32'h494B_3634; // ASCII "IK64"

  localparam int SYS_CLK_PIX_LOCKED_BIT = 0;           // pixel MMCM locked
  localparam int SYS_CLK_DDR_CALIB_BIT  = 1;           // MIG init_calib_complete
  localparam int SYS_CLK_AUD_LOCKED_BIT = 2;           // audio MMCM locked
  localparam int SYS_CLK_HDMI_HPD_BIT   = 3;           // HDMI TX hot-plug detect
  localparam int SYS_CLK_ETH_LINK_BIT   = 4;           // Ethernet link up (core 1 network path)

  // ---------------------------------------------------------------------------
  // Audio output (sid_audio_out): sample FIFO to the ADAU1761 over I2S.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] AUD_CTRL_OFS      = 16'h0000; // RW control bits below
  localparam logic [15:0] AUD_STATUS_OFS    = 16'h0004; // RW1C status bits below
  localparam logic [15:0] AUD_LEVEL_OFS     = 16'h0008; // RO FIFO fill in samples (cpu_clk view)
  localparam logic [15:0] AUD_SAMPLE_OFS    = 16'h000C; // WO one stereo frame: [15:0] left, [31:16] right
  localparam logic [15:0] AUD_UNDERRUNS_OFS = 16'h0010; // RO frames sent while the FIFO was empty (saturating)
  localparam logic [15:0] AUD_THRESH_OFS    = 16'h0014; // RW IRQ level: interrupt while LEVEL <= THRESH

  localparam int AUD_CTRL_ENABLE_BIT  = 0;             // 1: play FIFO; 0: send silence, FIFO holds
  localparam int AUD_CTRL_FLUSH_BIT   = 1;             // write 1: empty the FIFO (self-clearing)
  localparam int AUD_CTRL_SRC_BIT     = 2;             // 0: AUD_SAMPLE writes; 1: sid_player stream (mono to L/R)
  localparam int AUD_CTRL_IRQ_EN_BIT  = 8;             // low-level interrupt enable

  localparam int AUD_STATUS_IRQ_BIT      = 0;          // low-level interrupt pending (W1C)
  localparam int AUD_STATUS_UNDERRUN_BIT = 1;          // underrun since last clear (W1C)
  localparam int AUD_STATUS_FULL_BIT     = 2;          // FIFO full (RO)

  localparam int AUD_FIFO_DEPTH      = 2048;           // stereo frames
  localparam int AUD_LEVEL_W         = 12;             // 0..2048
  localparam int AUD_SAMPLE_RATE_HZ  = 48_000;
  localparam int AUD_MCLK_PER_FS     = 256;            // ADAU1761 MCLK = 256 * fs = 12.288 MHz
  localparam int AUD_BCLK_PER_FS     = 64;             // 2 x 32-bit I2S slots
  localparam int AUD_SAMPLE_W        = 16;             // MSB-aligned in each 32-bit slot

  // ---------------------------------------------------------------------------
  // SID player (sid_player): timestamped register writes into the reDIP-SID
  // core, replayed on a 985,248 Hz phi2; 48 kHz audio stream to sid_audio_out.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] SID_CTRL_OFS   = 16'h0000; // RW control bits below
  localparam logic [15:0] SID_STATUS_OFS = 16'h0004; // RW1C status bits below
  localparam logic [15:0] SID_CYCLE_OFS  = 16'h0008; // RO phi2 cycle counter (falling edges)
  localparam logic [15:0] SID_WTIME_OFS  = 16'h000C; // WO time of the next write (phi2 cycle)
  localparam logic [15:0] SID_WDATA_OFS  = 16'h0010; // WO push {WTIME, reg, val}: [12:8] reg, [7:0] val
  localparam logic [15:0] SID_RDBK_OFS   = 16'h0014; // RO [7:0] OSC3, [15:8] ENV3

  localparam int SID_CTRL_RUN_BIT        = 0;        // 1: phi2 runs and the FIFO is replayed
  localparam int SID_CTRL_RESET_BIT      = 1;        // level: hold SID res, flush FIFO, clear CYCLE and stickies

  localparam int SID_STATUS_OVERFLOW_BIT = 0;        // WDATA push dropped, FIFO full (W1C)
  localparam int SID_STATUS_FULL_BIT     = 1;        // FIFO full (RO)
  localparam int SID_STATUS_LEVEL_LSB    = 16;       // [16+SID_LEVEL_W-1:16] FIFO fill in writes (RO)

  localparam int SID_WDATA_REG_LSB       = 8;        // [12:8] SID register
  localparam int SID_RDBK_ENV3_LSB       = 8;        // RDBK [15:8] ENV3

  localparam int SID_FIFO_DEPTH          = 512;      // timestamped writes
  localparam int SID_LEVEL_W              = 10;       // 0..512
  localparam int SID_PHI2_HZ             = 985_248;  // PAL phi2
  localparam int SID_DECIM_TAPS          = 20;       // each of the two moving-sum stages

  // ---------------------------------------------------------------------------
  // Video (c64_video): 384x240 8-bpp indexed framebuffer, 3x scaled into
  // CEA-861 1280x720p60.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] VID_CTRL_OFS     = 16'h0000; // RW control bits below
  localparam logic [15:0] VID_STATUS_OFS   = 16'h0004; // RW1C status bits below
  localparam logic [15:0] VID_FRAME_OFS    = 16'h0008; // RO frame counter (pix_clk count, gray CDC)
  localparam logic [15:0] VID_LINE_OFS     = 16'h000C; // RO current output line 0..749 (gray CDC)
  localparam logic [15:0] VID_PALETTE_OFS  = 16'h0400; // WO 256 entries x 4 bytes: [23:16] R, [15:8] G, [7:0] B

  localparam int VID_CTRL_ENABLE_BIT  = 0;             // 1: framebuffer shown; 0: black
  localparam int VID_CTRL_PAGE_BIT    = 1;             // requested display page, taken at next vsync
  localparam int VID_CTRL_IRQ_EN_BIT  = 8;             // vsync interrupt enable

  localparam int VID_STATUS_PAGE_BIT  = 0;             // page being displayed (RO)
  localparam int VID_STATUS_VSYNC_BIT = 1;             // vsync since last clear (W1C)

  localparam int VID_PALETTE_ENTRIES  = 256;

  localparam int FB_WIDTH       = 384;                 // native pixels: 320 picture + 2 x 32 border
  localparam int FB_HEIGHT      = 240;                 // native lines: 200 picture + 2 x 20 border
  localparam int FB_SCALE       = 3;                   // 1152 x 720 on screen
  localparam int FB_PAGE_BYTES  = FB_WIDTH * FB_HEIGHT;// 92,160 bytes per page
  localparam int FB_PAGES       = 2;
  localparam int FB_WORDS       = FB_PAGES * FB_PAGE_BYTES / 4; // 46,080 x 32-bit words
  localparam int FB_WORD_ADDR_W = 16;                  // covers 46,080 words
  localparam int FB_LINE_WORDS  = FB_WIDTH / 4;        // 96 words per native line

  // CEA-861 1280x720p60, pixel clock 74.25 MHz, both syncs active high.
  localparam int VID_H_ACTIVE = 1280;
  localparam int VID_H_FRONT  = 110;
  localparam int VID_H_SYNC   = 40;
  localparam int VID_H_BACK   = 220;
  localparam int VID_H_TOTAL  = VID_H_ACTIVE + VID_H_FRONT + VID_H_SYNC + VID_H_BACK; // 1650
  localparam int VID_V_ACTIVE = 720;
  localparam int VID_V_FRONT  = 5;
  localparam int VID_V_SYNC   = 5;
  localparam int VID_V_BACK   = 20;
  localparam int VID_V_TOTAL  = VID_V_ACTIVE + VID_V_FRONT + VID_V_SYNC + VID_V_BACK; // 750
  localparam int VID_X_OFFSET = (VID_H_ACTIVE - FB_WIDTH * FB_SCALE) / 2;             // 64 px pillarbox

  // ---------------------------------------------------------------------------
  // PS/2 receiver (ps2_rx): USB keyboard on J15 through the board's PIC24.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] PS2_DATA_OFS   = 16'h0000; // RO read pops: bit 8 valid, [7:0] scan code byte
  localparam logic [15:0] PS2_STATUS_OFS = 16'h0004; // RW1C status bits below
  localparam logic [15:0] PS2_CTRL_OFS   = 16'h0008; // RW control bits below

  localparam int PS2_DATA_VALID_BIT      = 8;
  localparam int PS2_STATUS_AVAIL_BIT    = 0;          // FIFO not empty (RO)
  localparam int PS2_STATUS_PARITY_BIT   = 1;          // parity error seen (W1C)
  localparam int PS2_STATUS_OVERFLOW_BIT = 2;          // byte dropped, FIFO full (W1C)
  localparam int PS2_STATUS_FRAME_BIT    = 3;          // start/stop bit error or timeout (W1C)
  localparam int PS2_CTRL_IRQ_EN_BIT     = 0;          // interrupt while FIFO not empty

  localparam int PS2_FIFO_DEPTH = 16;

endpackage
