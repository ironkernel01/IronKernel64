# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
# -----------------------------------------------------------------------------
# File: build_bitstream.tcl
# Purpose: scripted, reproducible Vivado 2026.1 non-project build of the
#   IronKernel 64 board top c64_top: block design from Tcl, DDR3 controller IP,
#   synthesis, CDC constraints, implementation, gated reports, bitstream, the
#   MicroBlaze memory map (MMI) for updatemem and the fixed hardware platform.
# Overview:
#   * Paths derive from this script's location (fpga/), so the build survives
#     tree moves. Outputs go to build/fpga/ (build/fpga/<tag>/ with a tag).
#   * Steps: block design c64_cpu (fpga/bd/c64_bd.tcl) under build/fpga/bd,
#     output products with global synthesis; the AMD IP of the DDR3 path under
#     build/fpga/ip: the memory controller ik64_ddr_mig (fpga/ip/ik64_ddr_mig.tcl,
#     ik64_ddr_mig_create) and the AXI clock converter ik64_ddr_cc
#     (fpga/ip/ik64_ddr_cc.tcl, ik64_ddr_cc_create); RTL through fpga/c64_top.f
#     (the closed network core netlist fpga/netlist/ik64_net_core.dcp is read with
#     read_checkpoint before synthesis and becomes the cell u_net);
#     fpga/c64.xdc; synth_design (top c64_top, xc7a200tsbg484-1, generics BUILD_ID
#     and BUILD_DIRTY); fpga/constraints/ik64_rgmii.xdc; the ik64 cell-name CDC constraints (scripts/ik64_constrain_cdc.tcl);
#     opt/place/phys_opt/route; reports; gates; write_bitstream; write_mem_info;
#     write_hw_platform -fixed (the input of both firmware BSP flows); build_info.txt.
#   * Filelists: relative paths resolve against the repository root, except in
#     a filelist inside a copied third-party tree (an ancestor directory with
#     SOURCE.txt), which resolves against that tree's root (as
#     scripts/ik64_run_sim.ps1 does).
#   * reDIP-SID ($readmemh .hex tables and `include .svh files) lives in
#     third_party/redip-sid/ik64; the +incdir in fpga/c64_top.f becomes
#     synth_design -include_dirs, which is where Vivado finds them.
#   * Expected crossing instances in the top (a change fails the build until reviewed;
#     the network core's own crossings are constrained inside its netlist and are not
#     counted here):
#     fifo 0: the DDR3 clock crossing is the AMD axi_clock_converter IP (its own
#       constraints), so the packet-FIFO class of ik64_constrain_cdc.tcl matches nothing
#       (the class is optional);
#     axil_cdc 1: u_sid_cdc, the SID register slot cpu_clk -> sid_clk (the DDR3
#       arbiter register port is gone with the arbiter);
#     gray 2: u_video frame and line counters.
#     The audio sample FIFO and the SID stream FIFO (u_sid_strm) are
#     xpm_fifo_async, which the CDC script does not count as a class; their
#     crossings carry the XPM macro's own constraints.
#     The RGMII interface timing (fpga/constraints/ik64_rgmii.xdc) is read after
#     synthesis because it creates the forwarded clock rgmii_txc on the eth_txck pad from
#     the clock pin of the netlist's TXC ODDR (found through the clk125_90 net) and the
#     output delays refer to it. The netlist carries the IODELAY group and its own crossing
#     constraints (clock names resolved through its ports, so they hold under the top's
#     derived clock names).
#     One report_cdc waiver is added here, for the AMD axi_clock_converter (CDC-15, vendor
#     FIFO read register); see the comment at the waiver.
#   * Gates (each its own exit code; nothing is written past a failed gate):
#       99 bad arguments            11 missing source, filelist or XDC
#       12 block design or IP       10 synthesis error or critical warning
#       13 CDC constraint failure   25 opt_design   26 place_design
#       30 route_design             20 timing: setup WNS, hold WHS or pulse
#                                      width below 0, or any failing endpoint
#       21 utilization above 80 %   22 check_timing: unclocked or
#                                      unconstrained endpoints, loops
#       23 user asynchronous reset endpoints or latches outside the named
#          exceptions (ik64_reset_sync, the network core netlist u_net, vendor block
#          design u_cpu, vendor DDR3 IP, the XPM macros of the audio and SID stream FIFOs)
#       24 critical warnings during implementation
#       27 report_cdc Critical/Warning finding, or a methodology finding
#          (Warning or worse) without a waiver in this script
#       40 write_bitstream          41 write_mem_info
#       42 write_hw_platform
#       14 third-party setup check failed (python -I tools/setup_third_party.py --check;
#          the script's first step)
#       16 network core netlist missing or not merged into u_net
#   * Reports in build/fpga/reports: utilization post-synth and post-route,
#     timing summary, CDC (report_cdc -details), methodology, DRC,
#     check_timing, clock networks, clock interaction, I/O, failing paths.
# Usage: vivado -mode batch -source fpga/build_bitstream.tcl -tclargs
#          [build_id <8 hex>] [dirty 0|1] [tag <name>]   (pairs as "name value" or name=value)
#   Run through the Vivado slot wrapper (one build needs 4.5-5 GB):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_vivado.ps1 `
#     -Tcl <repo>/fpga/build_bitstream.tcl -Log <repo>/build/fpga/build.log
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
#   * 11-09-2026: SID sources and tables via fpga/c64_top.f (+incdir); no gate changed.
#   * 11-09-2026: Phase 4 network (u_mac, u_mdio, u_protocol): RGMII XDC after synthesis; CDC expectation fifo 12,
#     axil_cdc 6, gray 8 (each count named in the header); TIMING-47 waiver for the RGMII same-edge false paths
#     (RTLNet's own waiver); no existing gate loosened.
#   * 11-09-2026: SYNTH-5 waiver for the c64_oled framebuffer (distributed RAM by design); no gate loosened.
#   * 11-09-2026: SID on sid_clk: CDC expectation axil_cdc 2 (fifo stays 5, XPM FIFOs are not a class); setup guard (exit 14);
#     u_sid_strm/u_fifo joins the async-reset exceptions.
#   * 11-10-2026: QSPI boot: fpga/constraints/ik64_qspi.xdc is read after synthesis (generated SCK, flash pin timing).
#   * 11-10-2026: release split: no RTLNet source. The network core is the closed netlist u_net
#     (read_checkpoint before synthesis, new gate 16 if the netlist is missing or not merged); ik64_rgmii.xdc replaces RTLNet's
#     RGMII constraints; ik64_constrain_cdc.tcl replaces the RTLNet script (expectation fifo 0,
#     axil_cdc 1, gray 2); the DDR3 path is AMD axi_clock_converter + MIG (ik64_ddr_cc, ik64_ddr_mig), MIG
#     paths u_ddr/u_mig/u_ik64_ddr_mig_mig; ik64_reset_sync in the reset-sync inventory. Every gate kept.
#     One new waiver: report_cdc CDC-15 inside the AMD axi_clock_converter (scoped to its FIFO RAM and output registers).
#   * 11-10-2026: required TIMING-18 waivers for the nine QSPI flash ports (delays given against qspi_sck on the STARTUPE2
#     USRCCLKO pin, which the check does not relate to sys_clk); no gate loosened.
# -----------------------------------------------------------------------------

