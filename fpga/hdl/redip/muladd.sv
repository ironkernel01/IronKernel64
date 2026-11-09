// -----------------------------------------------------------------------------
// SPDX-License-Identifier: CERN-OHL-S-2.0
// File: muladd.sv (fpga/hdl/redip/)
// Purpose: Xilinx 7-series substitute for third_party/redip-sid/gateware/muladd.sv,
//   which instantiates the iCE40 SB_MAC16 primitive. Same module name, ports
//   and arithmetic; this file is compiled instead of the upstream one.
// Licence: derived from Dag Lem's muladd.sv of reDIP SID (Copyright (C) 2022
//   Dag Lem <resid@nimrod.no>, https://github.com/daglem/reDIP-SID), so it
//   stays under the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt). It is
//   distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY; see the CERN-OHL-S v2.
//   This is a substitution, not an edit of the upstream file (c64demo.md,
//   Licensing).
// Overview:
//   * o = c +- (a * b), a and b signed 16 bit, c and o signed 32 bit, wrapping
//     at 32 bits; s = 0 adds, s = 1 subtracts.
//   * Latency 0: the upstream SB_MAC16 is configured unregistered (CLK and CE
//     tied low, no pipeline-register parameters), so the result is
//     combinational and the callers (sid_filter.sv) rely on that.
//   * Written as a plain signed multiply-add so Vivado maps it to one DSP48E1.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: none (combinational).
// -----------------------------------------------------------------------------
(* use_dsp = "yes" *)
module muladd (
    input  logic signed [31:0] c,
    input  logic               s,
    input  logic signed [15:0] a,
    input  logic signed [15:0] b,
    output logic signed [31:0] o
);
    logic signed [31:0] p;

    always_comb begin
        p = a * b;
        o = s ? c - p : c + p;
    end
endmodule
