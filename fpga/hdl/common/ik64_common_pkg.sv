// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_common_pkg.sv
// Purpose: constants and pure functions shared by the IronKernel 64 common RTL.
// Overview:
//   * AXI4-Lite response codes (AXI_RESP_*).
//   * clog2i: integer ceiling log2 for elaboration-time sizing (0 for x <= 1).
//   * No ik64 module imports a package from RTLNet today (rtlnet_pkg is not
//     used by any C64 file); this package exists for the common modules and for
//     later use by ik64 code.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package ik64_common_pkg;

  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;

  function automatic int clog2i(input int x);
    int r;
    r = 0;
    while ((1 << r) < x) r++;
    return r;
  endfunction

endpackage
