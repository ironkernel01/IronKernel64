/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64_platform.h
 * Role: the address map of both MicroBlaze V cores for the blocks the BD
 *   exports as external ports (fabric windows, framebuffer, shared BRAM, DDR3).
 *
 * Owner: fpga/bd/c64_bd.tcl (namespace c64_bd: WIN0_BASE, WIN1_BASE, FB_BASE,
 *   SHM_BASE, DDR_BASE and the ranges). Every value here mirrors that file;
 *   change both in the same commit. Drift failure mode: the firmware accesses an
 *   unmapped address; with bus exceptions disabled the read returns garbage
 *   (DECERR data) and the write is lost, or the access lands in another block.
 * IP blocks inside the BD (UART Lite, IIC, timer, INTC, Mailbox, DMA) are not
 *   here: their bases come from the generated xparameters.h.
 * Offsets inside the fabric windows come from fw_c64/src/c64_regs.h
 *   (C64_WIN_*_OFS and C64_WIN1_*_OFS, mirrored from fpga/hdl/c64_pkg.sv).
 * Caching: both cores cache only the DDR3 window; every other region here is
 *   accessed uncached.
 */
#ifndef C64_PLATFORM_H
#define C64_PLATFORM_H

/* Core 0: fabric register window (M_AXI_C64) -> c64_top window decoder 0. */
#define C64_PLAT_WIN0_BASE       (0x44000000u)
#define C64_PLAT_WIN0_RANGE      (0x00080000u)  /* = C64_WIN_SIZE */
/* Core 1: fabric register window (M_AXI_DRV) -> c64_top window decoder 1,
 * RTLNet's window base and layout (C64_WIN1_*_OFS). */
#define C64_PLAT_WIN1_BASE       (0x44A00000u)
#define C64_PLAT_WIN1_RANGE      (0x00100000u)  /* = C64_WIN1_SIZE */

/* Core 0: framebuffer (AXI BRAM Controller -> c64_video port A), 2 pages. */
#define C64_PLAT_FB_BASE         (0xC0000000u)
#define C64_PLAT_FB_RANGE        (0x00040000u)  /* 256 KiB window, 184,320 bytes used */

/* Core 1: network DMA buffer BRAM (RTLNet layout, core 1 address space only). */
#define C64_PLAT_NETBUF_BASE     (0xC0000000u)
#define C64_PLAT_NETBUF_RANGE    (0x00020000u)

/* Both cores: shared drive BRAM (common/drive_proto.h DRIVE_SHM_BYTES). */
#define C64_PLAT_SHM_BASE        (0xC1000000u)
#define C64_PLAT_SHM_RANGE       (0x00020000u)  /* 128 KiB */

/* Both cores: DDR3 (MIG), cached. Size is the BD window; firmware probes the
 * populated size at boot (fw_c64/src/ddr_probe.c). */
#define C64_PLAT_DDR_BASE        (0x80000000u)
#define C64_PLAT_DDR_WINDOW      (0x20000000u)  /* 512 MiB */

/* DDR3 partition between the cores (firmware convention, not hardware):
 *   [0x8000_0000, +64 MiB)  core 1 code/data/heap pools (FreeRTOS, lwIP, libsmb2)
 *   [0x8400_0000, +64 MiB)  core 0 reserved (bring-up RAM-disk bank, register logs)
 *   rest                    free (reported as BYTES FREE on the boot screen)   */
#define C64_PLAT_DDR_CORE1_BASE  (0x80000000u)
#define C64_PLAT_DDR_CORE1_SIZE  (0x04000000u)
#define C64_PLAT_DDR_CORE0_BASE  (0x84000000u)
#define C64_PLAT_DDR_CORE0_SIZE  (0x04000000u)

#endif /* C64_PLATFORM_H */
