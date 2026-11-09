/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sid.c
 * Role: SID synthesizer (contract and model summary in sid.h).
 *
 * Derived from reSID 0.16 by Dag Lem <resid@nimrod.no> (GPL-2.0-or-later,
 *   https://github.com/libsidplayfp/resid commit
 *   f872782804c751eb94d409a1250cbfeb03940cd0; files kept unmodified in
 *   third_party/resid/): the oscillator, noise, sync/ring, combined-waveform
 *   indexing (wave.h/wave.cc), envelope rate periods, sustain levels and
 *   exponential thresholds (envelope.h/envelope.cc), DAC zero levels and voice
 *   DC (voice.cc), filter equations, routing, RES map and mixer DC
 *   (filter.h/filter.cc). The code is a C re-implementation in fixed point; the
 *   tables come from sid_tables.c (generated from the same files).
 *
 * Fixed-point formats:
 *   voice units  signed int32, reSID's 20-bit voice output >> 8:
 *                ((wave12 - wave_zero) * env8 + voice_DC) >> 8.
 *                6581 range 1147..5226, 8580 range -2040..2032 per voice.
 *   filter state vlp, vbp, vhp in voice units, clamped to +/-SID_FLT_CLAMP so
 *                every product below stays inside int32.
 *   F            Q2.14 unsigned, 2 sin(pi fc / 96000), 0..SID_F_MAX (1.125).
 *                Max product F * state = 18432 * 65535 < 2^31.
 *   1/Q          Q10 unsigned, 599..1448 (reSID 1024 / (0.707 + RES/15)).
 *                Max product = 1448 * 65535 < 2^27.
 *   mix          voice units x VOL (0..15).
 *   DC blocker   state in Q4 of mix units; pole 1 - 2^-9 at 48 kHz (~15 Hz).
 *   output       (DC-blocked mix) >> SID_OUT_SHIFT, saturated to int16. Three
 *                full-swing voices at VOL 15 span about 46,000 counts.
 *
 * Per-sample work (sid_render inner loop, one 48 kHz sample, 20-21 cycles):
 *   - oscillators: 3 x (multiply-add, bit-19 edge count with at most 3 LFSR
 *     shifts, bit-23 edge test); sync: one division only on a sync edge
 *     (at most once per source period, <= 3.9 kHz);
 *   - envelopes: 3 x (compare + add in the common case; at most a few steps);
 *   - waveforms: 3 x (switch + table/compare) and 3 x (multiply + shift);
 *   - filter: 2 iterations x 3 multiplies + clamps; mixer: 1 multiply;
 *   - DC blocker and saturation: shifts and compares.
 *   No per-sample division and no 64-bit arithmetic; the frame-level split
 *   divides once per sid_render call and the filter coefficient is computed on
 *   FC/model writes only.
 * Shifts of negative int32 values are arithmetic (GCC, two's complement).
 */
#include "sid.h"

#include <stddef.h> /* NULL */
#include <string.h> /* memset */

#define SID_ACC_MASK          (0xFFFFFFu)
#define SID_ACC_MSB           (0x800000u)
#define SID_ACC_BIT19         (0x080000u)
#define SID_LFSR_MASK         (0x7FFFFFu)
#define SID_LFSR_RESET        (0x7FFFF8u)
#define SID_WAVE_MASK         (0xFFFu)
#define SID_STEP_MAX_CYCLES   (32u)    /* longest oscillator step: freq * 32 < 2^21 */
#define SID_NOISE_SHIFTS_MAX  (4u)     /* bit-19 edges per step: <= 0xFFFF*32/2^20 + 1 = 3 */
#define SID_ENV_ITER_MAX      (SID_STEP_MAX_CYCLES + 1u) /* each iteration consumes >= 1 cycle */
#define SID_RATE_WRAP         (0x7FFFu)
#define SID_RATE_BIT15        (0x8000u)
#define SID_ENV_ATTACK        (0u)
#define SID_ENV_DECAY_SUSTAIN (1u)
#define SID_ENV_RELEASE       (2u)

#define SID_FILTER_RATE_HZ    (2u * SID_SAMPLE_RATE_HZ)  /* two filter iterations per sample */
#define SID_PI_Q30            (3373259426u)              /* pi * 2^30 */
#define SID_THETA_K           ((uint32_t)(((uint64_t)SID_PI_Q30 * 4u) / SID_FILTER_RATE_HZ))
                                                         /* pi / 96000 in Q32 = 140552 */
#define SID_CUTOFF_MAX_HZ     (18000u)  /* keeps hz * SID_THETA_K inside uint32 */
#define SID_F_MAX             (18432u)  /* 1.125 in Q14: Chamberlin stable for 1/Q >= 0.586 */
#define SID_FLT_CLAMP         (65535)
#define SID_DC_SHIFT          (9u)
#define SID_DC_FRAC           (4u)
#define SID_OUT_SHIFT         (2u)
#define SID_OUT_MAX           (32767)
#define SID_OUT_MIN           (-32768)

/* reSID voice.cc: waveform DAC zero level and envelope DAC DC offset (0x800 * 0xFF). */
#define SID_WAVE_ZERO_6581    (0x380)
#define SID_WAVE_ZERO_8580    (0x800)
#define SID_VOICE_DC_6581     (0x800 * 0xFF)
/* reSID filter.cc: mixer_DC = -0xfff*0xff/18 >> 7 in its 13-bit domain; in voice units
 * (>> 8): -(0xFFF * 0xFF / 18) >> 8 = -58012 >> 8 = -227. */
#define SID_MIXER_DC_6581     (-227)

#if SID_FRAME_CYCLES / SID_FRAME_SAMPLES >= SID_STEP_MAX_CYCLES
#error "cycles per sample exceed the oscillator step limit"
#endif

/* reSID envelope.cc rate_counter_period[]: cycles per envelope step for A/D/R 0..15. */
static const uint16_t g_rate_period[16] = {
    9u, 32u, 63u, 95u, 149u, 220u, 267u, 313u,
    392u, 977u, 1954u, 3126u, 3907u, 11720u, 19532u, 31251u,
};

typedef struct
{
    /* oscillator */
    uint32_t acc;          /* 24-bit phase accumulator */
    uint32_t freq;         /* 16-bit */
    uint32_t pw;           /* 12-bit */
    uint32_t lfsr;         /* 23-bit noise shift register */
    uint32_t waveform;     /* control bits 7..4 */
    uint32_t test;
    uint32_t ring;
    uint32_t sync;
    uint32_t msb_rose;     /* bit 23 rose in the last step */
    uint32_t after_edge;   /* cycles of the last step after that edge */
    /* envelope */
    uint32_t gate;
    uint32_t state;
    uint32_t env;          /* 8-bit envelope counter */
    uint32_t rate_counter; /* 15-bit */
    uint32_t rate_period;
    uint32_t exp_counter;
    uint32_t exp_period;
    uint32_t hold_zero;
    uint32_t attack;
    uint32_t decay;
    uint32_t sustain;
    uint32_t release;
} sid_voice_t;

static sid_voice_t g_v[SID_VOICES];
static sid_model_t g_model;
static const sid_wave_tab_t *g_tab[SID_TAB_COMBOS];
static const uint16_t *g_cutoff;
static int32_t g_wave_zero;
static int32_t g_voice_dc;
static int32_t g_mixer_dc;
/* filter and mixer registers */
static uint32_t g_fc;          /* 11-bit */
static uint32_t g_filt;        /* $D417 bits 3..0 */
static uint32_t g_mode;        /* $D418 bits 6..4: HP BP LP */
static uint32_t g_vol;         /* $D418 bits 3..0 */
static uint32_t g_3off;        /* $D418 bit 7 */
static int32_t g_f_q14;
static int32_t g_q_q10;
static int32_t g_vlp;
static int32_t g_vbp;
static int32_t g_vhp;
static int32_t g_dc_x1;
static int32_t g_dc_y;

/*
 * sid_src -- sync/ring source of a voice (1 <- 3, 2 <- 1, 3 <- 2).
 * Returns: the source voice index.
 */
static inline uint32_t sid_src(uint32_t v)
{
    return (v == 0u) ? 2u : v - 1u;
}

/*
 * sid_clamp -- limit a filter state to +/-SID_FLT_CLAMP.
 * Returns: the clamped value.
 */
static inline int32_t sid_clamp(int32_t x)
{
    if (x > SID_FLT_CLAMP) {
        return SID_FLT_CLAMP;
    }
    if (x < -SID_FLT_CLAMP) {
        return -SID_FLT_CLAMP;
    }
    return x;
}

/*
 * sid_set_cutoff -- recompute the filter coefficient F from FC and the model curve.
 * Steps:
 *   1. fc (Hz) from the reSID curve, limited to SID_CUTOFF_MAX_HZ.
 *   2. theta = pi fc / 96000 in Q16; sin(theta) by its Taylor series to theta^5
 *      (error below 2e-5 for theta <= 0.59).
 *   3. F = 2 sin(theta) in Q14 = sin_q16 / 2, limited to SID_F_MAX.
 * Returns: nothing.
 */
static void sid_set_cutoff(void)
{
    uint32_t hz = g_cutoff[g_fc & (SID_TAB_FC_ENTRIES - 1u)];
    uint32_t th;
    uint32_t th2;
    uint32_t th3;
    uint32_t th5;
    uint32_t sn;

    if (hz > SID_CUTOFF_MAX_HZ) {
        hz = SID_CUTOFF_MAX_HZ;
    }
    th = (hz * SID_THETA_K) >> 16;
    th2 = (th * th) >> 16;
    th3 = (th2 * th) >> 16;
    th5 = (th3 * th2) >> 16;
    sn = th - th3 / 6u + th5 / 120u;
    sn >>= 1;
    if (sn > SID_F_MAX) {
        sn = SID_F_MAX;
    }
    g_f_q14 = (int32_t)sn;
}

/*
 * sid_reset -- power-on state for one chip model.
 * Steps:
 *   1. Clear all voices: LFSR 0x7FFFF8, envelope in RELEASE at 0 frozen, period of R = 0.
 *   2. Select the model's wave tables, cutoff curve, DAC zero, voice DC and mixer DC.
 *   3. Clear the filter registers and state, recompute F and 1/Q, clear the DC blocker.
 * Returns: nothing.
 */
void sid_reset(sid_model_t model)
{
    memset(g_v, 0, sizeof(g_v));
    for (uint32_t v = 0u; v < SID_VOICES; v++) {
        g_v[v].lfsr = SID_LFSR_RESET;
        g_v[v].state = SID_ENV_RELEASE;
        g_v[v].rate_period = g_rate_period[0];
        g_v[v].exp_period = 1u;
        g_v[v].hold_zero = 1u;
    }
    g_model = (model == SID_MODEL_8580) ? SID_MODEL_8580 : SID_MODEL_6581;
    for (uint32_t c = 0u; c < SID_TAB_COMBOS; c++) {
        g_tab[c] = sid_tables_wave(g_model, c);
    }
    g_cutoff = sid_tables_cutoff_hz(g_model);
    if (g_model == SID_MODEL_8580) {
        g_wave_zero = SID_WAVE_ZERO_8580;
        g_voice_dc = 0;
        g_mixer_dc = 0;
    } else {
        g_wave_zero = SID_WAVE_ZERO_6581;
        g_voice_dc = SID_VOICE_DC_6581;
        g_mixer_dc = SID_MIXER_DC_6581;
    }
    g_fc = 0u;
    g_filt = 0u;
    g_mode = 0u;
    g_vol = 0u;
    g_3off = 0u;
    g_vlp = 0;
    g_vbp = 0;
    g_vhp = 0;
    g_dc_x1 = 0;
    g_dc_y = 0;
    sid_set_cutoff();
    g_q_q10 = (int32_t)sid_tables_res_q10(0u);
}

/*
 * sid_model -- the chip model selected by the last sid_reset.
 * Returns: SID_MODEL_6581 or SID_MODEL_8580.
 */
sid_model_t sid_model(void)
{
    return g_model;
}

/*
 * sid_write_control -- voice control register (waveform, test, ring, sync, gate).
 * Steps:
 *   1. Waveform, ring and sync bits.
 *   2. TEST set: accumulator and LFSR cleared; TEST released: LFSR = 0x7FFFF8.
 *   3. Gate rising: ATTACK with the attack period, unfreeze; gate falling: RELEASE.
 * Returns: nothing.
 */
static void sid_write_control(sid_voice_t *vo, uint32_t val)
{
    const uint32_t test_next = (val >> 3) & 1u;
    const uint32_t gate_next = val & 1u;

    vo->waveform = (val >> 4) & 0x0Fu;
    vo->ring = (val >> 2) & 1u;
    vo->sync = (val >> 1) & 1u;
    if (test_next != 0u) {
        vo->acc = 0u;
        vo->lfsr = 0u;
    } else if (vo->test != 0u) {
        vo->lfsr = SID_LFSR_RESET;
    }
    vo->test = test_next;

    if (vo->gate == 0u && gate_next != 0u) {
        vo->state = SID_ENV_ATTACK;
        vo->rate_period = g_rate_period[vo->attack];
        vo->hold_zero = 0u;
    } else if (vo->gate != 0u && gate_next == 0u) {
        vo->state = SID_ENV_RELEASE;
        vo->rate_period = g_rate_period[vo->release];
    }
    vo->gate = gate_next;
}

/*
 * sid_write -- apply one register write now.
 * Steps:
 *   1. Registers 0..20: the voice's FREQ, PW, control, AD or SR (period updated for the
 *      current envelope state as reSID does).
 *   2. $15/$16: FC (11 bits) and F; $17: RES (1/Q) and routing; $18: mode, 3OFF, volume.
 *   3. $19..$1F: read-only/unused, ignored.
 * Returns: nothing.
 */
void sid_write(uint8_t reg, uint8_t val)
{
    const uint32_t r = reg & (SID_REGS - 1u);

    if (r < SID_VOICES * 7u) {
        sid_voice_t *vo = &g_v[r / 7u];

        switch (r % 7u) {
        case 0u:
            vo->freq = (vo->freq & 0xFF00u) | val;
            break;
        case 1u:
            vo->freq = (vo->freq & 0x00FFu) | ((uint32_t)val << 8);
            break;
        case 2u:
            vo->pw = (vo->pw & 0xF00u) | val;
            break;
        case 3u:
            vo->pw = (vo->pw & 0x0FFu) | (((uint32_t)val & 0x0Fu) << 8);
            break;
        case 4u:
            sid_write_control(vo, val);
            break;
        case 5u:
            vo->attack = (uint32_t)val >> 4;
            vo->decay = (uint32_t)val & 0x0Fu;
            if (vo->state == SID_ENV_ATTACK) {
                vo->rate_period = g_rate_period[vo->attack];
            } else if (vo->state == SID_ENV_DECAY_SUSTAIN) {
                vo->rate_period = g_rate_period[vo->decay];
            }
            break;
        default:
            vo->sustain = (uint32_t)val >> 4;
            vo->release = (uint32_t)val & 0x0Fu;
            if (vo->state == SID_ENV_RELEASE) {
                vo->rate_period = g_rate_period[vo->release];
            }
            break;
        }
        return;
    }
    switch (r) {
    case SID_REG_FC_LO:
        g_fc = (g_fc & 0x7F8u) | ((uint32_t)val & 0x07u);
        sid_set_cutoff();
        break;
    case SID_REG_FC_HI:
        g_fc = (((uint32_t)val << 3) & 0x7F8u) | (g_fc & 0x007u);
        sid_set_cutoff();
        break;
    case SID_REG_RES_FILT:
        g_q_q10 = (int32_t)sid_tables_res_q10((uint32_t)val >> 4);
        g_filt = (uint32_t)val & 0x0Fu;
        break;
    case SID_REG_MODE_VOL:
        g_3off = ((uint32_t)val >> 7) & 1u;
        g_mode = ((uint32_t)val >> 4) & 0x07u;
        g_vol = (uint32_t)val & 0x0Fu;
        break;
    default:
        break;
    }
}

/*
 * sid_clock_osc -- advance the three oscillators by delta cycles (1..SID_STEP_MAX_CYCLES).
 * Steps:
 *   1. Per voice not in TEST: acc += freq * delta; shift the LFSR once per rising edge
 *      of bit 19 inside the step (edge count from the unwrapped sum); note a rising
 *      edge of bit 23 and how many cycles of the step follow it.
 *   2. Hard sync: a destination with SYNC whose source's bit 23 rose restarts from 0 at
 *      that cycle (acc = cycles after the edge * freq), unless the source was itself
 *      synced on the same cycle (reSID rule).
 * Returns: nothing.
 */
static void sid_clock_osc(uint32_t delta)
{
    for (uint32_t v = 0u; v < SID_VOICES; v++) {
        sid_voice_t *vo = &g_v[v];
        uint32_t prev;
        uint32_t nxt;
        uint32_t edges;

        vo->msb_rose = 0u;
        if (vo->test != 0u) {
            continue;
        }
        prev = vo->acc;
        nxt = prev + vo->freq * delta;
        edges = ((nxt + SID_ACC_BIT19) >> 20) - ((prev + SID_ACC_BIT19) >> 20);
        for (uint32_t i = 0u; i < edges && i < SID_NOISE_SHIFTS_MAX; i++) {
            const uint32_t bit0 = ((vo->lfsr >> 22) ^ (vo->lfsr >> 17)) & 1u;

            vo->lfsr = ((vo->lfsr << 1) & SID_LFSR_MASK) | bit0;
        }
        if ((prev & SID_ACC_MSB) == 0u && (nxt & SID_ACC_MSB) != 0u) {
            /* first cycle k with prev + k * freq >= 0x800000; the step's later cycles follow it */
            const uint32_t k = (SID_ACC_MSB - prev + vo->freq - 1u) / vo->freq;

            vo->msb_rose = 1u;
            vo->after_edge = delta - k;
        }
        vo->acc = nxt & SID_ACC_MASK;
    }
    for (uint32_t v = 0u; v < SID_VOICES; v++) {
        sid_voice_t *dst = &g_v[v];
        const sid_voice_t *src = &g_v[sid_src(v)];

        if (dst->sync != 0u && src->msb_rose != 0u
            && !(src->sync != 0u && g_v[sid_src(sid_src(v))].msb_rose != 0u)
            && dst->test == 0u) {
            dst->acc = (src->after_edge * dst->freq) & SID_ACC_MASK;
        }
    }
}

/*
 * sid_clock_env -- advance one envelope generator by delta cycles.
 * Steps:
 *   1. Cycles to the next rate-counter match (past the 2^15 wrap when the period is
 *      below the counter: the ADSR delay bug).
 *   2. While the step reaches a match: zero the counter; in ATTACK, or when the
 *      exponential divider expires, step the envelope (ATTACK up to $FF then DECAY,
 *      DECAY down to the sustain level, RELEASE down), unless frozen at 0; update the
 *      exponential divider at levels $FF/$5D/$36/$1A/$0E/$06/$00 (freeze at 0).
 *   3. Leftover cycles go into the counter (15-bit wrap).
 * Returns: nothing.
 */
static void sid_clock_env(sid_voice_t *vo, uint32_t delta)
{
    uint32_t rate_step;

    if (vo->rate_counter < vo->rate_period) {
        rate_step = vo->rate_period - vo->rate_counter;
    } else {
        rate_step = vo->rate_period + SID_RATE_WRAP - vo->rate_counter;
    }
    for (uint32_t it = 0u; delta != 0u && it < SID_ENV_ITER_MAX; it++) {
        if (delta < rate_step) {
            vo->rate_counter += delta;
            if ((vo->rate_counter & SID_RATE_BIT15) != 0u) {
                vo->rate_counter = (vo->rate_counter + 1u) & SID_RATE_WRAP;
            }
            return;
        }
        vo->rate_counter = 0u;
        delta -= rate_step;
        rate_step = vo->rate_period;
        if (vo->state != SID_ENV_ATTACK) {
            vo->exp_counter++;
            if (vo->exp_counter != vo->exp_period) {
                continue;
            }
        }
        vo->exp_counter = 0u;
        if (vo->hold_zero != 0u) {
            continue;
        }
        switch (vo->state) {
        case SID_ENV_ATTACK:
            vo->env = (vo->env + 1u) & 0xFFu;
            if (vo->env == 0xFFu) {
                vo->state = SID_ENV_DECAY_SUSTAIN;
                vo->rate_period = g_rate_period[vo->decay];
                rate_step = vo->rate_period;
            }
            break;
        case SID_ENV_DECAY_SUSTAIN:
            if (vo->env != vo->sustain * 0x11u) {
                vo->env--;
            }
            break;
        default:
            vo->env = (vo->env - 1u) & 0xFFu;
            break;
        }
        switch (vo->env) {
        case 0xFFu:
            vo->exp_period = 1u;
            break;
        case 0x5Du:
            vo->exp_period = 2u;
            break;
        case 0x36u:
            vo->exp_period = 4u;
            break;
        case 0x1Au:
            vo->exp_period = 8u;
            break;
        case 0x0Eu:
            vo->exp_period = 16u;
            break;
        case 0x06u:
            vo->exp_period = 30u;
            break;
        case 0x00u:
            vo->exp_period = 1u;
            vo->hold_zero = 1u;
            break;
        default:
            break;
        }
    }
}

/*
 * sid_clock -- advance oscillators and envelopes by any number of cycles.
 * Steps:
 *   1. Split delta into steps of at most SID_STEP_MAX_CYCLES (one step per sample in
 *      the 960-sample frame; bounded by delta / SID_STEP_MAX_CYCLES + 1 steps).
 *   2. Clock the oscillators, then each envelope, per step.
 * Returns: nothing.
 */
static void sid_clock(uint32_t delta)
{
    while (delta != 0u) {
        const uint32_t step = (delta > SID_STEP_MAX_CYCLES) ? SID_STEP_MAX_CYCLES : delta;

        sid_clock_osc(step);
        for (uint32_t v = 0u; v < SID_VOICES; v++) {
            sid_clock_env(&g_v[v], step);
        }
        delta -= step;
    }
}

/*
 * sid_combined -- look up a trimmed combined-waveform table.
 * Returns: the 12-bit table output (8-bit sample << 4).
 */
static inline uint32_t sid_combined(const sid_wave_tab_t *tab, uint32_t idx)
{
    const uint32_t k = (idx & tab->mask) - tab->first;

    return (k < tab->count) ? ((uint32_t)tab->data[k] << 4) : 0u;
}

/*
 * sid_wave -- 12-bit waveform output of one voice.
 * Steps:
 *   1. Triangle with the ring-modulated MSB, saw, pulse (TEST holds it high), noise bits.
 *   2. Select by the waveform bits; combined waveforms through the reSID tables (triangle
 *      combos indexed by triangle >> 1, the others by saw); noise combos read 0.
 * Returns: 0..0xFFF.
 */
static inline uint32_t sid_wave(const sid_voice_t *vo, uint32_t src_acc)
{
    const uint32_t acc = vo->acc;
    const uint32_t msb = ((vo->ring != 0u) ? (acc ^ src_acc) : acc) & SID_ACC_MSB;
    const uint32_t saw = acc >> 12;
    uint32_t tri;
    uint32_t pulse;
    uint32_t n;

    switch (vo->waveform) {
    case 0x1u:
        return (((msb != 0u) ? ~acc : acc) >> 11) & SID_WAVE_MASK;
    case 0x2u:
        return saw;
    case 0x3u:
        return sid_combined(g_tab[SID_TAB_ST], saw);
    case 0x4u:
        return (vo->test != 0u || saw >= vo->pw) ? SID_WAVE_MASK : 0u;
    case 0x5u:
        tri = (((msb != 0u) ? ~acc : acc) >> 11) & SID_WAVE_MASK;
        pulse = (vo->test != 0u || saw >= vo->pw) ? SID_WAVE_MASK : 0u;
        return sid_combined(g_tab[SID_TAB_PT], tri >> 1) & pulse;
    case 0x6u:
        pulse = (vo->test != 0u || saw >= vo->pw) ? SID_WAVE_MASK : 0u;
        return sid_combined(g_tab[SID_TAB_PS], saw) & pulse;
    case 0x7u:
        pulse = (vo->test != 0u || saw >= vo->pw) ? SID_WAVE_MASK : 0u;
        return sid_combined(g_tab[SID_TAB_PST], saw) & pulse;
    case 0x8u:
        n = vo->lfsr;
        return ((n & 0x400000u) >> 11) | ((n & 0x100000u) >> 10) | ((n & 0x010000u) >> 7)
               | ((n & 0x002000u) >> 5) | ((n & 0x000800u) >> 4) | ((n & 0x000080u) >> 1)
               | ((n & 0x000010u) << 1) | ((n & 0x000004u) << 2);
    default:
        return 0u;
    }
}

/*
 * sid_voice_out -- envelope-scaled DAC output of one voice in voice units.
 * Returns: ((wave - wave_zero) * env + voice_DC) >> 8.
 */
static inline int32_t sid_voice_out(uint32_t v)
{
    const sid_voice_t *vo = &g_v[v];
    const int32_t w = (int32_t)sid_wave(vo, g_v[sid_src(v)].acc);

    return ((w - g_wave_zero) * (int32_t)vo->env + g_voice_dc) >> 8;
}

/*
 * sid_sample -- one output sample from the current state.
 * Steps:
 *   1. Three voice outputs; 3OFF mutes voice 3 when it is not routed to the filter.
 *   2. Route into Vi (filter) or Vnf (direct) per $D417.
 *   3. Two Chamberlin iterations: Vlp -= F*Vbp, Vhp = Vbp/Q - Vlp - Vi, Vbp -= F*Vhp.
 *   4. Mix the selected LP/BP/HP outputs with Vnf and the mixer DC, times VOL.
 *   5. DC-blocking high-pass, scale, saturate.
 * Returns: the int16 sample.
 */
static inline int16_t sid_sample(void)
{
    int32_t vo[SID_VOICES];
    int32_t vi = 0;
    int32_t vnf = 0;
    int32_t vf = 0;
    int32_t mix;
    int32_t y;

    for (uint32_t v = 0u; v < SID_VOICES; v++) {
        vo[v] = sid_voice_out(v);
    }
    if (g_3off != 0u && (g_filt & 0x04u) == 0u) {
        vo[2] = 0;
    }
    for (uint32_t v = 0u; v < SID_VOICES; v++) {
        if ((g_filt & (1u << v)) != 0u) {
            vi += vo[v];
        } else {
            vnf += vo[v];
        }
    }
    for (uint32_t it = 0u; it < SID_FILTER_RATE_HZ / SID_SAMPLE_RATE_HZ; it++) {
        g_vlp = sid_clamp(g_vlp - ((g_f_q14 * g_vbp) >> 14));
        g_vhp = sid_clamp(((g_vbp * g_q_q10) >> 10) - g_vlp - vi);
        g_vbp = sid_clamp(g_vbp - ((g_f_q14 * g_vhp) >> 14));
    }
    if ((g_mode & 0x1u) != 0u) {
        vf += g_vlp;
    }
    if ((g_mode & 0x2u) != 0u) {
        vf += g_vbp;
    }
    if ((g_mode & 0x4u) != 0u) {
        vf += g_vhp;
    }
    mix = (vnf + vf + g_mixer_dc) * (int32_t)g_vol;

    g_dc_y += ((mix - g_dc_x1) * (1 << SID_DC_FRAC)) - (g_dc_y >> SID_DC_SHIFT);
    g_dc_x1 = mix;
    y = (g_dc_y >> SID_DC_FRAC) >> SID_OUT_SHIFT;
    if (y > SID_OUT_MAX) {
        y = SID_OUT_MAX;
    } else if (y < SID_OUT_MIN) {
        y = SID_OUT_MIN;
    }
    return (int16_t)y;
}

/*
 * sid_render -- render one frame of SID_FRAME_CYCLES cycles into n_samples samples.
 * Steps:
 *   1. Reject out == NULL or n_samples outside 1..SID_RENDER_MAX_SAMPLES (the writes are
 *      still applied, so the register state stays in step with the 6502).
 *   2. Split the frame: base = cycles / n, remainder spread by a Bresenham accumulator,
 *      so sample s ends at cycle floor((s + 1) * cycles / n) and the last at 19656.
 *   3. Per sample: clock up to each logged write inside the sample, apply it, clock to
 *      the sample's end cycle, compute the sample. The write loop is bounded by n_writes.
 *   4. Apply writes stamped at or past the frame end.
 * Returns: nothing.
 */
void sid_render(const sid_write_t *log, uint32_t n_writes, int16_t *out, uint32_t n_samples)
{
    uint32_t w = 0u;
    uint32_t pos = 0u;
    uint32_t frac = 0u;
    uint32_t base;
    uint32_t rem;

    if (log == NULL) {
        n_writes = 0u;
    }
    if (out != NULL && n_samples != 0u && n_samples <= SID_RENDER_MAX_SAMPLES) {
        base = SID_FRAME_CYCLES / n_samples;
        rem = SID_FRAME_CYCLES % n_samples;
        for (uint32_t s = 0u; s < n_samples; s++) {
            uint32_t end = pos + base;

            frac += rem;
            if (frac >= n_samples) {
                frac -= n_samples;
                end++;
            }
            while (w < n_writes && log[w].cycle < end) {
                if (log[w].cycle > pos) {
                    sid_clock(log[w].cycle - pos);
                    pos = log[w].cycle;
                }
                sid_write(log[w].reg, log[w].val);
                w++;
            }
            sid_clock(end - pos);
            pos = end;
            out[s] = sid_sample();
        }
    }
    for (; w < n_writes; w++) {
        sid_write(log[w].reg, log[w].val);
    }
}

/*
 * sid_read_osc3 -- $D41B.
 * Returns: the upper 8 bits of voice 3's waveform output.
 */
uint8_t sid_read_osc3(void)
{
    return (uint8_t)(sid_wave(&g_v[2], g_v[sid_src(2u)].acc) >> 4);
}

/*
 * sid_read_env3 -- $D41C.
 * Returns: voice 3's envelope counter.
 */
uint8_t sid_read_env3(void)
{
    return (uint8_t)g_v[2].env;
}

/*
 * sid_voice_level -- envelope level of one voice for the visualizer.
 * Returns: 0..255 for voice 0..2, 0 for any other index.
 */
uint8_t sid_voice_level(uint32_t voice)
{
    return (voice < SID_VOICES) ? (uint8_t)g_v[voice].env : 0u;
}
