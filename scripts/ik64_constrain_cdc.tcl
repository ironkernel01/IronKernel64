# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
# File: ik64_constrain_cdc.tcl
# Purpose: bound every IronKernel 64 clock-domain crossing built from the
#   ik64_common primitives by cell name, on a synthesized design. No blanket
#   asynchronous clock groups: each crossing gets the constraint its protocol
#   needs. Replaces the RTLNet script of the same job (same calling contract).
# Classes (cells found by name inside instances of the module(s) of the class):
#   sync      ik64_sync: false path to the D pin of every first stage
#             g_bit[*].sync_ff_reg[0] (ik64_pulse_sync and ik64_axil_cdc toggles
#             cross through ik64_sync and are covered here).
#   reset     ik64_reset_sync: false path to the CLR/PRE pins of pipe_reg[*].
#   gray      ik64_gray_sync: gray_src_reg -> gray_dst_ff_reg[0][*],
#             set_max_delay -datapath_only and set_bus_skew of one source period.
#   fifo      packet FIFO with Gray frame counters (modules named in
#             ik64_cdc_modules(fifo); none in ik64_common, so the default list is
#             ik64_packet_fifo and the class is optional). Registers s_gray ->
#             s_gray_m1 and m_gray -> m_gray_s1 as for gray; event toggles
#             events_s -> events_m1 set_max_delay -datapath_only of one source
#             period.
#   axil_cdc  ik64_axil_cdc: req_*_hold (to m_clk) and rsp_*_hold (to s_clk)
#             bundles, set_max_delay -datapath_only of the destination period.
#   report_cdc cannot recognize a Gray-coded bus (CDC-6) or a held bundle
#   (CDC-1, CDC-15); for exactly those registers of each instance the script
#   creates native report_cdc waivers (create_waiver -type CDC, user ik64) with
#   the protocol as the reason, so report_cdc lists them as waived and any other
#   finding still shows.
# Usage (after synth_design or open_checkpoint of a synthesized design):
#   set ::ik64_cdc_required {sync reset gray axil_cdc}  ;# classes this build must contain
#   set ::ik64_cdc_expect   {axil_cdc 3 gray 2}          ;# optional: exact instance counts
#   set ::ik64_cdc_report   <file>                       ;# optional: one line per instance
#   set ::ik64_cdc_extra_modules {sync rtlnet_sync ...}  ;# optional: more module names
#                                                        ;#   per class (e.g. cells of a
#                                                        ;#   netlist built from other RTL)
#   source scripts/ik64_constrain_cdc.tcl
#   The script prints one line per class, `ik64_cdc: <class> instances=<n>
#   crossings=<m> (required|optional)`, and `ik64_cdc: PASS` or
#   `ik64_cdc: FAIL ...`; it raises a Tcl error (the build turns it into an exit
#   code) when a required class matched nothing, when an instance lacks the
#   cells its constraint names (a renamed register would otherwise lose its
#   constraint silently), or when a class in ::ik64_cdc_expect has another
#   instance count. ::ik64_cdc_result holds the per-class counts as an
#   [array get] list {class {instances crossings} ...}.
#   Default required classes: all five (as the RTLNet script).
# Revision: 11-09-2026
#   * 11-09-2026: initial version (ik64-owned replacement for
#     the earlier RTLNet cell-name script; same classes, counting
#     and report format; module names per class are data, so a build may add the
#     names of other synchronizer modules).
# -----------------------------------------------------------------------------

namespace eval ik64_cdc {
  variable classes {sync reset gray fifo axil_cdc}
  variable modules
  array set modules {
    sync     {ik64_sync}
    reset    {ik64_reset_sync}
    gray     {ik64_gray_sync}
    fifo     {ik64_packet_fifo}
    axil_cdc {ik64_axil_cdc}
  }
  variable errors  {}
  variable counts
  array set counts {}
  variable detail  {}
  variable waivers 0
}

proc ik64_cdc::note {class inst n} {
  variable detail
  lappend detail [format "%-8s %4d  %s" $class $n $inst]
}

# Hierarchical instances of the modules of a class, uniquified or not.
proc ik64_cdc::instances {class} {
  variable modules
  set found {}
  set names $modules($class)
  if {[info exists ::ik64_cdc_extra_modules]} {
    foreach {c m} $::ik64_cdc_extra_modules { if {$c eq $class} { lappend names $m } }
  }
  foreach module $names {
    foreach c [get_cells -quiet -hierarchical -filter \
        "IS_PRIMITIVE == 0 && (REF_NAME == $module || ORIG_REF_NAME == $module || REF_NAME =~ ${module}__parameterized*)"] {
      lappend found $c
    }
  }
  return [lsort -unique $found]
}

