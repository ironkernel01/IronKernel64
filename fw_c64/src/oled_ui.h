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
 *     page 0 marquee of "<NAME> - <AUTHOR> - <RELEASED> - ", one pixel per vsync frame. A text
 *       of up to 48 characters repeats with period 8 * length columns; a longer one is cut to
 *       61 characters plus " - " and a 49..63 character one is padded, giving the full
 *       512-column period. The scroll wraps at the period, so the loop is seamless.
 *     page 1 "SONG nn/mm  mm:ss", redrawn when the second changes.
 *     pages 2-3 rolling chart of ENV3 (0..255 -> 0..16 pixels, bar from the bottom), one
 *       column per frame at a moving write column; SCROLL2/3 follow so the newest column is
 *       at display column 127.
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
#define OLED_UI_CHART_PIXELS  (16u)
#define OLED_UI_TEXT_MAX      (128u)   /* buffer bytes for the marquee text */

/* player: voice/time/info source; drive_ready: returns 1 when the drive answers (may be NULL). */
void oled_ui_init(const basic_player_ops_t *player, int (*drive_ready)(void));

/* playing: now-playing screen up; frame: video_vsync_count(); now_ms: millisecond counter. */
void oled_ui_poll(int playing, uint32_t frame, uint32_t now_ms);

/* Pure helpers (exposed for the host test). */
uint32_t oled_ui_marquee_text(char *out, const char *name, const char *author, const char *released,
                              uint32_t *period_cols);     /* returns the text length in chars */
uint32_t oled_ui_chart_height(uint8_t env);                      /* 0..16 pixels */
void     oled_ui_chart_bytes(uint32_t height, uint8_t *top, uint8_t *bottom);

#endif /* OLED_UI_H */
