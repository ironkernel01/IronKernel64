/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64_regs.h
 * Role: register offsets, bit positions and geometry of the IronKernel 64
 *   fabric blocks, as seen by the core 0 firmware.
 *
 * Contract: this file mirrors fpga/hdl/c64_pkg.sv. Every define here is
 *   C64_<package name> with the package value; tools/regs_check.py (run by
 *   fw_c64/build.ps1) evaluates both files and fails the build on any missing
 *   name or different value. Change both files in the same commit.
 *   Drift failure mode: a write lands in the wrong register (a palette write
 *   landing in CTRL blanks the display) and no hardware check catches it.
 * Base addresses are not here: they come from xparameters.h (owned by
 *   fpga/bd/c64_bd.tcl through the XSA).
 * Headers hold contracts and constants; per-function commentary lives in the
 *   .c files.
 */
#ifndef C64_REGS_H
#define C64_REGS_H

/* Common */
#define C64_REG_ADDR_W                 (16u)
#define C64_CPU_CLK_HZ                 (100000000u)
#define C64_WIN_SYS_OFS                (0x00000000u)
#define C64_WIN_AUD_OFS                (0x00010000u)
#define C64_WIN_VID_OFS                (0x00020000u)
#define C64_WIN_PS2_OFS                (0x00030000u)
#define C64_WIN_SID_OFS                (0x00040000u)
#define C64_WIN_BLOCK_SIZE             (0x00010000u)
#define C64_WIN_SIZE                   (0x00040000u)
#define C64_WIN1_SYS_OFS               (0x00000000u)
#define C64_WIN1_MAC_OFS               (0x00001000u)
#define C64_WIN1_MDIO_OFS              (0x00002000u)
#define C64_WIN1_ARB_OFS               (0x00004000u)
#define C64_WIN1_PROT_OFS              (0x00010000u)
#define C64_WIN1_SLOT_SIZE             (0x00001000u)
#define C64_WIN1_PROT_SIZE             (0x00010000u)
#define C64_WIN1_SIZE                  (0x00100000u)

/* System registers (c64_sysregs) */
#define C64_SYS_MAGIC_OFS              (0x0000u)
#define C64_SYS_BUILD_ID_OFS           (0x0004u)
#define C64_SYS_BUILD_FLAGS_OFS        (0x0008u)
#define C64_SYS_CLK_STATUS_OFS         (0x000Cu)
#define C64_SYS_LED_OFS                (0x0010u)
#define C64_SYS_SCRATCH_OFS            (0x0014u)
#define C64_SYS_MAGIC_VALUE            (0x494B3634u)
#define C64_SYS_CLK_PIX_LOCKED_BIT     (0u)
#define C64_SYS_CLK_DDR_CALIB_BIT      (1u)
#define C64_SYS_CLK_AUD_LOCKED_BIT     (2u)
#define C64_SYS_CLK_HDMI_HPD_BIT       (3u)
#define C64_SYS_CLK_ETH_LINK_BIT       (4u)

/* Audio output (sid_audio_out) */
#define C64_AUD_CTRL_OFS               (0x0000u)
#define C64_AUD_STATUS_OFS             (0x0004u)
#define C64_AUD_LEVEL_OFS              (0x0008u)
#define C64_AUD_SAMPLE_OFS             (0x000Cu)
#define C64_AUD_UNDERRUNS_OFS          (0x0010u)
#define C64_AUD_THRESH_OFS             (0x0014u)
#define C64_AUD_CTRL_ENABLE_BIT        (0u)
#define C64_AUD_CTRL_FLUSH_BIT         (1u)
#define C64_AUD_CTRL_SRC_BIT           (2u)
#define C64_AUD_CTRL_IRQ_EN_BIT        (8u)
#define C64_AUD_STATUS_IRQ_BIT         (0u)
#define C64_AUD_STATUS_UNDERRUN_BIT    (1u)
#define C64_AUD_STATUS_FULL_BIT        (2u)
#define C64_AUD_FIFO_DEPTH             (2048u)
#define C64_AUD_LEVEL_W                (12u)
#define C64_AUD_SAMPLE_RATE_HZ         (48000u)
#define C64_AUD_MCLK_PER_FS            (256u)
#define C64_AUD_BCLK_PER_FS            (64u)
#define C64_AUD_SAMPLE_W               (16u)

