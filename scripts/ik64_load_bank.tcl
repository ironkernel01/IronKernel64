# -----------------------------------------------------------------------------
# File: ik64_load_bank.tcl
# Purpose: write the device 9 tune bank image into DDR3 of the running board over JTAG (xsdb script).
# Usage: xsdb ik64_load_bank.tcl <bank.bin> [dry]
#   dry: print the xsdb command sequence only (no connect, no hardware access); plain tclsh works too.
# Overview:
#   1. Read and check the image (size within C64_PLAT_BANK_SIZE, "IK64BANK" magic).
#   2. connect; select core 1's target like ik64_jtag_load.tcl (by name microblaze_1, else the 2nd Hart*).
#   3. Try the download with core 1 running: no stop, no reset. If that access fails (the debug module
#      may refuse memory access to a running hart; unverified on hardware), fall back to: stop core 1
#      only, write, verify, con. That is a pause of well under a second; core 0 is never touched, there
#      is no reset and no ELF download. The output says which path ran.
#   4. Verify words read back (ik64_bank_lib.tcl).
#   The firmware (backend_ram_mount) invalidates its D-cache over the bank and validates the image at the
#   next OPEN or PING of device 9, so a reload needs no restart of core 1.
# The board lock is the caller's (load_bank.ps1).
# Revision: 11-10-2026
#   * 11-10-2026: initial version (not run on hardware).
# -----------------------------------------------------------------------------
set soft 0
proc fail {msg} {
  global soft
  if {$soft} { error $msg }
  puts "ik64_jtag: FAIL $msg"
  exit 1
}
if {[llength $argv] < 1} { fail "usage: xsdb ik64_load_bank.tcl <bank.bin> \[dry\]" }
set bankfile [file normalize [lindex $argv 0]]
set dry [expr {[llength $argv] > 1 && [lindex $argv 1] eq "dry"}]
set CORE 1
set HART_WAIT_MS 15000
set POLL_MS 200
source [file join [file dirname [file normalize [info script]]] ik64_bank_lib.tcl]

set img [bank_read_image $bankfile]
lassign [bank_geometry] base size
puts "ik64_jtag: bank image $bankfile ([string length $img] bytes of $size)[expr {$dry ? { (dry run: commands are printed, not executed)} : {}}]"

if {$dry} {
  puts "ik64_jtag: xsdb> connect"
  puts "ik64_jtag: xsdb> targets -target-properties -filter {name =~ \"*microblaze_$CORE*\"}   (preferred)"
  puts "ik64_jtag: xsdb> targets -target-properties -filter {name =~ \"Hart*\"}   (fallback: Hart number $CORE)"
  puts "ik64_jtag: xsdb> targets <selected id>"
  bank_write $bankfile $img $base 1
  puts "ik64_jtag: fallback if core 1 refuses memory access while running: stop (core 1 only); dow -data; verify; con"
  puts "ik64_jtag: PASS (dry run, nothing executed)"
  exit 0
}

if {[catch {connect} err]} { fail "connect: $err" }
proc hart_ids {} {
  set ids {}
  catch { foreach t [targets -target-properties -filter {name =~ "Hart*"}] { lappend ids [dict get $t target_id] } }
  return $ids
}
proc name_id {core} {
  set id ""
  catch {
    set l [targets -target-properties -filter "name =~ \"*microblaze_$core*\""]
    if {[llength $l] > 0} { set id [dict get [lindex $l 0] target_id] }
  }
  return $id
}
set t0 [clock milliseconds]
while {1} {
  set tid [name_id $CORE]
  set ids [hart_ids]
  if {$tid eq "" && [llength $ids] > $CORE} { set tid [lindex $ids $CORE] }
  if {$tid ne ""} { break }
  if {[clock milliseconds] - $t0 > $HART_WAIT_MS} { fail "no target for core $CORE (found [llength $ids] hart target(s))" }
  after $POLL_MS
}
if {[catch {targets $tid} err]} { fail "select target: $err" }
puts "ik64_jtag: core $CORE -> target id $tid"

# Path 1: write while core 1 runs (soft mode: a failure comes back as an error, not an exit).
set soft 1
set rc [catch {bank_write $bankfile $img $base 0} err1]
set soft 0
if {$rc} {
  puts "ik64_jtag: write with core 1 running failed ($err1); halting core 1 only for the transfer"
  if {[catch {stop} err] && ![string match "*Already stopped*" $err]} { fail "stop: $err" }
  bank_write $bankfile $img $base 0
  if {[catch {con} err]} { fail "con: $err" }
  puts "ik64_jtag: core 1 resumed (no reset)"
} else {
  puts "ik64_jtag: core 1 was not stopped or reset"
}
puts "ik64_jtag: PASS"
exit 0
