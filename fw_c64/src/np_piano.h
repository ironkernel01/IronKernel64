/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: np_piano.h
 * Role: the two piano keyboards of the now-playing screen, in the style of the classic C64
 *   "SID PLAYER" display (archive.org sid_collection): the note each voice sounds lights its
 *   key in the voice colour. Renderer plus a small heard-state tracker; no hardware access
 *   except the pixel primitives of video.h.
 *
 * Layout (384 x 240 page, text origin 32/20):
 *   - Two keyboards of 4 octaves = 28 white keys each. Upper keyboard C0..B3, lower C4..B7
 *     (96 semitones, the whole SID range). A white key is 8 px: 7 px body + a 1 px black
 *     separator. Frame: black outline, 225 x 36 px at x = 79, y = 134 and y = 174. Inside the
 *     frame the keys are 34 px high; black keys are 5 px wide, 20 px high (about 60 %),
 *     centred on the boundary between two white keys (2+3 pattern).
 *   - Text rows NP_PIANO_ROW_FIRST .. +NP_PIANO_ROWS-1 (14..23, y 132..211) belong to the
 *     piano; the text layer must not draw them (c64screen_set_overlay).
 * Lighting: a lit white key is filled over its whole height (black keys then overlay it); a lit
 *   black key fills its bar. Two or three voices on one key split it into vertical bands in
 *   voice order. Intensity: bright colour while level >= NP_PIANO_DIM_BELOW, dim colour from
 *   NP_PIANO_LIT_MIN up to that (the release fade); dark below NP_PIANO_LIT_MIN.
 * Which voices show: level >= NP_PIANO_LIT_MIN, TEST bit clear, a waveform selected, and not
 *   noise-only (waveform nibble 8 = noise alone is drums: no pitch, shown nowhere); freq != 0.
 *   Notes below C0 or above B7 clamp to the end key (B7 is never exceeded: 65535 * clk / 2^24
 *   is under 3.9 kHz).
 * Sound match: np_piano_event() takes every SID write with its absolute phi2 stamp (the
 *   write tap; stamps run up to PLAYER_LEAD_FRAMES periods ahead of the heard audio).
 *   np_piano_sync(now) applies only the writes with stamp <= now (CYCLE) and runs a private
 *   envelope model to now, so the keys show what is audible at the last sync before a frame
 *   (several play calls per frame: the state after the last one). Arpeggio notes and vibrato
 *   show the nearest semitone at each displayed frame; there is no minimum on-time (a note
 *   shorter than one displayed frame can be skipped).
 * Redraw: per page, only keys whose state changed (plus their neighbouring black keys, which
 *   overlap the white key) are painted; the first draw of a page paints everything.
 * Concurrency: main loop only.
 */
#ifndef NP_PIANO_H
#define NP_PIANO_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

#define NP_PIANO_VOICES         (3u)
#define NP_PIANO_KEYS           (96u)    /* C0 .. B7 */
#define NP_PIANO_KEYBOARDS      (2u)
#define NP_PIANO_KEYS_PER_KB    (48u)
#define NP_PIANO_WHITE_PER_KB   (28u)
#define NP_PIANO_WHITE_W        (8u)
#define NP_PIANO_BLACK_W        (5u)
#define NP_PIANO_KEY_H          (34u)
#define NP_PIANO_BLACK_H        (20u)
#define NP_PIANO_FRAME_X        (79u)
#define NP_PIANO_FRAME_W        (225u)
#define NP_PIANO_FRAME_H        (36u)
#define NP_PIANO_KB0_Y          (134u)
#define NP_PIANO_KB1_Y          (174u)
#define NP_PIANO_ROW_FIRST      (14u)
#define NP_PIANO_ROWS           (10u)
#define NP_PIANO_NO_KEY         (0xFFu)

#define NP_PIANO_LIT_MIN        (6u)     /* envelope level below this is dark */
#define NP_PIANO_DIM_BELOW      (96u)    /* below this level the dim colour is used */
#define NP_PIANO_EVENT_CAP      (512u)   /* queued SID writes (lead is 2-3 frames, ~60 writes each) */

typedef struct
{
    uint16_t freq;      /* SID frequency register, 16 bit */
    uint8_t  control;   /* control register: waveform bits 7..4, test 3, gate 0 */
    uint8_t  level;     /* envelope level 0..255 */
} np_piano_voice_t;

void     np_piano_init(uint32_t clock_hz, uint8_t background);
void     np_piano_set_colours(const uint8_t bright[NP_PIANO_VOICES], const uint8_t dim[NP_PIANO_VOICES]);
uint32_t np_piano_note(uint16_t freq_reg);                  /* key 0..95 */
void     np_piano_invalidate(void);                         /* both pages repaint fully next */

/* Pure renderer: draw the keys for these voices on a page; returns keys repainted. */
uint32_t np_piano_draw(uint32_t page, const np_piano_voice_t v[NP_PIANO_VOICES]);

/* Heard-state tracker (fed by the write tap, sampled by the player service). */
void     np_piano_reset(uint32_t stamp);
void     np_piano_event(uint32_t stamp, uint8_t reg, uint8_t val);
void     np_piano_sync(uint32_t now);
void     np_piano_state(np_piano_voice_t v[NP_PIANO_VOICES]);
uint32_t np_piano_lit_key(uint32_t voice, uint32_t *intensity);  /* key or NP_PIANO_NO_KEY */
uint32_t np_piano_overlay(uint32_t page);                   /* c64screen overlay callback */

#endif /* NP_PIANO_H */
