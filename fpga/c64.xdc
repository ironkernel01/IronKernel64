# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
# -----------------------------------------------------------------------------
# File: c64.xdc
# Purpose: pin, I/O standard, primary clock and configuration constraints of
#   the IronKernel 64 board top (c64_top) on the Digilent Nexys Video.
# Overview:
#   * Balls and I/O standards from the Digilent Nexys-Video-Master.xdc (Rev. A);
#     port names keep the master-XDC names.
#   * Derived from RTLNet boards/nexys_video/constraints/rtlnet_nexys_video.xdc
#     (commit ea70c8558ec4ef1133d1e9adde1b278e106302e0); the DDR3 block is copied
#     unchanged.
#   * One primary clock: sysclk 100 MHz on R4. Every MMCM output (cpu_clk,
#     clk200, ddr_sys_clk, pix_clk, pix_clk_x5, aud_clk) and the DDR3
#     controller's clocks are derived clocks Vivado creates from it; no clock
#     groups are declared. Clock-domain crossings are bounded cell by cell by
#     third_party/rtlnet/scripts/rtlnet_constrain_cdc.tcl, sourced by
#     fpga/build_bitstream.tcl after synthesis.
#   * Asynchronous board pins have no timing relationship to any internal
#     clock and are false paths (list and reasons at the end).
#   * HDMI TMDS pairs leave OSERDESE2 serializers directly; the sink recovers
#     the clock from the clock lane, so no output delays are constrained.
#   * Audio I2S pins leave IOB flip-flops (BCLK, LRCLK, DAC data) and an ODDR
#     (MCLK) on aud_clk; their relative timing is fixed by the IOB placement,
#     and the codec samples at 3.072 MHz BCLK (325 ns period), so they are
#     false paths rather than output-delay constrained.
#   * Ethernet: RGMII, MDIO and side-band pins copied from RTLNet
#     rtlnet_nexys_video.xdc; the RGMII timing, IDELAY group and TXC generated
#     clock are in third_party/rtlnet/boards/nexys_video/constraints/
#     rtlnet_nexys_video_rgmii.xdc, which fpga/build_bitstream.tcl reads after
#     synthesis (it names the u_mac/u_rgmii_io cells).
#   * microSD (deferred, not in milestone 1): sd_cclk W19, sd_cmd W20,
#     sd_d[0] V19, sd_d[3] U18, sd_cd T18, sd_reset V20 (bank 14, LVCMOS33).
#     Not constrained until the SD backend exists.
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
#   * 11-09-2026: Phase 4: RGMII, MDIO and eth_int_b pins (RTLNet), their false paths.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Clock: 100 MHz oscillator, R4, bank 34 (3.3 V), MRCC.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN R4    IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports sysclk]

# ---------------------------------------------------------------------------
# CPU RESET button, G4, bank 35 (1.5 V), low while pressed.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G4    IOSTANDARD LVCMOS15 } [get_ports { cpu_resetn }]

# ---------------------------------------------------------------------------
# USB-UART bridge, bank 14 (3.3 V). uart_tx_in = bridge TXD into the FPGA,
# uart_rx_out = FPGA transmit into the bridge RXD.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V18   IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }]
set_property -dict { PACKAGE_PIN AA19  IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]

# ---------------------------------------------------------------------------
# LEDs LD0..LD7, bank 13 (2.5 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS25 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS25 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS25 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U16   IOSTANDARD LVCMOS25 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS25 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS25 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W15   IOSTANDARD LVCMOS25 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN Y13   IOSTANDARD LVCMOS25 } [get_ports { led[7] }]

# ---------------------------------------------------------------------------
# HDMI source J8, bank 34 (3.3 V), TMDS_33; hot-plug detect on bank 13 (2.5 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T1    IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_p }]
set_property -dict { PACKAGE_PIN U1    IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_n }]
set_property -dict { PACKAGE_PIN W1    IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[0] }]
set_property -dict { PACKAGE_PIN Y1    IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[0] }]
set_property -dict { PACKAGE_PIN AA1   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[1] }]
set_property -dict { PACKAGE_PIN AB1   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[1] }]
set_property -dict { PACKAGE_PIN AB3   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[2] }]
set_property -dict { PACKAGE_PIN AB2   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[2] }]
set_property -dict { PACKAGE_PIN AB13  IOSTANDARD LVCMOS25 } [get_ports { hdmi_tx_hpd }]

