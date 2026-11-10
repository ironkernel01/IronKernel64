// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_ddr.sv
// Purpose: the IronKernel 64 DDR3 core: an AXI4 slave port in front of the AMD
//   7-series MIG controller IP ik64_ddr_mig (fpga/ip/ik64_ddr_mig.tcl) for the
//   Nexys Video MT41K256M16 DDR3 (512 MiB).
// Behaviors:
//   * One instance of ik64_ddr_mig, "No Buffer" clocking: sys_clk (100 MHz) and
//     ref_clk (200 MHz) arrive already buffered; the MIG builds its PLL/MMCM
//     from sys_clk and returns ui_clk (100 MHz).
//   * ui_resetn is the MIG ui reset (ui_clk_sync_rst, high while the MIG clock
//     tree is unlocked or sys_rstn is low) inverted. s_axi_aresetn is the reset
//     the MIG AXI slave runs with, driven by the board top (it combines
//     ui_resetn with the board reset tree).
//   * AXI4 slave on ui_clk: INCR and WRAP bursts, narrow beats, 128-bit data,
//     29-bit byte address, 2-bit ID. The MIG accepts nothing until calibration
//     completes (init_calib_complete).
//   * Unused MIG services are tied inactive: self refresh, user refresh, ZQ.
//   * IK64_DDR_SIM defined (benches): the MIG is replaced by ik64_ddr_sim
//     (fpga/tb/ddr), an AXI4 memory model with a calibration delay and no DDR3
//     pins; never synthesized.
//   * Same port contract as rtlnet_ddr (the instance name changes only).
//   * Hierarchy of the MIG instance: <inst>/u_mig/u_ik64_ddr_mig_mig/... (the
//     build's reset-gate and waiver patterns name it).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version (prepared, not yet wired into c64_top).
// Clocks: sys_clk, ref_clk (controller inputs); ui_clk (every AXI4 port and the
//   status outputs).
// -----------------------------------------------------------------------------
module ik64_ddr #(
  parameter int ADDR_W = 29,               // 512 MiB
  parameter int DATA_W = 128,
  parameter int ID_W   = 2
)(
  input  logic                sys_clk,
  input  logic                ref_clk,
  input  logic                sys_rstn,

  output logic                ui_clk,
  output logic                ui_resetn,
  input  logic                s_axi_aresetn,
  output logic                init_calib_complete,

  input  logic [ID_W-1:0]     s_axi_awid,
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]          s_axi_awlen,
  input  logic [2:0]          s_axi_awsize,
  input  logic [1:0]          s_axi_awburst,
  input  logic                s_axi_awlock,
  input  logic [3:0]          s_axi_awcache,
  input  logic [2:0]          s_axi_awprot,
  input  logic [3:0]          s_axi_awqos,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wlast,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [ID_W-1:0]     s_axi_bid,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ID_W-1:0]     s_axi_arid,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]          s_axi_arlen,
  input  logic [2:0]          s_axi_arsize,
  input  logic [1:0]          s_axi_arburst,
  input  logic                s_axi_arlock,
  input  logic [3:0]          s_axi_arcache,
  input  logic [2:0]          s_axi_arprot,
  input  logic [3:0]          s_axi_arqos,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [ID_W-1:0]     s_axi_rid,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rlast,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  // DDR3 SDRAM pins (MT41K256M16, 16 bit, one rank).
  inout  wire  [15:0]         ddr3_dq,
  inout  wire  [1:0]          ddr3_dqs_n,
  inout  wire  [1:0]          ddr3_dqs_p,
  output logic [14:0]         ddr3_addr,
  output logic [2:0]          ddr3_ba,
  output logic                ddr3_ras_n,
  output logic                ddr3_cas_n,
  output logic                ddr3_we_n,
  output logic                ddr3_reset_n,
  output logic [0:0]          ddr3_ck_p,
  output logic [0:0]          ddr3_ck_n,
  output logic [0:0]          ddr3_cke,
  output logic [1:0]          ddr3_dm,
  output logic [0:0]          ddr3_odt
);

  if (ADDR_W != 29 || DATA_W != 128 || ID_W != 2) begin : g_bad_cfg
    $fatal(1, "ik64_ddr: ADDR_W=%0d DATA_W=%0d ID_W=%0d, the MIG project is 29/128/2", ADDR_W, DATA_W, ID_W);
  end

