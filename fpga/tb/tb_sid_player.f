# tb_sid_player filelist (paths relative to the repository root).
# reDIP-SID (third_party/redip-sid, CERN-OHL-S-2.0, unmodified) without the iCE40 board files; muladd.sv
# comes from fpga/hdl/redip (inferred multiply-add instead of SB_MAC16). The *.hex tables are read by
# $readmemh and `include resolve next to the source file in Active-HDL, so the unmodified tables are found.
# Two files come from build/sim_redip (python -I build/sim_redip/gen_sim_redip.py): sid_filter.sv without the
# unsupported `unique0 case` and sid_api.sv without its $dumpfile/$dumpvars block (see c64demo.md, reDIP-SID).
-f third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_common.f
-f third_party/rtlnet/cores/rtlnet_common/testbench/rtlnet_tb_common.f
+incdir+third_party/redip-sid/gateware
third_party/redip-sid/gateware/sid_pkg.sv
third_party/redip-sid/gateware/sid_control.sv
third_party/redip-sid/gateware/sid_waveform.sv
third_party/redip-sid/gateware/sid_envelope.sv
third_party/redip-sid/gateware/sid_pot.sv
third_party/redip-sid/gateware/sid_dac.sv
third_party/redip-sid/gateware/sid_voice.sv
build/sim_redip/sid_filter.sv
build/sim_redip/sid_api.sv
fpga/hdl/redip/muladd.sv
fpga/hdl/c64_pkg.sv
fpga/hdl/sid_player.sv
fpga/tb/tb_sid_player.sv