# ---------------------------------------------------------------------------
# ADAU1761 audio codec, bank 34 (3.3 V): I2S and the control I2C bus.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN U6    IOSTANDARD LVCMOS33 } [get_ports { ac_mclk }]
set_property -dict { PACKAGE_PIN T5    IOSTANDARD LVCMOS33 } [get_ports { ac_bclk }]
set_property -dict { PACKAGE_PIN U5    IOSTANDARD LVCMOS33 } [get_ports { ac_lrclk }]
set_property -dict { PACKAGE_PIN W6    IOSTANDARD LVCMOS33 } [get_ports { ac_dac_sdata }]
set_property -dict { PACKAGE_PIN W5    IOSTANDARD LVCMOS33 } [get_ports { scl }]
set_property -dict { PACKAGE_PIN V5    IOSTANDARD LVCMOS33 } [get_ports { sda }]

# ---------------------------------------------------------------------------
# PS/2 from the PIC24 USB host (J15), bank 14 (3.3 V), pulled up.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN W17   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ps2_clk }]
set_property -dict { PACKAGE_PIN N13   IOSTANDARD LVCMOS33 PULLUP true } [get_ports { ps2_data }]

# ---------------------------------------------------------------------------
# RTL8211E Ethernet PHY. RGMII and management on bank 13 (2.5 V); the PHY reset
# on bank 34 (3.3 V), driven by the MDIO core, low until the firmware releases it.
# Pins as RTLNet rtlnet_nexys_video.xdc (VERIFY against the board schematic).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V13   IOSTANDARD LVCMOS25 } [get_ports { eth_rxck }]
set_property -dict { PACKAGE_PIN W10   IOSTANDARD LVCMOS25 } [get_ports { eth_rxctl }]
set_property -dict { PACKAGE_PIN AB16  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[0] }]
set_property -dict { PACKAGE_PIN AA15  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[1] }]
set_property -dict { PACKAGE_PIN AB15  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[2] }]
set_property -dict { PACKAGE_PIN AB11  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[3] }]
set_property -dict { PACKAGE_PIN AA14  IOSTANDARD LVCMOS25 } [get_ports { eth_txck }]
set_property -dict { PACKAGE_PIN V10   IOSTANDARD LVCMOS25 } [get_ports { eth_txctl }]
set_property -dict { PACKAGE_PIN Y12   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[0] }]
set_property -dict { PACKAGE_PIN W12   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[1] }]
set_property -dict { PACKAGE_PIN W11   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[2] }]
set_property -dict { PACKAGE_PIN Y11   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[3] }]
set_property -dict { PACKAGE_PIN AA16  IOSTANDARD LVCMOS25 } [get_ports { eth_mdc }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS25 } [get_ports { eth_mdio }]
set_property -dict { PACKAGE_PIN Y14   IOSTANDARD LVCMOS25 } [get_ports { eth_int_b }]
set_property -dict { PACKAGE_PIN U7    IOSTANDARD LVCMOS33 } [get_ports { eth_rst_b }]