`ifdef IK64_DDR_SIM
  ik64_ddr_sim #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_mig (.*);
`else
  logic ui_rst;

  assign ui_resetn = ~ui_rst;

  ik64_ddr_mig u_mig (
    .ddr3_addr           (ddr3_addr),
    .ddr3_ba             (ddr3_ba),
    .ddr3_cas_n          (ddr3_cas_n),
    .ddr3_ck_n           (ddr3_ck_n),
    .ddr3_ck_p           (ddr3_ck_p),
    .ddr3_cke            (ddr3_cke),
    .ddr3_ras_n          (ddr3_ras_n),
    .ddr3_reset_n        (ddr3_reset_n),
    .ddr3_we_n           (ddr3_we_n),
    .ddr3_dq             (ddr3_dq),
    .ddr3_dqs_n          (ddr3_dqs_n),
    .ddr3_dqs_p          (ddr3_dqs_p),
    .init_calib_complete (init_calib_complete),
    .ddr3_dm             (ddr3_dm),
    .ddr3_odt            (ddr3_odt),
    .ui_clk              (ui_clk),
    .ui_clk_sync_rst     (ui_rst),
    .ui_addn_clk_0       (),
    .ui_addn_clk_1       (),
    .ui_addn_clk_2       (),
    .ui_addn_clk_3       (),
    .ui_addn_clk_4       (),
    .mmcm_locked         (),
    .aresetn             (s_axi_aresetn),
    .app_sr_req          (1'b0),
    .app_ref_req         (1'b0),
    .app_zq_req          (1'b0),
    .app_sr_active       (),
    .app_ref_ack         (),
    .app_zq_ack          (),
    .s_axi_awid          (s_axi_awid),
    .s_axi_awaddr        (s_axi_awaddr),
    .s_axi_awlen         (s_axi_awlen),
    .s_axi_awsize        (s_axi_awsize),
    .s_axi_awburst       (s_axi_awburst),
    .s_axi_awlock        (s_axi_awlock),
    .s_axi_awcache       (s_axi_awcache),
    .s_axi_awprot        (s_axi_awprot),
    .s_axi_awqos         (s_axi_awqos),
    .s_axi_awvalid       (s_axi_awvalid),
    .s_axi_awready       (s_axi_awready),
    .s_axi_wdata         (s_axi_wdata),
    .s_axi_wstrb         (s_axi_wstrb),
    .s_axi_wlast         (s_axi_wlast),
    .s_axi_wvalid        (s_axi_wvalid),
    .s_axi_wready        (s_axi_wready),
    .s_axi_bid           (s_axi_bid),
    .s_axi_bresp         (s_axi_bresp),
    .s_axi_bvalid        (s_axi_bvalid),
    .s_axi_bready        (s_axi_bready),
    .s_axi_arid          (s_axi_arid),
    .s_axi_araddr        (s_axi_araddr),
    .s_axi_arlen         (s_axi_arlen),
    .s_axi_arsize        (s_axi_arsize),
    .s_axi_arburst       (s_axi_arburst),
    .s_axi_arlock        (s_axi_arlock),
    .s_axi_arcache       (s_axi_arcache),
    .s_axi_arprot        (s_axi_arprot),
    .s_axi_arqos         (s_axi_arqos),
    .s_axi_arvalid       (s_axi_arvalid),
    .s_axi_arready       (s_axi_arready),
    .s_axi_rid           (s_axi_rid),
    .s_axi_rdata         (s_axi_rdata),
    .s_axi_rresp         (s_axi_rresp),
    .s_axi_rlast         (s_axi_rlast),
    .s_axi_rvalid        (s_axi_rvalid),
    .s_axi_rready        (s_axi_rready),
    .device_temp         (),
    .sys_clk_i           (sys_clk),
    .clk_ref_i           (ref_clk),
    .sys_rst             (sys_rstn)
  );
`endif

endmodule
