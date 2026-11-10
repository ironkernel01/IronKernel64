/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: oled.h
 * Role: driver of the oled_ctrl block (128x32 SSD1306-style OLED of the Nexys Video) as seen by
 *   core 0: power, scroll offsets and the text/column primitives on the 4 x 512 virtual-column
 *   frame buffer.
 *
 * Hardware: register block at C64_PLAT_WIN0_BASE + C64_WIN_OLED_OFS (0x4405_0000), offsets in
 *   c64_regs.h. Hardware refreshes the panel at 60 Hz by itself once POWER is set; the frame
 *   buffer and the scroll registers can be written at any time and no call here waits.
 *
 * Contract:
 *   - Geometry: OLED_PAGES (4) pages of 8 pixel rows; each page is OLED_VCOLS (512) virtual
 *     columns of one byte (bit 0 = top row of the page). Display column x of page p shows
 *     virtual column (x + scroll[p]) mod 512, so the visible window is OLED_WIDTH (128) wide.
 *   - Text: 8x8 glyphs of font_openroms (bit 7 = leftmost pixel, row 0 = top), transposed to
 *     page format; one text row per page; 64 characters fill one virtual line. Characters
 *     that would pass virtual column 511 are clipped (no wrap).
 *   - oled_init() checks the ID register; when the block is absent every other call is a
 *     no-op and returns 0, and one UART line is logged.
 *   - Ownership: this module is the only code that touches the OLED registers.
 * Concurrency: main loop only.
 */
#ifndef OLED_H
#define OLED_H

#include <stdint.h> /* uint8_t, uint32_t */

#define OLED_PAGES        (4u)
#define OLED_VCOLS        (512u)
#define OLED_WIDTH        (128u)
#define OLED_GLYPH_COLS   (8u)
#define OLED_TEXT_CHARS   (OLED_VCOLS / OLED_GLYPH_COLS)   /* 64 */

#define OLED_STATE_OFF           (0u)
#define OLED_STATE_POWERING_UP   (1u)
#define OLED_STATE_RUNNING       (2u)
#define OLED_STATE_POWERING_DOWN (3u)

int      oled_init(void);                       /* 1 = block present, POWER set */
int      oled_present(void);
void     oled_clear(void);                      /* all pages, all columns to 0 */
void     oled_set_contrast(uint8_t contrast);
void     oled_set_scroll(uint32_t page, uint32_t off);  /* off taken mod 512 */
void     oled_put_column(uint32_t page, uint32_t vcol, uint8_t bits);
uint8_t  oled_get_column(uint32_t page, uint32_t vcol);
uint32_t oled_put_text(uint32_t page, uint32_t vcol, const char *ascii, int invert);
uint32_t oled_status(void);                     /* STATUS register, 0 when absent */

/* Pure helpers (exposed for the host test). */
uint8_t  oled_glyph_column(const uint8_t *glyph, uint32_t x, int invert);
uint32_t oled_ascii_to_screen(char c);          /* ASCII to C64 screen code (set 0) */

#endif /* OLED_H */
