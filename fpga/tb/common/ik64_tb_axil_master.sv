// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_tb_axil_master.sv
// Purpose: bench AXI4-Lite master with write32 / read32 tasks and a response
//   timeout; stands in for the CPU in register-file benches.
// Behaviors:
//   * write32 drives AW and W together, waits until both were accepted, then
//     takes B. read32 drives AR, waits for the accept, then takes R and returns
//     data and response.
//   * Handshakes are evaluated on the clock edge (values before the edge).
//   * A transaction that does not complete within TIMEOUT clocks is a failed
//     check (ik64_tb_pkg::tb_error) and returns resp 2'b10.
//   * wr / rd check an OKAY response.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: aclk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module ik64_tb_axil_master #(
  parameter int ADDR_W  = 32,
  parameter int TIMEOUT = 20000
)(
  input  logic              aclk,
  output logic [ADDR_W-1:0] awaddr,
  output logic              awvalid,
  input  logic              awready,
  output logic [31:0]       wdata,
  output logic [3:0]        wstrb,
  output logic              wvalid,
  input  logic              wready,
  input  logic [1:0]        bresp,
  input  logic              bvalid,
  output logic              bready,
  output logic [ADDR_W-1:0] araddr,
  output logic              arvalid,
  input  logic              arready,
  input  logic [31:0]       rdata,
  input  logic [1:0]        rresp,
  input  logic              rvalid,
  output logic              rready
);

  import ik64_tb_pkg::*;

  initial begin
    awaddr = '0; awvalid = 1'b0; wdata = '0; wstrb = '0; wvalid = 1'b0; bready = 1'b0;
    araddr = '0; arvalid = 1'b0; rready = 1'b0;
  end

  task automatic write32(input logic [ADDR_W-1:0] addr, input logic [31:0] data,
                         input logic [3:0] strb = 4'hF, output logic [1:0] resp);
    int waited;
    bit aw_taken;
    bit w_taken;
    @(posedge aclk);
    awaddr <= addr; awvalid <= 1'b1;
    wdata  <= data; wstrb   <= strb; wvalid <= 1'b1;
    aw_taken = 1'b0; w_taken = 1'b0; waited = 0;
    while (!(aw_taken && w_taken) && waited < TIMEOUT) begin
      @(posedge aclk);
      if (awvalid && awready) begin aw_taken = 1'b1; awvalid <= 1'b0; end
      if (wvalid  && wready)  begin w_taken  = 1'b1; wvalid  <= 1'b0; end
      waited++;
    end
    bready <= 1'b1;
    waited = 0;
    @(posedge aclk);
    while (!bvalid && waited < TIMEOUT) begin
      @(posedge aclk);
      waited++;
    end
    resp = bvalid ? bresp : 2'b10;
    if (!bvalid) tb_error($sformatf("AXI write 0x%08x timed out", addr));
    bready  <= 1'b0;
    awvalid <= 1'b0;
    wvalid  <= 1'b0;
  endtask

  task automatic read32(input logic [ADDR_W-1:0] addr, output logic [31:0] data, output logic [1:0] resp);
    int waited;
    @(posedge aclk);
    araddr <= addr; arvalid <= 1'b1;
    waited = 0;
    @(posedge aclk);
    while (!arready && waited < TIMEOUT) begin
      @(posedge aclk);
      waited++;
    end
    arvalid <= 1'b0;
    rready  <= 1'b1;
    waited = 0;
    @(posedge aclk);
    while (!rvalid && waited < TIMEOUT) begin
      @(posedge aclk);
      waited++;
    end
    data = rdata;
    resp = rvalid ? rresp : 2'b10;
    if (!rvalid) tb_error($sformatf("AXI read 0x%08x timed out", addr));
    rready <= 1'b0;
  endtask

  task automatic wr(input logic [ADDR_W-1:0] addr, input logic [31:0] data);
    logic [1:0] r;
    write32(addr, data, 4'hF, r);
    tb_check(r == 2'b00, $sformatf("AXI write 0x%08x response %0d", addr, r));
  endtask

  task automatic rd(input logic [ADDR_W-1:0] addr, output logic [31:0] data);
    logic [1:0] r;
    read32(addr, data, r);
    tb_check(r == 2'b00, $sformatf("AXI read 0x%08x response %0d", addr, r));
  endtask

endmodule
