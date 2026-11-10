/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sid_envmodel.h
 * Role: firmware model of the three SID ADSR envelopes, driven by the register writes the
 *   player sends, for the level bars (the fabric SID reads back only ENV3). Pure logic: no
 *   hardware access, builds on the host.
 *
 * Model (reSID-style, not cycle exact, visually right):
 *   - Per voice: gate bit 0 of the control register (reg 4 + 7 * voice), attack/decay
 *     nibbles of AD (reg 5 + 7 * voice), sustain/release nibbles of SR (reg 6 + 7 * voice).
 *   - A rate counter ticks once per phi2 cycle; one envelope step happens each time it reaches
 *     the rate period of the current state. Attack periods (cycles per level step, 256 steps
 *     from 0 to 255): 9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11720,
 *     19532, 31251 = 2 ms .. 8 s. Decay and release use the same periods but each level step
 *     only counts every exp-period ticks (1 above level 93, 2 above 54, 4 above 26, 8 above 14,
 *     16 above 6, else 30), which gives the exponential fall and decay/release times of
 *     6 ms .. 24 s.
 *   - Gate 0 -> 1: attack from the present level; gate 1 -> 0: release from the present level.
 *     Attack ends at 255 and enters decay; decay stops at the sustain level (nibble * 17) and
 *     holds there (a lowered sustain keeps decaying). Release stops at 0.
 *   - The TEST bit ($08) has no effect on the envelope, as in the chip (it resets the
 *     oscillator only); a control write of $08 simply has gate 0. The ADSR delay bug is not
 *     modelled and neither is the 15-bit rate counter wrap.
 * Time: a 32-bit phi2 cycle stamp, compared with signed differences. Stamps that go backwards
 *   count as "now" (no change).
 * Concurrency: caller's thread only (core 0 main loop).
 * Headers hold signatures, constants, types and contract prose; per-function commentary lives
 *   in sid_envmodel.c.
 */
#ifndef SID_ENVMODEL_H
#define SID_ENVMODEL_H

#include <stdint.h> /* uint8_t, uint32_t */

#define SID_ENVMODEL_VOICES        (3u)
#define SID_ENVMODEL_VOICE_REGS    (7u)     /* register stride between voices */
#define SID_ENVMODEL_REGS_USED     (21u)    /* writes to registers >= 21 are ignored */
#define SID_ENVMODEL_RATES         (16u)
#define SID_ENVMODEL_MAX_TICKS     (16384u) /* bound of one advance: more than a full 255 -> 0 fall */

typedef enum
{
    SID_ENV_ATTACK = 0,
    SID_ENV_DECAY,       /* decay and sustain (the chip uses one state) */
    SID_ENV_RELEASE
} sid_env_state_t;

typedef struct
{
    uint8_t  state;          /* sid_env_state_t */
    uint8_t  gate;
    uint8_t  level;          /* 0..255 */
    uint8_t  attack;         /* nibbles */
    uint8_t  decay;
    uint8_t  sustain;
    uint8_t  release;
    uint8_t  exp_counter;
    uint32_t rate_counter;
} sid_envmodel_voice_t;

typedef struct
{
    sid_envmodel_voice_t voice[SID_ENVMODEL_VOICES];
    uint32_t             time;        /* cycle stamp the model has been advanced to */
} sid_envmodel_t;

void     sid_envmodel_reset(sid_envmodel_t *m, uint32_t stamp);
void     sid_envmodel_advance(sid_envmodel_t *m, uint32_t stamp);
void     sid_envmodel_write(sid_envmodel_t *m, uint32_t stamp, uint8_t reg, uint8_t val);
uint8_t  sid_envmodel_level(const sid_envmodel_t *m, uint32_t voice);
uint32_t sid_envmodel_rate_period(uint8_t nibble);      /* cycles per step, 0..15 */
uint32_t sid_envmodel_exp_period(uint8_t level);        /* ticks per decay/release step */

#endif /* SID_ENVMODEL_H */
