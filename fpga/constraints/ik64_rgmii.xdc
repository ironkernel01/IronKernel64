# -----------------------------------------------------------------------------
# File: ik64_rgmii.xdc
# Purpose: top-level RGMII interface timing of IronKernel 64 for the network core netlist
#   (fpga/netlist/ik64_net_core.dcp) against the Realtek RTL8211E on the Nexys Video. DRAFT:
#   not read by fpga/build_bitstream.tcl yet; the integration phase wires it in after
#   fpga/c64.xdc.
# Overview:
#   * The netlist carries its own constraints inside the checkpoint: the IODELAY group of the
#     receive IDELAYE2 cells and the IDELAYCTRL (ik64_rgmii), the forwarded transmit clock
#     rgmii_txc (generated clock on the TXC ODDR output) and every clock-domain crossing of the
#     core. This file holds what only the top can name: the pins.
#   * Receive: rgmii_rxc is 8 ns on eth_rxck (1000 Mb/s, the tightest case; the core's BUFIO and
#     BUFR clocks derive from it), with the virtual launch clock rgmii_rxc_v. The PHY RX delay is
#     on (the firmware sets it through MDIO, RTL8211E extension page 0xA4 register 28), so
#     RXD/RX_CTL are centred on RXC: RTL8211E datasheet Rev. 1.6 Table 65, setup and hold at
#     least 1.2 ns. Same-edge capture (IDDR SAME_EDGE_PIPELINED): multicycle 0 / -1 and false
#     paths for the edge pairs that describe no capture.
#   * Transmit: rgmii_txc (from the netlist) leaves 90 degrees after the data edges (2 ns); PHY
#     TX delay is off, receiver setup and hold 1.0 ns, so output delays are +1.0 / -1.0 ns on
#     both edges.
#   * Slew FAST on the transmit pins (2.5 V bank 13, LVCMOS25; the IOSTANDARD and pin
#     assignments are in fpga/c64.xdc).
#   * The top must not buffer eth_rxck, eth_rxd and eth_rxctl a second time: the core holds their
#     IBUFs (IO_BUFFER_TYPE none on those ports, set in c64_top.sv).
#   * eth_mdc, eth_mdio, eth_rst_b and eth_int_b are slow side-band signals, declared false
#     paths in fpga/c64.xdc.
# Source of the numbers: RTL8211E datasheet Rev. 1.6 (Table 65), Nexys Video reference manual
#   (Ethernet PHY), RTLNet's RGMII constraint file for the same board (same values, port names
#   adapted).
# Language: XDC (Vivado 2026.1).
# Revision: 11-09-2026
#   * 11-09-2026: initial draft.
# -----------------------------------------------------------------------------

set_property SLEW FAST [get_ports {eth_txck eth_txctl eth_txd[*]}]

# ---- Receive clock and the PHY's launch clock ---------------------------------------
create_clock -name rgmii_rxc -period 8.000 [get_ports eth_rxck]
create_clock -name rgmii_rxc_v -period 8.000

# ---- Input delays (PHY RX delay on, TsetupT/TholdT >= 1.2 ns) --------------------------
set_input_delay -clock rgmii_rxc_v -max -1.200 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -min -2.800 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -max -1.200 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -min -2.800 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]

# ---- Same-edge capture -------------------------------------------------------------------
set_multicycle_path -setup 0  -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
set_multicycle_path -hold  -1 -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
set_false_path -setup -rise_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]
set_false_path -setup -fall_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -rise_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -fall_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]

# ---- Output delays (PHY TX delay off, receiver setup/hold 1.0 ns) ---------------------------
# rgmii_txc is created inside the netlist on the TXC ODDR output.
set_output_delay -clock rgmii_txc -max  1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -min -1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -max  1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -min -1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]
