# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
# -----------------------------------------------------------------------------
# File: c64_bd.tcl
# Purpose: create the IronKernel 64 block design `c64_cpu` by script: two
#   MicroBlaze V processors, core 0 "C64" and core 1 "1541" drive, with their
#   peripherals, the shared drive BRAM and the joint DDR3 path.
# Overview:
#   * Defines `c64_bd_create <bd_dir>`; the caller has an open (or in-memory)
#     project with the part set. The procedure creates the design under
#     <bd_dir>, validates and saves it, and returns the .bd file path.
#   * Derived from RTLNet microblaze/hdl/rtlnet_cpu_bd.tcl (commit
#     ea70c8558ec4ef1133d1e9adde1b278e106302e0): same processor configuration,
#     LMB, cache, DDR3 SmartConnect, reset and network-DMA patterns.
#   * Processors: microblaze_riscv 1.0 x2, RV32IMC with Zicsr, Zba, Zbb, Zbs,
#     performance pipeline, no MMU, no FPU, no bus exceptions, debug enabled,
#     ILMB + DLMB, AXI data port M_AXI_DP, cache ports M_AXI_IC / M_AXI_DC,
#     reset vector 0x0, C_PC_WIDTH 32, 8 KiB instruction cache and 8 KiB
#     write-through data cache over 0x8000_0000-0x9FFF_FFFF only.
#   * Core 0 (microblaze_0): 256 KiB LMB (firmware, 64 KiB emulated C64 RAM);
#     axi_uartlite_0 (console, 115200 8N1), axi_iic_0 (ADAU1761 codec, 100 kHz),
#     axi_timer_0, axi_intc_0, mailbox_0 port S0, the framebuffer AXI BRAM
#     controller axi_bram_ctrl_fb (its BRAM port exported as FB_BRAM to
#     c64_video in the top), the shared-BRAM controller axi_bram_ctrl_shm0, and
#     the exported AXI4-Lite master M_AXI_C64 (fabric window 0).
#   * Core 1 (microblaze_1): 64 KiB LMB (boot code, vectors, stacks); code and
#     data run from DDR3; axi_timer_1, axi_intc_1, mailbox_0 port S1, the
#     shared-BRAM controller axi_bram_ctrl_shm1, the exported AXI4-Lite master
#     M_AXI_DRV (fabric window 1, RTLNet register-window layout), and RTLNet's
#     CPU network path unchanged: axi_dma_0 (simple mode, 64-bit streams
#     S_AXIS_ETH / M_AXIS_ETH), axi_mem, axi_bram_ctrl_0 + axi_bram (128 KiB
#     network buffers). Core 1 has no UART: its console is the log ring in the
#     shared BRAM (common/drive_proto.h DRIVE_LOG_OFS), printed by core 0.
#   * Shared: shm_bram, a 128 KiB true dual-port block RAM, port A core 0,
#     port B core 1, both on clk (no clock crossing). mailbox_0 (synchronous
#     clocks) carries the doorbells. mdm_0 (MicroBlaze V debug module, two
#     debug ports, no JTAG UART: the UART FIFOs would add CDC-15 crossings).
#   * DDR3 path: the four cache masters (M_AXI_IC/M_AXI_DC of both cores) join
#     in the SmartConnect sc_ddr; its master is the exported 128-bit AXI4 port
#     M_AXI_DDR on clk with no ID signals. The clock crossing to the memory
#     controller is outside the block design (rtlnet_axi_cdc in c64_top).
#     The cores' DDR3 partitions are disjoint (common/c64_platform.h), so the
#     write-through caches need no coherence between the cores.
#   * Clock and reset come from outside: port `clk` (cpu_clk, 100 MHz) and
#     port `resetn` (active low, synchronous to clk). One proc_sys_reset per
#     core; the shared cells (sc_ddr, shared BRAM controllers) take core 0's.
#   * Interrupts (level, active high):
#       core 0 axi_intc_0: 0..7 = port irq0[7:0] (0 audio, 1 vsync, 2 PS/2),
#         8 timer, 9 UART, 10 mailbox (Interrupt_0), 11 IIC.
#       core 1 axi_intc_1: 0..7 = port irq1[7:0], 8 timer, 9 mailbox
#         (Interrupt_1), 10 DMA MM2S, 11 DMA S2MM.
#   * Address map (mirrored in common/c64_platform.h; keep both in step):
#       core 0                              core 1
#       0x0000_0000 256 KiB LMB             0x0000_0000  64 KiB LMB
#       0x4060_0000  64 KiB UART Lite       0x4040_0000  64 KiB AXI DMA regs
#       0x4080_0000  64 KiB IIC             0x4120_0000  64 KiB INTC
#       0x4120_0000  64 KiB INTC            0x41C0_0000  64 KiB Timer
#       0x41C0_0000  64 KiB Timer           0x44A0_0000   1 MiB M_AXI_DRV
#       0x4400_0000 512 KiB M_AXI_C64       0x4500_0000  64 KiB Mailbox S1
#       0x4500_0000  64 KiB Mailbox S0      0x8000_0000 512 MiB DDR3 (cached)
#       0x8000_0000 512 MiB DDR3 (cached)   0xC000_0000 128 KiB network BRAM
#       0xC000_0000 256 KiB framebuffer     0xC100_0000 128 KiB shared BRAM
#       0xC100_0000 128 KiB shared BRAM
#   * Cell names are part of the build interface: the MMI written by
#     write_mem_info names microblaze_0/microblaze_1 and lmb_bram_0/lmb_bram_1;
#     the firmware BSP flows name the processors and find peripherals by these
#     instance names (axi_iic_0, axi_uartlite_0, axi_intc_0, axi_timer_0,
#     mailbox_0, axi_intc_1, axi_timer_1, axi_dma_0).
# Language: Vivado Tcl (2026.1).
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
# Clocks: clk (cpu_clk 100 MHz) for every cell.
# -----------------------------------------------------------------------------

