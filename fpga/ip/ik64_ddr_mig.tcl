# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
# File: ik64_ddr_mig.tcl
# Purpose: generate the AMD 7-series memory controller IP (MIG, mig_7series 4.2)
#   of the IronKernel 64 DDR3 path from ik64_ddr_mig.prj, into a build tree.
# Overview:
#   * Defines `ik64_ddr_mig_create <ip_dir>`; the caller has an open (or
#     in-memory) project with the part set (xc7a200tsbg484-1). The procedure
#     creates the IP ik64_ddr_mig from the .prj next to this script, generates
#     its output products (global synthesis: no IP checkpoint, the controller is
#     synthesized with the top) and returns the .xci path. Nothing generated is
#     committed: the build tree <ip_dir> is recreated by every build.
#   * ik64_ddr_mig.prj is the Digilent Nexys Video MIG project (vivado-boards
#     nexys_video A.0 1.2 mig.prj, fetched 11-08-2026: MT41K256M16, 2500 ps /
#     400 MHz, 4:1, 100 MHz input, 16-bit, AXI, 512 MiB, pin assignment and
#     timing) with exactly four edits:
#       ModuleName       design_1_mig_7series_0_0 -> ik64_ddr_mig
#       SystemClock      Single-Ended -> No Buffer (sys_clk arrives buffered)
#       sys_clk_i pad    R4(MRCC_P) -> No connect (the clock is internal)
#       AXI data width   32 -> 128 (MIG native: 16 DQ x 8 beats)
#     The AXI ID width stays 2, narrow-burst support stays off. Except for the
#     module name the file is byte-identical to the RTLNet project that the
#     C64 build used until now.
#   * The IP ports are the interface of fpga/hdl/ddr/ik64_ddr.sv.
# Language: Vivado Tcl (2026.1).
# Revision: 11-09-2026
#   * 11-09-2026: initial version (prepared, not yet wired into the build).
# Clocks: none (generation only).
# -----------------------------------------------------------------------------

namespace eval ik64_ddr_mig {
  variable DIR [file normalize [file dirname [info script]]]
}

proc ik64_ddr_mig_create {ip_dir} {
  set prj [file join $::ik64_ddr_mig::DIR ik64_ddr_mig.prj]
  if {![file exists $prj]} { error "MIG project not found: $prj" }
  file delete -force $ip_dir
  file mkdir $ip_dir
  create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name ik64_ddr_mig -dir $ip_dir
  set ip [get_ips ik64_ddr_mig]
  set_property -dict [list \
    CONFIG.XML_INPUT_FILE        [file normalize $prj] \
    CONFIG.RESET_BOARD_INTERFACE Custom \
    CONFIG.MIG_DONT_TOUCH_PARAM  Custom \
    CONFIG.BOARD_MIG_PARAM       Custom] $ip
  set xci [get_files -of_objects [get_filesets sources_1] ik64_ddr_mig.xci]
  set_property generate_synth_checkpoint false $xci
  generate_target all $xci
  return $xci
}