# Script-relative roots.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set REPO       [file normalize [file join $SCRIPT_DIR ".."]]
set NETLIST    [file join $REPO fpga netlist]
set BUILD_DIR  [file join $REPO build fpga]
set RPT_DIR    [file join $BUILD_DIR reports]
set PART       xc7a200tsbg484-1
set TOP        c64_top
set UTIL_LIMIT 80.0

# Setup guard: the pinned third-party trees must match tools/third_party.json.
if {[catch {exec python -I [file join $REPO tools setup_third_party.py] --check 2>@1} guard_out]} {
  puts $guard_out
  puts "ik64_build: FAIL (14) third-party setup check failed; run: python -I tools/setup_third_party.py"
  exit 14
}

proc nv_exit {code msg} {
  puts "ik64_build: FAIL ($code) $msg"
  set crit [get_msg_config -count -severity {CRITICAL WARNING}]
  puts "ik64_build: critical warnings so far: $crit"
  exit $code
}

# ---------------------------------------------------------------------------
# Arguments: "name value" pairs, name=value, or comma-separated lists of them
# (vivado.bat splits '=' and ',' into separate arguments).
# ---------------------------------------------------------------------------
set opt(build_id) ""
set opt(dirty)    ""
set opt(tag)      ""
set toks {}
foreach a $argv { foreach t [split $a ",="] { if {$t ne ""} { lappend toks $t } } }
if {[llength $toks] % 2 != 0} { puts "usage: \[build_id XXXXXXXX\] \[dirty 0|1\] \[tag name\]"; exit 99 }
foreach {k v} $toks {
  set k [string tolower $k]
  if {![info exists opt($k)]} { puts "ik64_build: unknown argument '$k'"; exit 99 }
  set opt($k) $v
}
if {$opt(tag) ne ""} {
  if {![regexp {^[A-Za-z0-9_]{1,16}$} $opt(tag)]} { puts "ik64_build: bad tag '$opt(tag)'"; exit 99 }
  set BUILD_DIR [file join $REPO build fpga $opt(tag)]
  set RPT_DIR   [file join $BUILD_DIR reports]
}

