/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sidbus_log.c
 * Role: recording implementation of the SID register sink (sidbus.h): keeps the
 *   writes of the current 6502 call in a static array and answers reads from the
 *   last written values. Used for the siddump-style CLI dump and for bring-up
 *   before the fabric driver exists; link either this file or the fabric driver.
 *
 * Owns: g_log (the per-frame write record), g_regs (last value per register).
 */
#include "sidbus.h"

#include <stddef.h> /* NULL */
#include <string.h> /* memset */

static sidbus_write_t g_log[SIDBUS_LOG_CAPACITY];
static uint32_t g_count;
static uint32_t g_overflows;
static uint8_t g_regs[SIDBUS_REGS];
static sidbus_model_t g_model;

/*
 * sidbus_reset -- chip reset for a new song.
 * Steps:
 *   1. Clear the register values, the record and the overflow count; note the model.
 * Returns: nothing.
 */
void sidbus_reset(sidbus_model_t model)
{
    memset(g_regs, 0, sizeof(g_regs));
    g_count = 0u;
    g_overflows = 0u;
    g_model = model;
}

/*
 * sidbus_frame_begin -- start the record of a new 6502 call.
 * Steps:
 *   1. Empty the record and clear the overflow count of the previous call.
 * Returns: nothing.
 */
void sidbus_frame_begin(void)
{
    g_count = 0u;
    g_overflows = 0u;
}

/*
 * sidbus_write -- record one SID register write.
 * Steps:
 *   1. Keep the value for reads (register masked to 5 bits).
 *   2. Append {cycle, reg, val}, or count an overflow when the record is full.
 * Returns: nothing.
 */
void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val)
{
    const uint8_t r = (uint8_t)(reg & SIDBUS_REG_MASK);

    g_regs[r] = val;
    if (g_count < SIDBUS_LOG_CAPACITY) {
        g_log[g_count].cycle = cycle;
        g_log[g_count].reg = r;
        g_log[g_count].val = val;
        g_count++;
    } else {
        g_overflows++;
    }
}

/*
 * sidbus_read -- answer a read of a SID register.
 * Returns: the last written value for registers 0..24, 0 for 25..28 (POTX, POTY, OSC3,
 *   ENV3 have no source in the recording stub) and for the unused 29..31.
 */
uint8_t sidbus_read(uint8_t reg)
{
    const uint8_t r = (uint8_t)(reg & SIDBUS_REG_MASK);

    return (r <= SIDBUS_REG_LAST_WRITE) ? g_regs[r] : 0u;
}

/*
 * sidbus_log_frame -- the writes recorded since the last sidbus_frame_begin.
 * Returns: the record in cycle order; *n_writes receives the entry count.
 */
const sidbus_write_t *sidbus_log_frame(uint32_t *n_writes)
{
    if (n_writes != NULL) {
        *n_writes = g_count;
    }
    return g_log;
}

/*
 * sidbus_log_overflows -- writes of the current call that did not fit the record.
 * Returns: the count (0 for every play call within the 20,000-cycle cap).
 */
uint32_t sidbus_log_overflows(void)
{
    return g_overflows;
}

/*
 * sidbus_log_model -- chip model of the last sidbus_reset.
 * Returns: SIDBUS_MODEL_6581 or SIDBUS_MODEL_8580.
 */
sidbus_model_t sidbus_log_model(void)
{
    return g_model;
}
