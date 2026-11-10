/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sidbus_fabric.c
 * Role: sidbus.h on the sid_player block (C64_PLAT_WIN0_BASE + C64_WIN_SID_OFS; registers in
 *   c64_regs.h): every SID write becomes a timestamped FIFO push that the fabric replays at
 *   its phi2 cycle into the RTL SID.
 *
 * Ownership: the only file that touches the sid_player registers.
 * Model: the hardware is a 6581 (reDIP-SID, one chip); an 8580 request plays as a 6581.
 * Concurrency: core 0 main loop only (no ISR touches this block).
 */
#include "sidbus.h"
#include "sidbus_fabric.h"

#include <stddef.h> /* NULL */

#include "c64_platform.h"
#include "c64_regs.h"

#include "sleep.h"      /* usleep (reset hold) */
#include "xil_io.h"     /* Xil_In32, Xil_Out32 */

#define SID_REG(ofs)        (C64_PLAT_WIN0_BASE + C64_WIN_SID_OFS + (uint32_t)(ofs))
#define SID_CTRL_RUN        (1u << C64_SID_CTRL_RUN_BIT)
#define SID_CTRL_RESET      (1u << C64_SID_CTRL_RESET_BIT)
#define SID_REG_FIELD_MASK  (0x1Fu)
#define SID_RDBK_BYTE_MASK  (0xFFu)

static uint32_t g_base;        /* time the next frame_begin latches */
static uint32_t g_frame_base;  /* base of the current call */
static uint32_t g_dropped;     /* writes not pushed: FIFO stayed full */
static sidbus_fabric_tap_t g_tap;   /* optional write observer */

/*
 * sidbus_fabric_set_tap -- install (or with NULL remove) the write observer.
 * Returns: nothing.
 */
void sidbus_fabric_set_tap(sidbus_fabric_tap_t tap)
{
    g_tap = tap;
}

/*
 * sidbus_reset -- silence the SID and restart its time.
 * Steps:
 *   1. CTRL = RUN | RESET for SIDBUS_FABRIC_RESET_HOLD_US (the core sees res only while
 *      phi2 runs), then CTRL = RUN: CYCLE counts from 0, the FIFO is empty.
 *   2. Frame base 0. model: only the 6581 exists in the fabric; 8580 plays as 6581.
 * Returns: nothing.
 */
void sidbus_reset(sidbus_model_t model)
{
    (void)model;
    Xil_Out32(SID_REG(C64_SID_CTRL_OFS), SID_CTRL_RUN | SID_CTRL_RESET);
    usleep(SIDBUS_FABRIC_RESET_HOLD_US);
    Xil_Out32(SID_REG(C64_SID_CTRL_OFS), SID_CTRL_RUN);
    Xil_Out32(SID_REG(C64_SID_STATUS_OFS), 1u << C64_SID_STATUS_OVERFLOW_BIT);
    g_base = 0u;
    g_frame_base = 0u;
}

/*
 * sidbus_frame_begin -- latch the base time of the call that starts now.
 * Returns: nothing.
 */
void sidbus_frame_begin(void)
{
    g_frame_base = g_base;
}

/*
 * sidbus_write -- push one timestamped write.
 * Steps:
 *   1. Wait for FIFO room: at most SIDBUS_FABRIC_FULL_SPIN_MAX STATUS reads; still full: count
 *      the write as dropped and return (the hardware would drop it and flag OVERFLOW).
 *   2. WTIME = frame base + cycle; WDATA = reg << 8 | val.
 *   3. The write tap (if any) sees the pushed write with its absolute stamp.
 * Returns: nothing.
 */
void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val)
{
    uint32_t spins = 0u;

    while ((Xil_In32(SID_REG(C64_SID_STATUS_OFS)) & (1u << C64_SID_STATUS_FULL_BIT)) != 0u) {
        if (++spins > SIDBUS_FABRIC_FULL_SPIN_MAX) {
            g_dropped++;
            return;
        }
    }
    Xil_Out32(SID_REG(C64_SID_WTIME_OFS), g_frame_base + cycle);
    Xil_Out32(SID_REG(C64_SID_WDATA_OFS),
              ((uint32_t)(reg & SID_REG_FIELD_MASK) << C64_SID_WDATA_REG_LSB) | val);
    if (g_tap != NULL) {
        g_tap(g_frame_base + cycle, (uint8_t)(reg & SID_REG_FIELD_MASK), val);
    }
}

/*
 * sidbus_read -- 6502 read of $D419-$D41C.
 * Returns: OSC3 (reg 27) / ENV3 (reg 28) from RDBK; the POTs (25, 26) read 0.
 */
uint8_t sidbus_read(uint8_t reg)
{
    const uint32_t rdbk = Xil_In32(SID_REG(C64_SID_RDBK_OFS));

    if (reg == SIDBUS_REG_OSC3) {
        return (uint8_t)(rdbk & SID_RDBK_BYTE_MASK);
    }
    if (reg == SIDBUS_REG_ENV3) {
        return (uint8_t)((rdbk >> C64_SID_RDBK_ENV3_LSB) & SID_RDBK_BYTE_MASK);
    }
    return 0u;
}

/*
 * sidbus_fabric_cycle -- phi2 cycles since the last reset (CYCLE register).
 * Returns: the 32-bit count.
 */
uint32_t sidbus_fabric_cycle(void)
{
    return Xil_In32(SID_REG(C64_SID_CYCLE_OFS));
}

/*
 * sidbus_fabric_set_base -- time that the next sidbus_frame_begin() latches.
 * Returns: nothing.
 */
void sidbus_fabric_set_base(uint32_t cycle)
{
    g_base = cycle;
}

/*
 * sidbus_fabric_env3 -- voice 3 envelope from RDBK.
 * Returns: 0..255.
 */
uint8_t sidbus_fabric_env3(void)
{
    return sidbus_read(SIDBUS_REG_ENV3);
}

/*
 * sidbus_fabric_dropped -- writes dropped because the FIFO stayed full.
 * Returns: the count since boot.
 */
uint32_t sidbus_fabric_dropped(void)
{
    return g_dropped;
}