namespace eval c64_bd {
  variable CPU_CLK_HZ     100000000
  variable UART_BAUD      115200
  variable IIC_KHZ        100
  variable LMB0_SIZE      256K
  variable LMB1_SIZE      64K
  # Peripheral bases (same value in both cores' address spaces where both have one).
  variable DMA_BASE       0x40400000
  variable UART_BASE      0x40600000
  variable IIC_BASE       0x40800000
  variable INTC_BASE      0x41200000
  variable TIMER_BASE     0x41C00000
  variable MBOX_BASE      0x45000000
  # Exported fabric windows (c64_pkg.sv WIN_SIZE / WIN1_SIZE).
  variable WIN0_BASE      0x44000000
  variable WIN0_RANGE     512K
  variable WIN1_BASE      0x44A00000
  variable WIN1_RANGE     1M
  # Framebuffer: 2 pages x 92,160 bytes = 184,320 bytes in a 256 KiB window.
  variable FB_BASE        0xC0000000
  variable FB_RANGE       256K
  # Core 1 network buffers (RTLNet layout).
  variable NETBUF_BASE    0xC0000000
  variable NETBUF_RANGE   128K
  # Shared drive BRAM (drive_proto.h DRIVE_SHM_BYTES).
  variable SHM_BASE       0xC1000000
  variable SHM_RANGE      128K
  variable DDR_BASE       0x80000000
  variable DDR_SIZE       512M
  # Cacheable window (inclusive high address, 64-bit property format).
  variable CACHE_BASE     0x0000000080000000
  variable CACHE_HIGH     0x000000009FFFFFFF
  variable CACHE_BYTES    8192
  # DMA length register width: 2^14 - 1 = 16383 bytes per simple transfer,
  # above the 1518-byte frame and the 2 KiB buffer (RTLNet).
  variable DMA_LEN_W      14
}

