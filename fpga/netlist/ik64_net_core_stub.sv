// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2026.1 (win64) Build 6511674 Tue Jun 16 11:02:23 MDT 2026
// Date        : Mon Nov  9 23:48:48 2026
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
module ik64_net_core(clk125, clk125_90, clk200, axis_clk, cpu_clk, 
  sid_clk, clk125_resetn, clk200_resetn, axis_resetn, cpu_resetn_sync, sid_resetn, eth_rxck, 
  eth_rxctl, eth_rxd, eth_txck, eth_txctl, eth_txd, eth_mdc, mdio_o, mdio_t, mdio_i, eth_rst_b, 
  eth_int_b, s_axi_mac_awaddr, s_axi_mac_awvalid, s_axi_mac_awready, s_axi_mac_wdata, 
  s_axi_mac_wstrb, s_axi_mac_wvalid, s_axi_mac_wready, s_axi_mac_bresp, s_axi_mac_bvalid, 
  s_axi_mac_bready, s_axi_mac_araddr, s_axi_mac_arvalid, s_axi_mac_arready, 
  s_axi_mac_rdata, s_axi_mac_rresp, s_axi_mac_rvalid, s_axi_mac_rready, s_axi_mdio_awaddr, 
  s_axi_mdio_awvalid, s_axi_mdio_awready, s_axi_mdio_wdata, s_axi_mdio_wstrb, 
  s_axi_mdio_wvalid, s_axi_mdio_wready, s_axi_mdio_bresp, s_axi_mdio_bvalid, 
  s_axi_mdio_bready, s_axi_mdio_araddr, s_axi_mdio_arvalid, s_axi_mdio_arready, 
  s_axi_mdio_rdata, s_axi_mdio_rresp, s_axi_mdio_rvalid, s_axi_mdio_rready, 
  s_axi_prot_awaddr, s_axi_prot_awvalid, s_axi_prot_awready, s_axi_prot_wdata, 
  s_axi_prot_wstrb, s_axi_prot_wvalid, s_axi_prot_wready, s_axi_prot_bresp, 
  s_axi_prot_bvalid, s_axi_prot_bready, s_axi_prot_araddr, s_axi_prot_arvalid, 
  s_axi_prot_arready, s_axi_prot_rdata, s_axi_prot_rresp, s_axi_prot_rvalid, 
  s_axi_prot_rready, cpu_eth_rx_tdata, cpu_eth_rx_tkeep, cpu_eth_rx_tvalid, 
  cpu_eth_rx_tlast, cpu_eth_rx_tready, cpu_eth_tx_tdata, cpu_eth_tx_tkeep, 
  cpu_eth_tx_tvalid, cpu_eth_tx_tlast, cpu_eth_tx_tready, mdio_irq, mac_stat_link_up, 
  mac_stat_speed, mac_stat_rx_clk_ok, prot_stat_ip_valid, prot_stat_dhcp_bound)
