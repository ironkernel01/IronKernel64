#!/bin/sh
# ik64_run_verilator.sh -- builds and runs tb_sid_player under Verilator 5 (MSYS2 UCRT64).
# Usage (from any shell): scripts/ik64_run_verilator.sh      prints the bench's TEST PASS/FAIL line.
# Output: build/verilator/tb_sid_player. -fno-declone-ctor-dtor: see .claude/CLAUDE.md.
# Revision: 11-09-2026 first version
R="$(cd "$(dirname "$0")/.." && pwd)"
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "cd '$R' && verilator --binary --timing -j 4 -Wno-fatal -Wno-lint -Wno-style \
  -CFLAGS -fno-declone-ctor-dtor --top-module tb_sid_player --Mdir build/verilator/tb_sid_player \
  +incdir+third_party/redip-sid/ik64 +incdir+third_party/rtlnet/cores/rtlnet_common/hdl \
  third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_pkg.sv \
  third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_reset_sync.sv \
  third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_axil_slave.sv \
  third_party/rtlnet/cores/rtlnet_common/testbench/rtlnet_tb_pkg.sv \
  third_party/rtlnet/cores/rtlnet_common/testbench/rtlnet_tb_axil_master.sv \
  third_party/redip-sid/ik64/sid_pkg.sv third_party/redip-sid/ik64/sid_control.sv \
  third_party/redip-sid/ik64/sid_waveform.sv third_party/redip-sid/ik64/sid_envelope.sv \
  third_party/redip-sid/ik64/sid_pot.sv third_party/redip-sid/ik64/sid_dac.sv \
  third_party/redip-sid/ik64/sid_voice.sv third_party/redip-sid/ik64/sid_filter.sv \
  third_party/redip-sid/ik64/sid_api.sv fpga/hdl/redip/muladd.sv fpga/hdl/c64_pkg.sv \
  fpga/hdl/sid_player.sv fpga/tb/tb_sid_player.sv && cd third_party/redip-sid/ik64 && \
  time ../../../build/verilator/tb_sid_player/Vtb_sid_player"
