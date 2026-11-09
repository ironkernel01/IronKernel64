/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sidbus.h
 * Role: the SID register sink of the core 0 player: every 6502 access to the SID
 *   window ($D400-$D7FF, 32-byte mirror, register = addr & $1F) that c64mem.c
 *   forwards to the SID chip, which is an RTL SID core in the fabric.
 *
 * Interface (one implementation is linked):
 *   - sidbus_log.c: recording stub; stores the writes of the current frame in a
 *     static array (accessors in the "recording stub" section below).
 *   - the fabric driver (owned by the lead): streams the writes to the RTL SID.
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

typedef struct
{
    uint32_t cycle;   /* 6502 cycle offset inside the current call */
    uint8_t  reg;     /* 0..31 */
    uint8_t  val;
} sidbus_write_t;

void sidbus_reset(sidbus_model_t model);
void sidbus_frame_begin(void);
void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val);
uint8_t sidbus_read(uint8_t reg);

/* ---- recording stub only (sidbus_log.c) ---- */

/*
 * Capacity: the most SID writes one play call can make.
 *   - A play call is capped at 20,000 cycles (C64MEM_PLAY_MAX_CYCLES, c64mem.h); the
 *     run loop checks the cap between instructions, so a call ends within 20,000 + 8
 *     cycles (the last instruction takes at most 8).
 *   - The densest SID write pattern is a read-modify-write on $D4xx (INC/ASL... abs:
 *     6 cycles, two writes), one write per 3 cycles; STA abs is one per 4.
 *   - (20000 + 8) / 3 + 2 = 6671 entries x 8 bytes = 53,368 bytes of .bss.
 *   Keep SIDBUS_LOG_PLAY_MAX_CYCLES equal to C64MEM_PLAY_MAX_CYCLES (c64mem.c checks
 *   it at compile time). Drift failure mode: a smaller log drops writes; every
 *   dropped write is counted by sidbus_log_overflows, never silent. A long init
 *   call can exceed the capacity; its overflow is counted the same way.
 */
#define SIDBUS_LOG_PLAY_MAX_CYCLES  (20000u)
#define SIDBUS_LOG_OVERRUN_CYCLES   (8u)
#define SIDBUS_LOG_CAPACITY  ((SIDBUS_LOG_PLAY_MAX_CYCLES + SIDBUS_LOG_OVERRUN_CYCLES) / 3u + 2u)

const sidbus_write_t *sidbus_log_frame(uint32_t *n_writes);
uint32_t sidbus_log_overflows(void);
sidbus_model_t sidbus_log_model(void);

#endif /* SIDBUS_H */