/* synthesis syn_black_box black_box_pad_pin="clk125_resetn,clk200_resetn,axis_resetn,cpu_resetn_sync,sid_resetn,eth_rxck,eth_rxctl,eth_rxd[3:0],eth_txck,eth_txctl,eth_txd[3:0],eth_mdc,mdio_o,mdio_t,mdio_i,eth_rst_b,eth_int_b,s_axi_mac_awaddr[11:0],s_axi_mac_awvalid,s_axi_mac_awready,s_axi_mac_wdata[31:0],s_axi_mac_wstrb[3:0],s_axi_mac_wvalid,s_axi_mac_wready,s_axi_mac_bresp[1:0],s_axi_mac_bvalid,s_axi_mac_bready,s_axi_mac_araddr[11:0],s_axi_mac_arvalid,s_axi_mac_arready,s_axi_mac_rdata[31:0],s_axi_mac_rresp[1:0],s_axi_mac_rvalid,s_axi_mac_rready,s_axi_mdio_awaddr[11:0],s_axi_mdio_awvalid,s_axi_mdio_awready,s_axi_mdio_wdata[31:0],s_axi_mdio_wstrb[3:0],s_axi_mdio_wvalid,s_axi_mdio_wready,s_axi_mdio_bresp[1:0],s_axi_mdio_bvalid,s_axi_mdio_bready,s_axi_mdio_araddr[11:0],s_axi_mdio_arvalid,s_axi_mdio_arready,s_axi_mdio_rdata[31:0],s_axi_mdio_rresp[1:0],s_axi_mdio_rvalid,s_axi_mdio_rready,s_axi_prot_awaddr[15:0],s_axi_prot_awvalid,s_axi_prot_awready,s_axi_prot_wdata[31:0],s_axi_prot_wstrb[3:0],s_axi_prot_wvalid,s_axi_prot_wready,s_axi_prot_bresp[1:0],s_axi_prot_bvalid,s_axi_prot_bready,s_axi_prot_araddr[15:0],s_axi_prot_arvalid,s_axi_prot_arready,s_axi_prot_rdata[31:0],s_axi_prot_rresp[1:0],s_axi_prot_rvalid,s_axi_prot_rready,cpu_eth_rx_tdata[63:0],cpu_eth_rx_tkeep[7:0],cpu_eth_rx_tvalid,cpu_eth_rx_tlast,cpu_eth_rx_tready,cpu_eth_tx_tdata[63:0],cpu_eth_tx_tkeep[7:0],cpu_eth_tx_tvalid,cpu_eth_tx_tlast,cpu_eth_tx_tready,mdio_irq,mac_stat_link_up,mac_stat_speed[1:0],mac_stat_rx_clk_ok,prot_stat_ip_valid,prot_stat_dhcp_bound" */
/* synthesis syn_force_seq_prim="clk125" */
/* synthesis syn_force_seq_prim="clk125_90" */
/* synthesis syn_force_seq_prim="clk200" */
/* synthesis syn_force_seq_prim="axis_clk" */
/* synthesis syn_force_seq_prim="cpu_clk" */
/* synthesis syn_force_seq_prim="sid_clk" */;
  input clk125 /* synthesis syn_isclock = 1 */;
  input clk125_90 /* synthesis syn_isclock = 1 */;
  input clk200 /* synthesis syn_isclock = 1 */;
  input axis_clk /* synthesis syn_isclock = 1 */;
  input cpu_clk /* synthesis syn_isclock = 1 */;
  input sid_clk /* synthesis syn_isclock = 1 */;
  input clk125_resetn;
  input clk200_resetn;
  input axis_resetn;
  input cpu_resetn_sync;
  input sid_resetn;
  input eth_rxck;
  input eth_rxctl;
  input [3:0]eth_rxd;
  output eth_txck;
  output eth_txctl;
  output [3:0]eth_txd;
  output eth_mdc;
  output mdio_o;
  output mdio_t;
  input mdio_i;
  output eth_rst_b;
  input eth_int_b;
  input [11:0]s_axi_mac_awaddr;
  input s_axi_mac_awvalid;
  output s_axi_mac_awready;
  input [31:0]s_axi_mac_wdata;
  input [3:0]s_axi_mac_wstrb;
  input s_axi_mac_wvalid;
  output s_axi_mac_wready;
  output [1:0]s_axi_mac_bresp;
  output s_axi_mac_bvalid;
  input s_axi_mac_bready;
  input [11:0]s_axi_mac_araddr;
  input s_axi_mac_arvalid;
  output s_axi_mac_arready;
  output [31:0]s_axi_mac_rdata;
  output [1:0]s_axi_mac_rresp;
  output s_axi_mac_rvalid;
  input s_axi_mac_rready;
  input [11:0]s_axi_mdio_awaddr;
  input s_axi_mdio_awvalid;
  output s_axi_mdio_awready;
  input [31:0]s_axi_mdio_wdata;
  input [3:0]s_axi_mdio_wstrb;
  input s_axi_mdio_wvalid;
  output s_axi_mdio_wready;
  output [1:0]s_axi_mdio_bresp;
  output s_axi_mdio_bvalid;
  input s_axi_mdio_bready;
  input [11:0]s_axi_mdio_araddr;
  input s_axi_mdio_arvalid;
  output s_axi_mdio_arready;
  output [31:0]s_axi_mdio_rdata;
  output [1:0]s_axi_mdio_rresp;
  output s_axi_mdio_rvalid;
  input s_axi_mdio_rready;
  input [15:0]s_axi_prot_awaddr;
  input s_axi_prot_awvalid;
  output s_axi_prot_awready;
  input [31:0]s_axi_prot_wdata;
  input [3:0]s_axi_prot_wstrb;
  input s_axi_prot_wvalid;
  output s_axi_prot_wready;
  output [1:0]s_axi_prot_bresp;
  output s_axi_prot_bvalid;
  input s_axi_prot_bready;
  input [15:0]s_axi_prot_araddr;
  input s_axi_prot_arvalid;
  output s_axi_prot_arready;
  output [31:0]s_axi_prot_rdata;
  output [1:0]s_axi_prot_rresp;
  output s_axi_prot_rvalid;
  input s_axi_prot_rready;
  output [63:0]cpu_eth_rx_tdata;
  output [7:0]cpu_eth_rx_tkeep;
  output cpu_eth_rx_tvalid;
  output cpu_eth_rx_tlast;
  input cpu_eth_rx_tready;
  input [63:0]cpu_eth_tx_tdata;
  input [7:0]cpu_eth_tx_tkeep;
  input cpu_eth_tx_tvalid;
  input cpu_eth_tx_tlast;
  output cpu_eth_tx_tready;
  output mdio_irq;
  output mac_stat_link_up;
  output [1:0]mac_stat_speed;
  output mac_stat_rx_clk_ok;
  output prot_stat_ip_valid;
  output prot_stat_dhcp_bound;
endmodule
