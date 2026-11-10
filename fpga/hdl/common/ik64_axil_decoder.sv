// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_axil_decoder.sv
// Purpose: route one AXI4-Lite master to N AXI4-Lite slaves by address window.
// Behaviors:
//   * Slave i owns the addresses with (addr & ~(SLAVE_SIZE[i]-1)) == SLAVE_BASE[i]
//     (power-of-two sizes, bases aligned to their size). Lowest index wins if
//     windows overlap.
//   * One transaction in flight; a write is taken before a read. The request is
//     registered; the slave ports are driven from registers. awready/wready (or
//     arready) pulse one clock after the accept, like ik64_axil_slave.
//   * An address that matches no window is answered DECERR (2'b11) without
//     touching any slave; a read returns data 0.
//   * The selected slave sees awvalid and wvalid together, may accept them in
//     separate clocks, then bready; the slave's bresp / rresp / rdata are
//     forwarded unchanged.
//   * Each slave port carries the full ADDR_W address; the slave decodes its
//     own low bits. Packed buses: slave i at [i*W +: W].
//   * Synchronous active-low reset.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: aclk only; aresetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module ik64_axil_decoder #(
  parameter int                  N          = 2,    // slave ports
  parameter int                  ADDR_W     = 32,
  parameter logic [N*ADDR_W-1:0] SLAVE_BASE = '0,   // base of slave i at [i*ADDR_W +: ADDR_W]
  parameter logic [N*ADDR_W-1:0] SLAVE_SIZE = '0    // window size in bytes, power of two
)(
  input  logic                aclk,
  input  logic                aresetn,

  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [31:0]         s_axi_wdata,
  input  logic [3:0]          s_axi_wstrb,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [31:0]         s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  output logic [N*ADDR_W-1:0] m_axi_awaddr,
  output logic [N-1:0]        m_axi_awvalid,
  input  logic [N-1:0]        m_axi_awready,
  output logic [N*32-1:0]     m_axi_wdata,
  output logic [N*4-1:0]      m_axi_wstrb,
  output logic [N-1:0]        m_axi_wvalid,
  input  logic [N-1:0]        m_axi_wready,
  input  logic [N*2-1:0]      m_axi_bresp,
  input  logic [N-1:0]        m_axi_bvalid,
  output logic [N-1:0]        m_axi_bready,
  output logic [N*ADDR_W-1:0] m_axi_araddr,
  output logic [N-1:0]        m_axi_arvalid,
  input  logic [N-1:0]        m_axi_arready,
  input  logic [N*32-1:0]     m_axi_rdata,
  input  logic [N*2-1:0]      m_axi_rresp,
  input  logic [N-1:0]        m_axi_rvalid,
  output logic [N-1:0]        m_axi_rready
);

  localparam int         SEL_W       = (N > 1) ? $clog2(N) : 1;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_W_ISSUE,   // AW and W outstanding at the selected slave
    ST_W_WAIT,    // waiting for the slave's B
    ST_R_ISSUE,   // AR outstanding
    ST_R_WAIT,    // waiting for the slave's R
    ST_B_OUT,     // B to the master
    ST_R_OUT      // R to the master
  } state_t;

  state_t            state;
  logic [SEL_W-1:0]  sel;
  logic              aw_done;
  logic              w_done;
  logic [ADDR_W-1:0] req_addr;
  logic [31:0]       req_wdata;
  logic [3:0]        req_wstrb;

  // Window hit vector of an address.
  function automatic logic [N-1:0] hits(input logic [ADDR_W-1:0] a);
    logic [N-1:0] h;
    for (int i = 0; i < N; i++) begin
      h[i] = ((a & ~(SLAVE_SIZE[i*ADDR_W +: ADDR_W] - 1'b1)) == SLAVE_BASE[i*ADDR_W +: ADDR_W]);
    end
    return h;
  endfunction

  // Lowest set bit as {valid, index}.
  function automatic logic [SEL_W:0] pick(input logic [N-1:0] h);
    logic [SEL_W:0] r;
    r = '0;
    for (int i = N - 1; i >= 0; i--) if (h[i]) r = {1'b1, SEL_W'(i)};
    return r;
  endfunction

  logic [SEL_W:0] aw_sel;
  logic [SEL_W:0] ar_sel;
  assign aw_sel = pick(hits(s_axi_awaddr));
  assign ar_sel = pick(hits(s_axi_araddr));

  // Handshake completions at the selected slave this clock.
  logic aw_fire;
  logic w_fire;
  assign aw_fire = m_axi_awvalid[sel] && m_axi_awready[sel];
  assign w_fire  = m_axi_wvalid[sel]  && m_axi_wready[sel];

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state         <= ST_IDLE;
      sel           <= '0;
      aw_done       <= 1'b0;
      w_done        <= 1'b0;
      req_addr      <= '0;
      req_wdata     <= '0;
      req_wstrb     <= '0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= 2'b00;
      s_axi_rdata   <= '0;
      m_axi_awvalid <= '0;
      m_axi_wvalid  <= '0;
      m_axi_bready  <= '0;
      m_axi_arvalid <= '0;
      m_axi_rready  <= '0;
    end else begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;

      unique case (state)
        ST_IDLE: begin
          if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            req_addr      <= s_axi_awaddr;
            req_wdata     <= s_axi_wdata;
            req_wstrb     <= s_axi_wstrb;
            if (aw_sel[SEL_W]) begin
              sel                             <= aw_sel[SEL_W-1:0];
              m_axi_awvalid[aw_sel[SEL_W-1:0]] <= 1'b1;
              m_axi_wvalid[aw_sel[SEL_W-1:0]]  <= 1'b1;
              aw_done                         <= 1'b0;
              w_done                          <= 1'b0;
              state                           <= ST_W_ISSUE;
            end else begin
              s_axi_bresp  <= RESP_DECERR;
              s_axi_bvalid <= 1'b1;
              state        <= ST_B_OUT;
            end
          end else if (s_axi_arvalid && !s_axi_arready) begin
            s_axi_arready <= 1'b1;
            req_addr      <= s_axi_araddr;
            if (ar_sel[SEL_W]) begin
              sel                             <= ar_sel[SEL_W-1:0];
              m_axi_arvalid[ar_sel[SEL_W-1:0]] <= 1'b1;
              state                           <= ST_R_ISSUE;
            end else begin
              s_axi_rresp  <= RESP_DECERR;
              s_axi_rdata  <= '0;
              s_axi_rvalid <= 1'b1;
              state        <= ST_R_OUT;
            end
          end
        end
        ST_W_ISSUE: begin
          if (aw_fire) begin
            m_axi_awvalid[sel] <= 1'b0;
            aw_done            <= 1'b1;
          end
          if (w_fire) begin
            m_axi_wvalid[sel] <= 1'b0;
            w_done            <= 1'b1;
          end
          if ((aw_done || aw_fire) && (w_done || w_fire)) begin
            m_axi_bready[sel] <= 1'b1;
            state             <= ST_W_WAIT;
          end
        end
        ST_W_WAIT: begin
          if (m_axi_bvalid[sel] && m_axi_bready[sel]) begin
            m_axi_bready[sel] <= 1'b0;
            s_axi_bresp       <= m_axi_bresp[sel*2 +: 2];
            s_axi_bvalid      <= 1'b1;
            state             <= ST_B_OUT;
          end
        end
        ST_R_ISSUE: begin
          if (m_axi_arvalid[sel] && m_axi_arready[sel]) begin
            m_axi_arvalid[sel] <= 1'b0;
            m_axi_rready[sel]  <= 1'b1;
            state              <= ST_R_WAIT;
          end
        end
        ST_R_WAIT: begin
          if (m_axi_rvalid[sel] && m_axi_rready[sel]) begin
            m_axi_rready[sel] <= 1'b0;
            s_axi_rresp       <= m_axi_rresp[sel*2 +: 2];
            s_axi_rdata       <= m_axi_rdata[sel*32 +: 32];
            s_axi_rvalid      <= 1'b1;
            state             <= ST_R_OUT;
          end
        end
        ST_B_OUT: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            state        <= ST_IDLE;
          end
        end
        ST_R_OUT: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            state        <= ST_IDLE;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

  // Every slave port sees the registered request; only the selected slave's
  // valid is ever raised.
  always_comb begin
    for (int i = 0; i < N; i++) begin
      m_axi_awaddr[i*ADDR_W +: ADDR_W] = req_addr;
      m_axi_araddr[i*ADDR_W +: ADDR_W] = req_addr;
      m_axi_wdata[i*32 +: 32]          = req_wdata;
      m_axi_wstrb[i*4 +: 4]            = req_wstrb;
    end
  end

endmodule