# c64_bd_cpu -- create one MicroBlaze V with its LMB, proc_sys_reset and INTC.
#   idx: core index (cell suffix); lmb_size: LMB range.
proc c64_bd_cpu {idx lmb_size} {
  set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze_riscv:1.0 microblaze_$idx]
  set_property -dict [list \
    CONFIG.C_OPTIMIZATION            0 \
    CONFIG.C_USE_MULDIV              1 \
    CONFIG.C_USE_COMPRESSION         1 \
    CONFIG.C_USE_BITMAN_A            1 \
    CONFIG.C_USE_BITMAN_B            1 \
    CONFIG.C_USE_BITMAN_S            1 \
    CONFIG.C_USE_BARREL              1 \
    CONFIG.C_USE_FPU                 0 \
    CONFIG.C_USE_MMU                 0 \
    CONFIG.C_USE_ICACHE              1 \
    CONFIG.C_USE_DCACHE              1 \
    CONFIG.C_ICACHE_BYTE_SIZE        $::c64_bd::CACHE_BYTES \
    CONFIG.C_DCACHE_BYTE_SIZE        $::c64_bd::CACHE_BYTES \
    CONFIG.C_ICACHE_BASEADDR         $::c64_bd::CACHE_BASE \
    CONFIG.C_ICACHE_HIGHADDR         $::c64_bd::CACHE_HIGH \
    CONFIG.C_DCACHE_BASEADDR         $::c64_bd::CACHE_BASE \
    CONFIG.C_DCACHE_HIGHADDR         $::c64_bd::CACHE_HIGH \
    CONFIG.C_ICACHE_LINE_LEN         4 \
    CONFIG.C_DCACHE_LINE_LEN         4 \
    CONFIG.C_ICACHE_DATA_WIDTH       1 \
    CONFIG.C_DCACHE_DATA_WIDTH       1 \
    CONFIG.C_DCACHE_USE_WRITEBACK    0 \
    CONFIG.C_USE_BRANCH_TARGET_CACHE 0 \
    CONFIG.C_DEBUG_ENABLED           1 \
    CONFIG.C_D_AXI                   1 \
    CONFIG.C_D_LMB                   1 \
    CONFIG.C_I_LMB                   1 \
    CONFIG.C_I_AXI                   0 \
    CONFIG.C_USE_INTERRUPT           1 \
    CONFIG.C_M_AXI_D_BUS_EXCEPTION   0 \
    CONFIG.C_BASE_VECTORS            0x0000000000000000] $mb
  # Program counter width 32: the IP propagates the ILMB width (C_I_AXI 0), which wraps a jump to
  # 0x8000_0000 to the LMB; core 1 executes from DDR3 and core 0 may run DDR3-linked test images.
  set_property CONFIG.C_PC_WIDTH 32 $mb

  create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 ilmb_v10_$idx
  create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 dlmb_v10_$idx
  set ictl [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 ilmb_bram_if_cntlr_$idx]
  set dctl [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 dlmb_bram_if_cntlr_$idx]
  set_property CONFIG.C_ECC 0 $ictl
  set_property CONFIG.C_ECC 0 $dctl
  set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 lmb_bram_$idx]
  set_property -dict [list \
    CONFIG.Memory_Type     True_Dual_Port_RAM \
    CONFIG.use_bram_block  BRAM_Controller \
    CONFIG.Enable_B        Use_ENB_Pin \
    CONFIG.Use_RSTB_Pin    true] $bram

  connect_bd_intf_net [get_bd_intf_pins microblaze_$idx/ILMB] [get_bd_intf_pins ilmb_v10_$idx/LMB_M]
  connect_bd_intf_net [get_bd_intf_pins microblaze_$idx/DLMB] [get_bd_intf_pins dlmb_v10_$idx/LMB_M]
  connect_bd_intf_net [get_bd_intf_pins ilmb_v10_$idx/LMB_Sl_0] [get_bd_intf_pins ilmb_bram_if_cntlr_$idx/SLMB]
  connect_bd_intf_net [get_bd_intf_pins dlmb_v10_$idx/LMB_Sl_0] [get_bd_intf_pins dlmb_bram_if_cntlr_$idx/SLMB]
  connect_bd_intf_net [get_bd_intf_pins ilmb_bram_if_cntlr_$idx/BRAM_PORT] [get_bd_intf_pins lmb_bram_$idx/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_pins dlmb_bram_if_cntlr_$idx/BRAM_PORT] [get_bd_intf_pins lmb_bram_$idx/BRAM_PORTB]

  # Interrupt controller in default (non-fast) mode; the BSP handler reads the IVR.
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_$idx
  connect_bd_intf_net [get_bd_intf_pins axi_intc_$idx/interrupt] [get_bd_intf_pins microblaze_$idx/INTERRUPT]
  # Tick timer (two 32-bit counters; firmware uses timer 0).
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_$idx

  # Reset sequencer: external resetn (active low) plus the MDM debug reset.
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_cpu$idx
  connect_bd_net [get_bd_ports resetn] [get_bd_pins rst_cpu$idx/ext_reset_in]
  connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_cpu$idx/dcm_locked]
  connect_bd_net [get_bd_pins mdm_0/Debug_SYS_Rst] [get_bd_pins rst_cpu$idx/mb_debug_sys_rst]
  connect_bd_net [get_bd_pins rst_cpu$idx/mb_reset] [get_bd_pins microblaze_$idx/Reset]
  set intc_prst [get_bd_pins -quiet axi_intc_$idx/processor_rst]
  if {$intc_prst ne ""} { connect_bd_net [get_bd_pins rst_cpu$idx/mb_reset] $intc_prst }
  foreach p [list ilmb_v10_$idx/SYS_Rst dlmb_v10_$idx/SYS_Rst \
               ilmb_bram_if_cntlr_$idx/LMB_Rst dlmb_bram_if_cntlr_$idx/LMB_Rst] {
    connect_bd_net [get_bd_pins rst_cpu$idx/bus_struct_reset] [get_bd_pins $p]
  }
  foreach p [list microblaze_$idx/Clk ilmb_v10_$idx/LMB_Clk dlmb_v10_$idx/LMB_Clk \
               ilmb_bram_if_cntlr_$idx/LMB_Clk dlmb_bram_if_cntlr_$idx/LMB_Clk \
               axi_intc_$idx/s_axi_aclk axi_timer_$idx/s_axi_aclk rst_cpu$idx/slowest_sync_clk] {
    connect_bd_net [get_bd_ports clk] [get_bd_pins $p]
  }
  set intc_pclk [get_bd_pins -quiet axi_intc_$idx/processor_clk]
  if {$intc_pclk ne ""} { connect_bd_net [get_bd_ports clk] $intc_pclk }
  foreach p [list axi_intc_$idx/s_axi_aresetn axi_timer_$idx/s_axi_aresetn] {
    connect_bd_net [get_bd_pins rst_cpu$idx/peripheral_aresetn] [get_bd_pins $p]
  }
}

