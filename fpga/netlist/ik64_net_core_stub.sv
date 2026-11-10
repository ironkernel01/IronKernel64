// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2026.1 (win64) Build 6511674 Tue Jun 16 11:02:23 MDT 2026
// Date        : Tue Nov 10 01:45:11 2026
// Host        : PLUTO9 running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               C:/IronKernel/Commodore64/ironkernel/build/netcore/ik64_net_core_stub.sv
// Design      : ik64_net_core
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tsbg484-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* CPU_CLK_HZ = "100000000" *) (* CPU_RX_FIFO_KB = "16" *) (* CPU_TX_FIFO_KB = "8" *) 
(* EGRESS_FIFO_KB = "8" *) (* INGRESS_FIFO_KB = "16" *) (* MAC_FIFO_KB = "8" *) 
(* MAC_FRAME_BYTES = "1518" *) (* MAC_RX_IDELAY = "12" *) (* POR_RESET_MS = "20" *) 
(* PROTO_CLK_HZ = "50000000" *) 
module ik64_net_core(axis_clk, axis_resetn, clk125, clk125_90, 
  clk125_resetn, clk200, clk200_resetn, cpu_clk, cpu_eth_rx_tlast, cpu_eth_rx_tready, 
  cpu_eth_rx_tvalid, cpu_eth_tx_tlast, cpu_eth_tx_tready, cpu_eth_tx_tvalid, 
  cpu_resetn_sync, eth_int_b, eth_mdc, eth_rst_b, eth_rxck, eth_rxctl, eth_txck, eth_txctl, 
  mac_stat_link_up, mac_stat_rx_clk_ok, mdio_i, mdio_irq, mdio_o, mdio_t, prot_stat_dhcp_bound, 
  prot_stat_ip_valid, s_axi_mac_arready, s_axi_mac_arvalid, s_axi_mac_awready, 
  s_axi_mac_awvalid, s_axi_mac_bready, s_axi_mac_bvalid, s_axi_mac_rready, 
  s_axi_mac_rvalid, s_axi_mac_wready, s_axi_mac_wvalid, s_axi_mdio_arready, 
  s_axi_mdio_arvalid, s_axi_mdio_awready, s_axi_mdio_awvalid, s_axi_mdio_bready, 
  s_axi_mdio_bvalid, s_axi_mdio_rready, s_axi_mdio_rvalid, s_axi_mdio_wready, 
  s_axi_mdio_wvalid, s_axi_prot_arready, s_axi_prot_arvalid, s_axi_prot_awready, 
  s_axi_prot_awvalid, s_axi_prot_bready, s_axi_prot_bvalid, s_axi_prot_rready, 
  s_axi_prot_rvalid, s_axi_prot_wready, s_axi_prot_wvalid, sid_clk, sid_resetn, 
  cpu_eth_rx_tdata, cpu_eth_rx_tkeep, cpu_eth_tx_tdata, cpu_eth_tx_tkeep, eth_rxd, eth_txd, 
  mac_stat_speed, s_axi_mac_araddr, s_axi_mac_awaddr, s_axi_mac_bresp, s_axi_mac_rdata, 
  s_axi_mac_rresp, s_axi_mac_wdata, s_axi_mac_wstrb, s_axi_mdio_araddr, s_axi_mdio_awaddr, 
  s_axi_mdio_bresp, s_axi_mdio_rdata, s_axi_mdio_rresp, s_axi_mdio_wdata, s_axi_mdio_wstrb, 
  s_axi_prot_araddr, s_axi_prot_awaddr, s_axi_prot_bresp, s_axi_prot_rdata, 
  s_axi_prot_rresp, s_axi_prot_wdata, s_axi_prot_wstrb)
