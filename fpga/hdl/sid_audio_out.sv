// -----------------------------------------------------------------------------
// File: sid_audio_out.sv
// Purpose: core 0 audio output. Firmware writes 16-bit stereo frames into a
//   cpu_clk register; a dual-clock FIFO carries them into the audio clock
//   domain, where an I2S transmitter sends them to the ADAU1761 codec
//   (Nexys Video RM section 16; the codec is the I2S slave, the FPGA drives
//   MCLK, BCLK and LRCLK).
// Overview:
//   * Registers (AXI4-Lite through rtlnet_axil_slave, REG_ADDR_W-bit address;
//     offsets and bits are c64_pkg AUD_*). Undefined offsets read 0 and
//     ignore writes.
//       AUD_CTRL      RW [ENABLE] play the FIFO (0: send zeros, FIFO is not
//                        read and holds its contents); [IRQ_EN] interrupt
//                        enable; [FLUSH] write 1 to empty the FIFO. FLUSH is
//                        self-clearing: it reads 1 while the flush sequence
//                        runs and 0 once the FIFO is empty and writable again.
//       AUD_STATUS    [IRQ] W1C, [UNDERRUN] W1C, [FULL] RO.
//       AUD_LEVEL     RO FIFO fill in frames, cpu_clk view (see "LEVEL").
//       AUD_SAMPLE    WO one stereo frame, [15:0] left, [31:16] right, signed
//                        two's complement. Reads 0.
//       AUD_UNDERRUNS RO frames sent as zeros because the FIFO was empty while
//                        ENABLE was set; saturates at 2^32-1; cleared by reset.
//       AUD_THRESH    RW [AUD_LEVEL_W-1:0] interrupt level; reset value
//                        AUD_FIFO_DEPTH / 2 (half-empty interrupt).
//   * Interrupt (level based, exact rule):
//       - every cpu_clk where LEVEL <= THRESH sets STATUS.IRQ;
//       - a W1C of STATUS.IRQ clears it only on a clock where
//         LEVEL > THRESH (setting wins), so a cleared bit re-asserts at once
//         while the FIFO is still at or below the threshold;
//       - STATUS.IRQ latches whether or not CTRL.IRQ_EN is set (pollable);
//       - irq (output) = STATUS.IRQ && CTRL.IRQ_EN, registered.
//     Firmware fills the FIFO above THRESH, then writes 1 to STATUS.IRQ.
//   * STATUS.UNDERRUN is set by every counted underrun and cleared by W1C.
//   * STATUS.FULL reads 1 whenever an AUD_SAMPLE write would be dropped: FIFO
//     full, or the FIFO in its reset/flush sequence. A dropped write changes
//     nothing; in simulation it is also an $error (firmware must check FULL
//     or LEVEL first).
//   * FIFO: xpm_fifo_async, AUD_FIFO_DEPTH x 32 bits, block RAM, standard
//     read mode, read latency 1. Why: the producer (cpu_clk, 100 MHz) and the
//     consumer (aud_clk, 12.288 MHz from an audio MMCM in c64_top) are
//     unrelated clocks, and a frame is a 32-bit word, so a Gray-pointer
//     dual-clock FIFO is the coherent multi-bit crossing (fpga.md section 6).
//     Write count: firmware writes in bursts (one 960-frame block per PAL
//     frame); read count: exactly one frame per 1/fs while enabled. In
//     independent-clock mode the FIFO holds AUD_FIFO_DEPTH - 1 frames (its
//     full flag rises one entry early, xpm_fifo_base going_full).
//   * LEVEL: the FIFO's wr_data_count, registered once in cpu_clk. It is the
//     write pointer minus the read pointer after the read pointer has crossed
//     into cpu_clk through the FIFO's Gray synchronizer (FIFO_CDC_STAGES
//     stages), so it is exact for writes and lags reads by a few cpu_clk
//     cycles: it never under-reports, and the interrupt is at most that lag
//     late. It reads 0 during the reset/flush sequence.
//   * Flush and FIFO reset sequencing (xpm_fifo_async, UG974):
//       - rst is synchronous to wr_clk (cpu_clk) and active high;
//       - a new rst rising edge is ignored while wr_rst_busy is high, so rst
//         is raised only after wr_rst_busy has been observed low;
//       - rst is held high until wr_rst_busy is observed high (the FIFO has
//         captured the request), then released;
//       - wr_rst_busy stays high while the FIFO's internal reset handshake
//         resets the read side (rd_rst_busy in aud_clk) and waits for its
//         acknowledge; it falls only after both sides are out of reset, and
//         full stays high until rst is low;
//       - wr_en is never asserted while wr_rst_busy is high, and rd_en is
//         never asserted while rd_rst_busy is high;
//       - both clocks must run for the sequence to finish. If aud_clk is
//         stopped (audio MMCM not locked) the FIFO stays in reset: FULL and
//         CTRL.FLUSH read 1 and sample writes are dropped. Firmware flushes
//         after the audio clock recovers from a loss of lock.
//     The same sequence runs once after every cpu_resetn release, so a warm
//     cpu reset always starts from an empty FIFO. The xpm reset handshake is
//     the flush crossing: the read side is reset and acknowledged inside the
//     FIFO before wr_rst_busy falls. A frame already taken by the I2S
//     transmitter before the flush is still sent (at most one frame).
//   * I2S transmitter (aud_clk domain, Philips I2S, codec in slave mode):
//       - MCLK = aud_clk = AUD_MCLK_PER_FS * fs (forwarded by an ODDR in
//         c64_top); BCLK = MCLK / MCLK_PER_BCLK (AUD_BCLK_PER_FS * fs);
//         LRCLK = fs, low = left slot, high = right slot;
//       - each slot is SLOT_BCLKS BCLK periods; the 16-bit sample is sent
//         MSB first and MSB-aligned, followed by zero padding;
//       - the MSB is sent one BCLK period after the LRCLK edge;
//       - LRCLK and SDATA change on the BCLK falling edge; the codec samples
//         on the BCLK rising edge, half a BCLK period later;
//       - aud_bclk_q, aud_lrclk_q and aud_sdata_q are flip-flops in aud_clk
//         paced by a free-running divider (clock enables). They are DATA
//         signals: nothing inside the FPGA is clocked by them. c64_top sends
//         them through IOB output registers;
//       - frame boundary: once per LRCLK period, at BCLK period FETCH_BCLK
//         (after the last right-slot sample bit), the transmitter takes the
//         next frame. If ENABLE is set and the FIFO is out of reset and not
//         empty, it reads one FIFO word. If ENABLE is set and the FIFO is
//         empty it sends a zero frame and counts one underrun. If ENABLE is
//         clear, or the FIFO is in reset, it sends a zero frame, does not
//         read the FIFO and counts nothing.
//   * CDC inventory: ENABLE cpu_clk -> aud_clk by a 3-stage rtlnet_sync
//     (a level); underrun events aud_clk -> cpu_clk by rtlnet_pulse_sync
//     (events are one LRCLK period, 256 aud_clk cycles, apart); frames, LEVEL
//     and reset handshake inside xpm_fifo_async.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk (100 MHz, AXI and register file, FIFO write side);
//   aud_clk (12.288 MHz = 256 x 48 kHz from the audio MMCM, FIFO read side
//   and I2S). The two are asynchronous.
// -----------------------------------------------------------------------------
module sid_audio_out #(
  parameter int XPM_SIM_ASSERT = 0          // 1: enable xpm_fifo_async usage assertions (simulation)
)(
  // cpu_clk domain: 100 MHz CPU/AXI clock and its synchronous active-low reset.
  input  logic                          cpu_clk,
  input  logic                          cpu_resetn,

  // AXI4-Lite register slave, cpu_clk domain, 32-bit data, REG_ADDR_W-bit
  // byte address (64 KiB window); one outstanding transaction, all OKAY.
  input  logic [c64_pkg::REG_ADDR_W-1:0] s_axi_awaddr,
  input  logic                          s_axi_awvalid,
  output logic                          s_axi_awready,
  input  logic [31:0]                   s_axi_wdata,
  input  logic [3:0]                    s_axi_wstrb,
  input  logic                          s_axi_wvalid,
  output logic                          s_axi_wready,
  output logic [1:0]                    s_axi_bresp,
  output logic                          s_axi_bvalid,
  input  logic                          s_axi_bready,
  input  logic [c64_pkg::REG_ADDR_W-1:0] s_axi_araddr,
  input  logic                          s_axi_arvalid,
  output logic                          s_axi_arready,
  output logic [31:0]                   s_axi_rdata,
  output logic [1:0]                    s_axi_rresp,
  output logic                          s_axi_rvalid,
  input  logic                          s_axi_rready,

  // Interrupt to core 0, cpu_clk register, active-high level:
  // STATUS.IRQ && CTRL.IRQ_EN.
  output logic                          irq,

  // aud_clk domain: 12.288 MHz codec master clock (also forwarded to the
  // codec MCLK pin by an ODDR in c64_top) and its synchronous active-low
  // reset (released after the audio MMCM locks).
  input  logic                          aud_clk,
  input  logic                          aud_resetn,

  // I2S to the ADAU1761 (codec is slave), aud_clk flip-flops, data signals
  // paced by clock enables; c64_top drives the BCLK, LRCLK and DAC SDATA pins
  // from them through IOB registers. Idle (reset) level 0 on all three.
  output logic                          aud_bclk_q,   // BCLK = aud_clk / 4, 64 x fs
  output logic                          aud_lrclk_q,  // LRCLK = fs, 0 = left slot
  output logic                          aud_sdata_q   // DAC data, MSB first, changes on BCLK fall
);

  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Geometry, all derived from c64_pkg.
  // ---------------------------------------------------------------------------
  localparam int ADDR_W          = REG_ADDR_W;
  localparam int FRAME_W         = 2 * AUD_SAMPLE_W;                 // one FIFO word: {right, left}
  localparam int MCLK_PER_BCLK   = AUD_MCLK_PER_FS / AUD_BCLK_PER_FS; // 4
  localparam int SLOT_BCLKS      = AUD_BCLK_PER_FS / 2;              // 32 BCLK periods per slot
  localparam int PHASE_W         = $clog2(MCLK_PER_BCLK);            // MCLK cycles inside one BCLK period
  localparam int BITPOS_W        = $clog2(AUD_BCLK_PER_FS);          // BCLK period inside one LRCLK period
  localparam int SLOTPOS_W       = $clog2(SLOT_BCLKS);               // BCLK period inside one slot
  localparam int FS_CNT_W        = PHASE_W + BITPOS_W;               // MCLK cycles inside one LRCLK period
  localparam int PAD_W           = SLOT_BCLKS - AUD_SAMPLE_W;        // zero bits after each sample
  // Frame boundary: the first padding period of the right slot. The frame
  // register is not needed again until BCLK period 1 (left MSB).
  localparam int FETCH_BCLK      = SLOT_BCLKS + AUD_SAMPLE_W + 1;
  localparam logic [FS_CNT_W-1:0] FETCH_CNT   = FS_CNT_W'(FETCH_BCLK * MCLK_PER_BCLK);
  localparam logic [FS_CNT_W-1:0] CAPTURE_CNT = FETCH_CNT + 1'b1;     // FIFO read latency 1
  localparam int FIFO_CDC_STAGES = 3;                                // xpm_fifo_async Gray / reset synchronizers
  localparam int FIFO_READ_LAT   = 1;
  localparam int ENABLE_STAGES   = 3;
  localparam int XPM_PROG_THRESH = 10;                               // prog_full/prog_empty unused; any legal value
  localparam logic [AUD_LEVEL_W-1:0] THRESH_RESET = AUD_LEVEL_W'(AUD_FIFO_DEPTH / 2);
  localparam logic [31:0]        UNDERRUNS_MAX = '1;

  generate
    if ((1 << PHASE_W) != MCLK_PER_BCLK || MCLK_PER_BCLK < 2 || (1 << BITPOS_W) != AUD_BCLK_PER_FS) begin : g_bad_ratio
      $fatal(1, "sid_audio_out: MCLK/BCLK = %0d and BCLK/fs = %0d must be powers of two (MCLK/BCLK >= 2)",
             MCLK_PER_BCLK, AUD_BCLK_PER_FS);
    end
    if (PAD_W < 1 || (1 << $clog2(AUD_FIFO_DEPTH)) != AUD_FIFO_DEPTH || AUD_LEVEL_W != $clog2(AUD_FIFO_DEPTH) + 1)
    begin : g_bad_geometry
      $fatal(1, "sid_audio_out: AUD_SAMPLE_W=%0d needs padding in a %0d-bit slot; AUD_FIFO_DEPTH=%0d %s, AUD_LEVEL_W=%0d",
             AUD_SAMPLE_W, SLOT_BCLKS, AUD_FIFO_DEPTH, "must be a power of two with AUD_LEVEL_W = clog2 + 1", AUD_LEVEL_W);
    end
  endgenerate

  // Flush / FIFO reset sequencer states (cpu_clk).
  localparam logic [1:0] S_IDLE        = 2'd0; // FIFO usable
  localparam logic [1:0] S_READY_WAIT  = 2'd1; // wait for wr_rst_busy low before raising rst
  localparam logic [1:0] S_RST_ASSERT  = 2'd2; // rst high until wr_rst_busy is seen high
  localparam logic [1:0] S_RST_RELEASE = 2'd3; // rst low, wait for wr_rst_busy low (both sides reset)

  // ---------------------------------------------------------------------------
  // cpu_clk signals
  // ---------------------------------------------------------------------------
  logic                   reg_wr_en;
  logic [ADDR_W-1:0]      reg_wr_addr;
  logic [31:0]            reg_wr_data;
  logic                   reg_rd_en;
  logic [ADDR_W-1:0]      reg_rd_addr;
  logic [31:0]            reg_rd_data;

  logic                   ctrl_enable;       // CTRL.ENABLE
  logic                   ctrl_irq_en;       // CTRL.IRQ_EN
  // Initialised to their reset values so the FIFO sees rst = 0 and no write
  // before the first cpu_clk edge (power-up equals reset).
  logic [1:0]             flush_state = S_READY_WAIT; // the one sequencer state register
  logic                   fifo_rst    = 1'b0;         // xpm rst, registered sequencer output
  logic                   status_irq;        // STATUS.IRQ
  logic                   status_underrun;   // STATUS.UNDERRUN
  logic [AUD_LEVEL_W-1:0] thresh;            // AUD_THRESH
  logic [AUD_LEVEL_W-1:0] level;             // AUD_LEVEL (registered wr_data_count)
  logic [31:0]            underruns;         // AUD_UNDERRUNS

  logic                   fifo_full;
  logic                   fifo_wr_rst_busy;
  logic [AUD_LEVEL_W-1:0] fifo_wr_count;
  logic                   fifo_wr_req;       // AUD_SAMPLE write strobe
  logic                   fifo_wr_block;     // a write now would be dropped (STATUS.FULL)
  logic                   fifo_wr_en;        // gated write enable
  logic                   wr_ctrl;
  logic                   wr_status;
  logic                   wr_thresh;
  logic                   level_low;         // LEVEL <= THRESH
  logic                   underrun_cpu;      // one cpu_clk pulse per underrun

  logic [31:0]            ctrl_word;
  logic [31:0]            status_word;

  // ---------------------------------------------------------------------------
  // aud_clk signals
  // ---------------------------------------------------------------------------
  logic                   enable_aud;        // CTRL.ENABLE, last synchronizer stage
  logic [FS_CNT_W-1:0]    fs_cnt;            // MCLK cycle inside the LRCLK period
  logic [BITPOS_W-1:0]    bitpos;            // BCLK period inside the LRCLK period
  logic [BITPOS_W-1:0]    data_pos;          // stream position carried in this BCLK period
  logic [SLOT_BCLKS-1:0]  slot_word;         // MSB-aligned sample of the selected slot
  logic                   sdata_next;
  logic [FRAME_W-1:0]     frame;             // frame being sent: [15:0] left, [31:16] right
  logic                   fetched;           // a FIFO word is due on fifo_dout this clock
  logic                   fifo_empty;
  logic                   fifo_rd_rst_busy;
  logic                   fifo_rd_en;
  logic [FRAME_W-1:0]     fifo_dout;
  logic                   fetch_point;       // frame boundary this clock
  logic                   underrun_aud;      // one aud_clk pulse per underrun

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

  assign wr_ctrl       = reg_wr_en && (reg_wr_addr == AUD_CTRL_OFS);
  assign wr_status     = reg_wr_en && (reg_wr_addr == AUD_STATUS_OFS);
  assign wr_thresh     = reg_wr_en && (reg_wr_addr == AUD_THRESH_OFS);
  assign fifo_wr_req   = reg_wr_en && (reg_wr_addr == AUD_SAMPLE_OFS);
  assign fifo_wr_block = fifo_full || fifo_wr_rst_busy || (flush_state != S_IDLE);
  assign fifo_wr_en    = fifo_wr_req && !fifo_wr_block;
  assign level_low     = (level <= thresh);

  // ---------------------------------------------------------------------------
  // Control and threshold registers.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      ctrl_enable <= 1'b0;
      ctrl_irq_en <= 1'b0;
      thresh      <= THRESH_RESET;
    end else begin
      if (wr_ctrl) begin
        ctrl_enable <= reg_wr_data[AUD_CTRL_ENABLE_BIT];
        ctrl_irq_en <= reg_wr_data[AUD_CTRL_IRQ_EN_BIT];
      end
      if (wr_thresh) thresh <= reg_wr_data[AUD_LEVEL_W-1:0];
    end
  end

  // ---------------------------------------------------------------------------
  // Flush / FIFO reset sequencer: runs after reset and on CTRL.FLUSH. Raises
  // rst only with wr_rst_busy low, holds it until wr_rst_busy is high, then
  // waits for wr_rst_busy to fall (read side reset and acknowledged).
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      flush_state <= S_READY_WAIT;
      fifo_rst    <= 1'b0;
    end else begin
      case (flush_state)
        S_IDLE: begin
          if (wr_ctrl && reg_wr_data[AUD_CTRL_FLUSH_BIT]) begin
            flush_state <= S_READY_WAIT;
          end
        end
        S_READY_WAIT: begin
          if (!fifo_wr_rst_busy) begin
            fifo_rst    <= 1'b1;
            flush_state <= S_RST_ASSERT;
          end
        end
        S_RST_ASSERT: begin
          if (fifo_wr_rst_busy) begin
            fifo_rst    <= 1'b0;
            flush_state <= S_RST_RELEASE;
          end
        end
        S_RST_RELEASE: begin
          if (!fifo_wr_rst_busy) flush_state <= S_IDLE;
        end
        default: begin
          fifo_rst    <= 1'b0;
          flush_state <= S_READY_WAIT;
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // LEVEL register, sticky status bits, underrun counter and interrupt.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      level           <= '0;
      status_irq      <= 1'b0;
      status_underrun <= 1'b0;
      underruns       <= '0;
      irq             <= 1'b0;
    end else begin
      level <= fifo_wr_rst_busy ? '0 : fifo_wr_count;

      if (level_low)                                           status_irq <= 1'b1;
      else if (wr_status && reg_wr_data[AUD_STATUS_IRQ_BIT])   status_irq <= 1'b0;

      if (underrun_cpu)                                            status_underrun <= 1'b1;
      else if (wr_status && reg_wr_data[AUD_STATUS_UNDERRUN_BIT])  status_underrun <= 1'b0;

      if (underrun_cpu && (underruns != UNDERRUNS_MAX)) underruns <= underruns + 1'b1;

      irq <= status_irq && ctrl_irq_en;
    end
  end

  // ---------------------------------------------------------------------------
  // Registered read mux.
  // ---------------------------------------------------------------------------
  always_comb begin
    ctrl_word                          = '0;
    ctrl_word[AUD_CTRL_ENABLE_BIT]     = ctrl_enable;
    ctrl_word[AUD_CTRL_FLUSH_BIT]      = (flush_state != S_IDLE);
    ctrl_word[AUD_CTRL_IRQ_EN_BIT]     = ctrl_irq_en;
    status_word                        = '0;
    status_word[AUD_STATUS_IRQ_BIT]      = status_irq;
    status_word[AUD_STATUS_UNDERRUN_BIT] = status_underrun;
    status_word[AUD_STATUS_FULL_BIT]     = fifo_wr_block;
  end

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        AUD_CTRL_OFS:      reg_rd_data <= ctrl_word;
        AUD_STATUS_OFS:    reg_rd_data <= status_word;
        AUD_LEVEL_OFS:     reg_rd_data <= 32'(level);
        AUD_UNDERRUNS_OFS: reg_rd_data <= underruns;
        AUD_THRESH_OFS:    reg_rd_data <= 32'(thresh);
        default:           reg_rd_data <= '0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Sample FIFO, cpu_clk -> aud_clk: AUD_FIFO_DEPTH x FRAME_W block RAM,
  // standard read mode with one cycle of read latency, wr_data_count only
  // (USE_ADV_FEATURES bit 2). rst follows the sequencer above. Vendor IP:
  // xpm_fifo_async contains its own asynchronous-reset synchronizers
  // (xpm_cdc_sync_rst) and Gray pointer crossings; this is the documented
  // vendor-IP exception for this module.
  // ---------------------------------------------------------------------------
  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .ECC_MODE            ("no_ecc"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (XPM_SIM_ASSERT),
    .FIFO_WRITE_DEPTH    (AUD_FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (FRAME_W),
    .WR_DATA_COUNT_WIDTH (AUD_LEVEL_W),
    .PROG_FULL_THRESH    (XPM_PROG_THRESH),
    .FULL_RESET_VALUE    (0),
    .USE_ADV_FEATURES    ("0004"),
    .READ_MODE           ("std"),
    .FIFO_READ_LATENCY   (FIFO_READ_LAT),
    .READ_DATA_WIDTH     (FRAME_W),
    .RD_DATA_COUNT_WIDTH (1),
    .PROG_EMPTY_THRESH   (XPM_PROG_THRESH),
    .DOUT_RESET_VALUE    ("0"),
    .CDC_SYNC_STAGES     (FIFO_CDC_STAGES),
    .WAKEUP_TIME         (0)
  ) u_fifo (
    .sleep         (1'b0),
    .rst           (fifo_rst),
    .wr_clk        (cpu_clk),
    .wr_en         (fifo_wr_en),
    .din           (reg_wr_data),
    .full          (fifo_full),
    .prog_full     (),
    .wr_data_count (fifo_wr_count),
    .overflow      (),
    .wr_rst_busy   (fifo_wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (aud_clk),
    .rd_en         (fifo_rd_en),
    .dout          (fifo_dout),
    .empty         (fifo_empty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (fifo_rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  // ---------------------------------------------------------------------------
  // CDC: CTRL.ENABLE into aud_clk (a register held for many aud_clk cycles).
  // ---------------------------------------------------------------------------
  rtlnet_sync #(.WIDTH(1), .STAGES(ENABLE_STAGES), .RESET_VALUE(1'b0)) u_enable_sync (
    .clk    (aud_clk),
    .resetn (aud_resetn),
    .d      (ctrl_enable),
    .q      (enable_aud)
  );

  // CDC: underrun events into cpu_clk (one per LRCLK period at most).
  rtlnet_pulse_sync u_underrun_sync (
    .src_clk    (aud_clk),
    .src_resetn (aud_resetn),
    .src_pulse  (underrun_aud),
    .dst_clk    (cpu_clk),
    .dst_resetn (cpu_resetn),
    .dst_pulse  (underrun_cpu)
  );

  // ---------------------------------------------------------------------------
  // I2S transmitter (aud_clk).
  // ---------------------------------------------------------------------------
  assign bitpos      = fs_cnt[FS_CNT_W-1:PHASE_W];
  assign fetch_point = (fs_cnt == FETCH_CNT);
  assign fifo_rd_en  = fetch_point && enable_aud && !fifo_rd_rst_busy && !fifo_empty;

  // The bit carried in BCLK period b is stream position b - 1 (one BCLK of
  // I2S delay): position[BITPOS_W-1] picks the slot, the rest the bit inside
  // the MSB-aligned slot word.
  always_comb begin
    data_pos   = bitpos - 1'b1;
    slot_word  = data_pos[BITPOS_W-1] ? {frame[FRAME_W-1:AUD_SAMPLE_W], {PAD_W{1'b0}}}
                                      : {frame[AUD_SAMPLE_W-1:0], {PAD_W{1'b0}}};
    sdata_next = slot_word[SLOT_BCLKS - 1 - data_pos[SLOTPOS_W-1:0]];
  end

  // Divider and pin flip-flops: all three outputs are registered from the
  // same divider value, so LRCLK and SDATA change exactly on BCLK falling
  // edges (BCLK is high in the upper half of each BCLK period).
  always_ff @(posedge aud_clk) begin
    if (!aud_resetn) begin
      fs_cnt      <= '0;
      aud_bclk_q  <= 1'b0;
      aud_lrclk_q <= 1'b0;
      aud_sdata_q <= 1'b0;
    end else begin
      fs_cnt      <= fs_cnt + 1'b1;
      aud_bclk_q  <= fs_cnt[PHASE_W-1];
      aud_lrclk_q <= bitpos[BITPOS_W-1];
      aud_sdata_q <= sdata_next;
    end
  end

  // Frame boundary: take the next frame (FIFO word, or zeros) and flag an
  // underrun when playing from an empty FIFO.
  always_ff @(posedge aud_clk) begin
    if (!aud_resetn) begin
      frame        <= '0;
      fetched      <= 1'b0;
      underrun_aud <= 1'b0;
    end else begin
      fetched      <= fifo_rd_en;
      underrun_aud <= fetch_point && enable_aud && !fifo_rd_rst_busy && fifo_empty;
      if (fs_cnt == CAPTURE_CNT) frame <= fetched ? fifo_dout : '0;
    end
  end

  // ---------------------------------------------------------------------------
  // Simulation-only checks: the FIFO enables are gated structurally above;
  // these make a firmware overflow and any gating fault visible.
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always @(posedge cpu_clk) begin
    if (cpu_resetn && fifo_wr_req && fifo_wr_block)
      $error("%m: AUD_SAMPLE write dropped, FIFO full or in reset (STATUS.FULL = 1)");
    if (cpu_resetn && fifo_wr_en && fifo_wr_rst_busy)
      $error("%m: FIFO write while wr_rst_busy");
  end
  always @(posedge aud_clk) begin
    if (aud_resetn && fifo_rd_en && (fifo_empty || fifo_rd_rst_busy))
      $error("%m: FIFO read while empty or rd_rst_busy");
    if (aud_resetn && (^{aud_bclk_q, aud_lrclk_q, aud_sdata_q} === 1'bx))
      $error("%m: unknown I2S output after reset");
  end
  // synthesis translate_on

endmodule
