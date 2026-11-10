// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_axil_slave.sv
// Purpose: AXI4-Lite slave to register-strobe bridge; a register-file module
//   implements only its registers behind the reg_* port.
// Behaviors:
//   * One transaction at a time; a write is taken before a read when both are
//     pending. Every response is OKAY (bresp = rresp = 2'b00).
//   * Write: AW and W must both be valid in the same clock. awready/wready
//     pulse for one clock one clock later (registered). reg_wr_en pulses for
//     one clock only when wstrb == 4'hF; a partial write is answered OKAY and
//     dropped (all or nothing). bvalid is raised the clock after the accept
//     and held until bready.
//   * Read: arready pulses for one clock one clock later. reg_rd_en pulses for
//     one clock two clocks after the AR accept with reg_rd_addr; the register
//     file presents reg_rd_data on the NEXT clock (registered read mux) and
//     the bridge samples it on the clock after that. rvalid is held until
//     rready.
//   * Reset (synchronous, active low) clears every output and the state.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: s_axi_aclk only; s_axi_aresetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module ik64_axil_slave #(
  parameter int ADDR_W = 12             // byte-address bits decoded by the core
)(
  input  logic              s_axi_aclk,
  input  logic              s_axi_aresetn,
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

  output logic              reg_wr_en,
  output logic [ADDR_W-1:0] reg_wr_addr,
  output logic [31:0]       reg_wr_data,
  output logic              reg_rd_en,
  output logic [ADDR_W-1:0] reg_rd_addr,
  input  logic [31:0]       reg_rd_data
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_W_STROBE,   // write accepted; strobe the register file this clock
    ST_W_RESP,     // hold bvalid until bready
    ST_R_STROBE,   // read accepted; raise reg_rd_en
    ST_R_WAIT,     // register file registers its read mux
    ST_R_SAMPLE,   // reg_rd_data is valid now
    ST_R_RESP      // hold rvalid until rready
  } state_t;

  state_t state;
  logic   wr_full;

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      state         <= ST_IDLE;
      wr_full       <= 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= '0;
      reg_wr_en     <= 1'b0;
      reg_wr_addr   <= '0;
      reg_wr_data   <= '0;
      reg_rd_en     <= 1'b0;
      reg_rd_addr   <= '0;
    end else begin
      // Strobes and readies last one clock unless set below.
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      reg_wr_en     <= 1'b0;
      reg_rd_en     <= 1'b0;

      unique case (state)
        ST_IDLE: begin
          if (s_axi_awvalid && s_axi_wvalid) begin
            reg_wr_addr   <= s_axi_awaddr;
            reg_wr_data   <= s_axi_wdata;
            wr_full       <= &s_axi_wstrb;
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            state         <= ST_W_STROBE;
          end else if (s_axi_arvalid) begin
            reg_rd_addr   <= s_axi_araddr;
            s_axi_arready <= 1'b1;
            state         <= ST_R_STROBE;
          end
        end
        ST_W_STROBE: begin
          reg_wr_en    <= wr_full;
          s_axi_bvalid <= 1'b1;
          state        <= ST_W_RESP;
        end
        ST_W_RESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            state        <= ST_IDLE;
          end
        end
        ST_R_STROBE: begin
          reg_rd_en <= 1'b1;
          state     <= ST_R_WAIT;
        end
        ST_R_WAIT: state <= ST_R_SAMPLE;
        ST_R_SAMPLE: begin
          s_axi_rdata  <= reg_rd_data;
          s_axi_rvalid <= 1'b1;
          state        <= ST_R_RESP;
        end
        ST_R_RESP: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            state        <= ST_IDLE;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
