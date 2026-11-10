# -----------------------------------------------------------------------------
# File: ik64_jtag_load.tcl
# Purpose: load an ELF into one MicroBlaze V core of IronKernel 64 over JTAG
#   and run it (xsdb script). Adapted from RTLNet jtag_load_elf.tcl (hart
#   selection by core index, DDR3 calibration wait through the c64 sysregs of
#   the selected core, no RTLNet-specific CLK_STATUS address).
# Usage: xsdb ik64_jtag_load.tcl <elf> <core 0|1> [dry] [bank <bank.bin>]
#   dry: print the xsdb command sequence instead of running it (no connect, no
#   hardware access); runs under plain tclsh as well as under xsdb.
#   bank <file> (core 1 only): after the ELF download and its verification, and before the pc is set
#   and the core resumes, write the device 9 tune bank image (mkbank.py output) to DDR3 at
#   C64_PLAT_BANK_BASE and verify words read back (ik64_bank_lib.tcl). The ELF never covers that
#   region (fw_1541/build.ps1 ends the linker's ddr3 region below it); the firmware validates the
#   bank at its first OPEN of device 9.
# Overview:
#   1. Parse the ELF (entry, PT_LOAD segments) in Tcl.
#   2. connect; select the core's target: first by name (a target whose name
#      contains "microblaze_<core>"), else the Nth "Hart*" target (both cores
#      sit behind the 2-port mdm_riscv). The selection is UNVERIFIED on
#      hardware; the chosen target and the other core's target are printed.
#   3. stop only that core. Read the c64 sysregs through that core's own
#      register window (core 0 0x44000000, core 1 0x44A00000): check the
#      magic, print the build ID and, when the ELF loads into DDR3 (any segment
#      at 0x8000_0000 or above), wait up to DDR_WAIT_MS for the DDR3
#      calibrated bit (clk_status bit 1).
#   4. Reset: core 0 rst -system -stop (resets the whole design); core 1
#      rst -processor -stop (that hart only, core 0 keeps running; never
#      rst -system for core 1).
#   5. dow, verify first/middle/last word of every PT_LOAD segment, rwr pc
#      entry, con. Lines start with "ik64_jtag:"; the last line is PASS or FAIL.
# Cache note: core 1 runs from DDR3 behind 8 KiB write-through caches. The
#   download goes around them, and rst -processor resets them; the firmware also
#   invalidates both caches in main().
# Revision: 11-10-2026
#   * 11-09-2026: initial version (not run on hardware); -Core 1 path with DDR3
#     calibration wait, name-based target selection and dry mode.
#   * 11-10-2026: bank <file> option (device 9 tune bank, core 1); two words, since cmd splits at "=".
# -----------------------------------------------------------------------------
set SYS_BASE(0)     0x44000000
set SYS_BASE(1)     0x44A00000
set SYS_MAGIC_OFS   0x00
set SYS_BUILD_OFS   0x04
set SYS_CLK_OFS     0x0C
set SYS_MAGIC       0x494B3634
set CLK_DDR_BIT     1
set DDR_BASE        0x80000000
set HART_WAIT_MS    15000
set DDR_WAIT_MS     30000
set POLL_MS         200

proc fail {msg} { puts "ik64_jtag: FAIL $msg"; exit 1 }
if {[llength $argv] < 2} { fail "usage: xsdb ik64_jtag_load.tcl <elf> <core 0|1> \[dry\]" }
set elf [file normalize [lindex $argv 0]]
set core [lindex $argv 1]
set dry 0
set bankfile ""
# "bank <file>" is two words: xsdb.bat is a cmd batch file, and cmd splits arguments at '='.
set opts [lrange $argv 2 end]
for {set i 0} {$i < [llength $opts]} {incr i} {
  set opt [lindex $opts $i]
  if {$opt eq "dry"} {
    set dry 1
  } elseif {$opt eq "bank" && $i + 1 < [llength $opts]} {
    incr i
    set bankfile [file normalize [lindex $opts $i]]
  } else {
    fail "unknown option $opt"
  }
}
if {$core ne "0" && $core ne "1"} { fail "core must be 0 or 1" }
if {$bankfile ne "" && $core ne "1"} { fail "bank <file> is for core 1 (the drive core serves the bank)" }
source [file join [file dirname [file normalize [info script]]] ik64_bank_lib.tcl]
if {$bankfile ne ""} { set bank_img [bank_read_image $bankfile] }
if {![file exists $elf]} { fail "ELF not found: $elf" }
puts "ik64_jtag: elf $elf ([file size $elf] bytes), core $core[expr {$dry ? { (dry run: commands are printed, not executed)} : {}}]"

