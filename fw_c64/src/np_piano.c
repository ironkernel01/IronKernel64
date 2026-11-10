/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: np_piano.c
 * Role: renderer and heard-state tracker of the now-playing piano keyboards. Contract, layout
 *   and lighting rules: np_piano.h.
 * Note mapping: integer only. Q16 register of A4 (440 Hz) = 440 * 2^40 / clock; the lower
 *   boundary of key k (A4 = key 57) is that times 2^((2 (k - 57) - 1) / 24), from a 24-entry
 *   Q16 table of 2^(r/24) and a binary shift. A register maps to the highest key whose
 *   boundary it reaches (binary search, 7 steps).
 */
#include "np_piano.h"

#include "sid_envmodel.h"
#include "video.h"

#include <string.h>   /* memset, memcpy */

#define NP_KEY_A4          (57)
#define NP_SEMIS           (12u)
#define NP_A4_HZ           (440u)
#define NP_ROOT_STEPS      (24)        /* 24th roots of two per octave */
#define NP_Q               (16u)
#define NP_PAGES           (2u)
#define NP_PAL_HZ          (985248u)
#define NP_WAVE_MASK       (0xF0u)
#define NP_WAVE_NOISE      (0x80u)
#define NP_TEST_BIT        (0x08u)
#define NP_REG_FREQ_LO     (0u)
#define NP_REG_FREQ_HI     (1u)
#define NP_REG_CTRL        (4u)
#define NP_VOICE_STRIDE    (7u)
#define NP_REGS_USED       (21u)
#define NP_STATE_DIM       (1u)
#define NP_STATE_BRIGHT    (2u)
#define NP_STATE_BITS      (2u)
#define NP_STATE_MASK      (3u)
#define NP_COL_BLACK       (0u)
#define NP_COL_WHITE       (1u)
#define NP_WHITE_BODY      (NP_PIANO_WHITE_W - 1u)
#define NP_BLACK_OFFSET    (5u)        /* black key starts 5 px into the white key left of it */
#define NP_AREA_Y          (20u + NP_PIANO_ROW_FIRST * 8u)
#define NP_AREA_H          (NP_PIANO_ROWS * 8u)
#define NP_AREA_X          (32u)
#define NP_AREA_W          (320u)

/* 2^(r/24) in Q16. */
static const uint32_t g_root[24] = {
    65536u, 67456u, 69433u, 71468u, 73562u, 75717u, 77936u, 80220u,
    82570u, 84990u, 87480u, 90043u, 92682u, 95398u, 98193u, 101070u,
    104032u, 107080u, 110218u, 113448u, 116772u, 120194u, 123715u, 127341u
};
/* Semitone in the octave -> white key index 0..6 (a black key: the white key to its left). */
static const uint8_t g_white_of[NP_SEMIS] = { 0u, 0u, 1u, 1u, 2u, 3u, 3u, 4u, 4u, 5u, 5u, 6u };
static const uint8_t g_is_black[NP_SEMIS] = { 0u, 1u, 0u, 1u, 0u, 0u, 1u, 0u, 1u, 0u, 1u, 0u };
static const uint32_t g_kb_y[NP_PIANO_KEYBOARDS] = { NP_PIANO_KB0_Y, NP_PIANO_KB1_Y };

static uint64_t g_thr[NP_PIANO_KEYS];                  /* lower boundary of key k, Q16 register */
static uint8_t  g_bg = 6u;
static uint8_t  g_bright[NP_PIANO_VOICES] = { 13u, 7u, 10u };
static uint8_t  g_dim[NP_PIANO_VOICES]    = { 5u, 8u, 2u };
static uint8_t  g_rec[NP_PAGES][NP_PIANO_KEYS];        /* what each page shows */
static uint8_t  g_valid[NP_PAGES];

typedef struct
{
    uint32_t stamp;
    uint8_t  reg;
    uint8_t  val;
} np_event_t;

static np_event_t g_ev[NP_PIANO_EVENT_CAP];
static uint32_t   g_ev_head;
static uint32_t   g_ev_tail;
static uint32_t   g_ev_drops;
static sid_envmodel_t g_env;
static uint8_t    g_freq_lo[NP_PIANO_VOICES];
static uint8_t    g_freq_hi[NP_PIANO_VOICES];
static uint8_t    g_ctrl[NP_PIANO_VOICES];
static np_piano_voice_t g_heard[NP_PIANO_VOICES];