# c64_bd_periph -- create the AXI interconnect `name` (one slave, num_mi masters) on clk with
#   core idx's resets, and connect the processor's M_AXI_DP to it.
proc c64_bd_periph {name idx num_mi} {
  set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 $name]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI $num_mi] $ic
  connect_bd_intf_net [get_bd_intf_pins microblaze_$idx/M_AXI_DP] [get_bd_intf_pins $name/S00_AXI]
  connect_bd_net [get_bd_ports clk] [get_bd_pins $name/ACLK]
  connect_bd_net [get_bd_ports clk] [get_bd_pins $name/S00_ACLK]
  connect_bd_net [get_bd_pins rst_cpu$idx/interconnect_aresetn] [get_bd_pins $name/ARESETN]
  connect_bd_net [get_bd_pins rst_cpu$idx/peripheral_aresetn] [get_bd_pins $name/S00_ARESETN]
  for {set m 0} {$m < $num_mi} {incr m} {
    set mm [format M%02d $m]
    connect_bd_net [get_bd_ports clk] [get_bd_pins $name/${mm}_ACLK]
    connect_bd_net [get_bd_pins rst_cpu$idx/peripheral_aresetn] [get_bd_pins $name/${mm}_ARESETN]
  }
}

# c64_bd_axil_port -- create an exported AXI4-Lite master interface port on clk.
proc c64_bd_axil_port {name} {
  set p [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $name]
  set_property -dict [list \
    CONFIG.PROTOCOL   AXI4LITE \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.HAS_PROT   0 \
    CONFIG.FREQ_HZ    $::c64_bd::CPU_CLK_HZ] $p
  return $p
}

# c64_bd_bram_ctrl -- create a 32-bit single-port AXI4-Lite BRAM controller `name` on clk.
proc c64_bd_bram_ctrl {name rstn_pin} {
  set c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 $name]
  set_property -dict [list \
    CONFIG.PROTOCOL         AXI4LITE \
    CONFIG.DATA_WIDTH       32 \
    CONFIG.SINGLE_PORT_BRAM 1 \
    CONFIG.ECC_TYPE         0] $c
  connect_bd_net [get_bd_ports clk] [get_bd_pins $name/s_axi_aclk]
  connect_bd_net [get_bd_pins $rstn_pin] [get_bd_pins $name/s_axi_aresetn]
  return $c
}

