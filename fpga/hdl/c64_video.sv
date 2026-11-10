// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// File: c64_video.sv
// Purpose: IronKernel 64 video block: two 384x240 8-bpp indexed framebuffer
//   pages, a 256 x 24-bit palette, CEA-861 1280x720p60 timing with 3x
//   scaling and a 64-pixel black pillarbox, and the DVI TMDS encoders.
// Overview:
//   * Register file (cpu_clk, AXI4-Lite through ik64_axil_slave, map in
//     c64_pkg):
//       VID_CTRL    RW  bit ENABLE (0: black picture, timing keeps running),
//                       bit PAGE (requested page), bit IRQ_EN.
//       VID_STATUS  RW1C bit PAGE (RO, page on screen), bit VSYNC (W1C, set
//                       once per frame at the start of vertical blanking).
//       VID_FRAME   RO  frames since pix_resetn (32-bit, wraps).
//       VID_LINE    RO  output line 0..VID_V_TOTAL-1 being generated.
//       palette     WO  VID_PALETTE_OFS + 4*i: [23:16] R, [15:8] G, [7:0] B.
//     Other offsets read 0; writes to them are ignored. irq = VSYNC & IRQ_EN.
//   * Framebuffer: FB_WORDS x 32-bit true dual-port block RAM. Page p, pixel
//     (x, y) is byte p*FB_PAGE_BYTES + y*FB_WIDTH + x; byte 4k+b of the page
//     is word k, bits [8b+7:8b] (little endian, as the RISC-V CPU stores it).
//     xpm_memory_tdpram is used rather than ik64_ram_core because port A
//     needs per-byte write enables and a read port of its own (AXI BRAM
//     controller), and port B a second read port in another clock: the
//     RTLNet RAM is a simple dual-port RAM with one full-word write port.
//   * Framebuffer port A (cpu_clk) follows the AXI BRAM Controller BRAM
//     interface: fb_bram_addr is a BYTE address of FB_BYTE_ADDR_W = 18 bits
//     (bits [1:0] ignored, [17:2] the word); en, we[3:0] per byte lane, din,
//     dout with a read latency of 1 clock. The controller must have a
//     256 KiB (2**18) range, aligned to 256 KiB, and the top connects
//     bram_addr_a[17:0]. Words FB_WORDS..2**16-1 are not backed: writes there
//     are dropped and reads leave dout unchanged.
//   * Timing (pix_clk): h counts 0..VID_H_TOTAL-1 with the active pixels
//     first, v counts 0..VID_V_TOTAL-1 with the active lines first. de is
//     h < VID_H_ACTIVE && v < VID_V_ACTIVE. hsync is high for
//     h in [VID_H_ACTIVE + VID_H_FRONT, + VID_H_SYNC). vsync is high from the
//     hsync leading edge of line VID_V_ACTIVE + VID_V_FRONT - 1 to the hsync
//     leading edge VID_V_SYNC lines later, so its edges coincide with hsync
//     leading edges (CEA-861 progressive timing; the front and back porches
//     are then exactly VID_V_FRONT and VID_V_BACK lines counted from hsync).
//     Both syncs are active high.
//   * 3x scaling by counters: xsub counts 0..FB_SCALE-1 and lb_x steps every
//     FB_SCALE pixels inside the framebuffer window [VID_X_OFFSET,
//     VID_X_OFFSET + FB_WIDTH*FB_SCALE), so lb_x = (h - VID_X_OFFSET) / 3;
//     vsub counts 0..FB_SCALE-1 per output line, and the fetch address steps
//     one native line (FB_LINE_WORDS words) per FB_SCALE output lines, so the
//     native line is v / 3. Outside the window the picture is black.
//   * Line buffer: FB_LINE_WORDS (96) x 32-bit distributed RAM holding the
//     native line on screen. Before every output line v with v % 3 == 0 (and
//     before line 0, during the last blanking line of the frame) the fetch
//     FSM copies the next native line from framebuffer port B during the
//     horizontal blanking of the preceding line. Budget at FETCH_START_H =
//     VID_H_ACTIVE: 1 clock to start + 96 reads + 2 clocks port B latency +
//     1 clock line-buffer write = FETCH_CLOCKS = 100 clocks, inside the
//     VID_H_TOTAL - VID_H_ACTIVE = 370-clock blanking interval (checked at
//     elaboration). The last line-buffer read of the line is at
//     h = VID_X_OFFSET + FB_WIDTH*FB_SCALE - 1 = 1215, before the first write.
//   * Pixel pipeline (pix_clk): S0 counters -> S1 line-buffer word (byte
//     select) -> S2 palette entry -> S3 vid_rgb/vid_de/vid_hsync/vid_vsync
//     registers (syncs and de delayed with the data) -> dvi_tx (3 more
//     clocks) -> tmds_ch0/1/2/clk.
//   * Page flip: VID_CTRL.PAGE crosses to pix_clk as a level (ik64_sync)
//     and is latched into display_page at the start of vertical blanking
//     (h = 0, v = VID_V_ACTIVE). The first fetch of the next frame (line
//     VID_V_TOTAL-1) uses it, so a flip never tears a frame. display_page
//     crosses back (ik64_sync) as VID_STATUS.PAGE.
//   * Frame event: at the same pixel the frame counter increments and a
//     one-clock event crosses to cpu_clk through ik64_pulse_sync (one event
//     per 16.7 ms frame, far wider than the pulse synchronizer's spacing
//     limit) and sets VID_STATUS.VSYNC.
//   * VID_FRAME and VID_LINE cross with ik64_gray_sync. The line counter
//     wraps at VID_V_TOTAL (750), not at a power of two, so it is sent biased
//     by LINE_GRAY_BIAS = 2**(LINE_W-1) - VID_V_TOTAL/2 (= 137): the values
//     137..886 are the middle of the 10-bit reflected Gray code, where the
//     wrap 886 -> 137 changes only the most significant Gray bit, so every
//     step, the wrap included, changes one Gray bit. The cpu side subtracts
//     the bias. The first step after pix_resetn (0 -> 137) is the one
//     multi-bit step.
//   * Enable: VID_CTRL.ENABLE crosses as a level (ik64_sync) and forces
//     vid_rgb to black at S3; de and the syncs keep running.
//   * Palette: ik64_ram_core with independent clocks (a block RAM written
//     on cpu_clk, read on pix_clk). The dual-clock RAM is the CDC; a write to
//     the entry being displayed can corrupt that one pixel on that frame.
//     The palette powers up all zero (black); firmware loads it.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks:
//   * cpu_clk: 100 MHz CPU/AXI clock: register file, framebuffer port A,
//     palette write port, irq.
//   * pix_clk: 74.25 MHz pixel clock (pixel MMCM): timing, fetch, line buffer,
//     palette read port, TMDS encoders.
//   * cpu_resetn / pix_resetn: synchronous to their clocks, active low (from
//     ik64_reset_sync instances in c64_top.sv).
// -----------------------------------------------------------------------------
module c64_video
  import c64_pkg::*;