/*
 * np_piano_init -- build the note thresholds for a phi2 clock and set the background.
 * Steps: T = 440 * 2^40 / clock; per key k >= 1 the Q16 boundary T * 2^((2 (k - 57) - 1) / 24).
 * Returns: nothing. clock_hz 0 is treated as PAL.
 */
void np_piano_init(uint32_t clock_hz, uint8_t background)
{
    const uint64_t t = ((uint64_t)NP_A4_HZ << 40) / (uint64_t)((clock_hz != 0u) ? clock_hz : NP_PAL_HZ);

    g_bg = background;
    g_thr[0] = 0u;
    for (uint32_t k = 1u; k < NP_PIANO_KEYS; k++) {
        const int32_t m = 2 * ((int32_t)k - NP_KEY_A4) - 1;
        int32_t q = m / NP_ROOT_STEPS;
        int32_t r = m % NP_ROOT_STEPS;
        uint64_t th;

        if (r < 0) {
            r += NP_ROOT_STEPS;
            q--;
        }
        th = (t * g_root[r]) >> NP_Q;
        g_thr[k] = (q >= 0) ? (th << q) : (th >> (-q));
    }
    np_piano_invalidate();
    np_piano_reset(0u);
}

/*
 * np_piano_set_colours -- per-voice lit colours: bright, and dim for the release fade.
 * Returns: nothing.
 */
void np_piano_set_colours(const uint8_t bright[NP_PIANO_VOICES], const uint8_t dim[NP_PIANO_VOICES])
{
    for (uint32_t v = 0u; v < NP_PIANO_VOICES; v++) {
        g_bright[v] = bright[v];
        g_dim[v] = dim[v];
    }
    np_piano_invalidate();
}

/*
 * np_piano_invalidate -- forget what both pages show; the next draws repaint everything.
 * Returns: nothing.
 */
void np_piano_invalidate(void)
{
    memset(g_valid, 0, sizeof(g_valid));
}

/*
 * np_piano_note -- nearest semitone key of a frequency register.
 * Steps: binary search for the highest key whose lower boundary <= reg (Q16).
 * Returns: key 0 (C0) .. 95 (B7), clamped at both ends.
 */
uint32_t np_piano_note(uint16_t freq_reg)
{
    const uint64_t x = (uint64_t)freq_reg << NP_Q;
    uint32_t lo = 0u;
    uint32_t hi = NP_PIANO_KEYS - 1u;

    while (lo < hi) {
        const uint32_t mid = (lo + hi + 1u) / 2u;

        if (g_thr[mid] <= x) {
            lo = mid;
        } else {
            hi = mid - 1u;
        }
    }
    return lo;
}

/*
 * voice_key -- key and intensity a voice shows.
 * Returns: key, or NP_PIANO_NO_KEY when the voice is not drawn; *inten is NP_STATE_*.
 */
static uint32_t voice_key(const np_piano_voice_t *v, uint32_t *inten)
{
    const uint8_t wave = (uint8_t)(v->control & NP_WAVE_MASK);

    *inten = 0u;
    if (v->level < NP_PIANO_LIT_MIN || (v->control & NP_TEST_BIT) != 0u || wave == 0u ||
        wave == NP_WAVE_NOISE || v->freq == 0u) {
        return NP_PIANO_NO_KEY;
    }
    *inten = (v->level < NP_PIANO_DIM_BELOW) ? NP_STATE_DIM : NP_STATE_BRIGHT;
    return np_piano_note(v->freq);
}

/*
 * key_geometry -- where a key sits.
 * Returns: the white key column index within its keyboard (for a black key: the white key to
 *   its left); *kb the keyboard; *black 1 for a black key.
 */
static uint32_t key_geometry(uint32_t key, uint32_t *kb, uint32_t *black)
{
    const uint32_t local = key % NP_PIANO_KEYS_PER_KB;
    const uint32_t semi = local % NP_SEMIS;

    *kb = key / NP_PIANO_KEYS_PER_KB;
    *black = g_is_black[semi];
    return (local / NP_SEMIS) * 7u + g_white_of[semi];
}

/*
 * paint_key -- paint one key from its state byte.
 * Steps: collect the lit voices (2 bits each), split the key width into bands in voice order,
 *   paint each band in its colour, or the whole key in its own colour when none is lit. A white
 *   key also paints its black separator column.
 * Returns: nothing.
 */