/* synthesis syn_black_box black_box_pad_pin="axis_resetn,clk125_resetn,clk200_resetn,cpu_eth_rx_tlast,cpu_eth_rx_tready,cpu_eth_rx_tvalid,cpu_eth_tx_tlast,cpu_eth_tx_tready,cpu_eth_tx_tvalid,cpu_resetn_sync,eth_int_b,eth_mdc,eth_rst_b,eth_rxck,eth_rxctl,eth_txck,eth_txctl,mac_stat_link_up,mac_stat_rx_clk_ok,mdio_i,mdio_irq,mdio_o,mdio_t,prot_stat_dhcp_bound,prot_stat_ip_valid,s_axi_mac_arready,s_axi_mac_arvalid,s_axi_mac_awready,s_axi_mac_awvalid,s_axi_mac_bready,s_axi_mac_bvalid,s_axi_mac_rready,s_axi_mac_rvalid,s_axi_mac_wready,s_axi_mac_wvalid,s_axi_mdio_arready,s_axi_mdio_arvalid,s_axi_mdio_awready,s_axi_mdio_awvalid,s_axi_mdio_bready,s_axi_mdio_bvalid,s_axi_mdio_rready,s_axi_mdio_rvalid,s_axi_mdio_wready,s_axi_mdio_wvalid,s_axi_prot_arready,s_axi_prot_arvalid,s_axi_prot_awready,s_axi_prot_awvalid,s_axi_prot_bready,s_axi_prot_bvalid,s_axi_prot_rready,s_axi_prot_rvalid,s_axi_prot_wready,s_axi_prot_wvalid,sid_resetn,cpu_eth_rx_tdata[63:0],cpu_eth_rx_tkeep[7:0],cpu_eth_tx_tdata[63:0],cpu_eth_tx_tkeep[7:0],eth_rxd[3:0],eth_txd[3:0],mac_stat_speed[1:0],s_axi_mac_araddr[11:0],s_axi_mac_awaddr[11:0],s_axi_mac_bresp[1:0],s_axi_mac_rdata[31:0],s_axi_mac_rresp[1:0],s_axi_mac_wdata[31:0],s_axi_mac_wstrb[3:0],s_axi_mdio_araddr[11:0],s_axi_mdio_awaddr[11:0],s_axi_mdio_bresp[1:0],s_axi_mdio_rdata[31:0],s_axi_mdio_rresp[1:0],s_axi_mdio_wdata[31:0],s_axi_mdio_wstrb[3:0],s_axi_prot_araddr[15:0],s_axi_prot_awaddr[15:0],s_axi_prot_bresp[1:0],s_axi_prot_rdata[31:0],s_axi_prot_rresp[1:0],s_axi_prot_wdata[31:0],s_axi_prot_wstrb[3:0]" */
/* synthesis syn_force_seq_prim="axis_clk" */
/* synthesis syn_force_seq_prim="clk125" */
/* synthesis syn_force_seq_prim="clk125_90" */
/* synthesis syn_force_seq_prim="clk200" */
/* synthesis syn_force_seq_prim="cpu_clk" */
/* synthesis syn_force_seq_prim="sid_clk" */;
  input axis_clk /* synthesis syn_isclock = 1 */;
  input axis_resetn;
  input clk125 /* synthesis syn_isclock = 1 */;
  input clk125_90 /* synthesis syn_isclock = 1 */;
  input clk125_resetn;
  input clk200 /* synthesis syn_isclock = 1 */;
  input clk200_resetn;
  input cpu_clk /* synthesis syn_isclock = 1 */;
  output cpu_eth_rx_tlast;
  input cpu_eth_rx_tready;
  output cpu_eth_rx_tvalid;
  input cpu_eth_tx_tlast;
  output cpu_eth_tx_tready;
  input cpu_eth_tx_tvalid;
  input cpu_resetn_sync;
  input eth_int_b;
  output eth_mdc;
  output eth_rst_b;
  input eth_rxck;
  input eth_rxctl;
  output eth_txck;
  output eth_txctl;
  output mac_stat_link_up;
  output mac_stat_rx_clk_ok;
  input mdio_i;
  output mdio_irq;
  output mdio_o;
  output mdio_t;
  output prot_stat_dhcp_bound;
  output prot_stat_ip_valid;
  output s_axi_mac_arready;
  input s_axi_mac_arvalid;
  output s_axi_mac_awready;
  input s_axi_mac_awvalid;
  input s_axi_mac_bready;
  output s_axi_mac_bvalid;
  input s_axi_mac_rready;
  output s_axi_mac_rvalid;
  output s_axi_mac_wready;
  input s_axi_mac_wvalid;
  output s_axi_mdio_arready;
  input s_axi_mdio_arvalid;
  output s_axi_mdio_awready;
  input s_axi_mdio_awvalid;
  input s_axi_mdio_bready;
  output s_axi_mdio_bvalid;
  input s_axi_mdio_rready;
  output s_axi_mdio_rvalid;
  output s_axi_mdio_wready;
  input s_axi_mdio_wvalid;
  output s_axi_prot_arready;
  input s_axi_prot_arvalid;
  output s_axi_prot_awready;
  input s_axi_prot_awvalid;
  input s_axi_prot_bready;
  output s_axi_prot_bvalid;
  input s_axi_prot_rready;
  output s_axi_prot_rvalid;
  output s_axi_prot_wready;
  input s_axi_prot_wvalid;
  input sid_clk /* synthesis syn_isclock = 1 */;
  input sid_resetn;
  output [63:0]cpu_eth_rx_tdata;
  output [7:0]cpu_eth_rx_tkeep;
  input [63:0]cpu_eth_tx_tdata;
  input [7:0]cpu_eth_tx_tkeep;
  input [3:0]eth_rxd;
  output [3:0]eth_txd;
  output [1:0]mac_stat_speed;
  input [11:0]s_axi_mac_araddr;
  input [11:0]s_axi_mac_awaddr;
  output [1:0]s_axi_mac_bresp;
  output [31:0]s_axi_mac_rdata;
  output [1:0]s_axi_mac_rresp;
  input [31:0]s_axi_mac_wdata;
  input [3:0]s_axi_mac_wstrb;
  input [11:0]s_axi_mdio_araddr;
  input [11:0]s_axi_mdio_awaddr;
  output [1:0]s_axi_mdio_bresp;
  output [31:0]s_axi_mdio_rdata;
  output [1:0]s_axi_mdio_rresp;
  input [31:0]s_axi_mdio_wdata;
  input [3:0]s_axi_mdio_wstrb;
  input [15:0]s_axi_prot_araddr;
  input [15:0]s_axi_prot_awaddr;
  output [1:0]s_axi_prot_bresp;
  output [31:0]s_axi_prot_rdata;
  output [1:0]s_axi_prot_rresp;
  input [31:0]s_axi_prot_wdata;
  input [3:0]s_axi_prot_wstrb;
endmodule
