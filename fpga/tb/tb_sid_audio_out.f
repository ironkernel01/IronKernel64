# tb_sid_audio_out filelist (paths relative to the repository root).
-f third_party/rtlnet/cores/rtlnet_common/hdl/rtlnet_common.f
-f third_party/rtlnet/cores/rtlnet_common/testbench/rtlnet_tb_common.f
# xpm_fifo_async: the shared vendor library (xlib xpm) holds xpm_memory and xpm_cdc only, so the
# FIFO source is compiled into work from the located Vivado install (runner $VIVADO/ prefix).
$VIVADO/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv
fpga/hdl/c64_pkg.sv
fpga/hdl/sid_audio_out.sv
fpga/tb/tb_sid_audio_out.sv