static void paint_key(uint32_t page, uint32_t key, uint8_t state)
{
    uint32_t kb;
    uint32_t black;
    const uint32_t w = key_geometry(key, &kb, &black);
    const uint32_t x = NP_PIANO_FRAME_X + 1u + w * NP_PIANO_WHITE_W + (black ? NP_BLACK_OFFSET : 0u);
    const uint32_t y = g_kb_y[kb] + 1u;
    const uint32_t width = black ? NP_PIANO_BLACK_W : NP_WHITE_BODY;
    const uint32_t height = black ? NP_PIANO_BLACK_H : NP_PIANO_KEY_H;
    uint8_t col[NP_PIANO_VOICES];
    uint32_t n = 0u;

    for (uint32_t v = 0u; v < NP_PIANO_VOICES; v++) {
        const uint32_t s = ((uint32_t)state >> (v * NP_STATE_BITS)) & NP_STATE_MASK;

        if (s != 0u) {
            col[n++] = (s == NP_STATE_BRIGHT) ? g_bright[v] : g_dim[v];
        }
    }
    if (n == 0u) {
        video_fill_rect(page, x, y, width, height, black ? NP_COL_BLACK : NP_COL_WHITE);
    } else {
        for (uint32_t i = 0u; i < n; i++) {
            const uint32_t a = (i * width) / n;
            const uint32_t b = ((i + 1u) * width) / n;

            video_fill_rect(page, x + a, y, b - a, height, col[i]);
        }
    }
    if (!black) {
        video_fill_rect(page, x + NP_WHITE_BODY, y, 1u, height, NP_COL_BLACK);
    }
}

/*
 * paint_all -- first draw of a page: background over the piano rows, the two frames, every
 *   white key, then every black key.
 * Returns: nothing.
 */
static void paint_all(uint32_t page, const uint8_t *state)
{
    video_fill_rect(page, NP_AREA_X, NP_AREA_Y, NP_AREA_W, NP_AREA_H, g_bg);
    for (uint32_t kb = 0u; kb < NP_PIANO_KEYBOARDS; kb++) {
        video_fill_rect(page, NP_PIANO_FRAME_X, g_kb_y[kb], NP_PIANO_FRAME_W, NP_PIANO_FRAME_H,
                        NP_COL_BLACK);
    }
    for (uint32_t pass = 0u; pass < 2u; pass++) {
        for (uint32_t k = 0u; k < NP_PIANO_KEYS; k++) {
            uint32_t kb;
            uint32_t black;

            (void)key_geometry(k, &kb, &black);
            if (black == pass) {
                paint_key(page, k, state[k]);
            }
        }
    }
}

/*
 * np_piano_draw -- bring a page up to date for the given voices.
 * Steps:
 *   1. Key state bytes from the voices (2 bits per voice: 0 off, 1 dim, 2 bright).
 *   2. A page not yet drawn: paint everything.
 *   3. Else mark keys that differ from the page record, add the black neighbours of each
 *      changed white key, repaint white keys then black keys (blacks overlap whites).
 * Returns: keys painted (96 for a full paint, 0 when nothing changed).
 */
uint32_t np_piano_draw(uint32_t page, const np_piano_voice_t v[NP_PIANO_VOICES])
{
    uint8_t state[NP_PIANO_KEYS];
    uint8_t dirty[NP_PIANO_KEYS];
    uint32_t painted = 0u;
    uint8_t *rec = g_rec[page & 1u];

    memset(state, 0, sizeof(state));
    for (uint32_t i = 0u; i < NP_PIANO_VOICES; i++) {
        uint32_t inten;
        const uint32_t k = voice_key(&v[i], &inten);

        if (k != NP_PIANO_NO_KEY) {
            state[k] = (uint8_t)(state[k] | (inten << (i * NP_STATE_BITS)));
        }
    }
    if (!g_valid[page & 1u]) {
        paint_all(page, state);
        memcpy(rec, state, sizeof(state));
        g_valid[page & 1u] = 1u;
        return NP_PIANO_KEYS;
    }
    memset(dirty, 0, sizeof(dirty));
    for (uint32_t k = 0u; k < NP_PIANO_KEYS; k++) {
        uint32_t kb;
        uint32_t black;

        if (state[k] == rec[k]) {
            continue;
        }
        dirty[k] = 1u;
        (void)key_geometry(k, &kb, &black);
        if (!black) {
            const uint32_t semi = (k % NP_PIANO_KEYS_PER_KB) % NP_SEMIS;

            if (semi != 0u && semi != 5u) {            /* a black key to the left */
                dirty[k - 1u] = 1u;
            }
            if (semi != 4u && semi != 11u) {           /* a black key to the right */
                dirty[k + 1u] = 1u;
            }
        }
    }
    for (uint32_t pass = 0u; pass < 2u; pass++) {
        for (uint32_t k = 0u; k < NP_PIANO_KEYS; k++) {
            uint32_t kb;
            uint32_t black;

            (void)key_geometry(k, &kb, &black);
            if (dirty[k] && black == pass) {
                paint_key(page, k, state[k]);
                painted++;
            }
        }
    }
    memcpy(rec, state, sizeof(state));
    return painted;
}