proc rd32 {addr} {
  global dry
  if {$dry} { puts "ik64_jtag: xsdb> mrd -value [format 0x%08x $addr]"; return 0 }
  return [expr {[string trim [mrd -value $addr]] + 0}]
}

set fh [open $elf rb]
set data [read $fh]
close $fh
if {[string range $data 0 3] ne "\x7fELF" || [string index $data 4] ne "\x01"} { fail "not an ELF32 file" }
binary scan $data @24iu entry
binary scan $data @28iu phoff
binary scan $data @42su phentsize
binary scan $data @44su phnum
set segs {}
set needs_ddr 0
for {set i 0} {$i < $phnum} {incr i} {
  set o [expr {$phoff + $i * $phentsize}]
  binary scan $data @${o}iu ptype
  binary scan $data @[expr {$o + 4}]iu poffset
  binary scan $data @[expr {$o + 8}]iu pvaddr
  binary scan $data @[expr {$o + 16}]iu pfilesz
  if {$ptype == 1 && $pfilesz >= 4} {
    lappend segs [list $pvaddr $poffset $pfilesz]
    if {$pvaddr >= $DDR_BASE && $pvaddr < 0xC0000000} { set needs_ddr 1 }
  }
}
puts "ik64_jtag: entry [format 0x%x $entry], [llength $segs] loaded segment(s), DDR3 image $needs_ddr"
if {[llength $segs] == 0} { fail "ELF has no loadable segment" }

if {$dry} {
  puts "ik64_jtag: xsdb> connect"
} elseif {[catch {connect} err]} {
  fail "connect: $err"
}

