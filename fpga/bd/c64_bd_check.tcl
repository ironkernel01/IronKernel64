# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
# -----------------------------------------------------------------------------
# File: c64_bd_check.tcl
# Purpose: build the c64_cpu block design alone (no synthesis) to check that
#   c64_bd.tcl validates, and record the generated module's port list and the
#   address map that c64_top.sv and the firmware headers must match.
# Overview:
#   * Usage (through the Vivado slot wrapper):
#       powershell -NoProfile -ExecutionPolicy Bypass -File third_party/rtlnet/scripts/rtlnet_vivado.ps1 `
#         -Tcl <repo>/fpga/bd/c64_bd_check.tcl -Log <repo>/build/bd_check/bd_check.log
#   * Outputs in build/bd_check: c64_cpu_ports.txt (the port list of the
#     generated c64_cpu module) and c64_cpu_addr.txt (every address segment).
#   * Prints `C64_BD_CHECK: PASS` and exits 0, or `C64_BD_CHECK: FAIL <step>`
#     and exits 1.
# Language: Vivado Tcl (2026.1).
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
# Clocks: none.
# -----------------------------------------------------------------------------

set here [file dirname [file normalize [info script]]]
set repo [file normalize [file join $here .. ..]]
set out  [file join $repo build bd_check]
file mkdir $out

proc fail {step msg} {
  puts "C64_BD_CHECK: FAIL $step: $msg"
  exit 1
}

create_project -in_memory -part xc7a200tsbg484-1
source [file join $here c64_bd.tcl]
if {[catch {set bd [c64_bd_create $out]} err]} { fail create $err }
if {[catch {generate_target synthesis [get_files $bd]} err]} { fail generate $err }

# The synthesis view holds the c64_cpu module first, then its sub-hierarchies;
# keep the declarations of the first module only and strip the (* ... *) attributes.
set top_v [file join $out c64_cpu synth c64_cpu.v]
if {![file exists $top_v]} { fail ports "generated $top_v not found" }
set fh [open $top_v r]
set text [read $fh]
close $fh
set fo [open [file join $out c64_cpu_ports.txt] w]
set in_top 0
set n_ports 0
foreach line [split $text "\n"] {
  if {[regexp {^module c64_cpu\s*$} $line]} { set in_top 1; continue }
  if {!$in_top} { continue }
  if {[regexp {^endmodule} $line]} { break }
  regsub -all {\(\*[^*]*\*\)} $line {} line
  if {[regexp {^\s*((input|output|inout)\s[^;]*);} $line -> decl]} {
    puts $fo [string trim $decl]
    incr n_ports
  }
}
close $fo
if {$n_ports == 0} { fail ports "no port declarations found in $top_v" }

set fa [open [file join $out c64_cpu_addr.txt] w]
foreach seg [lsort [get_bd_addr_segs -of_objects [get_bd_addr_spaces]]] {
  puts $fa [format "%-60s %s %s" $seg [get_property OFFSET $seg] [get_property RANGE $seg]]
}
close $fa
puts "C64_BD_CHECK: PASS"
exit 0