/*
 * np_piano_reset -- clear the tracker at a song start (stamps restart at `stamp`).
 * Returns: nothing.
 */
void np_piano_reset(uint32_t stamp)
{
    g_ev_head = 0u;
    g_ev_tail = 0u;
    sid_envmodel_reset(&g_env, stamp);
    memset(g_freq_lo, 0, sizeof(g_freq_lo));
    memset(g_freq_hi, 0, sizeof(g_freq_hi));
    memset(g_ctrl, 0, sizeof(g_ctrl));
    memset(g_heard, 0, sizeof(g_heard));
}

/*
 * np_piano_event -- queue one SID write (absolute phi2 stamp, non-decreasing).
 * Returns: nothing; registers >= 21 are ignored, a full queue drops the write (counted).
 */
void np_piano_event(uint32_t stamp, uint8_t reg, uint8_t val)
{
    const uint32_t next = (g_ev_head + 1u) % NP_PIANO_EVENT_CAP;

    if (reg >= NP_REGS_USED) {
        return;
    }
    if (next == g_ev_tail) {
        g_ev_drops++;
        return;
    }
    g_ev[g_ev_head].stamp = stamp;
    g_ev[g_ev_head].reg = reg;
    g_ev[g_ev_head].val = val;
    g_ev_head = next;
}

/*
 * apply_write -- apply one queued write to the heard registers and the envelope model.
 * Returns: nothing.
 */
static void apply_write(const np_event_t *e)
{
    const uint32_t v = e->reg / NP_VOICE_STRIDE;
    const uint32_t r = e->reg % NP_VOICE_STRIDE;

    if (r == NP_REG_FREQ_LO) {
        g_freq_lo[v] = e->val;
    } else if (r == NP_REG_FREQ_HI) {
        g_freq_hi[v] = e->val;
    } else if (r == NP_REG_CTRL) {
        g_ctrl[v] = e->val;
    }
    sid_envmodel_write(&g_env, e->stamp, e->reg, e->val);
}

/*
 * np_piano_sync -- bring the heard state to the audio position `now` (CYCLE).
 * Steps: apply queued writes with stamp <= now (signed difference) in order, advance the
 *   envelope model to now, snapshot freq / control / level per voice.
 * Returns: nothing.
 */
void np_piano_sync(uint32_t now)
{
    while (g_ev_tail != g_ev_head && (int32_t)(g_ev[g_ev_tail].stamp - now) <= 0) {
        apply_write(&g_ev[g_ev_tail]);
        g_ev_tail = (g_ev_tail + 1u) % NP_PIANO_EVENT_CAP;
    }
    sid_envmodel_advance(&g_env, now);
    for (uint32_t v = 0u; v < NP_PIANO_VOICES; v++) {
        g_heard[v].freq = (uint16_t)(((uint32_t)g_freq_hi[v] << 8) | g_freq_lo[v]);
        g_heard[v].control = g_ctrl[v];
        g_heard[v].level = sid_envmodel_level(&g_env, v);
    }
}

/*
 * np_piano_state -- the last synced voice state.
 * Returns: nothing.
 */
void np_piano_state(np_piano_voice_t v[NP_PIANO_VOICES])
{
    memcpy(v, g_heard, sizeof(g_heard));
}

/*
 * np_piano_lit_key -- key and intensity (1 dim, 2 bright) a voice shows now.
 * Returns: key or NP_PIANO_NO_KEY.
 */
uint32_t np_piano_lit_key(uint32_t voice, uint32_t *intensity)
{
    return voice_key(&g_heard[voice], intensity);
}

/*
 * np_piano_overlay -- c64screen overlay callback: draw the synced state on the back page.
 * Returns: keys painted.
 */
uint32_t np_piano_overlay(uint32_t page)
{
    return np_piano_draw(page, g_heard);
}