# ---------------------------------------------------------------------------
# DDR3 SDRAM MT41K256M16 (Micron), banks 34 and 35, 1.5 V. Balls, I/O standards,
# slew and input termination exactly as the MIG project
# third_party/rtlnet/cores/rtlnet_ddr/ip/rtlnet_ddr_mig.prj generates them (the
# generated IP constraints carry the same values plus the controller's PHY and
# timing constraints). Bank 35 uses the internal VREF (0.75 V); the clock pair
# has no I/O buffer (the controller instantiates its own output primitives).
# The controller's system clock is ddr_sys_clk and its reference clock clk200,
# both from the system MMCM.
# ---------------------------------------------------------------------------
set_property IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_n[*]}]
set_property IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_p[*]}]
set_property INTERNAL_VREF 0.750 [get_iobanks 35]
set_property -dict { PACKAGE_PIN G2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[0]}]
set_property -dict { PACKAGE_PIN H4  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[1]}]
set_property -dict { PACKAGE_PIN H5  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[2]}]
set_property -dict { PACKAGE_PIN J1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[3]}]
set_property -dict { PACKAGE_PIN K1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[4]}]
set_property -dict { PACKAGE_PIN H3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[5]}]
set_property -dict { PACKAGE_PIN H2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[6]}]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[7]}]
set_property -dict { PACKAGE_PIN E3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[8]}]
set_property -dict { PACKAGE_PIN B2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[9]}]
set_property -dict { PACKAGE_PIN F3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[10]}]
set_property -dict { PACKAGE_PIN D2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[11]}]
set_property -dict { PACKAGE_PIN C2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[12]}]
set_property -dict { PACKAGE_PIN A1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[13]}]
set_property -dict { PACKAGE_PIN E2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[14]}]
set_property -dict { PACKAGE_PIN B1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[15]}]
set_property -dict { PACKAGE_PIN P6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[14]}]
set_property -dict { PACKAGE_PIN P2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[13]}]
set_property -dict { PACKAGE_PIN N4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[12]}]
set_property -dict { PACKAGE_PIN N5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[11]}]
set_property -dict { PACKAGE_PIN L5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[10]}]
set_property -dict { PACKAGE_PIN R1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[9]}]
set_property -dict { PACKAGE_PIN M6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[8]}]
set_property -dict { PACKAGE_PIN N2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[7]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[6]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[5]}]
set_property -dict { PACKAGE_PIN L6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[4]}]
set_property -dict { PACKAGE_PIN M1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[3]}]
set_property -dict { PACKAGE_PIN M3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[2]}]
set_property -dict { PACKAGE_PIN M5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[1]}]
set_property -dict { PACKAGE_PIN M2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[0]}]
set_property -dict { PACKAGE_PIN L4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[2]}]
set_property -dict { PACKAGE_PIN K6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[1]}]
set_property -dict { PACKAGE_PIN L3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[0]}]
set_property -dict { PACKAGE_PIN J4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ras_n}]
set_property -dict { PACKAGE_PIN K3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_cas_n}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_we_n}]
set_property -dict { PACKAGE_PIN G1  IOSTANDARD LVCMOS15    SLEW FAST } [get_ports {ddr3_reset_n}]
set_property -dict { PACKAGE_PIN J6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_cke[0]}]
set_property -dict { PACKAGE_PIN K4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_odt[0]}]
set_property -dict { PACKAGE_PIN G3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_dm[0]}]
set_property -dict { PACKAGE_PIN F1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_dm[1]}]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_p[0]}]
set_property -dict { PACKAGE_PIN J2  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_n[0]}]
set_property -dict { PACKAGE_PIN E1  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_p[1]}]
set_property -dict { PACKAGE_PIN D1  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_n[1]}]
set_property -dict { PACKAGE_PIN P5  IOSTANDARD DIFF_SSTL15 SLEW FAST } [get_ports {ddr3_ck_p[0]}]
set_property -dict { PACKAGE_PIN P4  IOSTANDARD DIFF_SSTL15 SLEW FAST } [get_ports {ddr3_ck_n[0]}]

# ---------------------------------------------------------------------------
# Asynchronous board pins: no timing relationship to any internal clock.
# Inputs: cpu_resetn only asserts rtlnet_reset_sync chains; uart_tx_in enters
# the UART Lite receiver's oversampler; ps2_clk/ps2_data enter ps2_rx's
# rtlnet_sync chains; hdmi_tx_hpd enters u_sync_status; scl/sda are the I2C
# bus at 100 kHz, sampled by axi_iic_0's own synchronizers; eth_int_b is a slow
# PHY side band synchronized in rtlnet_mdio, eth_mdio is the bit-banged
# management data line (rtlnet_mdio).
# Outputs: register driven and slow (LEDs, UART transmit, PHY reset, MDC/MDIO,
# I2C), or the audio pins (see the header).
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {cpu_resetn uart_tx_in ps2_clk ps2_data hdmi_tx_hpd scl sda eth_int_b eth_mdio}]
set_false_path -to   [get_ports {led[*] uart_rx_out eth_rst_b eth_mdc eth_mdio scl sda ac_mclk ac_bclk ac_lrclk ac_dac_sdata}]
# DDR3 RESET# is a static control level set by the controller's calibration sequence, not a clocked signal.
set_false_path -to   [get_ports {ddr3_reset_n}]

# ---------------------------------------------------------------------------
# Configuration: 3.3 V configuration bank, Quad-SPI flash (x4, 33 MHz),
# compressed bitstream.
# ---------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
