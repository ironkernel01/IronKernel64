# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
# File: ik64_ddr_cc.tcl
# Purpose: generate the AMD AXI clock converter IP (axi_clock_converter 2.1)
#   that carries the CPU cache port (cpu_clk) into the DDR3 controller clock
#   (ui_clk) in the IronKernel 64 DDR3 path.
# Overview:
#   * Defines `ik64_ddr_cc_create <ip_dir>`; the caller has an open (or
#     in-memory) project with the part set. Returns the .xci path; output
#     products are generated with the top (no IP checkpoint).
#   * AXI4, 29-bit address (512 MiB), 128-bit data, 2-bit ID (the MIG ID width),
#     read and write, asynchronous clocks, 3 synchronizer stages, no user
#     signals. WRAP, narrow and 1..256-beat INCR bursts pass unchanged.
#   * The IP ports are the interface of fpga/hdl/ddr/ik64_axi_cdc.sv.
#   * One master reaches the DDR3 controller, so no crossbar and no arbiter sit
#     between this IP and the MIG. If a second master is added later, put an
#     axi_crossbar / smartconnect in front of the converter (see the proposal in
#     the integration notes).
# Language: Vivado Tcl (2026.1).
# Revision: 11-09-2026
#   * 11-09-2026: initial version (prepared, not yet wired into the build).
# Clocks: none (generation only).
# -----------------------------------------------------------------------------

proc ik64_ddr_cc_create {ip_dir} {
  file delete -force $ip_dir
  file mkdir $ip_dir
  create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name ik64_ddr_cc -dir $ip_dir
  set ip [get_ips ik64_ddr_cc]
  set_property -dict [list \
    CONFIG.PROTOCOL                AXI4 \
    CONFIG.ADDR_WIDTH              29 \
    CONFIG.DATA_WIDTH              128 \
    CONFIG.ID_WIDTH                2 \
    CONFIG.AWUSER_WIDTH            0 \
    CONFIG.ARUSER_WIDTH            0 \
    CONFIG.WUSER_WIDTH             0 \
    CONFIG.RUSER_WIDTH             0 \
    CONFIG.BUSER_WIDTH             0 \
    CONFIG.READ_WRITE_MODE         READ_WRITE \
    CONFIG.ACLK_ASYNC              1 \
    CONFIG.SYNCHRONIZATION_STAGES  3] $ip
  set xci [get_files -of_objects [get_filesets sources_1] ik64_ddr_cc.xci]
  set_property generate_synth_checkpoint false $xci
  generate_target all $xci
  return $xci
}
