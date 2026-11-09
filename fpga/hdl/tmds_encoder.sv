// SPDX-License-Identifier: GPL-3.0-or-later
// -----------------------------------------------------------------------------
// File: tmds_encoder.sv
// Purpose: one DVI 1.0 TMDS lane encoder: 8-bit pixel data to a 10-bit
//   transition-minimized, DC-balanced character during the data enable
//   period, and one of the four control characters during blanking.
// Overview:
//   * Algorithm: DVI 1.0 (DDWG, 04-02-1999) section 3.2, TMDS encode flow
//     chart (Figure 3-5), implemented stage by stage:
//       stage 1 registers the inputs and the ones count N1{D};
//       stage 2 builds q_m[8:0] (XOR or XNOR chain, transition minimization)
//         and registers it with the ones count N1{q_m[7:0]};
//       stage 3 chooses q_out[9:8] and the data inversion from the running
//         disparity Cnt (DC balance) and registers q_out and Cnt.
//   * Control period (de low): q_out is the control character for {c1, c0}
//     (DVI 1.0 section 3.3.3, control period coding) and Cnt returns to 0, as
//     the flow chart requires at every control period.
//   * Running disparity bound: Cnt is the exact ones-minus-zeros count of the
//     data characters sent since the last control period. With |N1 - N0| of
//     q_m[7:0] at most 8, the three flow-chart branches give
//       Cnt == 0      -> new Cnt in [-8, 8];
//       Cnt >= 2      -> new Cnt in [Cnt - 10, Cnt]  (never grows);
//       Cnt <= -2     -> new Cnt in [Cnt, Cnt + 10]  (never shrinks);
//     so |Cnt| <= 8 and the CNT_W-bit two's-complement arithmetic below is
//     exact (every result lies inside [-16, 15]).
//   * Bit order: symbol[0] is q_out[0], the first bit on the wire. The
//     serializer (OSERDESE2 in c64_top.sv) shifts symbol[0] out first.
//   * Latency: 3 pixel clocks from (de, ctrl, data) to symbol (input, q_m and
//     q_out registers). All three lanes of dvi_tx share it, so the lanes stay
//     aligned.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk only (the 74.25 MHz pixel clock); resetn is synchronous to it.
// -----------------------------------------------------------------------------
module tmds_encoder (
  // Pixel clock (74.25 MHz for 720p60) and its synchronous active-low reset.
  input  logic       clk,
  input  logic       resetn,

  // Lane input, clk domain, one pixel per clock: de high selects data, de low
  // selects the control character for {ctrl[1], ctrl[0]} = {C1, C0}.
  input  logic       de,
  input  logic [1:0] ctrl,
  input  logic [7:0] data,

  // TMDS character, clk domain, 3 clocks after its input; bit 0 is
  // transmitted first.
  output logic [9:0] symbol
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int DATA_W       = 8;
  localparam int SYM_W        = 10;
  localparam int CNT_W        = 5;                 // signed running disparity, |Cnt| <= 8 (header)
  localparam int ONES_W       = 4;                 // ones count of 8 bits, 0..8
  localparam int HALF_ONES    = DATA_W / 2;        // N1 == N0 when the ones count is 4

  // Control characters q_out[9:0] (DVI 1.0 section 3.3.3), index {C1, C0}.
  localparam logic [SYM_W-1:0] CTRL_SYM_00 = 10'b1101010100;
  localparam logic [SYM_W-1:0] CTRL_SYM_01 = 10'b0010101011;
  localparam logic [SYM_W-1:0] CTRL_SYM_10 = 10'b0101010100;
  localparam logic [SYM_W-1:0] CTRL_SYM_11 = 10'b1010101011;

  // Ones count of an 8-bit word.
  function automatic logic [ONES_W-1:0] ones8(input logic [DATA_W-1:0] v);
    logic [ONES_W-1:0] n;
    n = '0;
    for (int i = 0; i < DATA_W; i++) n = n + ONES_W'(v[i]);
    return n;
  endfunction

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  // Stage 1: registered inputs.
  logic                    de_s1;
  logic [1:0]              ctrl_s1;
  logic [DATA_W-1:0]       data_s1;
  logic [ONES_W-1:0]       n1_data_s1;               // N1{D}

  // Stage 2: transition-minimized word.
  logic [DATA_W:0]         qm_comb;                  // q_m[8:0] from stage 1
  logic                    de_s2;
  logic [1:0]              ctrl_s2;
  logic [DATA_W:0]         qm_s2;
  logic [ONES_W-1:0]       n1_qm_s2;                 // N1{q_m[7:0]}

  // Stage 3: DC balance.
  logic signed [CNT_W-1:0] cnt;                      // running disparity Cnt(t-1)
  logic signed [CNT_W-1:0] cnt_next;
  logic signed [CNT_W-1:0] qm_disp;                  // N1{q_m[7:0]} - N0{q_m[7:0]}
  logic [SYM_W-1:0]        sym_next;

  // ---------------------------------------------------------------------------
  // Stage 1: register the lane inputs and N1{D}.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      de_s1      <= 1'b0;
      ctrl_s1    <= '0;
      data_s1    <= '0;
      n1_data_s1 <= '0;
    end else begin
      de_s1      <= de;
      ctrl_s1    <= ctrl;
      data_s1    <= data;
      n1_data_s1 <= ones8(data);
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2 logic: XNOR chain when N1{D} > 4, or N1{D} == 4 and D[0] == 0;
  // XOR chain otherwise. q_m[8] = 1 marks the XOR chain.
  // ---------------------------------------------------------------------------
  always_comb begin
    logic use_xnor;
    use_xnor   = (n1_data_s1 > ONES_W'(HALF_ONES)) || ((n1_data_s1 == ONES_W'(HALF_ONES)) && !data_s1[0]);
    qm_comb[0] = data_s1[0];
    for (int i = 1; i < DATA_W; i++) begin
      qm_comb[i] = use_xnor ? ~(qm_comb[i-1] ^ data_s1[i]) : (qm_comb[i-1] ^ data_s1[i]);
    end
    qm_comb[DATA_W] = ~use_xnor;
  end

  // Stage 2 register: q_m, its ones count, and the delayed control inputs.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      de_s2    <= 1'b0;
      ctrl_s2  <= '0;
      qm_s2    <= '0;
      n1_qm_s2 <= '0;
    end else begin
      de_s2    <= de_s1;
      ctrl_s2  <= ctrl_s1;
      qm_s2    <= qm_comb;
      n1_qm_s2 <= ones8(qm_comb[DATA_W-1:0]);
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3 logic: the three DC-balance branches of the flow chart, or the
  // control character with Cnt cleared.
  // ---------------------------------------------------------------------------
  // N1 - N0 = 2*N1 - 8, computed modulo 2**CNT_W; exact because it lies in [-8, 8].
  assign qm_disp = signed'(CNT_W'({n1_qm_s2, 1'b0}) - CNT_W'(DATA_W));

  always_comb begin
    sym_next = CTRL_SYM_00;
    cnt_next = '0;
    if (!de_s2) begin
      case (ctrl_s2)
        2'b00:   sym_next = CTRL_SYM_00;
        2'b01:   sym_next = CTRL_SYM_01;
        2'b10:   sym_next = CTRL_SYM_10;
        default: sym_next = CTRL_SYM_11;
      endcase
      cnt_next = '0;
    end else if ((cnt == '0) || (n1_qm_s2 == ONES_W'(HALF_ONES))) begin
      // Balanced word or no disparity to correct: q_out[9] = ~q_m[8], data
      // inverted when q_m[8] = 0.
      sym_next = {~qm_s2[DATA_W], qm_s2[DATA_W], qm_s2[DATA_W] ? qm_s2[DATA_W-1:0] : ~qm_s2[DATA_W-1:0]};
      cnt_next = qm_s2[DATA_W] ? (cnt + qm_disp) : (cnt - qm_disp);
    end else if (((cnt > 0) && (n1_qm_s2 > ONES_W'(HALF_ONES))) ||
                 ((cnt < 0) && (n1_qm_s2 < ONES_W'(HALF_ONES)))) begin
      // Word would grow |Cnt|: invert the data, q_out[9] = 1.
      sym_next = {1'b1, qm_s2[DATA_W], ~qm_s2[DATA_W-1:0]};
      cnt_next = cnt + (qm_s2[DATA_W] ? CNT_W'(2) : CNT_W'(0)) - qm_disp;
    end else begin
      // Word shrinks |Cnt|: send it as is, q_out[9] = 0.
      sym_next = {1'b0, qm_s2[DATA_W], qm_s2[DATA_W-1:0]};
      cnt_next = cnt - (qm_s2[DATA_W] ? CNT_W'(0) : CNT_W'(2)) + qm_disp;
    end
  end

  // Stage 3 register: the TMDS character and the running disparity.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      symbol <= CTRL_SYM_00;
      cnt    <= '0;
    end else begin
      symbol <= sym_next;
      cnt    <= cnt_next;
    end
  end

endmodule
