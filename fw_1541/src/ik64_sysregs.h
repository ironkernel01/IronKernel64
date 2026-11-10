/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ik64_sysregs.h
 * Role: core 1's access to the board system registers (c64_sysregs) in its
 *   register window. IK64's SYS slot at 0x44A0_0000 is c64_sysregs
 *   (fpga/hdl/c64_sysregs.sv), NOT RTLNet's sysregs
 *   (rtlnet_nexys_video_sysregs.h): offsets and bits differ, and no RTLNet
 *   board_sys_* function is linked. This header is the mapping:
 *     RTLNet NXV_SYS_CLK_STATUS / NXV_CLK_DDR_CALIB -> C64_SYS_CLK_STATUS_OFS bit C64_SYS_CLK_DDR_CALIB_BIT
 *     Ethernet link (RTLNet: mac status)            -> C64_SYS_CLK_ETH_LINK_BIT
 *     RTLNet build/version registers                -> C64_SYS_BUILD_ID_OFS (git hash), C64_SYS_BUILD_FLAGS_OFS
 *   Offsets and bit numbers come from fw_c64/src/c64_regs.h, which
 *   tools/regs_check.py keeps equal to fpga/hdl/c64_pkg.sv; this file includes
 *   it by relative path instead of copying the values.
 *
 * Headers hold contracts and constants; the functions are static inline reads.
 * IK64_DEVIATION 8 (fw_1541/DEVIATIONS.md).
 */
#ifndef IK64_SYSREGS_H
#define IK64_SYSREGS_H

#include "../../fw_c64/src/c64_regs.h"   /* C64_SYS_*, C64_WIN1_* */
#include "c64_platform.h"                /* C64_PLAT_WIN1_BASE */

#include <stdint.h> /* uint32_t */

/* BUILD_FLAGS: bit 0 = tree was dirty at build time; [15:8] = core index (c64_sysregs.sv). */
#define IK64_SYS_FLAGS_DIRTY_MASK   (0x1u)
#define IK64_SYS_FLAGS_CORE_SHIFT   (8u)
#define IK64_SYS_FLAGS_CORE_MASK    (0xFFu)

static inline uint32_t ik64_sys_read(uint32_t ofs)
{
    return *(volatile const uint32_t *)(C64_PLAT_WIN1_BASE + C64_WIN1_SYS_OFS + ofs);
}

static inline int ik64_sys_ddr_calibrated(void)
{
    return ((ik64_sys_read(C64_SYS_CLK_STATUS_OFS) >> C64_SYS_CLK_DDR_CALIB_BIT) & 1u) != 0u;
}

static inline int ik64_sys_eth_link(void)
{
    return ((ik64_sys_read(C64_SYS_CLK_STATUS_OFS) >> C64_SYS_CLK_ETH_LINK_BIT) & 1u) != 0u;
}

#endif /* IK64_SYSREGS_H */
