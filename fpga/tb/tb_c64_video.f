# tb_c64_video: c64_video + dvi_tx + tmds_encoder bench (paths relative to the repository root).
-f third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_common.f
-f third_party/rtlnet/cores/rtlnet_common/testbench/rtlnet_tb_common.f
fpga/hdl/c64_pkg.sv
fpga/hdl/tmds_encoder.sv
fpga/hdl/dvi_tx.sv
fpga/hdl/c64_video.sv
fpga/tb/tb_c64_video.sv
