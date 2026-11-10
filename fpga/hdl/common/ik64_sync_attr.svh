// -----------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later OR CERN-OHL-S-2.0
// File: ik64_sync_attr.svh
// Purpose: the one attribute set every IronKernel 64 synchronizer register
//   carries (AMD/Xilinx target).
// Overview:
//   * ASYNC_REG places the chain in one slice and marks it for the CDC tools,
//     SHREG_EXTRACT = "NO" keeps it out of SRLs, DONT_TOUCH stops merging and
//     retiming of the chain registers.
//   * `IK64_SYNC_ATTR is placed on a chain declaration:
//       `IK64_SYNC_ATTR
//       logic [STAGES-1:0] sync_ff = ...;
// Language: SystemVerilog-2012 (preprocessor only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: none.
// -----------------------------------------------------------------------------
`ifndef IK64_SYNC_ATTR_SVH
`define IK64_SYNC_ATTR_SVH
`define IK64_SYNC_ATTR (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO", DONT_TOUCH = "TRUE" *)
`endif
