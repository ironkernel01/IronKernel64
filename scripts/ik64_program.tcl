# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
# File: ik64_program.tcl
# Purpose: program the Nexys Video XC7A200T (volatile) over its on-board USB-JTAG
#   with the Vivado Hardware Manager (local hw_server) and report the result.
# Overview:
#   * connect_hw_server (starts a local hw_server if none runs), open the first
#     JTAG target, pick the device matching xc7a200t*, set PROGRAM.FILE,
#     program_hw_devices, refresh, then read the DONE status.
#   * Exit codes: 0 programmed and DONE high; 1 no hw_server / no target /
#     no device; 2 bad arguments or missing file; 3 programming failed or DONE
#     low.
#   * Every output line starts with "ik64_program:".
#   * Board access: the caller (scripts/program.ps1) holds the board lock.
# Usage: vivado -mode batch -source ik64_program.tcl -tclargs <bitfile>
#   Normally through scripts/program.ps1 and scripts/ik64_vivado.ps1.
# Language: Tcl (Vivado 2026.1).
# Revision: 11-10-2026
#   * 11-10-2026: initial version (ik64-owned; same hardware-manager sequence as the
#     earlier programming script).
# -----------------------------------------------------------------------------
if {[llength $argv] < 1} { puts "ik64_program: usage: -tclargs <bitfile>"; exit 2 }
set bit [file normalize [join $argv " "]]
if {![file exists $bit]} { puts "ik64_program: ERROR bitstream not found: $bit"; exit 2 }
puts "ik64_program: bitstream $bit ([file size $bit] bytes)"

open_hw_manager
if {[catch {connect_hw_server} err]} {
  puts "ik64_program: ERROR cannot reach the hw_server: $err"
  exit 1
}
puts "ik64_program: hw_server [current_hw_server]"
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
  puts "ik64_program: ERROR the hw_server has no JTAG target (cable unplugged or board off)"
  exit 1
}
puts "ik64_program: target [lindex $targets 0]"
current_hw_target [lindex $targets 0]
if {[catch {open_hw_target} err]} {
  puts "ik64_program: ERROR open_hw_target: $err"
  exit 1
}
set dev [lindex [get_hw_devices -quiet xc7a200t*] 0]
if {$dev eq ""} {
  puts "ik64_program: ERROR no xc7a200t device in the chain: [get_hw_devices -quiet]"
  exit 1
}
current_hw_device $dev
set dev_name [get_property NAME $dev]
puts "ik64_program: device $dev_name part [get_property PART $dev]"
set_property PROGRAM.FILE $bit $dev
catch {set_property PROBES.FILE {} $dev}
catch {set_property FULL_PROBES.FILE {} $dev}
set t0 [clock milliseconds]
if {[catch {program_hw_devices $dev} err]} {
  puts "ik64_program: ERROR program_hw_devices: $err"
  exit 3
}
refresh_hw_device -quiet $dev
set done [get_property -quiet REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
puts "ik64_program: programmed in [expr {([clock milliseconds] - $t0) / 1000.0}] s, DONE pin '$done'"
if {$done ne "1"} {
  puts "ik64_program: ERROR DONE pin not high after programming"
  exit 3
}
close_hw_target
disconnect_hw_server
puts "ik64_program: PASS $dev_name"
exit 0
