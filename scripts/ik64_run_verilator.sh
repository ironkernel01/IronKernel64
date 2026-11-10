#!/bin/sh
# ik64_run_verilator.sh -- builds and runs tb_sid_player under Verilator 5 (MSYS2 UCRT64).
# Usage (from any shell): scripts/ik64_run_verilator.sh      prints the bench's TEST PASS/FAIL line.
# Output: build/verilator/tb_sid_player. -fno-declone-ctor-dtor: see .claude/CLAUDE.md.
# Revision: 11-09-2026 first version; setup guard (setup_third_party.py --check)
#   11-10-2026: ik64_* common and bench support files replace the RTLNet ones.
R="$(cd "$(dirname "$0")/.." && pwd)"
python -I "$R/tools/setup_third_party.py" --check || { echo "ik64_run_verilator: third-party setup check failed; run: python -I tools/setup_third_party.py"; exit 2; }
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "cd '$R' && verilator --binary --timing -j 4 -Wno-fatal -Wno-lint -Wno-style \
  -CFLAGS -fno-declone-ctor-dtor --top-module tb_sid_player --Mdir build/verilator/tb_sid_player \
  +incdir+third_party/redip-sid/ik64 +incdir+fpga/hdl/common \
  fpga/hdl/common/ik64_common_pkg.sv \
  fpga/hdl/common/ik64_sync.sv \
  fpga/hdl/common/ik64_reset_sync.sv \
  fpga/hdl/common/ik64_axil_slave.sv \
  fpga/tb/common/ik64_tb_pkg.sv \
  fpga/tb/common/ik64_tb_axil_master.sv \
  third_party/redip-sid/ik64/sid_pkg.sv third_party/redip-sid/ik64/sid_control.sv \
  third_party/redip-sid/ik64/sid_waveform.sv third_party/redip-sid/ik64/sid_envelope.sv \
  third_party/redip-sid/ik64/sid_pot.sv third_party/redip-sid/ik64/sid_dac.sv \
  third_party/redip-sid/ik64/sid_voice.sv third_party/redip-sid/ik64/sid_filter.sv \
  third_party/redip-sid/ik64/sid_api.sv fpga/hdl/redip/muladd.sv fpga/hdl/c64_pkg.sv \
  fpga/hdl/sid_player.sv fpga/tb/tb_sid_player.sv && cd third_party/redip-sid/ik64 && \
  time ../../../build/verilator/tb_sid_player/Vtb_sid_player"
