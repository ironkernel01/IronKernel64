/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: video.h
 * Role: the c64_video block (registers, palette, vsync interrupt) and the two 8-bpp
 *   framebuffer pages, as seen by core 0.
 *
 * Ownership: video.c is the only file that touches the c64_video registers
 *   (C64_PLAT_WIN0_BASE + C64_WIN_VID_OFS) and the framebuffer BRAM (C64_PLAT_FB_BASE).
 *   Everything else draws through this API.
 *
 * Contract:
 *   - Geometry: C64_FB_WIDTH x C64_FB_HEIGHT pixels per page, one byte per pixel holding a
 *     palette index, row-major; page p starts at C64_PLAT_FB_BASE + p * C64_FB_PAGE_BYTES.
 *     Byte address y * C64_FB_WIDTH + x holds pixel (x, y); in a 32-bit word the lowest
 *     byte is the leftmost pixel (little-endian AXI BRAM byte lanes).
 *   - Double buffering: the CPU draws on the back page only. video_flip() asks the
 *     hardware to show the back page from the next vsync on; until that vsync both pages
 *     are busy (video_flip_pending() != 0) and drawing must wait. Callers poll
 *     video_flip_pending() instead of blocking.
 *   - Vsync: in VIDEO_VSYNC_IRQ mode the INTC calls video_vsync_isr(); in VIDEO_VSYNC_POLL
 *     mode the main loop calls video_poll(). Either way video_vsync_count() advances once
 *     per frame (60 Hz). Only one of the two may be used, chosen at video_init().
 *   - Coordinates outside the page are clipped, never written.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef VIDEO_H
#define VIDEO_H

#include <stdint.h> /* uint8_t, uint32_t */

#include "c64_regs.h"

/* C64 colour indices (palette entries 0..15, VIC-II order). */
#define VIDEO_COL_BLACK        (0u)
#define VIDEO_COL_WHITE        (1u)
#define VIDEO_COL_RED          (2u)
#define VIDEO_COL_CYAN         (3u)
#define VIDEO_COL_PURPLE       (4u)
#define VIDEO_COL_GREEN        (5u)
#define VIDEO_COL_BLUE         (6u)
#define VIDEO_COL_YELLOW       (7u)
#define VIDEO_COL_ORANGE       (8u)
#define VIDEO_COL_BROWN        (9u)
#define VIDEO_COL_LIGHT_RED    (10u)
#define VIDEO_COL_DARK_GREY    (11u)
#define VIDEO_COL_GREY         (12u)
#define VIDEO_COL_LIGHT_GREEN  (13u)
#define VIDEO_COL_LIGHT_BLUE   (14u)
#define VIDEO_COL_LIGHT_GREY   (15u)
#define VIDEO_C64_COLOURS      (16u)

#define VIDEO_GLYPH_PIXELS     (8u)   /* glyphs are 8 x 8 pixels */

typedef enum
{
    VIDEO_VSYNC_POLL = 0,  /* main loop calls video_poll() */
    VIDEO_VSYNC_IRQ  = 1   /* INTC calls video_vsync_isr() */
} video_vsync_mode_t;

void     video_init(video_vsync_mode_t mode);
void     video_vsync_isr(void *ref);
uint32_t video_poll(void);
uint32_t video_vsync_count(void);
uint32_t video_frame_counter(void);

uint32_t video_back_page(void);
uint32_t video_front_page(void);
int      video_flip_pending(void);
void     video_flip(void);

void     video_set_palette(uint32_t index, uint32_t rgb);
void     video_fill_page(uint32_t page, uint8_t colour);
void     video_fill_rect(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                         uint8_t colour);
void     video_putpixel(uint32_t page, uint32_t x, uint32_t y, uint8_t colour);
void     video_glyph(uint32_t page, uint32_t x, uint32_t y, const uint8_t *rows, uint8_t fg,
                     uint8_t bg, int reverse);

#endif /* VIDEO_H */
