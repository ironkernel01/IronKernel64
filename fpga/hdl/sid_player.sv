// -----------------------------------------------------------------------------
// File: sid_player.sv
// Purpose: SID sound for core 0. Firmware pushes timestamped SID register
//   writes (the 6502 side of the emulator); this block replays each write at
//   its phi2 cycle into the reDIP-SID core (sid_api, one 6581 at $D400),
//   reads OSC3/ENV3 back, and turns the core's output into a 48 kHz mono
//   sample stream for sid_audio_out.
// Overview:
//   * Registers (AXI4-Lite through rtlnet_axil_slave, REG_ADDR_W-bit address;
//     offsets and bits are c64_pkg SID_*). Undefined offsets read 0 and ignore
//     writes.
//       SID_CTRL    RW [RUN] phi2 and the replay run (0: phi2 and the 48 kHz
//                      tick freeze); [RESET] level: holds the core's res high,
//                      empties the FIFO, holds CYCLE at 0 and clears OVERFLOW
//                      (RUN must be 1 for the core to see res, its pipeline
//                      only advances with phi2).
//       SID_STATUS  [OVERFLOW] W1C, [FULL] RO, [LEVEL] RO FIFO fill (writes).
//       SID_CYCLE   RO phi2 cycles completed (counted on phi2 falling edges).
//       SID_WTIME   WO time (phi2 cycle) of the next pushed write.
//       SID_WDATA   WO push: [12:8] SID register, [7:0] value; stores
//                      {WTIME, reg, val}. Reads 0.
//       SID_RDBK    RO [7:0] OSC3 (reg $1B), [15:8] ENV3 (reg $1C), each
//                      updated about every other phi2 cycle.
//   * phi2: exact rational NCO on cpu_clk. acc += 2 * SID_PHI2_HZ per clock;
//     when acc >= CPU_CLK_HZ it subtracts CPU_CLK_HZ and phi2 toggles. The mean
//     phi2 rate is exactly SID_PHI2_HZ; each phase is 50 or 51 clocks (>= 20,
//     the SID pipeline's budget per phi2 cycle).
//   * Write FIFO: SID_FIFO_DEPTH x {time[31:0], reg[4:0], val[7:0]}, block RAM
//     with a registered read of the head entry. Pushes are ANDed with !full;
//     a push into a full FIFO is dropped, sets sticky OVERFLOW and, in
//     simulation, is an $error (suppressed only while a bench sets
//     sim_expect_overflow). Pushes during RESET are dropped silently.
//   * Replay and bus timing. One phi2 cycle starts at the phi2 rising edge.
//     At that clock the replay decides the cycle's bus operation and bus_i
//     takes it together with phi2 = 1, so it is stable until the next rising
//     edge:
//       - write: the FIFO head is due when $signed(CYCLE - time) >= 0 (late
//         writes play at once, at most one per cycle): popped, r_w_n = 0,
//         cs_n = 0, addr/data from the entry;
//       - else read: r_w_n = 1, cs_n = 0, addr alternates $1B / $1C;
//       - during RESET: cs_n = 1.
//     CYCLE counts falling edges, so a write with time T is presented in the
//     phi2 cycle whose rising edge sees CYCLE == T.
//     Why this matches a 6510: sid_control (upstream) samples a write on
//     ~phi2 & ~r_w_n during its voice cycles 1..6, which start the clock after
//     the falling edge and last 6 clocks (the pipeline is idle for the rest of
//     the 50-clock low phase), taking addr/data/cs from bus_i in those
//     clocks; a read is combinational on phi2 & r_w_n, data_o valid while phi2
//     is high. Holding addr, data, r_w_n and cs_n for the whole cycle covers
//     both (the real 6510 holds write data through the falling edge). OSC3 and
//     ENV3 are latched inside the core at voice cycle 8 of the previous cycle,
//     so data_o is stable; it is captured on the clock of the falling edge.
//   * Audio: audio_o.left (s24) is taken once per phi2 cycle into two cascaded
//     moving sums of SID_DECIM_TAPS (gain 20 * 20 = 400, delay lines are
//     shift registers). On each exact 48 kHz tick (acc += 48,000 against
//     CPU_CLK_HZ, so it matches sid_audio_out's drain rate exactly) the second
//     sum is scaled by 1/400 and by 1/256 (s24 to s16, the core's 24-bit word
//     carries the 16-bit sample in its top bits), saturated to s16 and sent as
//     strm_valid (1 clock) with strm_sample.
//   * No interrupt. The SID core has no reset: it relies on initial values and
//     the replay holds res through CTRL.RESET only; cpu_resetn resets this
//     block's own logic.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: cpu_clk (100 MHz) only; cpu_resetn is synchronous to it.
// -----------------------------------------------------------------------------
module sid_player (
  // cpu_clk domain: 100 MHz CPU/AXI/SID clock and its synchronous active-low
  // reset (this block's own logic only; the SID core has no reset).
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

  // 48 kHz mono sample stream to sid_audio_out (cpu_clk): strm_valid is one
  // clock wide; strm_sample is signed two's complement, valid with it.
  output logic                          strm_valid,
  output logic signed [15:0]            strm_sample
);

  import c64_pkg::*;

  // ---------------------------------------------------------------------------
  // Geometry, all derived from c64_pkg.
  // ---------------------------------------------------------------------------
  localparam int ADDR_W    = REG_ADDR_W;
  localparam int PTR_W     = $clog2(SID_FIFO_DEPTH);
  localparam int ENTRY_W   = 32 + 5 + 8;                              // {time, reg, val}
  localparam int NCO_W     = $clog2(CPU_CLK_HZ + 2 * SID_PHI2_HZ);
  localparam int N1_W      = 24 + $clog2(SID_DECIM_TAPS);             // first moving sum
  localparam int N2_W      = N1_W + $clog2(SID_DECIM_TAPS);           // second moving sum
  localparam int GAIN      = SID_DECIM_TAPS * SID_DECIM_TAPS;         // 400
  // Scale 1/(GAIN * 256) = (sum >>> 8) * SCALE_MUL >>> SCALE_SHIFT.
  localparam int SCALE_SHIFT = 18;
  localparam logic signed [11:0] SCALE_MUL = 12'((1 << SCALE_SHIFT) / GAIN); // 655
  localparam logic [4:0] REG_OSC3 = 5'h1B;
  localparam logic [4:0] REG_ENV3 = 5'h1C;
  localparam logic [NCO_W-1:0] PHI2_STEP = NCO_W'(2 * SID_PHI2_HZ);
  localparam logic [NCO_W-1:0] CLK_HZ    = NCO_W'(CPU_CLK_HZ);
  localparam logic [NCO_W-1:0] AUD_STEP  = NCO_W'(AUD_SAMPLE_RATE_HZ);

  generate
    if (SID_FIFO_DEPTH != (1 << PTR_W) || SID_LEVEL_W != PTR_W + 1 || SID_DECIM_TAPS < 2 ||
        2 * SID_PHI2_HZ * 20 > CPU_CLK_HZ * 2) begin : g_bad_geometry
      $fatal(1, "sid_player: SID_FIFO_DEPTH=%0d must be a power of two and SID_LEVEL_W=%0d = log2 + 1; phi2 needs >= 20 clocks per cycle",
             SID_FIFO_DEPTH, SID_LEVEL_W);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic                   reg_wr_en;
  logic [ADDR_W-1:0]      reg_wr_addr;
  logic [31:0]            reg_wr_data;
  logic                   reg_rd_en;
  logic [ADDR_W-1:0]      reg_rd_addr;
  logic [31:0]            reg_rd_data;

  logic                   ctrl_run;
  logic                   ctrl_reset;
  logic                   status_overflow;
  logic [31:0]            wtime;
  logic [31:0]            cycle_cnt;         // SID_CYCLE: phi2 falling edges
  logic [15:0]            rdbk;              // {ENV3, OSC3}

  logic                   wr_ctrl;
  logic                   wr_status;
  logic                   wr_wtime;
  logic                   fifo_wr_req;       // SID_WDATA write strobe
  logic                   fifo_full;
  logic                   fifo_wr_en;
  logic                   fifo_pop;

  // FIFO
  (* ram_style = "block" *)
  logic [ENTRY_W-1:0]     mem [SID_FIFO_DEPTH];
  logic [PTR_W-1:0]       wr_ptr;
  logic [PTR_W-1:0]       rd_ptr;
  logic [SID_LEVEL_W-1:0] level;
  logic [ENTRY_W-1:0]     head;              // mem[rd_ptr], one clock old
  logic                   head_ok;           // head holds the entry at rd_ptr

  // phi2 NCO and replay
  logic [NCO_W-1:0]       phi2_acc;
  logic [NCO_W-1:0]       phi2_sum;
  logic                   phi2_tick;         // phi2 toggles at the end of this clock
  logic                   phi2_rise;
  logic                   phi2_fall;
  logic                   due;
  sid::bus_i_t            bus_i;
  logic                   cs_n;
  logic                   op_read;           // current cycle is a read
  logic                   op_env;            // the read is ENV3
  logic                   rd_sel;            // next read is ENV3
  logic [7:0]             sid_data;
  sid::audio_t            sid_audio;
  sid::cs_t               sid_cs;

  // Audio
  logic [NCO_W-1:0]       aud_acc;
  logic [NCO_W-1:0]       aud_sum;
  logic                   aud_tick;
  logic                   cic1_en;           // stage 1 update, the clock after phi2_rise
  logic                   cic2_en;           // stage 2 update, one clock later
  logic signed [23:0]     cic_in;
  logic [SID_DECIM_TAPS-1:0][23:0]   dl1 = '0;   // delay lines: no reset, zero at power-up
  logic signed [N1_W-1:0] sum1;
  logic [SID_DECIM_TAPS-1:0][N1_W-1:0] dl2 = '0;
  logic signed [N2_W-1:0] sum2;
  logic signed [N2_W-9:0] scale_in;          // sum2 >>> 8
  logic signed [N2_W+1:0] scale_out;
  logic [2:0]             strm_pipe;         // aud_tick through scale_in, scale_out, strm_sample

  logic [31:0]            ctrl_word;
  logic [31:0]            status_word;

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

  assign wr_ctrl     = reg_wr_en && (reg_wr_addr == SID_CTRL_OFS);
  assign wr_status   = reg_wr_en && (reg_wr_addr == SID_STATUS_OFS);
  assign wr_wtime    = reg_wr_en && (reg_wr_addr == SID_WTIME_OFS);
  assign fifo_wr_req = reg_wr_en && (reg_wr_addr == SID_WDATA_OFS);
  assign fifo_full   = (level == SID_LEVEL_W'(SID_FIFO_DEPTH));
  assign fifo_wr_en  = fifo_wr_req && !fifo_full && !ctrl_reset;

  // ---------------------------------------------------------------------------
  // Control, WTIME and sticky status.
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      ctrl_run        <= 1'b0;
      ctrl_reset      <= 1'b0;
      status_overflow <= 1'b0;
      wtime           <= '0;
    end else begin
      if (wr_ctrl) begin
        ctrl_run   <= reg_wr_data[SID_CTRL_RUN_BIT];
        ctrl_reset <= reg_wr_data[SID_CTRL_RESET_BIT];
      end
      if (wr_wtime) wtime <= reg_wr_data;

      if (ctrl_reset)                                                     status_overflow <= 1'b0;
      else if (fifo_wr_req && fifo_full)                                  status_overflow <= 1'b1;
      else if (wr_status && reg_wr_data[SID_STATUS_OVERFLOW_BIT])         status_overflow <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Write FIFO. level is the one occupancy register; head follows rd_ptr one
  // clock late and head_ok marks it valid (a push into an empty FIFO is
  // readable two clocks later; phi2 rising edges are >= 50 clocks apart).
  // ---------------------------------------------------------------------------
  always_ff @(posedge cpu_clk) begin
    if (fifo_wr_en) mem[wr_ptr] <= {wtime, reg_wr_data[SID_WDATA_REG_LSB+:5], reg_wr_data[7:0]};
    head <= mem[rd_ptr];
  end

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn || ctrl_reset) begin
      wr_ptr  <= '0;
      rd_ptr  <= '0;
      level   <= '0;
      head_ok <= 1'b0;
    end else begin
      if (fifo_wr_en) wr_ptr <= wr_ptr + 1'b1;
      if (fifo_pop)   rd_ptr <= rd_ptr + 1'b1;
      level   <= level + SID_LEVEL_W'(fifo_wr_en) - SID_LEVEL_W'(fifo_pop);
      head_ok <= (level != '0);
    end
  end

  // ---------------------------------------------------------------------------
  // phi2 NCO, cycle counter and the replay bus.
  // ---------------------------------------------------------------------------
  assign phi2_sum  = phi2_acc + PHI2_STEP;
  assign phi2_tick = ctrl_run && (phi2_sum >= CLK_HZ);
  assign phi2_rise = phi2_tick && !bus_i.phi2;
  assign phi2_fall = phi2_tick && bus_i.phi2;
  assign due       = head_ok && !ctrl_reset && ($signed(cycle_cnt - head[ENTRY_W-1-:32]) >= 0);
  assign fifo_pop  = phi2_rise && due;
  assign sid_cs    = '{cs_n: cs_n, cs_io1_n: 1'b1, a8: 1'b0, a5: 1'b0};

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      phi2_acc  <= '0;
      cycle_cnt <= '0;
      bus_i     <= '{addr: '0, data: '0, phi2: 1'b0, r_w_n: 1'b1, res: 1'b0};
      cs_n      <= 1'b1;
      op_read   <= 1'b0;
      op_env    <= 1'b0;
      rd_sel    <= 1'b0;
      rdbk      <= '0;
    end else begin
      bus_i.res <= ctrl_reset;

      if (ctrl_run) begin
        phi2_acc <= phi2_tick ? phi2_sum - CLK_HZ : phi2_sum;
      end
      if (phi2_tick) bus_i.phi2 <= !bus_i.phi2;

      if (ctrl_reset) cycle_cnt <= '0;
      else if (phi2_fall) cycle_cnt <= cycle_cnt + 1'b1;

      if (phi2_rise) begin
        if (ctrl_reset) begin
          cs_n        <= 1'b1;
          bus_i.r_w_n <= 1'b1;
          op_read     <= 1'b0;
        end else if (due) begin
          bus_i.addr  <= head[12:8];
          bus_i.data  <= head[7:0];
          bus_i.r_w_n <= 1'b0;
          cs_n        <= 1'b0;
          op_read     <= 1'b0;
        end else begin
          bus_i.addr  <= rd_sel ? REG_ENV3 : REG_OSC3;
          bus_i.r_w_n <= 1'b1;
          cs_n        <= 1'b0;
          op_read     <= 1'b1;
          op_env      <= rd_sel;
          rd_sel      <= !rd_sel;
        end
      end

      // The core drives data_o for the read through the end of phi2 high.
      if (phi2_fall && op_read && !cs_n) begin
        if (op_env) rdbk[15:8] <= sid_data;
        else        rdbk[7:0]  <= sid_data;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // reDIP-SID core: one 6581 at $D400, left channel = SID 1.
  // ---------------------------------------------------------------------------
  sid_api u_sid (
    .clk     (cpu_clk),
    .bus_i   (bus_i),
    .cs      (sid_cs),
    .data_o  (sid_data),
    .pot_i   ('0),
    .pot_o   (),
    .audio_i ('0),
    .audio_o (sid_audio)
  );

  // ---------------------------------------------------------------------------
  // Audio: two moving sums per phi2 cycle, exact 48 kHz tick, scale, saturate.
  // The two stage updates run on consecutive clocks (no chained adders).
  // Delay lines have no reset: SRL-style shift registers, zero at power-up.
  // ---------------------------------------------------------------------------
  assign aud_sum  = aud_acc + AUD_STEP;
  assign aud_tick = ctrl_run && (aud_sum >= CLK_HZ);

  always_ff @(posedge cpu_clk) begin
    if (cic1_en) dl1 <= {dl1[SID_DECIM_TAPS-2:0], cic_in};
    if (cic2_en) dl2 <= {dl2[SID_DECIM_TAPS-2:0], sum1};
  end

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      aud_acc     <= '0;
      cic1_en     <= 1'b0;
      cic2_en     <= 1'b0;
      cic_in      <= '0;
      sum1        <= '0;
      sum2        <= '0;
      scale_in    <= '0;
      scale_out   <= '0;
      strm_pipe   <= '0;
      strm_valid  <= 1'b0;
      strm_sample <= '0;
    end else begin
      if (ctrl_reset) begin
        sum1 <= '0;
        sum2 <= '0;
      end else begin
        if (cic1_en) sum1 <= sum1 + N1_W'(cic_in) - N1_W'($signed(dl1[SID_DECIM_TAPS-1]));
        if (cic2_en) sum2 <= sum2 + N2_W'(sum1) - N2_W'($signed(dl2[SID_DECIM_TAPS-1]));
      end

      cic1_en <= phi2_rise;
      cic2_en <= cic1_en;
      if (phi2_rise) cic_in <= sid_audio.left;

      if (ctrl_run) aud_acc <= aud_tick ? aud_sum - CLK_HZ : aud_sum;

      strm_pipe <= {strm_pipe[1:0], aud_tick};
      scale_in  <= sum2 >>> 8;
      scale_out <= scale_in * SCALE_MUL;
      strm_valid <= strm_pipe[2];
      if (strm_pipe[2]) begin
        if ((scale_out >>> SCALE_SHIFT) > 32767)       strm_sample <= 16'sh7FFF;
        else if ((scale_out >>> SCALE_SHIFT) < -32768) strm_sample <= 16'sh8000;
        else                                           strm_sample <= 16'(scale_out >>> SCALE_SHIFT);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Registered read mux.
  // ---------------------------------------------------------------------------
  always_comb begin
    ctrl_word                          = '0;
    ctrl_word[SID_CTRL_RUN_BIT]        = ctrl_run;
    ctrl_word[SID_CTRL_RESET_BIT]      = ctrl_reset;
    status_word                        = '0;
    status_word[SID_STATUS_OVERFLOW_BIT] = status_overflow;
    status_word[SID_STATUS_FULL_BIT]   = fifo_full;
    status_word[SID_STATUS_LEVEL_LSB+:SID_LEVEL_W] = level;
  end

  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        SID_CTRL_OFS:   reg_rd_data <= ctrl_word;
        SID_STATUS_OFS: reg_rd_data <= status_word;
        SID_CYCLE_OFS:  reg_rd_data <= cycle_cnt;
        SID_RDBK_OFS:   reg_rd_data <= 32'(rdbk);
        default:        reg_rd_data <= '0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Simulation-only checks. sim_expect_overflow is set by a bench that
  // overfills the FIFO on purpose.
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  bit sim_expect_overflow = 1'b0;
  always @(posedge cpu_clk) begin
    if (cpu_resetn && fifo_wr_req && fifo_full && !ctrl_reset && !sim_expect_overflow)
      $error("%m: SID_WDATA push dropped, FIFO full (STATUS.OVERFLOW)");
    if (cpu_resetn && fifo_wr_en && fifo_full)
      $error("%m: FIFO write while full");
    if (cpu_resetn && fifo_pop && !head_ok)
      $error("%m: FIFO pop of an invalid head");
  end
  // synthesis translate_on

endmodule
