/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: oled_ui.h
 * Role: content of the 128x32 OLED: an idle screen and the now-playing screen. Draws only
 *   through oled.h; reads the player only through basic_player_ops_t.
 *
 * Contract:
 *   - Idle: page 0 "IRONKERNEL 64", page 1 "BASIC V2 READY", page 2 "DRIVE 8: PRESENT" or
 *     "DRIVE 8: NOT READY" (drive_ready callback, re-asked at most every OLED_UI_PING_MS),
 *     page 3 blank.
 *   - Now playing:
 *     pages 0-1 double-height marquee (8x16 pixel characters, font_openroms), one column per
 *       vsync frame, of "<NAME>  *  <AUTHOR>  *  <RELEASED>  *  SONG nn/mm  *  TIME mm:ss  *  "
 *       (empty fields are left out). The text is longer than the 512-column frame buffer, so the
 *       hardware scroll registers act as a ring: the 256 columns from the scroll offset are kept
 *       drawn, and each frame draws the one column that enters that range (text column modulo
 *       8 * length), so the loop is seamless at any text length. The marquee starts over (offset 0, text from its first
 *       column) whenever the song number, the header texts (name / author / released / song count) or
 *       the tune change, which includes the time running backwards (a tune LOADed and RUN while the
 *       screen stayed up, or a song restarted). TIME changes every second
 *       inside the running text: the text is rebuilt (same length) and the drawn range is
 *       redrawn at the same scroll offset and text position, so the scroll neither jumps nor
 *       restarts. Both pages use the same offset.
 *     pages 2-3 three horizontal level bars (voice 1 top, voice 3 bottom), 4 pixel rows each at
 *       rows 1-4, 6-9, 11-14, length 0..128 columns from the envelope level 0..255 (voice 3
 *       from the hardware ENV3, voices 1 and 2 from the firmware envelope model).
 *   - oled_ui_poll() does nothing until the OLED block is present. It is called every main
 *     loop pass with the vsync counter; per-frame work runs once per counted frame (at most
 *     OLED_UI_MAX_CATCHUP frames after a stall).
 * Concurrency: main loop only.
 */
#ifndef OLED_UI_H
#define OLED_UI_H

#include <stdint.h> /* uint8_t, uint32_t */

#include "basic.h"  /* basic_player_ops_t, basic_tune_info_t */

#define OLED_UI_PING_MS       (5000u)
#define OLED_UI_MAX_CATCHUP   (4u)
#define OLED_UI_TEXT_MAX      (192u)   /* buffer bytes for the marquee text */

/* player: voice/time/info source; drive_ready: returns 1 when the drive answers (may be NULL). */
void oled_ui_init(const basic_player_ops_t *player, int (*drive_ready)(void));

/* playing: now-playing screen up; frame: video_vsync_count(); now_ms: millisecond counter. */
void oled_ui_poll(int playing, uint32_t frame, uint32_t now_ms);

/* Pure helpers (exposed for the host test). */
uint32_t oled_ui_marquee_text(char *out, const char *name, const char *author, const char *released,
                              uint32_t song, uint32_t songs, uint32_t secs);   /* length in chars */
void     oled_ui_double_column(uint8_t col, uint8_t *top, uint8_t *bottom);
uint32_t oled_ui_bar_len(uint8_t level);                         /* 0..128 columns */
void     oled_ui_bar_bytes(uint32_t col, const uint32_t len[BASIC_VOICES], uint8_t *top,
                           uint8_t *bottom);

#endif /* OLED_UI_H */
