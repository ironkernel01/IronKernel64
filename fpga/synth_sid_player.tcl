# -----------------------------------------------------------------------------
# File: synth_sid_player.tcl
# Purpose: out-of-context Vivado synthesis check of sid_player with the
#   unmodified reDIP-SID gateware (third_party/redip-sid) and the inferred
#   fpga/hdl/redip/muladd.sv: proves the sources are accepted (readmemh tables,
#   elaboration-time $tanh/$pow, $dumpfile block), reports utilization and the
#   worst setup slack at a 10 ns cpu_clk. No implementation.
#   rtlnet_synth_check.tcl is not used: it takes filelists relative to the
#   RTLNet tree and has no clock constraint, so no slack.
# Usage: scripts via third_party/rtlnet/scripts/rtlnet_vivado.ps1
#   -Tcl fpga/synth_sid_player.tcl -Log build/synth/sid_player.log
#   [-TclArgs <part>]   (default xc7a200tsbg484-1)
# Exit codes: 0 pass, 10 synthesis error or critical warning.
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
# -----------------------------------------------------------------------------
set repo [file normalize [file join [file dirname [info script]] ".."]]
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tsbg484-1"}]
set sid  [file join $repo third_party redip-sid gateware]
# Vivado 2026.1 rejects ANSI ports of type logic (Synth 8-6735) in modules whose
# #() header holds only localparams while `default_nettype none is active, which
# is true for most upstream sid_*.sv files. Each upstream file is therefore read
# from a generated copy in <cwd>/redip_synth with that one directive changed to
# `default_nettype wire; nothing else differs. The .hex tables and .svh includes
# are copied beside them (readmemh and `include resolve there).
set gen [file join [pwd] redip_synth]
file mkdir $gen
foreach f [glob -directory $sid *.hex] { file copy -force $f $gen }
proc up {name} {
  global sid gen
  set fh [open [file join $sid $name] r]
  set txt [read $fh]
  close $fh
  set n [regsub -all {`default_nettype none} $txt {`default_nettype wire} txt]
  set fh [open [file join $gen $name] w]
  puts -nonewline $fh $txt
  close $fh
  puts "synth_sid_player: $name read from a copy, $n default_nettype directive(s) changed"
  return [file join $gen $name]
}
up sid_waveform_PST.svh
up sid_waveform__ST.svh
set files [list \
  [file join $repo third_party rtlnet cores rtlnet_common hdl rtlnet_axil_slave.sv] \
  [file join $repo fpga hdl c64_pkg.sv] \
  [up sid_pkg.sv] \
  [up sid_control.sv] \
  [up sid_waveform.sv] \
  [up sid_envelope.sv] \
  [up sid_pot.sv] \
  [up sid_dac.sv] \
  [up sid_voice.sv] \
  [up sid_filter.sv] \
  [up sid_api.sv] \
  [file join $repo fpga hdl redip muladd.sv] \
  [file join $repo fpga hdl sid_player.sv]]
foreach f $files { read_verilog -sv $f }
if {[catch {synth_design -top sid_player -part $part -mode out_of_context -include_dirs [list $gen]} err]} {
  puts "synth_sid_player: FAIL synth_design: $err"; exit 10
}
create_clock -name cpu_clk -period 10.000 [get_ports cpu_clk]
report_utilization -file [file join [pwd] sid_player_utilization.rpt]
report_timing_summary -file [file join [pwd] sid_player_timing.rpt] -max_paths 5
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "synth_sid_player: WNS $wns ns at 10 ns"
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
puts "synth_sid_player: critical warnings $crit"
if {$crit > 0} { puts "synth_sid_player: FAIL critical warnings"; exit 10 }
puts "synth_sid_player: PASS sid_player"
exit 0