proc c64_bd_create {bd_dir} {
  set CPU_CLK_HZ $::c64_bd::CPU_CLK_HZ

  create_bd_design -dir $bd_dir c64_cpu
  current_bd_design c64_cpu

  # ---------------------------------------------------------------------------
  # External ports.
  # ---------------------------------------------------------------------------
  set p_clk [create_bd_port -dir I -type clk -freq_hz $CPU_CLK_HZ clk]
  set p_rst [create_bd_port -dir I -type rst resetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $p_rst
  # Core 0 console: the wrapper pins are uart_rxd (input, from the USB-UART
  # bridge) and uart_txd (output, to it).
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 uart
  # Core 0 codec control bus: iic_scl_i/_o/_t and iic_sda_i/_o/_t; the IOBUFs
  # are in c64_top.
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 iic
  # Fabric interrupts, level, active high.
  set p_irq0 [create_bd_port -dir I -from 7 -to 0 -type intr irq0]
  set_property CONFIG.SENSITIVITY LEVEL_HIGH $p_irq0
  set p_irq1 [create_bd_port -dir I -from 7 -to 0 -type intr irq1]
  set_property CONFIG.SENSITIVITY LEVEL_HIGH $p_irq1
  # Fabric register windows.
  c64_bd_axil_port M_AXI_C64
  c64_bd_axil_port M_AXI_DRV
  # Framebuffer port A of c64_video (BRAM controller master, 32-bit words, byte
  # address, write enables per byte, read latency 1).
  set p_fb [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:bram_rtl:1.0 FB_BRAM]
  # Width, size and latency are read-only on the port: they follow axi_bram_ctrl_fb.
  set_property -dict [list \
    CONFIG.MASTER_TYPE     BRAM_CTRL \
    CONFIG.READ_WRITE_MODE READ_WRITE] $p_fb
  # Core 1 Ethernet frame streams (RTLNet cpu_axis_ethernet_stream): 64-bit
  # tdata, tkeep, tlast.
  set p_rx [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_ETH]
  set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES 8 \
    CONFIG.HAS_TKEEP       1 \
    CONFIG.HAS_TLAST       1 \
    CONFIG.HAS_TREADY      1 \
    CONFIG.HAS_TSTRB       0 \
    CONFIG.TUSER_WIDTH     0 \
    CONFIG.TID_WIDTH       0 \
    CONFIG.TDEST_WIDTH     0 \
    CONFIG.FREQ_HZ         $CPU_CLK_HZ] $p_rx
  set p_tx [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_ETH]
  set_property CONFIG.FREQ_HZ $CPU_CLK_HZ $p_tx
  # DDR3 path: 128-bit AXI4 master, no ID signals, 32-bit address.
  set p_ddr [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_DDR]
  set_property -dict [list \
    CONFIG.PROTOCOL   AXI4 \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.DATA_WIDTH 128 \
    CONFIG.HAS_REGION 0 \
    CONFIG.FREQ_HZ    $CPU_CLK_HZ] $p_ddr
  set_property CONFIG.ASSOCIATED_BUSIF M_AXI_C64:M_AXI_DRV:S_AXIS_ETH:M_AXIS_ETH:M_AXI_DDR $p_clk
  set_property CONFIG.ASSOCIATED_RESET resetn $p_clk

  # ---------------------------------------------------------------------------
  # Shared cells first (the per-core procedures connect to them).
  # ---------------------------------------------------------------------------
  set one [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_one]
  set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 1] $one
  set mdm [create_bd_cell -type ip -vlnv xilinx.com:ip:mdm_riscv:1.0 mdm_0]
  set_property -dict [list CONFIG.C_MB_DBG_PORTS 2 CONFIG.C_USE_UART 0] $mdm

  c64_bd_cpu 0 $::c64_bd::LMB0_SIZE
  c64_bd_cpu 1 $::c64_bd::LMB1_SIZE
  connect_bd_intf_net [get_bd_intf_pins mdm_0/MBDEBUG_0] [get_bd_intf_pins microblaze_0/DEBUG]
  connect_bd_intf_net [get_bd_intf_pins mdm_0/MBDEBUG_1] [get_bd_intf_pins microblaze_1/DEBUG]
  set rst0 rst_cpu0/peripheral_aresetn
  set rst1 rst_cpu1/peripheral_aresetn

  # Mailbox: both ports on clk (C_ASYNC_CLKS 0), each port reset by its core.
  set mbox [create_bd_cell -type ip -vlnv xilinx.com:ip:mailbox:2.1 mailbox_0]
  set_property CONFIG.C_ASYNC_CLKS 0 $mbox
  connect_bd_net [get_bd_ports clk] [get_bd_pins mailbox_0/S0_AXI_ACLK]
  connect_bd_net [get_bd_ports clk] [get_bd_pins mailbox_0/S1_AXI_ACLK]
  connect_bd_net [get_bd_pins $rst0] [get_bd_pins mailbox_0/S0_AXI_ARESETN]
  connect_bd_net [get_bd_pins $rst1] [get_bd_pins mailbox_0/S1_AXI_ARESETN]

  # Shared drive BRAM: true dual port, port A core 0, port B core 1; the size
  # follows the controllers' 128 KiB range (32 RAMB36).
  c64_bd_bram_ctrl axi_bram_ctrl_shm0 $rst0
  c64_bd_bram_ctrl axi_bram_ctrl_shm1 $rst1
  set shm [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 shm_bram]
  set_property -dict [list \
    CONFIG.Memory_Type    True_Dual_Port_RAM \
    CONFIG.use_bram_block BRAM_Controller] $shm
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_shm0/BRAM_PORTA] [get_bd_intf_pins shm_bram/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_shm1/BRAM_PORTA] [get_bd_intf_pins shm_bram/BRAM_PORTB]

  # DDR3 SmartConnect: four cache masters to one 128-bit master.
  set scd [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ddr]
  set_property -dict [list CONFIG.NUM_SI 4 CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 1] $scd
  connect_bd_net [get_bd_ports clk] [get_bd_pins sc_ddr/aclk]
  connect_bd_net [get_bd_pins $rst0] [get_bd_pins sc_ddr/aresetn]
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_IC] [get_bd_intf_pins sc_ddr/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_DC] [get_bd_intf_pins sc_ddr/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins microblaze_1/M_AXI_IC] [get_bd_intf_pins sc_ddr/S02_AXI]
  connect_bd_intf_net [get_bd_intf_pins microblaze_1/M_AXI_DC] [get_bd_intf_pins sc_ddr/S03_AXI]
  connect_bd_intf_net [get_bd_intf_pins sc_ddr/M00_AXI] [get_bd_intf_ports M_AXI_DDR]

  # ---------------------------------------------------------------------------
  # Core 0 peripherals.
  # ---------------------------------------------------------------------------
  set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
  set_property -dict [list \
    CONFIG.C_BAUDRATE   $::c64_bd::UART_BAUD \
    CONFIG.C_DATA_BITS  8 \
    CONFIG.C_USE_PARITY 0] $uart
  connect_bd_net [get_bd_ports clk] [get_bd_pins axi_uartlite_0/s_axi_aclk]
  connect_bd_net [get_bd_pins $rst0] [get_bd_pins axi_uartlite_0/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_uartlite_0/UART] [get_bd_intf_ports uart]

  set iic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0]
  set_property CONFIG.IIC_FREQ_KHZ $::c64_bd::IIC_KHZ $iic
  connect_bd_net [get_bd_ports clk] [get_bd_pins axi_iic_0/s_axi_aclk]
  connect_bd_net [get_bd_pins $rst0] [get_bd_pins axi_iic_0/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_iic_0/IIC] [get_bd_intf_ports iic]

  c64_bd_bram_ctrl axi_bram_ctrl_fb $rst0
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_fb/BRAM_PORTA] [get_bd_intf_ports FB_BRAM]

  # axi_periph_0: M00 UART, M01 timer, M02 INTC, M03 IIC, M04 mailbox S0,
  # M05 M_AXI_C64, M06 framebuffer, M07 shared BRAM.
  c64_bd_periph axi_periph_0 0 8
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M00_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M01_AXI] [get_bd_intf_pins axi_timer_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M02_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M03_AXI] [get_bd_intf_pins axi_iic_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M04_AXI] [get_bd_intf_pins mailbox_0/S0_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M05_AXI] [get_bd_intf_ports M_AXI_C64]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M06_AXI] [get_bd_intf_pins axi_bram_ctrl_fb/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_0/M07_AXI] [get_bd_intf_pins axi_bram_ctrl_shm0/S_AXI]

  # Core 0 interrupts: irq0[7:0] at 0..7, timer 8, UART 9, mailbox 10, IIC 11.
  set cat0 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 irq_concat_0]
  set_property -dict [list \
    CONFIG.NUM_PORTS 5 \
    CONFIG.IN0_WIDTH 8 \
    CONFIG.IN1_WIDTH 1 \
    CONFIG.IN2_WIDTH 1 \
    CONFIG.IN3_WIDTH 1 \
    CONFIG.IN4_WIDTH 1] $cat0
  connect_bd_net [get_bd_ports irq0] [get_bd_pins irq_concat_0/In0]
  connect_bd_net [get_bd_pins axi_timer_0/interrupt] [get_bd_pins irq_concat_0/In1]
  connect_bd_net [get_bd_pins axi_uartlite_0/interrupt] [get_bd_pins irq_concat_0/In2]
  connect_bd_net [get_bd_pins mailbox_0/Interrupt_0] [get_bd_pins irq_concat_0/In3]
  connect_bd_net [get_bd_pins axi_iic_0/iic2intc_irpt] [get_bd_pins irq_concat_0/In4]
  connect_bd_net [get_bd_pins irq_concat_0/dout] [get_bd_pins axi_intc_0/intr]

  # ---------------------------------------------------------------------------
  # Core 1 peripherals: RTLNet CPU network path (DMA in simple mode, 64-bit
  # memory side and streams, realignment on MM2S only, 14-bit length).
  # ---------------------------------------------------------------------------
  set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
  set_property -dict [list \
    CONFIG.c_include_sg              0 \
    CONFIG.c_sg_length_width         $::c64_bd::DMA_LEN_W \
    CONFIG.c_addr_width              32 \
    CONFIG.c_include_mm2s            1 \
    CONFIG.c_include_s2mm            1 \
    CONFIG.c_m_axi_mm2s_data_width   64 \
    CONFIG.c_m_axis_mm2s_tdata_width 64 \
    CONFIG.c_m_axi_s2mm_data_width   64 \
    CONFIG.c_s_axis_s2mm_tdata_width 64 \
    CONFIG.c_include_mm2s_dre        1 \
    CONFIG.c_include_s2mm_dre        0 \
    CONFIG.c_mm2s_burst_size         16 \
    CONFIG.c_s2mm_burst_size         16] $dma
  foreach p {axi_dma_0/s_axi_lite_aclk axi_dma_0/m_axi_mm2s_aclk axi_dma_0/m_axi_s2mm_aclk} {
    connect_bd_net [get_bd_ports clk] [get_bd_pins $p]
  }
  connect_bd_net [get_bd_pins $rst1] [get_bd_pins axi_dma_0/axi_resetn]
  connect_bd_intf_net [get_bd_intf_ports S_AXIS_ETH] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_ports M_AXIS_ETH]

  # Network buffer memory: AXI4 64-bit controller and its block RAM (RTLNet).
  set bctl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0]
  set_property -dict [list \
    CONFIG.PROTOCOL         AXI4 \
    CONFIG.DATA_WIDTH       64 \
    CONFIG.SINGLE_PORT_BRAM 1 \
    CONFIG.ECC_TYPE         0] $bctl
  connect_bd_net [get_bd_ports clk] [get_bd_pins axi_bram_ctrl_0/s_axi_aclk]
  connect_bd_net [get_bd_pins $rst1] [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn]
  set nbram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 axi_bram]
  set_property -dict [list \
    CONFIG.Memory_Type    Single_Port_RAM \
    CONFIG.use_bram_block BRAM_Controller] $nbram
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins axi_bram/BRAM_PORTA]

  # axi_mem: core 1 memory path and both DMA channels to the network BRAM.
  set icm [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem]
  set_property -dict [list CONFIG.NUM_SI 3 CONFIG.NUM_MI 1] $icm
  foreach p {ACLK S00_ACLK S01_ACLK S02_ACLK M00_ACLK} {
    connect_bd_net [get_bd_ports clk] [get_bd_pins axi_mem/$p]
  }
  connect_bd_net [get_bd_pins rst_cpu1/interconnect_aresetn] [get_bd_pins axi_mem/ARESETN]
  foreach p {S00_ARESETN S01_ARESETN S02_ARESETN M00_ARESETN} {
    connect_bd_net [get_bd_pins $rst1] [get_bd_pins axi_mem/$p]
  }
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem/S02_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_mem/M00_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]

  # axi_periph_1: M00 timer, M01 INTC, M02 mailbox S1, M03 M_AXI_DRV,
  # M04 DMA registers, M05 network BRAM path (axi_mem), M06 shared BRAM.
  c64_bd_periph axi_periph_1 1 7
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M00_AXI] [get_bd_intf_pins axi_timer_1/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M01_AXI] [get_bd_intf_pins axi_intc_1/s_axi]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M02_AXI] [get_bd_intf_pins mailbox_0/S1_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M03_AXI] [get_bd_intf_ports M_AXI_DRV]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M04_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M05_AXI] [get_bd_intf_pins axi_mem/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph_1/M06_AXI] [get_bd_intf_pins axi_bram_ctrl_shm1/S_AXI]

  # Core 1 interrupts: irq1[7:0] at 0..7, timer 8, mailbox 9, DMA MM2S 10, DMA S2MM 11.
  set cat1 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 irq_concat_1]
  set_property -dict [list \
    CONFIG.NUM_PORTS 5 \
    CONFIG.IN0_WIDTH 8 \
    CONFIG.IN1_WIDTH 1 \
    CONFIG.IN2_WIDTH 1 \
    CONFIG.IN3_WIDTH 1 \
    CONFIG.IN4_WIDTH 1] $cat1
  connect_bd_net [get_bd_ports irq1] [get_bd_pins irq_concat_1/In0]
  connect_bd_net [get_bd_pins axi_timer_1/interrupt] [get_bd_pins irq_concat_1/In1]
  connect_bd_net [get_bd_pins mailbox_0/Interrupt_1] [get_bd_pins irq_concat_1/In2]
  connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins irq_concat_1/In3]
  connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins irq_concat_1/In4]
  connect_bd_net [get_bd_pins irq_concat_1/dout] [get_bd_pins axi_intc_1/intr]

  # ---------------------------------------------------------------------------
  # Address map.
  # ---------------------------------------------------------------------------
  set d0 [get_bd_addr_spaces microblaze_0/Data]
  set i0 [get_bd_addr_spaces microblaze_0/Instruction]
  set d1 [get_bd_addr_spaces microblaze_1/Data]
  set i1 [get_bd_addr_spaces microblaze_1/Instruction]
  assign_bd_address -offset 0x00000000 -range $::c64_bd::LMB0_SIZE -target_address_space $d0 \
    [get_bd_addr_segs dlmb_bram_if_cntlr_0/SLMB/Mem] -force
  assign_bd_address -offset 0x00000000 -range $::c64_bd::LMB0_SIZE -target_address_space $i0 \
    [get_bd_addr_segs ilmb_bram_if_cntlr_0/SLMB/Mem] -force
  assign_bd_address -offset 0x00000000 -range $::c64_bd::LMB1_SIZE -target_address_space $d1 \
    [get_bd_addr_segs dlmb_bram_if_cntlr_1/SLMB/Mem] -force
  assign_bd_address -offset 0x00000000 -range $::c64_bd::LMB1_SIZE -target_address_space $i1 \
    [get_bd_addr_segs ilmb_bram_if_cntlr_1/SLMB/Mem] -force

  assign_bd_address -offset $::c64_bd::UART_BASE -range 64K -target_address_space $d0 \
    [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::IIC_BASE -range 64K -target_address_space $d0 \
    [get_bd_addr_segs axi_iic_0/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::INTC_BASE -range 64K -target_address_space $d0 \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::TIMER_BASE -range 64K -target_address_space $d0 \
    [get_bd_addr_segs axi_timer_0/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::MBOX_BASE -range 64K -target_address_space $d0 \
    [get_bd_addr_segs mailbox_0/S0_AXI/S0_AXI_Reg] -force
  assign_bd_address -offset $::c64_bd::WIN0_BASE -range $::c64_bd::WIN0_RANGE -target_address_space $d0 \
    [get_bd_addr_segs M_AXI_C64/Reg] -force
  assign_bd_address -offset $::c64_bd::FB_BASE -range $::c64_bd::FB_RANGE -target_address_space $d0 \
    [get_bd_addr_segs axi_bram_ctrl_fb/S_AXI/Mem0] -force
  assign_bd_address -offset $::c64_bd::SHM_BASE -range $::c64_bd::SHM_RANGE -target_address_space $d0 \
    [get_bd_addr_segs axi_bram_ctrl_shm0/S_AXI/Mem0] -force

  assign_bd_address -offset $::c64_bd::DMA_BASE -range 64K -target_address_space $d1 \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force
  assign_bd_address -offset $::c64_bd::INTC_BASE -range 64K -target_address_space $d1 \
    [get_bd_addr_segs axi_intc_1/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::TIMER_BASE -range 64K -target_address_space $d1 \
    [get_bd_addr_segs axi_timer_1/S_AXI/Reg] -force
  assign_bd_address -offset $::c64_bd::MBOX_BASE -range 64K -target_address_space $d1 \
    [get_bd_addr_segs mailbox_0/S1_AXI/S1_AXI_Reg] -force
  assign_bd_address -offset $::c64_bd::WIN1_BASE -range $::c64_bd::WIN1_RANGE -target_address_space $d1 \
    [get_bd_addr_segs M_AXI_DRV/Reg] -force
  assign_bd_address -offset $::c64_bd::SHM_BASE -range $::c64_bd::SHM_RANGE -target_address_space $d1 \
    [get_bd_addr_segs axi_bram_ctrl_shm1/S_AXI/Mem0] -force
  foreach sp [list $d1 [get_bd_addr_spaces axi_dma_0/Data_MM2S] [get_bd_addr_spaces axi_dma_0/Data_S2MM]] {
    assign_bd_address -offset $::c64_bd::NETBUF_BASE -range $::c64_bd::NETBUF_RANGE \
      -target_address_space $sp [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force
  }

  foreach sp [list $d0 $i0 $d1 $i1] {
    assign_bd_address -offset $::c64_bd::DDR_BASE -range $::c64_bd::DDR_SIZE \
      -target_address_space $sp [get_bd_addr_segs M_AXI_DDR/Reg] -force
  }

  validate_bd_design
  save_bd_design
  return [get_files c64_cpu.bd]
}
