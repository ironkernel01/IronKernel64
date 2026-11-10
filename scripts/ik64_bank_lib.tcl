# -----------------------------------------------------------------------------
# File: ik64_bank_lib.tcl
# Purpose: shared Tcl helpers that put the device 9 tune bank image into DDR3 over JTAG. Sourced by
#   ik64_jtag_load.tcl (bank loaded after the ELF download, before the core resumes) and by
#   ik64_load_bank.tcl (bank loaded into a running core). Runs under xsdb and, in dry mode, under
#   plain tclsh.
# Procs:
#   bank_geometry        -> {base size} from common/c64_platform.h (C64_PLAT_BANK_BASE / _SIZE), the
#                           one place that defines them
#   bank_read_image file -> the image bytes; checks the size against the bank and the "IK64BANK" magic
#   bank_write file img base dry -> dow -data of the file (or prints it) and verifies words read back:
#                           the 8 header words, then a stride of words through the image and the last word
# The image is validated by the firmware again at every OPEN (magic, version, bounds, CRCs), so this
#   side only guards against a wrong file and a failed transfer.
# Revision: 11-10-2026
#   * 11-10-2026: initial version.
# -----------------------------------------------------------------------------
set BANK_VERIFY_POINTS 12
set BANK_LIB_DIR [file dirname [file normalize [info script]]]

proc bank_geometry {} {
  global BANK_LIB_DIR
  set hdr [file normalize [file join $BANK_LIB_DIR .. common c64_platform.h]]
  if {![file exists $hdr]} { fail "bank: $hdr not found" }
  set fh [open $hdr r]
  set txt [read $fh]
  close $fh
  if {![regexp {C64_PLAT_BANK_BASE\s+\(0x([0-9A-Fa-f]+)u\)} $txt -> b] ||
      ![regexp {C64_PLAT_BANK_SIZE\s+\(0x([0-9A-Fa-f]+)u\)} $txt -> s]} {
    fail "bank: C64_PLAT_BANK_BASE/SIZE not found in $hdr"
  }
  return [list [expr {"0x$b" + 0}] [expr {"0x$s" + 0}]]
}

proc bank_read_image {file} {
  lassign [bank_geometry] base size
  if {![file exists $file]} { fail "bank image not found: $file" }
  set n [file size $file]
  if {$n < 32 || $n > $size} { fail "bank image $file is $n bytes; the bank holds 32 .. $size" }
  set fh [open $file rb]
  set img [read $fh]
  close $fh
  if {[string range $img 0 7] ne "IK64BANK"} { fail "bank image $file has no IK64BANK magic" }
  return $img
}

proc bank_write {file img base dry} {
  global BANK_VERIFY_POINTS
  set n [string length $img]
  set words [expr {$n / 4}]
  puts "ik64_jtag: bank [format 0x%08x $base], $n bytes"
  if {$dry} {
    puts "ik64_jtag: xsdb> dow -data $file [format 0x%08x $base]"
  } elseif {[catch {dow -data $file $base} err]} {
    fail "bank dow: $err"
  }
  # Verify: header words, then evenly spread words, then the last whole word.
  set idx {}
  for {set i 0} {$i < 8 && $i < $words} {incr i} { lappend idx $i }
  set stride [expr {max(1, $words / $BANK_VERIFY_POINTS)}]
  for {set i 8} {$i < $words} {incr i $stride} { lappend idx $i }
  if {$words > 0} { lappend idx [expr {$words - 1}] }
  set checked 0
  foreach i [lsort -unique -integer $idx] {
    binary scan $img @[expr {$i * 4}]iu want
    set a [expr {$base + $i * 4}]
    if {$dry} {
      puts [format "ik64_jtag: xsdb> mrd -value 0x%08x   (expect 0x%08x)" $a $want]
    } else {
      if {[catch {set got [expr {[string trim [mrd -value $a]] + 0}]} err]} { fail "bank verify: cannot read [format 0x%08x $a]: $err" }
      if {$got != $want} { fail [format "bank verify mismatch at 0x%08x: memory 0x%08x, image 0x%08x" $a $got $want] }
    }
    incr checked
  }
  puts "ik64_jtag: bank verified ($checked words)"
}
