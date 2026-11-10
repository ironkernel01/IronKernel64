// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_axil_cdc.sv
// Purpose: carry AXI4-Lite transactions between two clocks so a register file
//   can live in its own clock domain.
// Behaviors:
//   * Slave side (s_clk): takes one whole transaction (write: address, data,
//     strobe; read: address; a write wins when both are valid) into a held
//     request bundle and flips req_toggle. awready/wready/arready pulse one
//     clock after the accept.
//   * Master side (m_clk): sees the flip through ik64_sync (u_req_sync), issues
//     the transaction on its AXI4-Lite master port (AW and W together, then
//     bready; or AR, then rready), captures the response into a held bundle and
//     flips ack_toggle.
//   * The slave side sees the flip through ik64_sync (u_ack_sync) and answers on
//     B or R with the slave's bresp/rresp and rdata.
//   * The bundles hold still while their toggle crosses. The registers named
//     req_*_hold and rsp_*_hold are the CDC script interface
//     (scripts/ik64_constrain_cdc.tcl: max delay datapath-only of the
//     destination period and a CDC waiver). Do not rename them.
//   * One transaction in flight. Both resets must assert together; a one-sided
//     reset during a transaction is unsupported.
//   * Both resets are synchronous to their own clock, active low.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: s_clk (slave side), m_clk (master side); any ratio.
// -----------------------------------------------------------------------------
module ik64_axil_cdc #(
  parameter int ADDR_W = 12,            // address bits carried
  parameter int STAGES = 3              // toggle synchronizer depth
)(
  input  logic              s_clk,
  input  logic              s_resetn,
  input  logic [ADDR_W-1:0] s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [ADDR_W-1:0] s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,

  input  logic              m_clk,
  input  logic              m_resetn,
  output logic [ADDR_W-1:0] m_axi_awaddr,
  output logic              m_axi_awvalid,
  input  logic              m_axi_awready,
  output logic [31:0]       m_axi_wdata,
  output logic [3:0]        m_axi_wstrb,
  output logic              m_axi_wvalid,
  input  logic              m_axi_wready,
  input  logic [1:0]        m_axi_bresp,
  input  logic              m_axi_bvalid,
  output logic              m_axi_bready,
  output logic [ADDR_W-1:0] m_axi_araddr,
  output logic              m_axi_arvalid,
  input  logic              m_axi_arready,
  input  logic [31:0]       m_axi_rdata,
  input  logic [1:0]        m_axi_rresp,
  input  logic              m_axi_rvalid,
  output logic              m_axi_rready
);

  // ---- slave side (s_clk) ----------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_WAIT_ACK,   // request crossing; waiting for the acknowledge toggle
    S_RESP        // B or R handshake
  } s_state_t;

  s_state_t          s_state;
  logic              req_toggle;
  logic              req_is_write_hold;
  logic [ADDR_W-1:0] req_addr_hold;
  logic [31:0]       req_wdata_hold;
  logic [3:0]        req_wstrb_hold;
  logic              ack_sync;
  logic              ack_seen;

  // ---- master side (m_clk) ---------------------------------------------------
  typedef enum logic [2:0] {
    M_IDLE,
    M_WRITE,      // AW and W outstanding
    M_WRESP,      // waiting for B
    M_RADDR,      // AR outstanding
    M_RRESP       // waiting for R
  } m_state_t;

  m_state_t          m_state;
  logic              req_sync;
  logic              req_seen;
  logic              ack_toggle;
  logic [1:0]        rsp_resp_hold;
  logic [31:0]       rsp_rdata_hold;
  logic              aw_done;
  logic              w_done;

  ik64_sync #(.WIDTH(1), .STAGES(STAGES)) u_req_sync (
    .clk(m_clk), .resetn(m_resetn), .d(req_toggle), .q(req_sync));
  ik64_sync #(.WIDTH(1), .STAGES(STAGES)) u_ack_sync (
    .clk(s_clk), .resetn(s_resetn), .d(ack_toggle), .q(ack_sync));

  assign s_axi_bresp = rsp_resp_hold;
  assign s_axi_rresp = rsp_resp_hold;

  always_ff @(posedge s_clk) begin
    if (!s_resetn) begin
      s_state           <= S_IDLE;
      req_toggle        <= 1'b0;
      req_is_write_hold <= 1'b0;
      req_addr_hold     <= '0;
      req_wdata_hold    <= '0;
      req_wstrb_hold    <= '0;
      ack_seen          <= 1'b0;
      s_axi_awready     <= 1'b0;
      s_axi_wready      <= 1'b0;
      s_axi_arready     <= 1'b0;
      s_axi_bvalid      <= 1'b0;
      s_axi_rvalid      <= 1'b0;
      s_axi_rdata       <= '0;
    end else begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      unique case (s_state)
        S_IDLE: begin
          // The ready pulse of the previous accept must be over before a new
          // request is looked at (the master may still show its valid).
          if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready) begin
            req_is_write_hold <= 1'b1;
            req_addr_hold     <= s_axi_awaddr;
            req_wdata_hold    <= s_axi_wdata;
            req_wstrb_hold    <= s_axi_wstrb;
            s_axi_awready     <= 1'b1;
            s_axi_wready      <= 1'b1;
            req_toggle        <= !req_toggle;
            s_state           <= S_WAIT_ACK;
          end else if (s_axi_arvalid && !s_axi_arready) begin
            req_is_write_hold <= 1'b0;
            req_addr_hold     <= s_axi_araddr;
            s_axi_arready     <= 1'b1;
            req_toggle        <= !req_toggle;
            s_state           <= S_WAIT_ACK;
          end
        end
        S_WAIT_ACK: begin
          if (ack_sync != ack_seen) begin
            ack_seen <= ack_sync;
            if (req_is_write_hold) begin
              s_axi_bvalid <= 1'b1;
            end else begin
              s_axi_rvalid <= 1'b1;
              s_axi_rdata  <= rsp_rdata_hold;
            end
            s_state <= S_RESP;
          end
        end
        S_RESP: begin
          if ((s_axi_bvalid && s_axi_bready) || (s_axi_rvalid && s_axi_rready)) begin
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_state      <= S_IDLE;
          end
        end
        default: s_state <= S_IDLE;
      endcase
    end
  end

  logic aw_fire;
  logic w_fire;
  assign aw_fire = m_axi_awvalid && m_axi_awready;
  assign w_fire  = m_axi_wvalid  && m_axi_wready;

  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      m_state        <= M_IDLE;
      req_seen       <= 1'b0;
      ack_toggle     <= 1'b0;
      rsp_resp_hold  <= 2'b00;
      rsp_rdata_hold <= '0;
      m_axi_awaddr   <= '0;
      m_axi_awvalid  <= 1'b0;
      m_axi_wdata    <= '0;
      m_axi_wstrb    <= '0;
      m_axi_wvalid   <= 1'b0;
      m_axi_bready   <= 1'b0;
      m_axi_araddr   <= '0;
      m_axi_arvalid  <= 1'b0;
      m_axi_rready   <= 1'b0;
      aw_done        <= 1'b0;
      w_done         <= 1'b0;
    end else begin
      unique case (m_state)
        M_IDLE: begin
          if (req_sync != req_seen) begin
            req_seen <= req_sync;
            if (req_is_write_hold) begin
              m_axi_awaddr  <= req_addr_hold;
              m_axi_wdata   <= req_wdata_hold;
              m_axi_wstrb   <= req_wstrb_hold;
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              aw_done       <= 1'b0;
              w_done        <= 1'b0;
              m_state       <= M_WRITE;
            end else begin
              m_axi_araddr  <= req_addr_hold;
              m_axi_arvalid <= 1'b1;
              m_state       <= M_RADDR;
            end
          end
        end
        M_WRITE: begin
          if (aw_fire) begin
            m_axi_awvalid <= 1'b0;
            aw_done       <= 1'b1;
          end
          if (w_fire) begin
            m_axi_wvalid <= 1'b0;
            w_done       <= 1'b1;
          end
          if ((aw_done || aw_fire) && (w_done || w_fire)) begin
            m_axi_bready <= 1'b1;
            m_state      <= M_WRESP;
          end
        end
        M_WRESP: begin
          if (m_axi_bvalid && m_axi_bready) begin
            m_axi_bready  <= 1'b0;
            rsp_resp_hold <= m_axi_bresp;
            ack_toggle    <= !ack_toggle;
            m_state       <= M_IDLE;
          end
        end
        M_RADDR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            m_state       <= M_RRESP;
          end
        end
        M_RRESP: begin
          if (m_axi_rvalid && m_axi_rready) begin
            m_axi_rready   <= 1'b0;
            rsp_resp_hold  <= m_axi_rresp;
            rsp_rdata_hold <= m_axi_rdata;
            ack_toggle     <= !ack_toggle;
            m_state        <= M_IDLE;
          end
        end
        default: m_state <= M_IDLE;
      endcase
    end
  end

endmodule