# Build identity from git unless given.
if {$opt(build_id) eq ""} {
  if {[catch {exec git -C $REPO rev-parse --short=8 HEAD} h]} { set h 00000000 }
  set opt(build_id) [string trim $h]
}
if {$opt(dirty) eq ""} {
  if {[catch {exec git -C $REPO status --porcelain} st]} { set st "?" }
  set opt(dirty) [expr {[string trim $st] eq "" ? 0 : 1}]
}
if {![regexp {^[0-9a-fA-F]{1,8}$} $opt(build_id)]} { puts "ik64_build: bad build_id '$opt(build_id)'"; exit 99 }
if {$opt(dirty) ni {0 1}} { puts "ik64_build: dirty must be 0 or 1"; exit 99 }
set BUILD_ID_HEX [format %08x [scan $opt(build_id) %x]]
puts "ik64_build: repo $REPO"
puts "ik64_build: build_id $BUILD_ID_HEX dirty $opt(dirty) part $PART"

file mkdir $BUILD_DIR
file delete -force $RPT_DIR [file join $BUILD_DIR bd] [file join $BUILD_DIR ip]
file mkdir $RPT_DIR

# ---------------------------------------------------------------------------
# Filelist reader: nested -f, +incdir+, comments; each source read once;
# third-party trees (SOURCE.txt) resolve against their own root.
# ---------------------------------------------------------------------------
set ::incdirs {}
set ::read_files {}
proc filelist_root {full} {
  set dir [file dirname $full]
  while {[string length $dir] > [string length $::REPO]} {
    if {[file exists [file join $dir SOURCE.txt]]} { return $dir }
    set dir [file dirname $dir]
  }
  return $::REPO
}
proc read_filelist {root path} {
  set full [file normalize [file join $root $path]]
  if {![file exists $full]} { nv_exit 11 "filelist not found: $path" }
  set root [filelist_root $full]
  set f [open $full r]
  set lines [split [read $f] "\n"]
  close $f
  foreach raw $lines {
    set line [string trim [regsub {(#|//).*$} $raw ""]]
    if {$line eq ""} continue
    if {[regexp {^-f\s+(.+)$} $line -> sub]} { read_filelist $root [string trim $sub]; continue }
    if {[regexp {^\+incdir\+(.+)$} $line -> d]} {
      set dd [file normalize [file join $root $d]]
      if {[lsearch -exact $::incdirs $dd] < 0} { lappend ::incdirs $dd }
      continue
    }
    if {[regexp {^\+define\+} $line]} continue
    set src [file normalize [file join $root $line]]
    if {[lsearch -exact $::read_files $src] >= 0} continue
    if {![file exists $src]} { nv_exit 11 "source not found: $line (from $path)" }
    lappend ::read_files $src
    read_verilog -sv $src
  }
}

# ---------------------------------------------------------------------------
# Block design.
# ---------------------------------------------------------------------------
create_project -in_memory -part $PART
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
if {[catch {
  source [file join $REPO fpga bd c64_bd.tcl]
  set bd_file [c64_bd_create [file join $BUILD_DIR bd]]
  set_property synth_checkpoint_mode None [get_files $bd_file]
  generate_target all [get_files $bd_file]
} err]} { nv_exit 12 "block design: $err" }

# ---------------------------------------------------------------------------
# DDR3 path IP: the MIG memory controller (generated from fpga/ip/ik64_ddr_mig.prj)
# and the AXI clock converter (cpu_clk -> ui_clk).
# ---------------------------------------------------------------------------
if {[catch {
  source [file join $REPO fpga ip ik64_ddr_mig.tcl]
  ik64_ddr_mig_create [file join $BUILD_DIR ip mig]
} err]} { nv_exit 12 "DDR3 controller IP: $err" }
if {[catch {
  source [file join $REPO fpga ip ik64_ddr_cc.tcl]
  ik64_ddr_cc_create [file join $BUILD_DIR ip cc]
} err]} { nv_exit 12 "DDR3 clock converter IP: $err" }

# ---------------------------------------------------------------------------
# RTL and constraints.
# ---------------------------------------------------------------------------
# The network core is a netlist: read_checkpoint (before synth_design) makes it the definition of the
# module ik64_net_core that c64_top instantiates as u_net; the stub fpga/netlist/ik64_net_core_stub.sv
# documents the ports and is not read here (a black-box stub would raise a critical warning).
set net_dcp [file join $NETLIST ik64_net_core.dcp]
if {![file exists $net_dcp]} { nv_exit 16 "network core netlist not found: $net_dcp" }
if {[catch {read_checkpoint $net_dcp} err]} { nv_exit 16 "reading the network core netlist: $err" }
read_filelist $REPO fpga/c64_top.f
set xdc [file join $REPO fpga c64.xdc]
if {![file exists $xdc]} { nv_exit 11 "XDC not found: $xdc" }
read_xdc $xdc

# ---------------------------------------------------------------------------
# Synthesis.
# ---------------------------------------------------------------------------
set synth_args [list -top $TOP -part $PART -include_dirs $::incdirs \
  -generic BUILD_ID=32'h$BUILD_ID_HEX -generic BUILD_DIRTY=1'b$opt(dirty)]
if {[catch {synth_design {*}$synth_args} err]} { nv_exit 10 "synth_design: $err" }
set crit_synth [get_msg_config -count -severity {CRITICAL WARNING}]
if {$crit_synth > 0} { nv_exit 10 "$crit_synth critical warning(s) up to synthesis (see the log)" }
report_utilization -file [file join $RPT_DIR post_synth_utilization.rpt]

# Network core: the netlist was read as a source before synthesis (it resolves the module
# ik64_net_core of c64_top); it must now sit inside u_net. It carries its own IODELAY group
# and every crossing constraint of the core.
set n_net [llength [get_cells -quiet -hierarchical -filter {NAME =~ u_net/*}]]
puts "ik64_build: network core netlist merged, $n_net cells inside u_net"
if {$n_net == 0} { nv_exit 16 "u_net holds no cells after synthesis (netlist not merged)" }
write_checkpoint -force [file join $BUILD_DIR post_synth.dcp]

# CDC-8 on the MIG reset synchronizers: ASYNC_REG on the first two
# stages of each chain; a missing target fails the build.
set mig_re_list {
  {^u_ddr/u_mig/u_ik64_ddr_mig_mig/u_iodelay_ctrl/rst_ref_sync_r_reg\[0\]\[[01]\]$}
  {^u_ddr/u_mig/u_ik64_ddr_mig_mig/u_ddr3_infrastructure/rstdiv0_sync_r_reg\[[01]\]$}
}
set mig_fdpe [get_cells -quiet -hierarchical -filter {REF_NAME == FDPE}]
foreach re $mig_re_list {
  set cells {}
  foreach c $mig_fdpe { if {[regexp -- $re $c]} { lappend cells $c } }
  if {[llength $cells] == 0} { nv_exit 13 "MIG ASYNC_REG target missing: $re" }
  set_property ASYNC_REG TRUE $cells
  puts "ik64_build: ASYNC_REG set on [llength $cells] MIG reset synchronizer cells ($re)"
}

# RGMII interface timing (pin level; names the ports and the netlist's rgmii_txc clock).
set rgmii_xdc [file join $REPO fpga constraints ik64_rgmii.xdc]
if {![file exists $rgmii_xdc]} { nv_exit 11 "XDC not found: $rgmii_xdc" }
if {[catch {read_xdc $rgmii_xdc} err]} { nv_exit 13 "RGMII constraints: $err" }

# QSPI flash pin timing (generated SCK on the STARTUPE2 inside the Quad SPI IP).
set qspi_xdc [file join $REPO fpga constraints ik64_qspi.xdc]
if {![file exists $qspi_xdc]} { nv_exit 11 "XDC not found: $qspi_xdc" }
if {[catch {read_xdc $qspi_xdc} err]} { nv_exit 13 "QSPI constraints: $err" }

# Crossing constraints by cell name (counts in the header).
set ::ik64_cdc_required {sync reset gray axil_cdc}
set ::ik64_cdc_expect   {fifo 0 axil_cdc 1 gray 2}
set ::ik64_cdc_report   [file join $RPT_DIR cdc_instances.txt]
if {[catch {source [file join $REPO scripts ik64_constrain_cdc.tcl]} err]} { nv_exit 13 "CDC constraints: $err" }

# report_cdc waiver for the AMD AXI clock converter (u_ddr_cdc/u_cc): the IP's write-data FIFO (fifo_generator, distributed
# RAM) is read through a register behind the FIFO read enable, which report_cdc flags as CDC-15 (clock enable controlled CDC
# structure, one Warning). It is vendor-generated and constrained by the IP's own XDC (set_max_delay -datapath_only,
# set_bus_skew on its Gray pointers); no user logic is inside. Scope: the RAM clock pins to the output-register D pins of the
# converter's FIFO memories only, rule CDC-15 only; a missing scope fails the build.
set cc_ip u_ddr_cdc/u_cc/inst/gen_clock_conv.gen_async_conv.asyncfifo_axi
set cc_from [get_pins -quiet -hierarchical -filter "NAME =~ $cc_ip/*dm_gen.dm/RAM_reg_*/CLK"]
set cc_to   [get_pins -quiet -hierarchical -filter "NAME =~ $cc_ip/*dm_gen.dm/*dout_i_reg*/D"]
if {[llength $cc_from] == 0 || [llength $cc_to] == 0} { nv_exit 13 "AXI clock converter CDC-15 waiver: scope not found ([llength $cc_from] / [llength $cc_to] pins)" }
create_waiver -type CDC -id CDC-15 -user ik64 -from $cc_from -to $cc_to   -description "AMD axi_clock_converter (fifo_generator) internal: distributed-RAM output register behind the FIFO read enable; vendor IP with its own constraints"
puts "ik64_build: CDC-15 waiver for the AXI clock converter: [llength $cc_from] RAM clock pins, [llength $cc_to] output register pins"

# ---------------------------------------------------------------------------
# Implementation (timing-driven directives for the MicroBlaze V caches).
# ---------------------------------------------------------------------------
if {[catch {opt_design} err]}   { nv_exit 25 "opt_design: $err" }
if {[catch {place_design -directive Explore} err]} { nv_exit 26 "place_design: $err" }
if {[catch {phys_opt_design -directive AggressiveExplore} err]} { nv_exit 26 "phys_opt_design: $err" }
if {[catch {route_design -directive Explore} err]} { nv_exit 30 "route_design: $err" }
set wns_pr [get_property SLACK [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]]
puts "ik64_build: post-route WNS $wns_pr ns"
if {$wns_pr ne "" && $wns_pr < 0} {
  if {[catch {phys_opt_design -directive AggressiveExplore} err]} { nv_exit 30 "post-route phys_opt_design: $err" }
  set wns_pr [get_property SLACK [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]]
  puts "ik64_build: post-route phys_opt WNS $wns_pr ns"
}
write_checkpoint -force [file join $BUILD_DIR post_route.dcp]

# ---------------------------------------------------------------------------
# Reports.
# ---------------------------------------------------------------------------
report_utilization        -file [file join $RPT_DIR post_route_utilization.rpt]
report_utilization -hierarchical -file [file join $RPT_DIR post_route_utilization_hier.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $RPT_DIR post_route_timing_summary.rpt]
report_cdc -details       -file [file join $RPT_DIR post_route_cdc.rpt]
report_methodology        -file [file join $RPT_DIR post_route_methodology.rpt]
report_drc                -file [file join $RPT_DIR post_route_drc.rpt]
report_clock_networks     -file [file join $RPT_DIR post_route_clock_networks.rpt]
report_clock_interaction  -file [file join $RPT_DIR post_route_clock_interaction.rpt]
report_io                 -file [file join $RPT_DIR post_route_io.rpt]
set ct [check_timing -verbose -return_string]
set fh [open [file join $RPT_DIR post_route_check_timing.rpt] w]; puts $fh $ct; close $fh

# ---------------------------------------------------------------------------
# Gate: timing (queried from the design, not parsed from a report).
# ---------------------------------------------------------------------------
set wns [get_property SLACK [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -hold  -max_paths 1 -nworst 1] 0]]
if {$wns eq ""} { nv_exit 20 "no setup timing path found (unconstrained design?)" }
if {$whs eq ""} { nv_exit 20 "no hold timing path found" }
set fail_setup [llength [get_timing_paths -setup -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
set fail_hold  [llength [get_timing_paths -hold  -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
set wpws ""
set fail_pw 0
set ts [report_timing_summary -no_detailed_paths -no_check_timing -return_string]
set ts_lines [split $ts "\n"]
for {set i 0} {$i < [llength $ts_lines]} {incr i} {
  if {[string match "*WNS(ns)*WPWS(ns)*" [lindex $ts_lines $i]]} {
    set nums [regexp -all -inline {\S+} [lindex $ts_lines [expr {$i + 2}]]]
    if {[llength $nums] >= 12} { set wpws [lindex $nums 8]; set fail_pw [lindex $nums 10] }
    break
  }
}
puts "ik64_build: timing WNS $wns ns ($fail_setup failing setup endpoints), WHS $whs ns ($fail_hold failing hold endpoints), WPWS $wpws ns ($fail_pw failing pulse-width endpoints)"
if {$wpws eq ""} { nv_exit 20 "pulse-width summary not found in report_timing_summary" }
if {$wns < 0 || $whs < 0 || $fail_setup > 0 || $fail_hold > 0 || $wpws < 0 || $fail_pw > 0} {
  report_timing -setup -max_paths 50 -nworst 1 -slack_lesser_than 0 -file [file join $RPT_DIR failing_setup.rpt]
  report_timing -hold  -max_paths 50 -nworst 1 -slack_lesser_than 0 -file [file join $RPT_DIR failing_hold.rpt]
  nv_exit 20 "timing not met"
}

# ---------------------------------------------------------------------------
# Gate: check_timing (every endpoint clocked and constrained, no loops).
# ---------------------------------------------------------------------------
set ct_fail {}
foreach {all name n} [regexp -all -inline {checking (\S+) \((\d+)\)} $ct] {
  if {$name in {no_clock unconstrained_internal_endpoints loops latch_loops multiple_clock generated_clocks} && $n > 0} {
    lappend ct_fail "$name=$n"
  }
}
if {[llength $ct_fail] > 0} { nv_exit 22 "check_timing: [join $ct_fail {, }]" }

# ---------------------------------------------------------------------------
# Gate: utilization ceiling (LUT, FF, block RAM, DSP).
# ---------------------------------------------------------------------------
set ur [report_utilization -return_string]
set util_summary {}
foreach {label key} {"Slice LUTs" lut "Slice Registers" ff "Block RAM Tile" bram "DSPs" dsp} {
  set found 0
  foreach line [split $ur "\n"] {
    set f [split $line "|"]
    if {[llength $f] < 7} continue
    if {[string trim [string trimright [string trim [lindex $f 1]] "*"]] ne $label} continue
    set used [string trim [lindex $f 2]]
    set pct  [string trim [lindex $f end-1]]
    if {![string is double -strict $pct]} continue
    lappend util_summary "$key=$used ($pct%)"
    if {$pct > $UTIL_LIMIT} { nv_exit 21 "$label at $pct % (limit $UTIL_LIMIT %)" }
    set found 1
    break
  }
  if {!$found} { nv_exit 21 "utilization row '$label' not found" }
}
puts "ik64_build: utilization [join $util_summary {, }]"

# ---------------------------------------------------------------------------
# Gate: asynchronous clear/preset endpoints and latches. Named exceptions:
# ik64_reset_sync instances (u_rst_*), the closed network core netlist (u_net: the
# reset synchronizers of the core's own clock domains), the vendor block design (u_cpu),
# the vendor DDR3 controller IP (u_ddr/u_mig) and the XPM macro of the
# audio sample FIFO (u_audio/u_fifo) and the SID stream FIFO (u_sid_strm/u_fifo),
# both xpm_fifo_async internal reset logic.
# ---------------------------------------------------------------------------
set latches [get_cells -quiet -hierarchical -filter {PRIMITIVE_SUBGROUP == latch || REF_NAME =~ LD*}]
set n_async_rs 0
set n_async_bd 0
set n_async_mig 0
set n_async_xpm 0
set n_async_net 0
set n_async_cc 0
set bad_async {}
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME == FDCE || REF_NAME == FDPE}] {
  set p [get_pins -quiet $c/CLR]
  if {$p eq ""} { set p [get_pins -quiet $c/PRE] }
  set net [get_nets -quiet -of_objects $p]
  if {$net ne "" && [get_property TYPE $net] in {GROUND POWER}} continue
  set parent [get_cells -quiet [get_property PARENT $c]]
  set pref ""
  if {$parent ne ""} { set pref "[get_property REF_NAME $parent] [get_property ORIG_REF_NAME $parent]" }
  if {[regexp {/pipe_reg\[[0-9]+\]$} $c] && [regexp {(^| )ik64_reset_sync} $pref]} { incr n_async_rs; continue }
  if {[string match "u_cpu/*" $c]} { incr n_async_bd; continue }
  if {[string match "u_net/*" $c]} { incr n_async_net; continue }
  if {[string match "u_ddr/u_mig/*" $c]} { incr n_async_mig; continue }
  if {[string match "u_ddr_cdc/u_cc/*" $c]} { incr n_async_cc; continue }
  if {[string match "u_audio/u_fifo/*" $c] || [string match "u_sid_strm/u_fifo/*" $c]} { incr n_async_xpm; continue }
  lappend bad_async $c
}
puts "ik64_build: asynchronous reset endpoints: ik64_reset_sync $n_async_rs, network core netlist $n_async_net, vendor block design $n_async_bd, vendor memory controller $n_async_mig, vendor AXI clock converter $n_async_cc, XPM audio and SID stream FIFOs $n_async_xpm, other [llength $bad_async]; latches [llength $latches]"
if {[llength $latches] > 0} { nv_exit 23 "latches: [lrange $latches 0 9]" }
if {[llength $bad_async] > 0} { nv_exit 23 "user asynchronous reset endpoints: [lrange $bad_async 0 9]" }

# ---------------------------------------------------------------------------
# Gate: report_cdc and report_methodology findings. CDC: no Critical or
# Warning finding at all. Methodology: every Warning or worse must match a
# waiver below (rule, object pattern, rationale); matched waivers are printed.
# ---------------------------------------------------------------------------
set cdc_bad {}
set cdc_ids 0
set cdc_waived {}
foreach line [split [report_cdc -details -return_string] "\n"] {
  if {[regexp {^(CDC-[0-9]+)\s+(Critical|Warning|Info)\s+([0-9]+)\s} $line -> id sev cnt]} {
    incr cdc_ids
    if {$sev ne "Info"} { lappend cdc_bad "$id $sev x$cnt" }
  } elseif {[regexp {^(CDC-[0-9]+)\s+([0-9]+)\s*$} $line -> id cnt]} {
    lappend cdc_waived "$id x$cnt"
  }
}
puts "ik64_build: report_cdc: $cdc_ids finding classes, waived by ik64_constrain_cdc.tcl and the netlist: [expr {[llength $cdc_waived] ? [join $cdc_waived {, }] : {none}}]"
if {$cdc_ids == 0} { nv_exit 27 "report_cdc ID summary not found (format changed?)" }
if {[llength $cdc_bad] > 0} { nv_exit 27 "report_cdc findings: [join $cdc_bad {, }]" }

# Waiver test for LUTAR-1 on the reset ANDs (rst_arstn, pix_arstn, aud_arstn): the LUT drives only
# CLR pins of ik64_reset_sync chains.
proc nv_waive_reset_and {desc} {
  if {![regexp {^LUT cell u_rst_[a-z0-9_]+/pipe\[[0-9]+\]_i_1(__[0-9]+)?,} $desc]} { return 0 }
  set pins [regexp -all -inline {\S+/(?:CLR|PRE)\M} $desc]
  if {[llength $pins] == 0} { return 0 }
  foreach p $pins {
    if {![regexp {^u_rst_[a-z0-9_]+/pipe_reg\[[0-9]+\]/CLR$} [string trimright $p ",."]]} { return 0 }
  }
  return 1
}
# Waiver test for LUTAR-1 in the vendor MIG.
proc nv_waive_mig_lutar {desc} {
  set m {u_ddr/u_mig/u_ik64_ddr_mig_mig}
  set lut_re {/u_iodelay_ctrl/rstdiv2_sync_r\[11\]_i_1, }
  if {![regexp "^LUT cell ${m}${lut_re}" $desc]} { return 0 }
  set pins [regexp -all -inline {\S+/(?:CLR|PRE)\M} $desc]
  if {[llength $pins] == 0} { return 0 }
  foreach p $pins {
    if {![regexp "^$m/u_ddr3_infrastructure/rstdiv0_sync_r1_reg_rep(__\[0-9\]+)?/PRE\$" [string trimright $p ",."]]} { return 0 }
  }
  return 1
}
# Waivers: {rule test rationale ?required?}.
set meth_waivers {
  {LUTAR-1 {^LUT cell u_cpu/\S+, with 2 or more inputs, drives asynchronous preset/clear pin\(s\) u_cpu/}
           {vendor MDM JTAG control logic inside the MicroBlaze block design}}
  {LUTAR-1 proc:nv_waive_reset_and
           {rst_arstn / pix_arstn / aud_arstn = button AND MMCM locked into the ik64_reset_sync chains only}}
  {TIMING-9 {.}
           {report_cdc (gated above: no Critical/Warning) shows every crossing synchronized; the asynchronous groups are the MDM BSCAN clocks of the vendor IP}}
  {TIMING-47 {^A False Path timing constraint is set between synchronous clocks rgmii_rxc_v and rgmii_rxc }
           {RGMII same-edge capture: the opposite-edge setup and same-edge hold pairs of the DDR input describe no capture (fpga/constraints/ik64_rgmii.xdc)}}
  {LUTAR-1 proc:nv_waive_mig_lutar
           {AMD MIG IP u_ddr/u_mig: vendor-generated reset logic, LUT u_iodelay_ctrl/rstdiv2_sync_r[11]_i_1 drives the PRE pins of the replicated rstdiv0_sync_r1_reg_rep cells of u_ddr3_infrastructure (reset synchronizer, no user logic)}
           {match}}
  {PDRC-190 {^The FDRE cell u_ddr/u_mig/u_ik64_ddr_mig_mig/temp_mon_enabled\.u_tempmon/device_temp_sync_r5_reg\[([0-9]|1[01])\] in site }
            {AMD MIG IP u_ddr/u_mig: vendor-generated temperature monitor, cells temp_mon_enabled.u_tempmon/device_temp_sync_r5_reg[0..11] (XADC temperature synchronizer); the placement is fixed by the vendor IP}
            {0 1 2 3 4 5 6 7 8 9 10 11}}
  {SYNTH-6 {^The timing for the instance (u_sid/mem_reg|u_sid/u_sid/filter/w0_T_lsl17_6581_reg|u_sid/u_sid/waveform/p_t_6581_reg|u_sid/u_sid/waveform/ps__6581_reg), implemented as a RAM block, might be sub-optimal as no output register was merged into the block\.}
           {sid_clk domain (50 MHz), post-route WNS of the domain above 6 ns: the reDIP-SID table ROMs (upstream, unmodified, read with zero added latency by design) and the sid_player write FIFO RAM, whose output register would add a read cycle with no timing need}
           {u_sid/mem_reg u_sid/u_sid/filter/w0_T_lsl17_6581_reg u_sid/u_sid/waveform/p_t_6581_reg u_sid/u_sid/waveform/ps__6581_reg}}
  {SYNTH-5 {^The instance u_oled/g_fb\[[0-3]\]\.mem_reg_[0-9_]+ is implemented as distributed LUT RAM }
           {c64_oled framebuffer: 2 KiB requested as ram_style distributed on purpose (block RAM is at 79 % against the 80 % gate); the message only states that Vivado kept the requested mapping}}
  {TIMING-18 {^An input delay is missing on (qspi_dq\[[0-3]\]) relative to the rising and/or falling clock edge\(s\) of sys_clk\.$}
             {QSPI flash inputs: constrained against qspi_sck, the clock generated on the STARTUPE2 USRCCLKO pin (fpga/constraints/ik64_qspi.xdc, PG153 recipe); the check does not relate that clock to sys_clk; the paths are timed (clock interaction qspi_sck -> cpu_clk_mmcm)}
             {{qspi_dq[0]} {qspi_dq[1]} {qspi_dq[2]} {qspi_dq[3]}}}
  {TIMING-18 {^An output delay is missing on (qspi_cs|qspi_dq\[[0-3]\]) relative to the rising and/or falling clock edge\(s\) of sys_clk\.$}
             {QSPI flash outputs: constrained against qspi_sck, the clock generated on the STARTUPE2 USRCCLKO pin (fpga/constraints/ik64_qspi.xdc, PG153 recipe); the check does not relate that clock to sys_clk; the paths are timed (clock interaction cpu_clk_mmcm -> qspi_sck)}
             {qspi_cs {qspi_dq[0]} {qspi_dq[1]} {qspi_dq[2]} {qspi_dq[3]}}}
  {XDCB-5 {^The option '-to : \[get_pins -hier -include_replicated_objects -filter \{NAME =~ \*temp_mon_enabled\.u_tempmon/device_temp_sync_r1_reg\[\*\]/D\}\]' of constraint 'set_max_delay' }
          {AMD MIG IP u_ddr/u_mig: the vendor-generated temperature monitor constraint (set_max_delay to temp_mon_enabled.u_tempmon/device_temp_sync_r1_reg[*]/D) uses a hierarchical pin query; it is vendor IP constraint text}
          {match}}
}
array set meth_seen {}
set meth_bad {}
foreach v [get_methodology_violations -quiet] {
  set rule [get_property CHECK $v]
  set sev  [get_property SEVERITY $v]
  set desc [string trim [get_property DESCRIPTION $v]]
  if {$sev eq "Advisory"} continue
  set hit ""
  set hitidx -1
  set hitkey match
  set wi -1
  foreach w $meth_waivers {
    incr wi
    lassign $w wr wtest wwhy wreq
    if {$wr ne $rule} continue
    set key match
    if {[string match "proc:*" $wtest]} {
      set ok [[string range $wtest 5 end] $desc]
    } else {
      set ok [regexp -- $wtest $desc -> key1]
      if {$ok && [info exists key1] && $key1 ne ""} { set key $key1 }
      unset -nocomplain key1
    }
    if {$ok} { set hit $wwhy; set hitidx $wi; set hitkey $key; break }
  }
  if {$hit ne ""} {
    set meth_seen($hitidx,$hitkey) 1
    puts "ik64_build: waived $rule ($sev): $hit"
  } else {
    lappend meth_bad "$rule ($sev)"
    puts "ik64_build: UNWAIVED $rule ($sev): [string range $desc 0 300]"
  }
}
set wi -1
foreach w $meth_waivers {
  incr wi
  lassign $w wr wtest wwhy wreq
  foreach k $wreq {
    if {![info exists meth_seen($wi,$k)]} { lappend meth_bad "required waiver target missing: $wr $k" }
  }
  if {[llength $wreq] > 0} {
    set n 0
    foreach k $wreq { if {[info exists meth_seen($wi,$k)]} { incr n } }
    puts "ik64_build: required waiver $wr: $n of [llength $wreq] targets matched"
  }
}
if {[llength $meth_bad] > 0} { nv_exit 27 "methodology findings without waiver: [join $meth_bad {, }]" }

# ---------------------------------------------------------------------------
# Gate: no critical warning during implementation.
# ---------------------------------------------------------------------------
set crit_all [get_msg_config -count -severity {CRITICAL WARNING}]
if {$crit_all > $crit_synth} { nv_exit 24 "[expr {$crit_all - $crit_synth}] critical warning(s) during implementation" }

# ---------------------------------------------------------------------------
# Bitstream (LMBs hold no firmware yet; the firmware merge step adds both
# ELFs through the MMI), MMI and the fixed hardware platform.
# ---------------------------------------------------------------------------
set bit_hw [file join $BUILD_DIR c64_hw.bit]
set mmi    [file join $BUILD_DIR c64.mmi]
if {[catch {write_bitstream -force $bit_hw} err]} { nv_exit 40 "write_bitstream: $err" }
if {[catch {write_mem_info -force $mmi} err]} { nv_exit 41 "write_mem_info: $err" }
set xsa [file join $BUILD_DIR c64.xsa]
if {[catch {write_hw_platform -fixed -force -include_bit -file $xsa} err]} { nv_exit 42 "write_hw_platform: $err" }

# ---------------------------------------------------------------------------
# Build record.
# ---------------------------------------------------------------------------
set fh [open [file join $BUILD_DIR build_info.txt] w]
puts $fh "design        $TOP"
puts $fh "part          $PART"
puts $fh "git_hash      $BUILD_ID_HEX"
puts $fh "git_dirty     $opt(dirty)"
puts $fh "tool          [version -short]"
puts $fh "built         [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}]"
puts $fh "wns_ns        $wns"
puts $fh "whs_ns        $whs"
puts $fh "wpws_ns       $wpws"
puts $fh "utilization   [join $util_summary {, }]"
puts $fh "cdc_classes   $::ik64_cdc_result"
puts $fh "bitstream_hw  [file tail $bit_hw]"
puts $fh "mmi           [file tail $mmi]"
puts $fh "xsa           [file tail $xsa]"
close $fh
puts "ik64_build: PASS $bit_hw"
exit 0
