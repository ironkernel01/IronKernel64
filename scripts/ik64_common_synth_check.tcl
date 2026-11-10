# -----------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
# File: ik64_common_synth_check.tcl
# Purpose: out-of-context synthesis check of the ik64_common primitives and a
#   functional test of scripts/ik64_constrain_cdc.tcl on the resulting netlist
#   (cell names the script matches, instance and crossing counts, create_waiver).
#   Optionally generates the DDR3 path IP (ik64_ddr_cc, ik64_ddr_mig).
# Usage (through the Vivado slot launcher):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ik64_vivado.ps1 `
#     -Tcl scripts/ik64_common_synth_check.tcl -Log .sim/synth/ik64_common.log -TclArgs [ip]
#   `ip` also creates the two DDR3 path IPs in an in-memory project (a few minutes).
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
# -----------------------------------------------------------------------------
set repo [file normalize [file join [file dirname [info script]] ..]]
set work [file join $repo .sim synth ik64_common_work]
file mkdir $work
set do_ip [expr {[lsearch -exact $argv ip] >= 0}]

# Test top: one instance of every primitive that has a CDC class, on three clocks.
set fh [open [file join $work ik64_cdc_top.sv] w]
puts $fh {
module ik64_cdc_top (
  input  logic a_clk, b_clk, arstn, d_in,
  input  logic [7:0] cnt_a,
  input  logic [11:0] awaddr,
  input  logic awvalid, wvalid, arvalid, bready, rready,
  input  logic [31:0] wdata,
  output logic q_sync, q_pulse,
  output logic [7:0] q_gray,
  output logic rst_a_n, rst_b_n,
  output logic awready, wready, bvalid, arready, rvalid,
  output logic [31:0] rdata
);
  ik64_reset_sync u_rst_a (.clk(a_clk), .arstn(arstn), .resetn(rst_a_n));
  ik64_reset_sync u_rst_b (.clk(b_clk), .arstn(arstn), .resetn(rst_b_n));
  ik64_sync #(.WIDTH(1), .STAGES(3)) u_sync (.clk(b_clk), .resetn(rst_b_n), .d(d_in), .q(q_sync));
  ik64_pulse_sync u_pulse (.src_clk(a_clk), .src_resetn(rst_a_n), .src_pulse(d_in),
                           .dst_clk(b_clk), .dst_resetn(rst_b_n), .dst_pulse(q_pulse));
  ik64_gray_sync #(.WIDTH(8), .STAGES(2)) u_gray (.src_clk(a_clk), .src_resetn(rst_a_n), .src_count(cnt_a),
                                                  .dst_clk(b_clk), .dst_resetn(rst_b_n), .dst_count(q_gray));
  logic [11:0] m_awaddr, m_araddr;
  logic m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;
  logic [31:0] m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  ik64_axil_cdc #(.ADDR_W(12)) u_cdc (
    .s_clk(a_clk), .s_resetn(rst_a_n),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(awaddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m_clk(b_clk), .m_resetn(rst_b_n),
    .m_axi_awaddr(m_awaddr), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
    .m_axi_bresp(2'b00), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
    .m_axi_araddr(m_araddr), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rdata(m_rdata), .m_axi_rresp(2'b00), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));
  // Register slave behind the crossing.
  ik64_axil_slave #(.ADDR_W(12)) u_slv (
    .s_axi_aclk(b_clk), .s_axi_aresetn(rst_b_n),
    .s_axi_awaddr(m_awaddr), .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
    .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
    .s_axi_bresp(), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
    .s_axi_araddr(m_araddr), .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
    .s_axi_rdata(m_rdata), .s_axi_rresp(), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
    .reg_wr_en(), .reg_wr_addr(), .reg_wr_data(), .reg_rd_en(), .reg_rd_addr(), .reg_rd_data(wdata));
endmodule
}
close $fh

set_part xc7a200tsbg484-1
read_verilog -sv [list \
  [file join $repo fpga hdl common ik64_common_pkg.sv] \
  [file join $repo fpga hdl common ik64_ram_core.sv] \
  [file join $repo fpga hdl common ik64_sync.sv] \
  [file join $repo fpga hdl common ik64_reset_sync.sv] \
  [file join $repo fpga hdl common ik64_pulse_sync.sv] \
  [file join $repo fpga hdl common ik64_gray_sync.sv] \
  [file join $repo fpga hdl common ik64_axil_slave.sv] \
  [file join $repo fpga hdl common ik64_axil_cdc.sv] \
  [file join $repo fpga hdl common ik64_axil_decoder.sv] \
  [file join $work ik64_cdc_top.sv]]
set_property include_dirs [file join $repo fpga hdl common] [current_fileset]
synth_design -top ik64_cdc_top -part xc7a200tsbg484-1 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name a_clk -period 10.0 [get_ports a_clk]
create_clock -name b_clk -period 30.0 [get_ports b_clk]

# The script under test: exact instance counts of the test top.
set ::ik64_cdc_required {sync reset gray axil_cdc}
set ::ik64_cdc_expect   {reset 2 gray 1 axil_cdc 1 sync 4}
set ::ik64_cdc_report   [file join $work cdc_instances.txt]
source [file join $repo scripts ik64_constrain_cdc.tcl]
puts "ik64_check: result $::ik64_cdc_result"
report_cdc -details -file [file join $work report_cdc.txt]
puts "ik64_check: CDC script PASS"

if {$do_ip} {
  create_project -in_memory -part xc7a200tsbg484-1
  source [file join $repo fpga ip ik64_ddr_cc.tcl]
  source [file join $repo fpga ip ik64_ddr_mig.tcl]
  set x1 [ik64_ddr_cc_create [file join $work ip_cc]]
  puts "ik64_check: axi_clock_converter generated: $x1"
  set x2 [ik64_ddr_mig_create [file join $work ip_mig]]
  puts "ik64_check: MIG generated: $x2"
  puts "ik64_check: IP PASS"
}
puts "ik64_check: PASS"
