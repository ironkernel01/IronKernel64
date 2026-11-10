# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
# -----------------------------------------------------------------------------
# File: ik64_qspi.xdc
# Purpose: pin timing of the configuration QSPI flash (S25FL256S) behind core 1's AXI Quad SPI
#   (u_cpu/axi_quad_spi_0, STARTUPE2 inside the IP).
# Overview:
#   * Read by fpga/build_bitstream.tcl after synthesis (the STARTUPE2 cell must exist).
#   * SCK = ext_spi_clk (cpu_clk 100 MHz) / 2 = 50 MHz, leaving the FPGA on USRCCLKO. The
#     constraints follow the AMD recipe for the IP with STARTUPE2 at SCK ratio 2 (PG153 v3.2,
#     ch. 4 "STARTUPE2 Enabled"): generated clock on USRCCLKO with edges {3 5 7} of ext_spi_clk,
#     shifted by the STARTUPE2 USRCCLKO-to-CCLK delay that Vivado does not time (PG153: 0.1 ns to
#     7.5 ns over all devices, 0.5 ns to 6.7 ns for K7-2; the 7.5 ns bound is used here, the worst
#     case for output hold and input setup); multicycle 2/1 on both directions (data launches on
#     every second ext_spi_clk edge); SCK register to USRCCLKO kept within 1.5 ns.
#   * Output setup at the fastest STARTUPE2 delay (0.5 ns) is not covered by the single edge
#     shift: the slow-corner data path with the fast-corner STARTUPE2 delay leaves about -0.4 ns
#     against the 3.0 ns flash setup time (build of 11-10-2026, slack -0.88 ns without the shift).
#     That pairing does not occur on silicon (both delays track the same process corner), and the
#     bootloader checks the CRC of everything it reads.
#   * Flash data sheet values (S25FL256S, 3.3 V, 50 MHz class): output data setup 3.0 ns and hold
#     2.0 ns before/after SCK, clock-to-output valid 7.65 ns max / 1.0 ns min (30 pF), plus 0.5 ns
#     board skew. Input data is captured on the next ext_spi_clk edge (setup multicycle 2, hold 1),
#     which is how the IP samples at ratio 2.
# Revision: 11-10-2026
#   * 11-10-2026: initial version; output-enable registers packed into the IOBs (O registers left free).
#   * 11-10-2026: STARTUPE2 delay (edge shift), output multicycle and SCK route limit from PG153
#     (build 3 missed setup by 0.88 ns on qspi_dq[0..1]/qspi_cs and hold by 1.9 ns on the T paths).
# Clocks: qspi_sck (generated from cpu_clk).
# -----------------------------------------------------------------------------
# The IP packs only its input registers (IO*_I_REG) into the IOBs. Pack the five output-enable (T) registers too (the data
# and chip-select O registers cannot join them in the OLOGIC, place_design failed with them forced): unpacked, the T paths cost 6.6 ns of routing and missed the pin timing (build of
# 11-10-2026: WNS -2.19 ns on the five T endpoints).
set qspi_iob [get_cells -hierarchical -filter {REF_NAME =~ FD* && NAME =~ u_cpu/axi_quad_spi_0/* && (NAME =~ *SPI_MODE_CONTROL_LOGIC_I/QSPI_IO*_T || NAME =~ *SPI_MODE_CONTROL_LOGIC_I/QSPI_MODE_2_T_CONTROL.QSPI_IO*_T || NAME =~ *SPI_MODE_CONTROL_LOGIC_I/QSPI_SS_T)}]
if {[llength $qspi_iob] != 5} { error "ik64_qspi.xdc: expected 5 output-enable registers to pack into IOBs, found [llength $qspi_iob]" }
set_property IOB TRUE $qspi_iob
set qspi_su [get_cells -hierarchical -filter {REF_NAME == STARTUPE2 && NAME =~ u_cpu/*}]
if {[llength $qspi_su] != 1} { error "ik64_qspi.xdc: expected one STARTUPE2 inside u_cpu, found [llength $qspi_su]" }
set qspi_cclk [get_pins -of_objects $qspi_su -filter {REF_PIN_NAME == USRCCLKO}]
set cpu_clk_obj [get_clocks -of_objects [get_pins u_bufg_cpu/O]]
set qspi_cclk_delay 7.5
set qspi_sck_reg [get_cells -hierarchical -filter {NAME =~ u_cpu/axi_quad_spi_0/*SPI_MODE_CONTROL_LOGIC_I/*SCK_O_reg_reg}]
if {[llength $qspi_sck_reg] != 1} { error "ik64_qspi.xdc: expected one SCK_O_reg_reg, found [llength $qspi_sck_reg]" }
set_max_delay 1.5 -datapath_only -from [get_pins -of_objects $qspi_sck_reg -filter {REF_PIN_NAME == C}] -to $qspi_cclk
set_min_delay 0.1 -from [get_pins -of_objects $qspi_sck_reg -filter {REF_PIN_NAME == C}] -to $qspi_cclk
set qspi_shift [list $qspi_cclk_delay $qspi_cclk_delay $qspi_cclk_delay]
create_generated_clock -name qspi_sck -source [get_pins u_bufg_cpu/O] -edges {3 5 7} -edge_shift $qspi_shift $qspi_cclk
set qspi_pins [get_ports {qspi_dq[*] qspi_cs}]
set_output_delay -clock qspi_sck -max 3.5  $qspi_pins
set_output_delay -clock qspi_sck -min -2.0 $qspi_pins
set_input_delay  -clock qspi_sck -clock_fall -max 8.15 [get_ports {qspi_dq[*]}]
set_input_delay  -clock qspi_sck -clock_fall -min 1.0  [get_ports {qspi_dq[*]}]
set_multicycle_path -setup 2 -from [get_clocks qspi_sck] -to $cpu_clk_obj
set_multicycle_path -hold  1 -end -from [get_clocks qspi_sck] -to $cpu_clk_obj
set_multicycle_path -setup 2 -start -from $cpu_clk_obj -to [get_clocks qspi_sck]
set_multicycle_path -hold  1 -from $cpu_clk_obj -to [get_clocks qspi_sck]