#(
  parameter int FB_BYTE_ADDR_W = FB_WORD_ADDR_W + 2   // framebuffer port A byte address bits (18)
)(
  // CPU clock (100 MHz) and its synchronous active-low reset; the register
  // file, framebuffer port A and irq are in this domain.
  input  logic                      cpu_clk,
  input  logic                      cpu_resetn,

  // Pixel clock (74.25 MHz, pixel MMCM) and its synchronous active-low reset;
  // timing, scan-out and TMDS encoding are in this domain.
  input  logic                      pix_clk,
  input  logic                      pix_resetn,

  // AXI4-Lite register slave, cpu_clk domain, 32-bit data, byte addresses
  // inside the block's 64 KiB window (offsets in c64_pkg VID_*_OFS).
  input  logic [REG_ADDR_W-1:0]     s_axi_awaddr,
  input  logic                      s_axi_awvalid,
  output logic                      s_axi_awready,
  input  logic [31:0]               s_axi_wdata,
  input  logic [3:0]                s_axi_wstrb,
  input  logic                      s_axi_wvalid,
  output logic                      s_axi_wready,
  output logic [1:0]                s_axi_bresp,
  output logic                      s_axi_bvalid,
  input  logic                      s_axi_bready,
  input  logic [REG_ADDR_W-1:0]     s_axi_araddr,
  input  logic                      s_axi_arvalid,
  output logic                      s_axi_arready,
  output logic [31:0]               s_axi_rdata,
  output logic [1:0]                s_axi_rresp,
  output logic                      s_axi_rvalid,
  input  logic                      s_axi_rready,

  // Framebuffer port A, cpu_clk domain, from the BD's AXI BRAM Controller
  // (BRAM_PORTA): byte address (bits [1:0] ignored), enable, per-byte write
  // enables (we[b] writes bits [8b+7:8b]), write data, read data valid one
  // clock after an enabled read.
  input  logic [FB_BYTE_ADDR_W-1:0] fb_bram_addr,
  input  logic                      fb_bram_en,
  input  logic [3:0]                fb_bram_we,
  input  logic [31:0]               fb_bram_din,
  output logic [31:0]               fb_bram_dout,

  // Interrupt to the core 0 interrupt controller, cpu_clk domain, active-high
  // level: VID_STATUS.VSYNC pending and VID_CTRL.IRQ_EN.
  output logic                      irq,

  // TMDS characters, pix_clk domain, to the OSERDESE2 10:1 serializers in
  // c64_top.sv (bit 0 first): blue + syncs, green, red, clock-lane word.
  output logic [9:0]                tmds_ch0,
  output logic [9:0]                tmds_ch1,
  output logic [9:0]                tmds_ch2,
  output logic [9:0]                tmds_clk,

  // Video before TMDS encoding, pix_clk domain, for testbenches and debug:
  // data enable, active-high syncs, {R, G, B} (black outside de, in the
  // pillarbox and while disabled). The TMDS words lag these by 3 clocks.
  output logic                      vid_de,
  output logic                      vid_hsync,
  output logic                      vid_vsync,
  output logic [23:0]               vid_rgb
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int BYTE_W          = 8;
  localparam int WORD_W          = 32;
  localparam int BYTES_PER_WORD  = WORD_W / BYTE_W;
  localparam int BYTE_SEL_W      = $clog2(BYTES_PER_WORD);         // byte lane bits of an address
  localparam int RGB_W           = 24;

  // Framebuffer geometry.
  localparam int FB_PAGE_WORDS   = FB_PAGE_BYTES / BYTES_PER_WORD;  // 23,040
  localparam int FB_MEM_BITS     = FB_WORDS * WORD_W;
  localparam int FB_RD_LATENCY_A = 1;                               // AXI BRAM Controller read latency
  localparam int FB_RD_LATENCY_B = 2;                               // scan-out port, output register on
  localparam int LB_RD_LATENCY   = 1;                               // line buffer: S0 address, S1 word
  localparam int PAL_RD_LATENCY  = 1;                               // palette: S1 index, S2 entry

  // Line buffer: one native line, byte index lb_x 0..FB_WIDTH.
  localparam int LB_ADDR_W       = $clog2(FB_LINE_WORDS);           // 7
  localparam int LB_X_W          = $clog2(FB_WIDTH + 1);            // 9
  localparam int SUB_W           = $clog2(FB_SCALE);                // 2

  // Palette.
  localparam int PAL_ADDR_W      = $clog2(VID_PALETTE_ENTRIES);     // 8
  localparam int PAL_SPAN_LSB    = PAL_ADDR_W + BYTE_SEL_W;         // address bits above the palette span

  // Timing (pix_clk), see the header for the sync placement.
  localparam int H_W             = $clog2(VID_H_TOTAL);             // 11
  localparam int LINE_W          = $clog2(VID_V_TOTAL);             // 10
  localparam int H_SYNC_START    = VID_H_ACTIVE + VID_H_FRONT;      // 1390
  localparam int H_SYNC_END      = H_SYNC_START + VID_H_SYNC;       // 1430
  localparam int V_SYNC_FIRST    = VID_V_ACTIVE + VID_V_FRONT - 1;  // 724: vsync rises at its hsync edge
  localparam int V_SYNC_LAST     = V_SYNC_FIRST + VID_V_SYNC;       // 729: vsync falls at its hsync edge
  localparam int FB_X_START      = VID_X_OFFSET;                    // 64
  localparam int FB_X_END        = VID_X_OFFSET + FB_WIDTH * FB_SCALE; // 1216
  localparam int FETCH_START_H   = VID_H_ACTIVE;                    // first blanking pixel
  localparam int FETCH_CLOCKS    = 1 + FB_LINE_WORDS + FB_RD_LATENCY_B + 1;
  localparam int H_BLANK         = VID_H_TOTAL - VID_H_ACTIVE;      // 370

  // Line counter Gray bias (header): values centred in the LINE_W-bit code.
  localparam int LINE_GRAY_BIAS  = (1 << (LINE_W - 1)) - (VID_V_TOTAL / 2); // 137
  localparam int FRAME_W         = 32;

  // Fetch FSM states.
  localparam logic S_IDLE        = 1'b0;   // waiting for the fetch slot of a line
  localparam logic S_FETCH       = 1'b1;   // issuing FB_LINE_WORDS reads to port B

  // Elaboration checks of the geometry this module assumes.
  generate
    if (FB_WIDTH * FB_SCALE + 2 * VID_X_OFFSET != VID_H_ACTIVE) begin : g_bad_width
      $fatal(1, "c64_video: FB_WIDTH*FB_SCALE + 2*VID_X_OFFSET must equal VID_H_ACTIVE");
    end
    if (FB_HEIGHT * FB_SCALE != VID_V_ACTIVE) begin : g_bad_height
      $fatal(1, "c64_video: FB_HEIGHT*FB_SCALE must equal VID_V_ACTIVE (no letterbox)");
    end
    if (FETCH_CLOCKS > H_BLANK) begin : g_bad_fetch
      $fatal(1, "c64_video: line fetch (%0d clocks) does not fit the blanking (%0d)", FETCH_CLOCKS, H_BLANK);
    end
    if ((VID_V_TOTAL % 2) != 0) begin : g_bad_vtotal
      $fatal(1, "c64_video: the biased Gray line counter needs an even VID_V_TOTAL");
    end
    if ((VID_PALETTE_OFS % (VID_PALETTE_ENTRIES * BYTES_PER_WORD)) != 0) begin : g_bad_palofs
      $fatal(1, "c64_video: VID_PALETTE_OFS must be aligned to the palette span");
    end
    if (FB_BYTE_ADDR_W != FB_WORD_ADDR_W + BYTE_SEL_W) begin : g_bad_fbaddr
      $fatal(1, "c64_video: FB_BYTE_ADDR_W must be FB_WORD_ADDR_W + 2");
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals: cpu_clk domain
  // ---------------------------------------------------------------------------
  logic                      reg_wr_en;
  logic [REG_ADDR_W-1:0]     reg_wr_addr;
  logic [31:0]               reg_wr_data;
  logic                      reg_rd_en;
  logic [REG_ADDR_W-1:0]     reg_rd_addr;
  logic [31:0]               reg_rd_data;

  logic                      ctrl_enable;          // VID_CTRL.ENABLE
  logic                      ctrl_page;            // VID_CTRL.PAGE (requested)
  logic                      ctrl_irq_en;          // VID_CTRL.IRQ_EN
  logic                      vsync_pending;        // VID_STATUS.VSYNC
  logic                      vsync_evt_cpu;        // one cpu_clk pulse per frame event
  logic                      page_shown_cpu;       // VID_STATUS.PAGE (synchronized)
  logic [FRAME_W-1:0]        frame_cpu;            // VID_FRAME
  logic [LINE_W-1:0]         line_biased_cpu;      // VID_LINE + LINE_GRAY_BIAS
  logic [LINE_W-1:0]         line_cpu;             // VID_LINE

  logic                      pal_hit;              // write address inside the palette span
  logic                      pal_wr_en;
  logic [PAL_ADDR_W-1:0]     pal_wr_addr;

  logic [FB_WORD_ADDR_W-1:0] fb_a_word;            // port A word address
  logic                      fb_a_en;              // port A enable, backed words only

  // ---------------------------------------------------------------------------
  // Signals: pix_clk domain
  // ---------------------------------------------------------------------------
  logic                      enable_pix;           // VID_CTRL.ENABLE, synchronized
  logic                      page_req_pix;         // VID_CTRL.PAGE, synchronized
  logic                      display_page;         // page latched at vertical blanking
  logic [FRAME_W-1:0]        frame_cnt;

  // S0: timing and scaling counters.
  logic [H_W-1:0]            h_cnt;
  logic [LINE_W-1:0]         v_cnt;
  logic [SUB_W-1:0]          xsub;                 // pixel repeat 0..FB_SCALE-1
  logic [LB_X_W-1:0]         lb_x;                 // native x = (h - VID_X_OFFSET) / FB_SCALE
  logic [SUB_W-1:0]          vsub;                 // line repeat 0..FB_SCALE-1
  logic                      h_last;
  logic                      v_last;
  logic                      de_s0;
  logic                      hsync_s0;
  logic                      vsync_s0;
  logic                      fbwin_s0;             // inside the framebuffer window horizontally
  logic                      vblank_start;         // h = 0, v = VID_V_ACTIVE
  logic                      fetch_due;            // this line's blanking fetches a native line
  logic                      fetch_first;          // ... and it is native line 0

  // Fetch FSM and port B read pipeline.
  logic                      fetch_state;
  logic [LB_ADDR_W-1:0]      fetch_cnt;
  logic [FB_WORD_ADDR_W-1:0] fetch_addr;
  logic                      fb_b_en;
  logic [31:0]               fb_b_dout;
  logic [FB_RD_LATENCY_B-1:0] fb_rd_valid;         // read issued 1 and 2 clocks ago
  logic [LB_ADDR_W-1:0]      fb_rd_idx [0:FB_RD_LATENCY_B-1];
  logic                      lb_wr_en;
  logic [LB_ADDR_W-1:0]      lb_wr_addr;

  // S1 / S2: line buffer word, palette entry.
  logic [31:0]               lb_rd_data;           // valid at S1
  logic [BYTE_SEL_W-1:0]     lane_s1;
  logic                      de_s1;
  logic                      hsync_s1;
  logic                      vsync_s1;
  logic                      fbwin_s1;
  logic [PAL_ADDR_W-1:0]     pal_idx;              // S1 byte select
  logic [RGB_W-1:0]          pal_rd_data;          // valid at S2
  logic                      de_s2;
  logic                      hsync_s2;
  logic                      vsync_s2;
  logic                      fbwin_s2;

  // ===========================================================================
  // cpu_clk domain
  // ===========================================================================

  // AXI4-Lite to register strobes (one transaction at a time, read data due
  // one clock after reg_rd_en).
  ik64_axil_slave #(
    .ADDR_W (REG_ADDR_W)
  ) u_axil (
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

  // Palette writes: any word address inside the 1 KiB span at VID_PALETTE_OFS.
  assign pal_hit     = (reg_wr_addr[REG_ADDR_W-1:PAL_SPAN_LSB] == VID_PALETTE_OFS[REG_ADDR_W-1:PAL_SPAN_LSB]);
  assign pal_wr_en   = reg_wr_en && pal_hit;
  assign pal_wr_addr = reg_wr_addr[BYTE_SEL_W +: PAL_ADDR_W];

  // Control register, vsync pending flag (set wins over a same-clock W1C) and
  // the registered interrupt.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      ctrl_enable   <= 1'b0;
      ctrl_page     <= 1'b0;
      ctrl_irq_en   <= 1'b0;
      vsync_pending <= 1'b0;
      irq           <= 1'b0;
    end else begin
      if (reg_wr_en && (reg_wr_addr == VID_CTRL_OFS)) begin
        ctrl_enable <= reg_wr_data[VID_CTRL_ENABLE_BIT];
        ctrl_page   <= reg_wr_data[VID_CTRL_PAGE_BIT];
        ctrl_irq_en <= reg_wr_data[VID_CTRL_IRQ_EN_BIT];
      end
      if (vsync_evt_cpu) begin
        vsync_pending <= 1'b1;
      end else if (reg_wr_en && (reg_wr_addr == VID_STATUS_OFS) && reg_wr_data[VID_STATUS_VSYNC_BIT]) begin
        vsync_pending <= 1'b0;
      end
      irq <= vsync_pending && ctrl_irq_en;
    end
  end

  assign line_cpu = line_biased_cpu - LINE_W'(LINE_GRAY_BIAS);

  // Registered read mux; the palette is write-only and reads 0.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      reg_rd_data <= '0;
      case (reg_rd_addr)
        VID_CTRL_OFS: begin
          reg_rd_data[VID_CTRL_ENABLE_BIT] <= ctrl_enable;
          reg_rd_data[VID_CTRL_PAGE_BIT]   <= ctrl_page;
          reg_rd_data[VID_CTRL_IRQ_EN_BIT] <= ctrl_irq_en;
        end
        VID_STATUS_OFS: begin
          reg_rd_data[VID_STATUS_PAGE_BIT]  <= page_shown_cpu;
          reg_rd_data[VID_STATUS_VSYNC_BIT] <= vsync_pending;
        end
        VID_FRAME_OFS: reg_rd_data            <= frame_cpu;
        VID_LINE_OFS:  reg_rd_data[LINE_W-1:0] <= line_cpu;
        default:       reg_rd_data            <= '0;
      endcase
    end
  end

  // Framebuffer port A: only the FB_WORDS backed words are enabled.
  assign fb_a_word = fb_bram_addr[FB_BYTE_ADDR_W-1:BYTE_SEL_W];
  assign fb_a_en   = fb_bram_en && (fb_a_word < FB_WORD_ADDR_W'(FB_WORDS));

  // ===========================================================================
  // Clock-domain crossings
  // ===========================================================================

  // CPU control levels into pix_clk: ENABLE and the requested PAGE.
  ik64_sync #(
    .WIDTH  (2),
    .STAGES (3)
  ) u_sync_ctrl_pix (
    .clk    (pix_clk),
    .resetn (pix_resetn),
    .d      ({ctrl_page, ctrl_enable}),
    .q      ({page_req_pix, enable_pix})
  );

  // Displayed page back into cpu_clk for VID_STATUS.PAGE.
  ik64_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_sync_page_cpu (
    .clk    (cpu_clk),
    .resetn (cpu_resetn),
    .d      (display_page),
    .q      (page_shown_cpu)
  );

  // Frame event (start of vertical blanking) into cpu_clk for VID_STATUS.VSYNC.
  ik64_pulse_sync #(
    .STAGES (3)
  ) u_sync_vsync (
    .src_clk    (pix_clk),
    .src_resetn (pix_resetn),
    .src_pulse  (vblank_start),
    .dst_clk    (cpu_clk),
    .dst_resetn (cpu_resetn),
    .dst_pulse  (vsync_evt_cpu)
  );

  // Frame counter into cpu_clk (steps +1 per frame).
  ik64_gray_sync #(
    .WIDTH  (FRAME_W),
    .STAGES (2)
  ) u_sync_frame (
    .src_clk    (pix_clk),
    .src_resetn (pix_resetn),
    .src_count  (frame_cnt),
    .dst_clk    (cpu_clk),
    .dst_resetn (cpu_resetn),
    .dst_count  (frame_cpu)
  );

  // Biased line counter into cpu_clk: one Gray bit per step, wrap included.
  ik64_gray_sync #(
    .WIDTH  (LINE_W),
    .STAGES (2)
  ) u_sync_line (
    .src_clk    (pix_clk),
    .src_resetn (pix_resetn),
    .src_count  (v_cnt + LINE_W'(LINE_GRAY_BIAS)),
    .dst_clk    (cpu_clk),
    .dst_resetn (cpu_resetn),
    .dst_count  (line_biased_cpu)
  );

  // ===========================================================================
  // Memories
  // ===========================================================================

  // Framebuffer, both pages: port A byte-write read/write on cpu_clk (read
  // latency 1, the AXI BRAM Controller's), port B read-only on pix_clk (read
  // latency 2, output register for the 74.25 MHz cascade). Contents start at
  // zero; no port resets its output.
  xpm_memory_tdpram #(
    .ADDR_WIDTH_A            (FB_WORD_ADDR_W),
    .ADDR_WIDTH_B            (FB_WORD_ADDR_W),
    .AUTO_SLEEP_TIME         (0),
    .BYTE_WRITE_WIDTH_A      (BYTE_W),
    .BYTE_WRITE_WIDTH_B      (WORD_W),
    .CASCADE_HEIGHT          (0),
    .CLOCKING_MODE           ("independent_clock"),
    .ECC_MODE                ("no_ecc"),
    .MEMORY_INIT_FILE        ("none"),
    .MEMORY_INIT_PARAM       ("0"),
    .MEMORY_OPTIMIZATION     ("true"),
    .MEMORY_PRIMITIVE        ("block"),
    .MEMORY_SIZE             (FB_MEM_BITS),
    .MESSAGE_CONTROL         (0),
    .READ_DATA_WIDTH_A       (WORD_W),
    .READ_DATA_WIDTH_B       (WORD_W),
    .READ_LATENCY_A          (FB_RD_LATENCY_A),
    .READ_LATENCY_B          (FB_RD_LATENCY_B),
    .READ_RESET_VALUE_A      ("0"),
    .READ_RESET_VALUE_B      ("0"),
    .RST_MODE_A              ("SYNC"),
    .RST_MODE_B              ("SYNC"),
    .SIM_ASSERT_CHK          (0),
    .USE_EMBEDDED_CONSTRAINT (0),
    .USE_MEM_INIT            (0),
    .WAKEUP_TIME             ("disable_sleep"),
    .WRITE_DATA_WIDTH_A      (WORD_W),
    .WRITE_DATA_WIDTH_B      (WORD_W),
    .WRITE_MODE_A            ("no_change"),
    .WRITE_MODE_B            ("no_change")
  ) u_fb (
    .sleep          (1'b0),
    .clka           (cpu_clk),
    .rsta           (1'b0),
    .ena            (fb_a_en),
    .regcea         (1'b1),
    .wea            (fb_bram_we),
    .addra          (fb_a_word),
    .dina           (fb_bram_din),
    .injectsbiterra (1'b0),
    .injectdbiterra (1'b0),
    .douta          (fb_bram_dout),
    .sbiterra       (),
    .dbiterra       (),
    .clkb           (pix_clk),
    .rstb           (1'b0),
    .enb            (fb_b_en),
    .regceb         (1'b1),
    .web            (1'b0),
    .addrb          (fetch_addr),
    .dinb           ('0),
    .injectsbiterrb (1'b0),
    .injectdbiterrb (1'b0),
    .doutb          (fb_b_dout),
    .sbiterrb       (),
    .dbiterrb       ()
  );

  // Palette, 256 x 24: written from the register file on cpu_clk, read by the
  // pixel pipeline on pix_clk (latency 1). The dual-clock RAM is the CDC.
  ik64_ram_core #(
    .RAM_STYLE    ("block"),
    .CLOCKING     ("INDEPENDENT"),
    .DATA_W       (RGB_W),
    .ADDR_W       (PAL_ADDR_W),
    .READ_LATENCY (PAL_RD_LATENCY)
  ) u_palette (
    .wr_clk    (cpu_clk),
    .wr_en     (pal_wr_en),
    .wr_addr   (pal_wr_addr),
    .wr_data   (reg_wr_data[RGB_W-1:0]),
    .rd_clk    (pix_clk),
    .rd_resetn (pix_resetn),
    .rd_en     (1'b1),
    .rd_addr   (pal_idx),
    .rd_data   (pal_rd_data)
  );

  // Line buffer, 96 x 32 (128-deep distributed RAM): written by the fetch,
  // read every pixel at the S0 lb_x word (latency 1).
  ik64_ram_core #(
    .RAM_STYLE    ("distributed"),
    .CLOCKING     ("COMMON"),
    .DATA_W       (WORD_W),
    .ADDR_W       (LB_ADDR_W),
    .READ_LATENCY (LB_RD_LATENCY)
  ) u_line_buf (
    .wr_clk    (pix_clk),
    .wr_en     (lb_wr_en),
    .wr_addr   (lb_wr_addr),
    .wr_data   (fb_b_dout),
    .rd_clk    (pix_clk),
    .rd_resetn (pix_resetn),
    .rd_en     (1'b1),
    .rd_addr   (lb_x[LB_X_W-1:BYTE_SEL_W]),
    .rd_data   (lb_rd_data)
  );

  // ===========================================================================
  // pix_clk domain
  // ===========================================================================

  // S0 decode of the timing counters.
  assign h_last       = (h_cnt == H_W'(VID_H_TOTAL - 1));
  assign v_last       = (v_cnt == LINE_W'(VID_V_TOTAL - 1));
  assign de_s0        = (h_cnt < H_W'(VID_H_ACTIVE)) && (v_cnt < LINE_W'(VID_V_ACTIVE));
  assign hsync_s0     = (h_cnt >= H_W'(H_SYNC_START)) && (h_cnt < H_W'(H_SYNC_END));
  assign vsync_s0     = ((v_cnt == LINE_W'(V_SYNC_FIRST)) && (h_cnt >= H_W'(H_SYNC_START))) ||
                        ((v_cnt >  LINE_W'(V_SYNC_FIRST)) && (v_cnt < LINE_W'(V_SYNC_LAST))) ||
                        ((v_cnt == LINE_W'(V_SYNC_LAST))  && (h_cnt <  H_W'(H_SYNC_START)));
  assign fbwin_s0     = (h_cnt >= H_W'(FB_X_START)) && (h_cnt < H_W'(FB_X_END));
  assign vblank_start = (h_cnt == '0) && (v_cnt == LINE_W'(VID_V_ACTIVE));
  assign fetch_first  = v_last;
  assign fetch_due    = v_last || ((v_cnt < LINE_W'(VID_V_ACTIVE - 1)) && (vsub == SUB_W'(FB_SCALE - 1)));

  // Timing and 3x scaling counters. lb_x/xsub hold the values for the
  // current h_cnt: reloaded on the clock before the window, stepped inside it.
  always_ff @(posedge pix_clk) begin
    if (!pix_resetn) begin
      h_cnt <= '0;
      v_cnt <= '0;
      vsub  <= '0;
      xsub  <= '0;
      lb_x  <= '0;
    end else begin
      if (h_last) begin
        h_cnt <= '0;
        if (v_last) begin
          v_cnt <= '0;
          vsub  <= '0;
        end else begin
          v_cnt <= v_cnt + 1'b1;
          vsub  <= (vsub == SUB_W'(FB_SCALE - 1)) ? '0 : vsub + 1'b1;
        end
      end else begin
        h_cnt <= h_cnt + 1'b1;
      end

      if (h_cnt == H_W'(FB_X_START - 1)) begin
        xsub <= '0;
        lb_x <= '0;
      end else if (fbwin_s0) begin
        if (xsub == SUB_W'(FB_SCALE - 1)) begin
          xsub <= '0;
          lb_x <= lb_x + 1'b1;
        end else begin
          xsub <= xsub + 1'b1;
        end
      end
    end
  end

  // Page latch and frame counter at the start of vertical blanking.
  always_ff @(posedge pix_clk) begin
    if (!pix_resetn) begin
      display_page <= 1'b0;
      frame_cnt    <= '0;
    end else if (vblank_start) begin
      display_page <= page_req_pix;
      frame_cnt    <= frame_cnt + 1'b1;
    end
  end

  // Line fetch FSM: in the blanking of a line whose successor starts a native
  // line, read FB_LINE_WORDS consecutive words from port B. fetch_addr runs on
  // from line to line and is reloaded with the page base before native line 0.
  always_ff @(posedge pix_clk) begin
    if (!pix_resetn) begin
      fetch_state <= S_IDLE;
      fetch_cnt   <= '0;
      fetch_addr  <= '0;
    end else begin
      case (fetch_state)
        S_IDLE: begin
          if ((h_cnt == H_W'(FETCH_START_H)) && fetch_due) begin
            fetch_cnt   <= '0;
            fetch_state <= S_FETCH;
            if (fetch_first) begin
              fetch_addr <= display_page ? FB_WORD_ADDR_W'(FB_PAGE_WORDS) : '0;
            end
          end
        end
        S_FETCH: begin
          fetch_addr <= fetch_addr + 1'b1;
          fetch_cnt  <= fetch_cnt + 1'b1;
          if (fetch_cnt == LB_ADDR_W'(FB_LINE_WORDS - 1)) begin
            fetch_state <= S_IDLE;
          end
        end
        default: fetch_state <= S_IDLE;
      endcase
    end
  end

  assign fb_b_en = (fetch_state == S_FETCH);

  // Port B read pipeline: the line-buffer index travels with each read and
  // the word is written when port B presents it (FB_RD_LATENCY_B clocks).
  always_ff @(posedge pix_clk) begin
    if (!pix_resetn) begin
      fb_rd_valid <= '0;
      for (int i = 0; i < FB_RD_LATENCY_B; i++) fb_rd_idx[i] <= '0;
    end else begin
      fb_rd_valid  <= {fb_rd_valid[FB_RD_LATENCY_B-2:0], fb_b_en};
      fb_rd_idx[0] <= fetch_cnt;
      for (int i = 1; i < FB_RD_LATENCY_B; i++) fb_rd_idx[i] <= fb_rd_idx[i-1];
    end
  end

  assign lb_wr_en   = fb_rd_valid[FB_RD_LATENCY_B-1];
  assign lb_wr_addr = fb_rd_idx[FB_RD_LATENCY_B-1];

  // S1: byte lane select of the line-buffer word gives the palette index.
  assign pal_idx = lb_rd_data[lane_s1 * BYTE_W +: BYTE_W];

  // Pixel pipeline S0 -> S1 -> S2 -> S3 (outputs): controls delayed with the
  // data; black outside de, in the pillarbox, and while disabled.
  always_ff @(posedge pix_clk) begin
    if (!pix_resetn) begin
      lane_s1   <= '0;
      de_s1     <= 1'b0;
      hsync_s1  <= 1'b0;
      vsync_s1  <= 1'b0;
      fbwin_s1  <= 1'b0;
      de_s2     <= 1'b0;
      hsync_s2  <= 1'b0;
      vsync_s2  <= 1'b0;
      fbwin_s2  <= 1'b0;
      vid_de    <= 1'b0;
      vid_hsync <= 1'b0;
      vid_vsync <= 1'b0;
      vid_rgb   <= '0;
    end else begin
      lane_s1   <= lb_x[BYTE_SEL_W-1:0];
      de_s1     <= de_s0;
      hsync_s1  <= hsync_s0;
      vsync_s1  <= vsync_s0;
      fbwin_s1  <= fbwin_s0;
      de_s2     <= de_s1;
      hsync_s2  <= hsync_s1;
      vsync_s2  <= vsync_s1;
      fbwin_s2  <= fbwin_s1;
      vid_de    <= de_s2;
      vid_hsync <= hsync_s2;
      vid_vsync <= vsync_s2;
      vid_rgb   <= (de_s2 && fbwin_s2 && enable_pix) ? pal_rd_data : '0;
    end
  end

  // TMDS encoding of the S3 video.
  dvi_tx u_dvi (
    .pix_clk    (pix_clk),
    .pix_resetn (pix_resetn),
    .rgb        (vid_rgb),
    .hsync      (vid_hsync),
    .vsync      (vid_vsync),
    .de         (vid_de),
    .tmds_ch0   (tmds_ch0),
    .tmds_ch1   (tmds_ch1),
    .tmds_ch2   (tmds_ch2),
    .tmds_clk   (tmds_clk)
  );

  // ---------------------------------------------------------------------------
  // Simulation-only guard: a line-buffer write must never land while the
  // active part of a line is still reading the buffer.
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always_ff @(posedge pix_clk) begin
    if (pix_resetn && lb_wr_en && (h_cnt < H_W'(FETCH_START_H))) begin
      $error("c64_video: line-buffer write at h=%0d v=%0d overlaps the active line", h_cnt, v_cnt);
    end
  end
  // synthesis translate_on

endmodule
