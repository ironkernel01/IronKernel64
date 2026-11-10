// -----------------------------------------------------------------------------
// File: ps2_rx.sv
// Purpose: PS/2 device-to-host receiver for the USB keyboard on J15. The
//   board's PIC24 USB HID host presents the keyboard as a PS/2 device on the
//   FPGA's PS2_CLK / PS2_DATA pins (Nexys Video RM section 8); this core
//   receives its scan-code bytes into a FIFO that core 0 reads over
//   AXI4-Lite.
// Overview:
//   * RECEIVE ONLY. Host-to-device transmission (clock inhibit, request to
//     send, keyboard LED and typematic commands) is not implemented: the core
//     never drives either line, and c64_top connects both pins as inputs with
//     pull-ups. Firmware therefore cannot set keyboard LEDs or reset the
//     keyboard; the PIC24 bridge initialises the keyboard itself.
//   * Registers (AXI4-Lite through ik64_axil_slave, REG_ADDR_W-bit address;
//     offsets and bits are c64_pkg PS2_*). Undefined offsets read 0 and
//     ignore writes.
//       PS2_DATA    RO [7:0] oldest byte, [PS2_DATA_VALID_BIT] 1 when a byte
//                      was returned. A read pops that byte. A read of an empty
//                      FIFO returns 0 (valid clear) and changes nothing.
//       PS2_STATUS  [AVAIL] RO FIFO not empty; [PARITY], [OVERFLOW], [FRAME]
//                      sticky, W1C (write 1 clears; an event in the same clock
//                      wins).
//       PS2_CTRL    RW [IRQ_EN].
//   * irq (output) = STATUS.AVAIL && CTRL.IRQ_EN, registered, a level.
//   * Input path: ps2_clk and ps2_data are asynchronous. Each enters a
//     3-stage ik64_sync chain in cpu_clk (reset value 1, the idle level),
//     then a glitch filter: the filtered line takes a new value only after the
//     synchronized line has held it for FILTER_CYCLES consecutive clocks.
//     FILTER_NS is one sixteenth of the shortest PS/2 half period
//     (16.7 kHz -> 29.9 us), so a pulse shorter than about 1.9 us is ignored
//     and a legal clock phase (at least 30 us) always passes.
//   * Frame (11 bits, device to host, data valid on the falling clock edge):
//     start 0, 8 data bits LSB first, odd parity, stop 1. Bits are sampled at
//     each falling edge of the filtered clock from the filtered data line,
//     FILTER_NS after the real edge; the device holds data for the whole
//     clock-low phase.
//       - start bit 1                 -> FRAME set, no frame started;
//       - stop bit 0                  -> FRAME set, byte discarded;
//       - parity not odd (stop good)  -> PARITY set, byte discarded;
//       - no falling edge for BIT_TIMEOUT_US inside a frame -> FRAME set, the
//         partial frame is discarded and the receiver waits for a new start
//         bit (resynchronisation after a lost edge);
//       - good frame, FIFO full       -> OVERFLOW set, byte discarded.
//   * FIFO: PS2_FIFO_DEPTH bytes in registers, single clock. The write enable
//     is gated by !full (an overflow drops the new byte, the queue keeps the
//     old ones); simulation flags any storage write or pop that bypasses the
//     guards.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk (CLK_HZ, 100 MHz on the Nexys Video) only; cpu_resetn is
//   synchronous to it, active low. ps2_clk / ps2_data are asynchronous inputs
//   (not clocks).
// -----------------------------------------------------------------------------
module ps2_rx #(
  parameter int CLK_HZ = 100_000_000          // cpu_clk frequency, Hz (filter and timeout)
)(
  // cpu_clk domain: CPU/AXI clock and its synchronous active-low reset.
  input  logic                           cpu_clk,
  input  logic                           cpu_resetn,

  // AXI4-Lite register slave, cpu_clk domain, 32-bit data, REG_ADDR_W-bit
  // byte address (64 KiB window); one outstanding transaction, all OKAY.
  input  logic [c64_pkg::REG_ADDR_W-1:0] s_axi_awaddr,
  input  logic                           s_axi_awvalid,
  output logic                           s_axi_awready,
  input  logic [31:0]                    s_axi_wdata,
  input  logic [3:0]                     s_axi_wstrb,
  input  logic                           s_axi_wvalid,
  output logic                           s_axi_wready,
  output logic [1:0]                     s_axi_bresp,
  output logic                           s_axi_bvalid,
  input  logic                           s_axi_bready,
  input  logic [c64_pkg::REG_ADDR_W-1:0] s_axi_araddr,
  input  logic                           s_axi_arvalid,
  output logic                           s_axi_arready,
  output logic [31:0]                    s_axi_rdata,
  output logic [1:0]                     s_axi_rresp,
  output logic                           s_axi_rvalid,
  input  logic                           s_axi_rready,

  // PS/2 lines from the PIC24 USB-HID bridge (Nexys Video PS2_CLK W17,
  // PS2_DATA N13, pulled up; open-collector, idle high). Asynchronous to
  // cpu_clk; c64_top passes the input buffers' outputs straight in. Inputs
  // only: this core never drives the lines.
  input  logic                           ps2_clk,
  input  logic                           ps2_data,

  // Interrupt to core 0, cpu_clk register, active-high level:
  // FIFO not empty && CTRL.IRQ_EN.
  output logic                           irq
);

  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Timing constants, derived from the PS/2 clock range (10 .. 16.7 kHz).
  // ---------------------------------------------------------------------------
  localparam int ADDR_W           = REG_ADDR_W;
  localparam int NS_PER_S         = 1_000_000_000;
  localparam int US_PER_S         = 1_000_000;
  localparam int PS2_CLK_MAX_HZ   = 16_700;                          // fastest legal device clock
  localparam int PS2_HALF_MIN_NS  = NS_PER_S / (2 * PS2_CLK_MAX_HZ); // 29,940 ns shortest clock phase
  localparam int FILTER_DIV       = 16;                              // filter = 1/16 of the shortest phase
  localparam int FILTER_NS        = PS2_HALF_MIN_NS / FILTER_DIV;    // 1,871 ns
  localparam int CLK_PER_US       = CLK_HZ / US_PER_S;
  localparam int FILTER_CYCLES    = (CLK_PER_US * FILTER_NS) / (NS_PER_S / US_PER_S); // 187 at 100 MHz
  // Bit timeout: the slowest frame (10 kHz, 11 bits) lasts 1.1 ms and one
  // bit 100 us; 2 ms without a falling edge inside a frame is a stall.
  localparam int BIT_TIMEOUT_US   = 2_000;
  localparam int TIMEOUT_CYCLES   = CLK_PER_US * BIT_TIMEOUT_US;     // 200,000 at 100 MHz
  localparam int FILTER_W         = $clog2(FILTER_CYCLES + 1);
  localparam int TIMEOUT_W        = $clog2(TIMEOUT_CYCLES + 1);
  localparam int SYNC_STAGES      = 3;
  localparam int LINES            = 2;                               // [0] clock, [1] data
  localparam int LINE_CLK         = 0;
  localparam int LINE_DATA        = 1;

  localparam int BYTE_W           = 8;
  localparam int BITCNT_W         = $clog2(BYTE_W);
  localparam int PTR_W            = $clog2(PS2_FIFO_DEPTH);
  localparam int COUNT_W          = PTR_W + 1;

  generate
    if (CLK_PER_US < 1 || FILTER_CYCLES < 2) begin : g_bad_clk
      $fatal(1, "ps2_rx: CLK_HZ=%0d too low for the %0d ns glitch filter", CLK_HZ, FILTER_NS);
    end
    if ((1 << PTR_W) != PS2_FIFO_DEPTH) begin : g_bad_depth
      $fatal(1, "ps2_rx: PS2_FIFO_DEPTH=%0d must be a power of two", PS2_FIFO_DEPTH);
    end
  endgenerate

  // Frame receiver states.
  localparam logic [1:0] S_IDLE   = 2'd0;  // waiting for a start bit
  localparam logic [1:0] S_DATA   = 2'd1;  // 8 data bits, LSB first
  localparam logic [1:0] S_PARITY = 2'd2;  // odd parity bit
  localparam logic [1:0] S_STOP   = 2'd3;  // stop bit

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic                   reg_wr_en;
  logic [ADDR_W-1:0]      reg_wr_addr;
  logic [31:0]            reg_wr_data;
  logic                   reg_rd_en;
  logic [ADDR_W-1:0]      reg_rd_addr;
  logic [31:0]            reg_rd_data;

  logic [LINES-1:0]       line_sync;          // last synchronizer stage per line
  logic [LINES-1:0]       line_filt;          // glitch-filtered lines
  logic                   clk_filt_d;         // history of the filtered clock
  logic                   clk_fall;           // filtered clock falling edge, one clock

  logic [1:0]             rx_state;           // the one receiver state register
  logic [BITCNT_W-1:0]    rx_bit;             // data bit index
  logic [BYTE_W-1:0]      rx_shift;           // data bits, LSB first
  logic                   rx_parity;          // received parity bit
  logic [TIMEOUT_W-1:0]   rx_timer;           // clocks since the last falling edge
  logic                   rx_push;            // good byte in rx_shift, one clock
  logic                   ev_parity;          // events, one clock each
  logic                   ev_frame;

  logic [BYTE_W-1:0]      fifo_mem [PS2_FIFO_DEPTH];
  logic [PTR_W-1:0]       fifo_wr_ptr;
  logic [PTR_W-1:0]       fifo_rd_ptr;
  logic [COUNT_W-1:0]     fifo_count;
  logic                   fifo_full;
  logic                   fifo_empty;
  logic                   fifo_wr_en;         // gated storage write
  logic                   fifo_pop_req;       // PS2_DATA read strobe
  logic                   fifo_pop;           // gated pop
  logic                   ev_overflow;

  logic                   ctrl_irq_en;
  logic                   status_parity;
  logic                   status_overflow;
  logic                   status_frame;
  logic                   wr_status;
  logic [31:0]            status_word;

  // ---------------------------------------------------------------------------
  // AXI4-Lite to register strobes; read data is due one clock after reg_rd_en.
  // ---------------------------------------------------------------------------
  ik64_axil_slave #(.ADDR_W(ADDR_W)) u_axil (
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
  // Asynchronous PS/2 lines: 3-stage level synchronizers in cpu_clk, idle
  // high, so the chains reset to 1. Only the last stage is read.
  // ---------------------------------------------------------------------------
  ik64_sync #(.WIDTH(LINES), .STAGES(SYNC_STAGES), .RESET_VALUE(1'b1)) u_line_sync (
    .clk    (cpu_clk),
    .resetn (cpu_resetn),
    .d      ({ps2_data, ps2_clk}),
    .q      (line_sync)
  );

  // Glitch filter per line: the output follows the synchronized line only
  // after FILTER_CYCLES consecutive clocks at the new value.
  genvar gl;
  generate
    for (gl = 0; gl < LINES; gl++) begin : g_filter
      logic                filt;              // filtered level
      logic [FILTER_W-1:0] filt_cnt;          // clocks the synchronized line has differed

      always_ff @(posedge cpu_clk) begin
        if (!cpu_resetn) begin
          filt     <= 1'b1;
          filt_cnt <= '0;
        end else if (line_sync[gl] == filt) begin
          filt_cnt <= '0;
        end else if (filt_cnt == FILTER_W'(FILTER_CYCLES - 1)) begin
          filt     <= line_sync[gl];
          filt_cnt <= '0;
        end else begin
          filt_cnt <= filt_cnt + 1'b1;
        end
      end

      assign line_filt[gl] = filt;
    end
  endgenerate

  // Falling-edge detect on the filtered clock against its history register.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      clk_filt_d <= 1'b1;
      clk_fall   <= 1'b0;
    end else begin
      clk_filt_d <= line_filt[LINE_CLK];
      clk_fall   <= clk_filt_d && !line_filt[LINE_CLK];
    end
  end

  // ---------------------------------------------------------------------------
  // Frame receiver: one bit per filtered falling edge, bit timeout inside a
  // frame. Emits rx_push for a good byte and one-clock error events.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      rx_state  <= S_IDLE;
      rx_bit    <= '0;
      rx_shift  <= '0;
      rx_parity <= 1'b0;
      rx_timer  <= '0;
      rx_push   <= 1'b0;
      ev_parity <= 1'b0;
      ev_frame  <= 1'b0;
    end else begin
      rx_push   <= 1'b0;
      ev_parity <= 1'b0;
      ev_frame  <= 1'b0;

      if (clk_fall || rx_state == S_IDLE) rx_timer <= '0;
      else                                rx_timer <= rx_timer + 1'b1;

      if (rx_state != S_IDLE && !clk_fall && rx_timer == TIMEOUT_W'(TIMEOUT_CYCLES - 1)) begin
        ev_frame <= 1'b1;
        rx_state <= S_IDLE;
      end else if (clk_fall) begin
        case (rx_state)
          S_IDLE: begin
            if (!line_filt[LINE_DATA]) begin
              rx_bit   <= '0;
              rx_state <= S_DATA;
            end else begin
              ev_frame <= 1'b1;
            end
          end
          S_DATA: begin
            rx_shift <= {line_filt[LINE_DATA], rx_shift[BYTE_W-1:1]};
            rx_bit   <= rx_bit + 1'b1;
            if (rx_bit == BITCNT_W'(BYTE_W - 1)) rx_state <= S_PARITY;
          end
          S_PARITY: begin
            rx_parity <= line_filt[LINE_DATA];
            rx_state  <= S_STOP;
          end
          S_STOP: begin
            if (!line_filt[LINE_DATA])         ev_frame  <= 1'b1;
            else if (^{rx_shift, rx_parity})   rx_push   <= 1'b1;
            else                               ev_parity <= 1'b1;
            rx_state <= S_IDLE;
          end
          default: rx_state <= S_IDLE;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Byte FIFO: write gated by !full, pop gated by !empty.
  // ---------------------------------------------------------------------------
  assign fifo_full    = (fifo_count == COUNT_W'(PS2_FIFO_DEPTH));
  assign fifo_empty   = (fifo_count == '0);
  assign fifo_wr_en   = rx_push && !fifo_full;
  assign ev_overflow  = rx_push && fifo_full;
  assign fifo_pop_req = reg_rd_en && (reg_rd_addr == PS2_DATA_OFS);
  assign fifo_pop     = fifo_pop_req && !fifo_empty;

  // Storage, written only through the gated enable.
  always_ff @(posedge cpu_clk) begin
    if (fifo_wr_en) fifo_mem[fifo_wr_ptr] <= rx_shift;
  end

  // Pointers and occupancy.
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count  <= '0;
    end else begin
      if (fifo_wr_en) fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
      if (fifo_pop)   fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
      if (fifo_wr_en && !fifo_pop)      fifo_count <= fifo_count + 1'b1;
      else if (fifo_pop && !fifo_wr_en) fifo_count <= fifo_count - 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Control, sticky status (event wins over W1C) and interrupt.
  // ---------------------------------------------------------------------------
  assign wr_status = reg_wr_en && (reg_wr_addr == PS2_STATUS_OFS);

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      ctrl_irq_en     <= 1'b0;
      status_parity   <= 1'b0;
      status_overflow <= 1'b0;
      status_frame    <= 1'b0;
      irq             <= 1'b0;
    end else begin
      if (reg_wr_en && (reg_wr_addr == PS2_CTRL_OFS)) ctrl_irq_en <= reg_wr_data[PS2_CTRL_IRQ_EN_BIT];

      if (ev_parity)                                              status_parity <= 1'b1;
      else if (wr_status && reg_wr_data[PS2_STATUS_PARITY_BIT])   status_parity <= 1'b0;

      if (ev_overflow)                                              status_overflow <= 1'b1;
      else if (wr_status && reg_wr_data[PS2_STATUS_OVERFLOW_BIT])   status_overflow <= 1'b0;

      if (ev_frame)                                               status_frame <= 1'b1;
      else if (wr_status && reg_wr_data[PS2_STATUS_FRAME_BIT])    status_frame <= 1'b0;

      irq <= !fifo_empty && ctrl_irq_en;
    end
  end

  // ---------------------------------------------------------------------------
  // Registered read mux; a PS2_DATA read returns the head byte and pops it.
  // ---------------------------------------------------------------------------
  always_comb begin
    status_word                          = '0;
    status_word[PS2_STATUS_AVAIL_BIT]    = !fifo_empty;
    status_word[PS2_STATUS_PARITY_BIT]   = status_parity;
    status_word[PS2_STATUS_OVERFLOW_BIT] = status_overflow;
    status_word[PS2_STATUS_FRAME_BIT]    = status_frame;
  end

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      reg_rd_data <= '0;
      case (reg_rd_addr)
        PS2_DATA_OFS: begin
          if (!fifo_empty) begin
            reg_rd_data[BYTE_W-1:0]         <= fifo_mem[fifo_rd_ptr];
            reg_rd_data[PS2_DATA_VALID_BIT] <= 1'b1;
          end
        end
        PS2_STATUS_OFS: reg_rd_data <= status_word;
        PS2_CTRL_OFS:   reg_rd_data[PS2_CTRL_IRQ_EN_BIT] <= ctrl_irq_en;
        default:        reg_rd_data <= '0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Simulation-only checks: the FIFO enables are gated structurally above;
  // these make any bypass of the guards visible. A good byte arriving at a
  // full FIFO is a specified event (STATUS.OVERFLOW), not a design error.
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always @(posedge cpu_clk) begin
    if (cpu_resetn && fifo_wr_en && fifo_full) $error("%m: PS/2 FIFO storage write while full");
    if (cpu_resetn && fifo_pop && fifo_empty)  $error("%m: PS/2 FIFO pop while empty");
    if (cpu_resetn && (^{irq, fifo_count, rx_state} === 1'bx)) $error("%m: unknown PS/2 state after reset");
  end
  // synthesis translate_on

endmodule