# Flip-flop cells under one instance whose local name matches a regular expression.
proc ik64_cdc::cells_in {inst regexp} {
  set pat "^[string map {[ \\[ ] \\] . \\.} $inst]/$regexp\$"
  return [get_cells -quiet -hierarchical -regexp -filter {IS_SEQUENTIAL == 1} $pat]
}

# Period of the clock on a flip-flop's C pin ("" when none).
proc ik64_cdc::period_of {cell} {
  set clk [lindex [get_clocks -quiet -of_objects [get_pins -quiet $cell/C]] 0]
  if {$clk eq ""} { return "" }
  return [get_property PERIOD $clk]
}

proc ik64_cdc::fail {msg} {
  variable errors
  lappend errors $msg
  puts "ik64_cdc: ERROR $msg"
}

# Max delay (datapath only) plus bus skew of one source period, src -> dst.
proc ik64_cdc::bound_gray {inst src dst} {
  set per [period_of [lindex $src 0]]
  if {$per eq ""} { fail "$inst: no clock on [lindex $src 0]"; return 0 }
  set_max_delay -datapath_only -from $src -to $dst $per
  set_bus_skew -from $src -to $dst $per
  waive {CDC-6} $inst $src $dst \
    "ik64 Gray crossing: one bit changes per source clock; bounded by max delay and bus skew of one source period"
  return 1
}

# report_cdc waiver for a crossing whose protocol report_cdc cannot recognize.
# Scope: the source registers' clock pins to the destination cells' data pins of
# this one instance; every waiver carries its reason.
proc ik64_cdc::waive {ids inst from_cells to_cells reason} {
  variable waivers
  set from [get_pins -quiet -of_objects $from_cells -filter {REF_PIN_NAME == C}]
  set to   [get_pins -quiet -of_objects $to_cells -filter {DIRECTION == IN && IS_CLOCK == 0}]
  if {[llength $from] == 0 || [llength $to] == 0} { fail "$inst: no pins for the $ids waiver"; return }
  foreach id $ids {
    if {[catch {create_waiver -type CDC -id $id -from $from -to $to -user ik64 -description "$inst: $reason"} err]} {
      fail "$inst: create_waiver $id: $err"
    } else {
      incr waivers
    }
  }
}

proc ik64_cdc::do_sync {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances sync] {
    incr n_inst
    set first [cells_in $inst {g_bit\[[0-9]+\]\.sync_ff_reg\[0\]}]
    if {[llength $first] == 0} { fail "$inst: no g_bit\[*\].sync_ff_reg\[0\] cells"; continue }
    set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
    incr n_x [llength $first]
    note sync $inst [llength $first]
  }
  set counts(sync) [list $n_inst $n_x]
}

proc ik64_cdc::do_reset {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances reset] {
    incr n_inst
    set pipe [cells_in $inst {pipe_reg\[[0-9]+\]}]
    set pins [get_pins -quiet -of_objects $pipe -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
    if {[llength $pins] == 0} { fail "$inst: no pipe_reg\[*\] CLR/PRE pins"; continue }
    set_false_path -to $pins
    incr n_x [llength $pins]
    note reset $inst [llength $pins]
  }
  set counts(reset) [list $n_inst $n_x]
}

proc ik64_cdc::do_gray {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances gray] {
    incr n_inst
    set src [cells_in $inst {gray_src_reg(\[[0-9]+\])?}]
    set dst [cells_in $inst {gray_dst_ff_reg\[0\](\[[0-9]+\])?}]
    if {[llength $src] == 0 || [llength $dst] == 0} { fail "$inst: gray_src_reg / gray_dst_ff_reg\[0\] not found"; continue }
    if {[bound_gray $inst $src $dst]} { incr n_x [llength $dst]; note gray $inst [llength $dst] }
  }
  set counts(gray) [list $n_inst $n_x]
}

