/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sid_envmodel.c
 * Role: the SID ADSR envelope model (contract and rate tables described in sid_envmodel.h).
 */
#include "sid_envmodel.h"

#define ENV_REG_CTRL        (4u)
#define ENV_REG_AD          (5u)
#define ENV_REG_SR          (6u)
#define ENV_GATE_BIT        (0x01u)
#define ENV_NIBBLE_MASK     (0x0Fu)
#define ENV_NIBBLE_BITS     (4u)
#define ENV_SUSTAIN_SCALE   (17u)
#define ENV_MAX_LEVEL       (255u)

/* Cycles per envelope step for rate nibbles 0..15 (attack 2 ms .. 8 s over 255 steps). */
static const uint16_t g_rate_period[SID_ENVMODEL_RATES] = {
    9u, 32u, 63u, 95u, 149u, 220u, 267u, 313u, 392u, 977u, 1954u, 3126u, 3907u, 11720u, 19532u, 31251u
};

/*
 * sid_envmodel_rate_period -- rate counter period of a rate nibble.
 * Returns: cycles per step (the low 4 bits of nibble are used).
 */
uint32_t sid_envmodel_rate_period(uint8_t nibble)
{
    return g_rate_period[nibble & ENV_NIBBLE_MASK];
}

/*
 * sid_envmodel_exp_period -- decay/release ticks per level step at a level.
 * Returns: 1 above 93, 2 above 54, 4 above 26, 8 above 14, 16 above 6, else 30 (the chip's
 *   exponential approximation; level 0 holds, the value is not used there).
 */
uint32_t sid_envmodel_exp_period(uint8_t level)
{
    if (level > 93u) {
        return 1u;
    }
    if (level > 54u) {
        return 2u;
    }
    if (level > 26u) {
        return 4u;
    }
    if (level > 14u) {
        return 8u;
    }
    if (level > 6u) {
        return 16u;
    }
    return 30u;
}

/*
 * env_period -- rate period of the voice's present state.
 * Returns: cycles per step.
 */
static uint32_t env_period(const sid_envmodel_voice_t *v)
{
    switch (v->state) {
    case SID_ENV_ATTACK:
        return sid_envmodel_rate_period(v->attack);
    case SID_ENV_DECAY:
        return sid_envmodel_rate_period(v->decay);
    default:
        return sid_envmodel_rate_period(v->release);
    }
}

/*
 * env_idle -- the voice has nothing to step (decay at or below sustain, release at 0).
 * Returns: 1 when idle.
 */
static int env_idle(const sid_envmodel_voice_t *v)
{
    if (v->state == SID_ENV_DECAY) {
        return v->level <= (uint8_t)(v->sustain * ENV_SUSTAIN_SCALE);
    }
    if (v->state == SID_ENV_RELEASE) {
        return v->level == 0u;
    }
    return 0;
}

/*
 * env_step -- one rate counter expiry.
 * Steps: attack: level + 1, at 255 enter decay. Decay/release: count exp ticks; on the exp
 *   period lower the level by one (never below 0; decay stops at the sustain level).
 * Returns: nothing.
 */
static void env_step(sid_envmodel_voice_t *v)
{
    if (v->state == SID_ENV_ATTACK) {
        v->exp_counter = 0u;
        if (v->level < ENV_MAX_LEVEL) {
            v->level++;
        }
        if (v->level == ENV_MAX_LEVEL) {
            v->state = SID_ENV_DECAY;
        }
        return;
    }
    v->exp_counter++;
    if (v->exp_counter >= sid_envmodel_exp_period(v->level)) {
        v->exp_counter = 0u;
        if (v->level > 0u) {
            v->level--;
        }
    }
}

/*
 * env_advance_voice -- run one voice for a number of cycles.
 * Steps: while cycles remain and at most SID_ENVMODEL_MAX_TICKS steps: idle voices drop the
 *   remaining cycles; otherwise consume up to the next expiry and step.
 * Returns: nothing.
 */
