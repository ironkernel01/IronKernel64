# -----------------------------------------------------------------------------
# File: ik64_jtag_load.tcl
# Purpose: load an ELF into the LMB of one MicroBlaze V core of IronKernel 64
#   over JTAG and run it (xsdb script). Adapted from RTLNet jtag_load_elf.tcl
#   (hart selection by core index, no RTLNet-specific DDR3/CLK_STATUS access).
# Usage: xsdb ik64_jtag_load.tcl <elf> <core 0|1>
# Overview: connect, wait for the Nth "Hart*" target (N = core), stop, reset
#   (core 0: rst -system -stop; core 1: rst -processor -stop so core 0 keeps
#   running), dow, verify first/middle/last word of every PT_LOAD segment,
#   rwr pc entry, con. Lines start with "ik64_jtag:"; last line PASS or FAIL.
# Revision: 11-09-2026
#   * 11-09-2026: initial version (not run on hardware).
# -----------------------------------------------------------------------------
proc fail {msg} { puts "ik64_jtag: FAIL $msg"; exit 1 }
if {[llength $argv] < 2} { fail "usage: xsdb ik64_jtag_load.tcl <elf> <core>" }
set elf [file normalize [lindex $argv 0]]
set core [lindex $argv 1]
if {![file exists $elf]} { fail "ELF not found: $elf" }
puts "ik64_jtag: elf $elf ([file size $elf] bytes), core $core"

proc rd32 {addr} { return [expr {[string trim [mrd -value $addr]] + 0}] }

set fh [open $elf rb]
set data [read $fh]
close $fh
if {[string range $data 0 3] ne "\x7fELF" || [string index $data 4] ne "\x01"} { fail "not an ELF32 file" }
binary scan $data @24iu entry
binary scan $data @28iu phoff
binary scan $data @42su phentsize
binary scan $data @44su phnum
set segs {}
for {set i 0} {$i < $phnum} {incr i} {
  set o [expr {$phoff + $i * $phentsize}]
  binary scan $data @${o}iu ptype
  binary scan $data @[expr {$o + 4}]iu poffset
  binary scan $data @[expr {$o + 8}]iu pvaddr
  binary scan $data @[expr {$o + 16}]iu pfilesz
  if {$ptype == 1 && $pfilesz >= 4} { lappend segs [list $pvaddr $poffset $pfilesz] }
}
puts "ik64_jtag: entry [format 0x%x $entry], [llength $segs] loaded segment(s)"

if {[catch {connect} err]} { fail "connect: $err" }
# The harts appear a few seconds after connect: poll until the Nth exists.
set t0 [clock milliseconds]
set ids {}
while {1} {
  set ids {}
  catch {
    foreach t [targets -target-properties -filter {name =~ "Hart*"}] { lappend ids [dict get $t target_id] }
  }
  if {[llength $ids] > $core} { break }
  if {[clock milliseconds] - $t0 > 15000} { fail "no hart for core $core (found [llength $ids] hart target(s))" }
  after 200
}
puts "ik64_jtag: [llength $ids] hart target(s), using id [lindex $ids $core]"
if {[catch {targets [lindex $ids $core]} err]} { fail "select target: $err" }
puts "ik64_jtag: target [lindex [split [string trim [targets -filter {is_current == 1}]] \n] 0]"

if {[catch {stop} err] && ![string match "*Already stopped*" $err]} { fail "stop: $err" }
puts "ik64_jtag: stopped [state]"
if {$core == 0} { set rcmd {rst -system -stop} } else { set rcmd {rst -processor -stop} }
if {[catch {eval $rcmd} err]} { fail "$rcmd: $err" }
puts "ik64_jtag: reset ($rcmd), [state]"

if {[catch {dow $elf} err]} { fail "dow: $err" }
set nwords 0
foreach seg $segs {
  lassign $seg vaddr foff fsz
  set last [expr {($fsz & ~3) - 4}]
  foreach rel [lsort -unique -integer [list 0 [expr {(($fsz / 2) & ~3)}] $last]] {
    binary scan $data @[expr {$foff + $rel}]iu want
    set a [expr {$vaddr + $rel}]
    if {[catch {rd32 $a} got]} { fail "verify: cannot read [format 0x%08x $a]: $got" }
    if {$got != $want} { fail [format "verify mismatch at 0x%08x: memory 0x%08x, ELF 0x%08x" $a $got $want] }
    incr nwords
  }
}
puts "ik64_jtag: download verified ($nwords words in [llength $segs] segment(s))"
if {[catch {rwr pc $entry} err]} { fail "rwr pc: $err" }
if {[catch {con} err]} { fail "con: $err" }
after 500
puts "ik64_jtag: state [state]"
puts "ik64_jtag: PASS"
exit 0
