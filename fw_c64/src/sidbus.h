/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sidbus.h
 * Role: the SID register sink of the core 0 player: every 6502 access to the SID
 *   window ($D400-$D7FF, 32-byte mirror, register = addr & $1F) that c64mem.c
 *   forwards to the SID chip, which is an RTL SID core in the fabric.
 *
 * Interface (one implementation is linked): sidbus_fabric.c streams the writes to the
 *   sid_player block (timestamped FIFO in front of the RTL SID). sidbus_log.c is the
 *   superseded recording stub and is not part of the build.
 *
 * Call order, all from the core 0 main loop:
 *   sidbus_reset(model)       on every PSID song init, before the init call.
 *   sidbus_frame_begin()      by c64mem at the start of every 6502 call (init, play);
 *                             the cycle offsets of the following writes count from it.
 *   sidbus_write(cycle,r,v)   for every SID register write, in cycle order. cycle is
 *                             the 6502 cycle offset inside the current call (0 = its
 *                             first cycle; a play call stays below
 *                             C64MEM_PLAY_MAX_CYCLES + 8, an init call can run longer).
 *                             Read-modify-write instructions issue two writes (the NMOS
 *                             dummy write of the old value, then the result).
 *   sidbus_read(reg)          for 6502 reads of $D419-$D41C (POTX, POTY, OSC3, ENV3;
 *                             reg 25..28). Reads of the write-only registers are
 *                             answered by c64mem's own shadow and never reach here.
 * Frame model: one play call per PAL frame of SID_BUS_FRAME_CYCLES (312 x 63) cycles.
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in the implementation file.
 */
#ifndef SIDBUS_H
#define SIDBUS_H

#include <stdint.h> /* uint8_t, uint32_t */

#define SIDBUS_REGS            (32u)
#define SIDBUS_REG_MASK        (0x1Fu)
#define SIDBUS_REG_LAST_WRITE  (24u)      /* $D418: registers 0..24 are write-only */
#define SIDBUS_REG_POTX        (25u)
#define SIDBUS_REG_POTY        (26u)
#define SIDBUS_REG_OSC3        (27u)
#define SIDBUS_REG_ENV3        (28u)
#define SIDBUS_FRAME_CYCLES    (19656u)   /* PAL: 312 lines x 63 cycles */

typedef enum
{
    SIDBUS_MODEL_6581 = 0,
    SIDBUS_MODEL_8580 = 1
} sidbus_model_t;

void sidbus_reset(sidbus_model_t model);
void sidbus_frame_begin(void);
void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val);
uint8_t sidbus_read(uint8_t reg);

/* Play-call cycle cap that c64mem.c cross-checks against C64MEM_PLAY_MAX_CYCLES. */
#define SIDBUS_LOG_PLAY_MAX_CYCLES  (20000u)

#endif /* SIDBUS_H */