static void env_advance_voice(sid_envmodel_voice_t *v, uint32_t cycles)
{
    uint32_t guard = 0u;

    while (cycles > 0u && guard < SID_ENVMODEL_MAX_TICKS) {
        uint32_t period;
        uint32_t to_next;

        if (env_idle(v)) {
            v->rate_counter = 0u;
            return;
        }
        period = env_period(v);
        to_next = (period > v->rate_counter) ? (period - v->rate_counter) : 0u;
        if (cycles < to_next) {
            v->rate_counter += cycles;
            return;
        }
        cycles -= to_next;
        v->rate_counter = 0u;
        env_step(v);
        guard++;
    }
}

/*
 * sid_envmodel_reset -- all envelopes to 0, gate off, registers 0; time = stamp.
 * Returns: nothing.
 */
void sid_envmodel_reset(sid_envmodel_t *m, uint32_t stamp)
{
    for (uint32_t i = 0u; i < SID_ENVMODEL_VOICES; i++) {
        sid_envmodel_voice_t *v = &m->voice[i];

        v->state = SID_ENV_RELEASE;
        v->gate = 0u;
        v->level = 0u;
        v->attack = 0u;
        v->decay = 0u;
        v->sustain = 0u;
        v->release = 0u;
        v->exp_counter = 0u;
        v->rate_counter = 0u;
    }
    m->time = stamp;
}

/*
 * sid_envmodel_advance -- run all voices up to a cycle stamp.
 * Returns: nothing; a stamp not after the model time changes nothing.
 */
void sid_envmodel_advance(sid_envmodel_t *m, uint32_t stamp)
{
    const int32_t d = (int32_t)(stamp - m->time);

    if (d <= 0) {
        return;
    }
    for (uint32_t i = 0u; i < SID_ENVMODEL_VOICES; i++) {
        env_advance_voice(&m->voice[i], (uint32_t)d);
    }
    m->time = stamp;
}

/*
 * sid_envmodel_write -- apply a SID register write at a cycle stamp.
 * Steps: advance to the stamp; control: gate 0 -> 1 starts attack, 1 -> 0 starts release;
 *   AD / SR: store the nibbles (the new rates apply from the next step).
 * Returns: nothing; registers outside the three voices are ignored.
 */
void sid_envmodel_write(sid_envmodel_t *m, uint32_t stamp, uint8_t reg, uint8_t val)
{
    sid_envmodel_voice_t *v;
    uint32_t idx;
    uint32_t r;

    if (reg >= SID_ENVMODEL_REGS_USED) {
        return;
    }
    sid_envmodel_advance(m, stamp);
    idx = reg / SID_ENVMODEL_VOICE_REGS;
    r = reg % SID_ENVMODEL_VOICE_REGS;
    v = &m->voice[idx];
    if (r == ENV_REG_CTRL) {
        const uint8_t gate = (uint8_t)(val & ENV_GATE_BIT);

        if (gate != 0u && v->gate == 0u) {
            v->state = SID_ENV_ATTACK;
            v->exp_counter = 0u;
        } else if (gate == 0u && v->gate != 0u) {
            v->state = SID_ENV_RELEASE;
        }
        v->gate = gate;
    } else if (r == ENV_REG_AD) {
        v->attack = (uint8_t)(val >> ENV_NIBBLE_BITS);
        v->decay = (uint8_t)(val & ENV_NIBBLE_MASK);
    } else if (r == ENV_REG_SR) {
        v->sustain = (uint8_t)(val >> ENV_NIBBLE_BITS);
        v->release = (uint8_t)(val & ENV_NIBBLE_MASK);
    }
}

/*
 * sid_envmodel_level -- envelope of a voice at the model time.
 * Returns: 0..255; 0 for a voice index out of range.
 */
uint8_t sid_envmodel_level(const sid_envmodel_t *m, uint32_t voice)
{
    return (voice < SID_ENVMODEL_VOICES) ? m->voice[voice].level : 0u;
}
