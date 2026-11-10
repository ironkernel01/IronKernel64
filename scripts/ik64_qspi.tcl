# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
# File: ik64_qspi.tcl
# Purpose: configuration-flash operations on the Nexys Video through the Vivado Hardware Manager:
#   program the QSPI flash (erase, program, verify), read it back to a file, or reboot the FPGA from
#   the flash (JPROGRAM) without a power cycle.
# Usage: vivado -mode batch -source ik64_qspi.tcl -tclargs program <image.mcs>
#        vivado -mode batch -source ik64_qspi.tcl -tclargs backup <out.bin> [<bytes>]
#        vivado -mode batch -source ik64_qspi.tcl -tclargs reboot
#   Normally through scripts/program_qspi.ps1 and scripts/ik64_vivado.ps1; the caller holds the board lock.
#   (Two words, never key=value: the launcher is a cmd batch file that splits at '='.)
# Overview:
#   * Part s25fl256sxxxxxx0-spi-x1_x2_x4 (Spansion S25FL256S, 32 MiB, confirmed on the board 11-10-2026 by a
#     read-only probe), interface SPIx4. The script loads the indirect-programming helper bitstream over
#     JTAG, then program_hw_cfgmem erases, programs and verifies; the
#     bitstream in the flash is NOT what is running afterwards: reboot runs boot_hw_device to configure
#     from the flash.
#   * backup reads the first <bytes> (default the whole 32 MiB) of the flash into a file with
#     readback_hw_cfgmem; it does not change the flash.
# Exit codes: 0 PASS, 1 no hw_server / target / device, 2 bad arguments or file, 3 operation failed.
# Every output line starts with "ik64_qspi:".
# Language: Tcl (Vivado 2026.1).
# Revision: 11-10-2026
#   * 11-10-2026: initial version.
#   * 11-10-2026: load the indirect-programming helper bitstream before program/backup (first board run
#     failed with Labtools 27-3347); backup uses -datacount (bytes) instead of -size.
# -----------------------------------------------------------------------------
set PART s25fl256sxxxxxx0-spi-x1_x2_x4
if {[llength $argv] < 1} { puts "ik64_qspi: usage: -tclargs program <mcs> | backup <bin> \[bytes\] | reboot"; exit 2 }
set mode [lindex $argv 0]
switch -- $mode {
  program { if {[llength $argv] != 2 || ![file exists [lindex $argv 1]]} { puts "ik64_qspi: ERROR program needs an existing .mcs"; exit 2 } }
  backup  { if {[llength $argv] < 2} { puts "ik64_qspi: ERROR backup needs an output file"; exit 2 } }
  reboot  { }
  default { puts "ik64_qspi: ERROR unknown mode $mode"; exit 2 }
}

open_hw_manager
if {[catch {connect_hw_server} err]} { puts "ik64_qspi: ERROR cannot reach the hw_server: $err"; exit 1 }
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} { puts "ik64_qspi: ERROR the hw_server has no JTAG target"; exit 1 }
current_hw_target [lindex $targets 0]
if {[catch {open_hw_target} err]} { puts "ik64_qspi: ERROR open_hw_target: $err"; exit 1 }
set dev [lindex [get_hw_devices -quiet xc7a200t*] 0]
if {$dev eq ""} { puts "ik64_qspi: ERROR no xc7a200t device in the chain"; exit 1 }
current_hw_device $dev
puts "ik64_qspi: device [get_property NAME $dev], mode $mode"

proc cfgmem_for {dev part} {
  set mem [lindex [get_cfgmem_parts $part] 0]
  if {$mem eq ""} { puts "ik64_qspi: ERROR flash part $part unknown"; exit 2 }
  create_hw_cfgmem -hw_device $dev $mem
  set cm [get_property PROGRAM.HW_CFGMEM $dev]
  # Load the indirect-programming helper design first (what the Hardware Manager GUI does): the running
  # ik64 design owns the flash pins, and without the helper program_hw_cfgmem stops at "Failure to set
  # flash parameters" (Labtools 27-3347) and readback_hw_cfgmem at "indirect programming bitstream was
  # not found" (27-3138).
  create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
  program_hw_devices $dev
  refresh_hw_device $dev
  set_property PROGRAM.BLANK_CHECK 0 $cm
  set_property PROGRAM.ERASE 1 $cm
  set_property PROGRAM.CFG_PROGRAM 1 $cm
  set_property PROGRAM.VERIFY 1 $cm
  set_property PROGRAM.CHECKSUM 0 $cm
  return $cm
}

set t0 [clock milliseconds]
if {$mode eq "program"} {
  set mcs [file normalize [lindex $argv 1]]
  set cm [cfgmem_for $dev $PART]
  set_property PROGRAM.ADDRESS_RANGE {use_file} $cm
  set_property PROGRAM.FILES [list $mcs] $cm
  set_property PROGRAM.PRM_FILE {} $cm
  set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cm
  puts "ik64_qspi: programming $mcs ([file size $mcs] bytes), erase + program + verify"
  if {[catch {program_hw_cfgmem -hw_cfgmem $cm} err]} { puts "ik64_qspi: ERROR program_hw_cfgmem: $err"; exit 3 }
  puts "ik64_qspi: flash programmed and verified in [expr {([clock milliseconds] - $t0) / 1000.0}] s"
} elseif {$mode eq "backup"} {
  set out [file normalize [lindex $argv 1]]
  set bytes [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0x2000000}]
  set cm [cfgmem_for $dev $PART]
  # cfgmem_for has loaded the indirect-programming helper design that the readback needs.
  if {[catch {
    if {[string length [info commands readback_hw_cfgmem]] == 0} { error "readback_hw_cfgmem not available" }
    readback_hw_cfgmem -hw_cfgmem $cm -file $out -format bin -offset 0 -datacount $bytes -force
  } err]} { puts "ik64_qspi: ERROR readback: $err"; exit 3 }
  puts "ik64_qspi: read back [file size $out] bytes to $out in [expr {([clock milliseconds] - $t0) / 1000.0}] s"
} else {
  if {[catch {boot_hw_device $dev} err]} { puts "ik64_qspi: ERROR boot_hw_device: $err"; exit 3 }
  # Configuration from the flash takes a moment (compressed image at CONFIGRATE 33, x4): poll DONE, bounded.
  set done ""
  for {set i 0} {$i < 50} {incr i} {
    after 200
    refresh_hw_device -quiet $dev
    set done [get_property -quiet REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
    if {$done eq "1"} break
  }
  puts "ik64_qspi: JPROGRAM issued, DONE pin '$done' after [expr {([clock milliseconds] - $t0) / 1000.0}] s"
  if {$done ne "1"} { puts "ik64_qspi: ERROR DONE pin not high after the reboot"; exit 3 }
}
catch {close_hw_target}
catch {disconnect_hw_server}
puts "ik64_qspi: PASS $mode"
exit 0