proc ik64_cdc::do_fifo {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances fifo] {
    incr n_inst
    set s_g  [cells_in $inst {s_gray_reg(\[[0-9]+\])?}]
    set s_m1 [cells_in $inst {s_gray_m1_reg(\[[0-9]+\])?}]
    set m_g  [cells_in $inst {m_gray_reg(\[[0-9]+\])?}]
    set m_s1 [cells_in $inst {m_gray_s1_reg(\[[0-9]+\])?}]
    set e_s  [cells_in $inst {events_s_reg(\[[0-9]+\])?}]
    set e_m1 [cells_in $inst {events_m1_reg(\[[0-9]+\])?}]
    if {[llength $s_g] == 0 || [llength $s_m1] == 0 || [llength $m_g] == 0 || [llength $m_s1] == 0} {
      fail "$inst: s_gray/s_gray_m1/m_gray/m_gray_s1 registers not found"; continue
    }
    if {[bound_gray $inst $s_g $s_m1]} { incr n_x [llength $s_m1] }
    if {[bound_gray $inst $m_g $m_s1]} { incr n_x [llength $m_s1] }
    if {[llength $e_s] > 0 && [llength $e_m1] > 0} {
      set per [period_of [lindex $e_s 0]]
      if {$per ne ""} {
        set_max_delay -datapath_only -from $e_s -to $e_m1 $per
        waive {CDC-6} $inst $e_s $e_m1 \
          "ik64 packet FIFO event toggles: independent single-bit toggles, each synchronized, bounded by one source period"
        incr n_x [llength $e_m1]
      }
    }
    note fifo $inst [expr {[llength $s_m1] + [llength $m_s1] + [llength $e_m1]}]
  }
  set counts(fifo) [list $n_inst $n_x]
}

proc ik64_cdc::do_axil_cdc {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances axil_cdc] {
    incr n_inst
    set req [cells_in $inst {req_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set rsp [cells_in $inst {rsp_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set ack [cells_in $inst {u_ack_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
    set rqs [cells_in $inst {u_req_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
    if {[llength $req] == 0 || [llength $rsp] == 0 || [llength $ack] == 0 || [llength $rqs] == 0} {
      fail "$inst: req_*_hold / rsp_*_hold / toggle synchronizers not found"; continue
    }
    # The request bundle's destination is m_clk (u_req_sync's clock), the
    # response bundle's destination is s_clk (u_ack_sync's clock).
    set m_clk [lindex [get_clocks -quiet -of_objects [get_pins $rqs/C]] 0]
    set s_clk [lindex [get_clocks -quiet -of_objects [get_pins $ack/C]] 0]
    if {$m_clk eq "" || $s_clk eq ""} { fail "$inst: clocks of the toggle synchronizers not found"; continue }
    set_max_delay -datapath_only -from $req -to $m_clk [get_property PERIOD $m_clk]
    set_max_delay -datapath_only -from $rsp -to $s_clk [get_property PERIOD $s_clk]
    set all [cells_in $inst {.*}]
    waive {CDC-1 CDC-15} $inst [concat $req $rsp] $all \
      "ik64_axil_cdc held bundle: req_*_hold/rsp_*_hold stay constant while the toggle crosses through ik64_sync and are read only after the synchronized toggle edge; bounded by max delay of the destination period"
    incr n_x [expr {[llength $req] + [llength $rsp]}]
    note axil_cdc $inst [expr {[llength $req] + [llength $rsp]}]
  }
  set counts(axil_cdc) [list $n_inst $n_x]
}

proc ik64_cdc::run {required expect} {
  variable classes
  variable counts
  variable errors
  variable detail
  variable waivers
  set errors {}
  set detail {}
  set waivers 0
  array unset counts
  foreach c $classes { do_$c }
  foreach c $classes {
    lassign $counts($c) n_inst n_x
    set req [expr {[lsearch -exact $required $c] >= 0 ? "required" : "optional"}]
    puts [format "ik64_cdc: %-8s instances=%-4d crossings=%-5d (%s)" $c $n_inst $n_x $req]
    if {$req eq "required" && $n_x == 0} { fail "class $c is required in this build and matched nothing" }
  }
  foreach r $required {
    if {[lsearch -exact $classes $r] < 0} { fail "unknown required class '$r'" }
  }
  foreach {c n} $expect {
    if {![info exists counts($c)]} { fail "unknown expected class '$c'"; continue }
    set got [lindex $counts($c) 0]
    if {$got != $n} { fail "class $c has $got instances, expected $n" } else { puts "ik64_cdc: $c instance count $got as expected" }
  }
  if {[info exists ::ik64_cdc_report]} {
    set fh [open $::ik64_cdc_report w]
    puts $fh "# class  constrained-cells  instance"
    foreach l $detail { puts $fh $l }
    close $fh
  }
  puts "ik64_cdc: $waivers report_cdc waiver(s) created (Gray buses, FIFO event toggles, held bundles)"
  set ::ik64_cdc_result [array get counts]
  if {[llength $errors] > 0} {
    puts "ik64_cdc: FAIL [llength $errors] error(s)"
    error "ik64_cdc: [join $errors {; }]"
  }
  puts "ik64_cdc: PASS"
}

if {![info exists ::ik64_cdc_required]} { set ::ik64_cdc_required $::ik64_cdc::classes }
if {![info exists ::ik64_cdc_expect]} { set ::ik64_cdc_expect {} }
ik64_cdc::run $::ik64_cdc_required $::ik64_cdc_expect