/* SID player (sid_player) */
#define C64_SID_CTRL_OFS               (0x0000u)
#define C64_SID_STATUS_OFS             (0x0004u)
#define C64_SID_CYCLE_OFS              (0x0008u)
#define C64_SID_WTIME_OFS              (0x000Cu)
#define C64_SID_WDATA_OFS              (0x0010u)
#define C64_SID_RDBK_OFS               (0x0014u)
#define C64_SID_CTRL_RUN_BIT           (0u)
#define C64_SID_CTRL_RESET_BIT         (1u)
#define C64_SID_STATUS_OVERFLOW_BIT    (0u)
#define C64_SID_STATUS_FULL_BIT        (1u)
#define C64_SID_STATUS_LEVEL_LSB       (16u)
#define C64_SID_WDATA_REG_LSB          (8u)
#define C64_SID_RDBK_ENV3_LSB          (8u)
#define C64_SID_FIFO_DEPTH             (512u)
#define C64_SID_LEVEL_W                (10u)
#define C64_SID_PHI2_HZ                (985248u)
#define C64_SID_DECIM_TAPS             (20u)

/* Video (c64_video) */
#define C64_VID_CTRL_OFS               (0x0000u)
#define C64_VID_STATUS_OFS             (0x0004u)
#define C64_VID_FRAME_OFS              (0x0008u)
#define C64_VID_LINE_OFS               (0x000Cu)
#define C64_VID_PALETTE_OFS            (0x0400u)
#define C64_VID_CTRL_ENABLE_BIT        (0u)
#define C64_VID_CTRL_PAGE_BIT          (1u)
#define C64_VID_CTRL_IRQ_EN_BIT        (8u)
#define C64_VID_STATUS_PAGE_BIT        (0u)
#define C64_VID_STATUS_VSYNC_BIT       (1u)
#define C64_VID_PALETTE_ENTRIES        (256u)
#define C64_FB_WIDTH                   (384u)
#define C64_FB_HEIGHT                  (240u)
#define C64_FB_SCALE                   (3u)
#define C64_FB_PAGE_BYTES              (92160u)
#define C64_FB_PAGES                   (2u)
#define C64_FB_WORDS                   (46080u)
#define C64_FB_WORD_ADDR_W             (16u)
#define C64_FB_LINE_WORDS              (96u)
#define C64_VID_H_ACTIVE               (1280u)
#define C64_VID_H_FRONT                (110u)
#define C64_VID_H_SYNC                 (40u)
#define C64_VID_H_BACK                 (220u)
#define C64_VID_H_TOTAL                (1650u)
#define C64_VID_V_ACTIVE               (720u)
#define C64_VID_V_FRONT                (5u)
#define C64_VID_V_SYNC                 (5u)
#define C64_VID_V_BACK                 (20u)
#define C64_VID_V_TOTAL                (750u)
#define C64_VID_X_OFFSET               (64u)

/* PS/2 receiver (ps2_rx) */
#define C64_PS2_DATA_OFS               (0x0000u)
#define C64_PS2_STATUS_OFS             (0x0004u)
#define C64_PS2_CTRL_OFS               (0x0008u)
#define C64_PS2_DATA_VALID_BIT         (8u)
#define C64_PS2_STATUS_AVAIL_BIT       (0u)
#define C64_PS2_STATUS_PARITY_BIT      (1u)
#define C64_PS2_STATUS_OVERFLOW_BIT    (2u)
#define C64_PS2_STATUS_FRAME_BIT       (3u)
#define C64_PS2_CTRL_IRQ_EN_BIT        (0u)
#define C64_PS2_FIFO_DEPTH             (16u)

#endif /* C64_REGS_H */