# --- target selection -------------------------------------------------------
# hart_ids -- target ids of the Hart* targets, in order; name_id -- id of the target named for the core.
proc hart_ids {} {
  set ids {}
  catch {
    foreach t [targets -target-properties -filter {name =~ "Hart*"}] { lappend ids [dict get $t target_id] }
  }
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
if {$dry} {
  puts "ik64_jtag: xsdb> targets -target-properties -filter {name =~ \"*microblaze_$core*\"}   (preferred)"
  puts "ik64_jtag: xsdb> targets -target-properties -filter {name =~ \"Hart*\"}   (fallback: Hart number $core)"
  puts "ik64_jtag: xsdb> targets <selected id>"
} else {
  # The harts appear a few seconds after connect: poll until the core's target exists.
  set t0 [clock milliseconds]
  while {1} {
    set tid [name_id $core]
    set ids [hart_ids]
    if {$tid eq "" && [llength $ids] > $core} { set tid [lindex $ids $core] }
    if {$tid ne ""} { break }
    if {[clock milliseconds] - $t0 > $HART_WAIT_MS} { fail "no target for core $core (found [llength $ids] hart target(s))" }
    after $POLL_MS
  }
  puts "ik64_jtag: hart targets $ids, core $core -> id $tid ([expr {[name_id $core] ne {} ? {by name} : {by hart order}}])"
  if {[catch {targets $tid} err]} { fail "select target: $err" }
  puts "ik64_jtag: target [lindex [split [string trim [targets -filter {is_current == 1}]] \n] 0]"
}

# --- stop only this core ----------------------------------------------------
if {$dry} {
  puts "ik64_jtag: xsdb> stop"
} elseif {[catch {stop} err] && ![string match "*Already stopped*" $err]} {
  fail "stop: $err"
}

# --- system registers through this core's own window ------------------------
set sys $SYS_BASE($core)
set magic [rd32 [expr {$sys + $SYS_MAGIC_OFS}]]
if {!$dry && $magic != $SYS_MAGIC} {
  fail [format "sysregs magic at 0x%08x is 0x%08x, expected 0x%08x (wrong core selected, or no bitstream)" $sys $magic $SYS_MAGIC]
}
if {!$dry} {
  puts [format "ik64_jtag: sysregs at 0x%08x magic ok, build ID %08x" $sys [rd32 [expr {$sys + $SYS_BUILD_OFS}]]]
}
if {$needs_ddr} {
  if {$dry} {
    puts "ik64_jtag: xsdb> (poll mrd [format 0x%08x [expr {$sys + $SYS_CLK_OFS}]] bit $CLK_DDR_BIT = DDR3 calibrated, up to $DDR_WAIT_MS ms)"
  } else {
    set t0 [clock milliseconds]
    while {1} {
      set clk [rd32 [expr {$sys + $SYS_CLK_OFS}]]
      if {($clk >> $CLK_DDR_BIT) & 1} { break }
      if {[clock milliseconds] - $t0 > $DDR_WAIT_MS} { fail [format "DDR3 not calibrated after %d ms (clk_status 0x%08x)" $DDR_WAIT_MS $clk] }
      after $POLL_MS
    }
    puts "ik64_jtag: DDR3 calibrated ([expr {[clock milliseconds] - $t0}] ms)"
  }
}

# --- reset: core 0 the whole design, core 1 only its own hart ---------------
if {$core eq "0"} { set rcmd {rst -system -stop} } else { set rcmd {rst -processor -stop} }
if {$dry} { puts "ik64_jtag: xsdb> $rcmd" } elseif {[catch {eval $rcmd} err]} { fail "$rcmd: $err" }

# --- download and verify ----------------------------------------------------
if {$dry} { puts "ik64_jtag: xsdb> dow $elf" } elseif {[catch {dow $elf} err]} { fail "dow: $err" }
set nwords 0
foreach seg $segs {
  lassign $seg vaddr foff fsz
  set last [expr {($fsz & ~3) - 4}]
  foreach rel [lsort -unique -integer [list 0 [expr {(($fsz / 2) & ~3)}] $last]] {
    binary scan $data @[expr {$foff + $rel}]iu want
    set a [expr {$vaddr + $rel}]
    if {$dry} {
      puts [format "ik64_jtag: xsdb> mrd -value 0x%08x   (expect 0x%08x)" $a $want]
    } else {
      if {[catch {rd32 $a} got]} { fail "verify: cannot read [format 0x%08x $a]: $got" }
      if {$got != $want} { fail [format "verify mismatch at 0x%08x: memory 0x%08x, ELF 0x%08x" $a $got $want] }
    }
    incr nwords
  }
}
puts "ik64_jtag: download verified ($nwords words in [llength $segs] segment(s))"

# --- tune bank (device 9); the core is still halted at its reset vector ----------
if {$bankfile ne ""} {
  lassign [bank_geometry] bank_base bank_size
  bank_write $bankfile $bank_img $bank_base $dry
}

# --- start at the ELF entry --------------------------------------------------
if {$dry} {
  puts "ik64_jtag: xsdb> rwr pc [format 0x%x $entry]"
  puts "ik64_jtag: xsdb> con"
  puts "ik64_jtag: PASS (dry run, nothing executed)"
  exit 0
}
if {[catch {rwr pc $entry} err]} { fail "rwr pc: $err" }
if {[catch {con} err]} { fail "con: $err" }
after 500
puts "ik64_jtag: state [state]"
puts "ik64_jtag: PASS"
exit 0
