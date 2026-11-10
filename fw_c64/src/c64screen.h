/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64screen.h
 * Role: the 40 x 25 C64 text layer: shadow screen-code and colour memories (the C64's $0400
 *   and $D800), border and background colours, the screen editor's line-link table, the
 *   blinking cursor, and the dirty-cell redraw into the framebuffer through video.h.
 *
 * Contract:
 *   - Cells hold C64 screen codes (bit 7 = reverse video) and colour indices 0..15. Glyph
 *     for a cell = font_openroms_glyph(charset * 256 + screen code); the font carries its
 *     own reverse halves, so the reverse bit selects the glyph directly.
 *   - Text area origin in the 384 x 240 page: C64SCREEN_ORIGIN_X / _Y (32 px left and right
 *     border, 20 lines top and bottom). The border is drawn in the border colour.
 *   - Line links: c64screen_linked(row) != 0 means row continues the logical line that
 *     starts on row - 1 (a logical line is at most C64SCREEN_LINE_MAX = 80 characters, as
 *     on a C64). Scrolling and row insertion move the links with the rows. Row 0 is never
 *     linked.
 *   - The cursor is drawn by flipping bit 7 of the cell under it while the blink phase is
 *     on (as the C64 KERNAL does); it blinks at C64SCREEN_BLINK_FRAMES per phase from the
 *     vsync count (60 Hz / 15 = 4 phases per second, a 2 Hz blink).
 *   - c64screen_render() never blocks: when a page flip is still pending it returns 0 and
 *     draws nothing; the caller calls it again from its loop. Each page keeps a record of
 *     what it shows, so only changed cells are redrawn on each page.
 *   - The model (cells, colours, links) is written by the main context only.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef C64SCREEN_H
#define C64SCREEN_H

#include <stdint.h> /* uint8_t, uint32_t */

#define C64SCREEN_COLS          (40u)
#define C64SCREEN_ROWS          (25u)
#define C64SCREEN_CELLS         (C64SCREEN_COLS * C64SCREEN_ROWS)   /* 1000 */
#define C64SCREEN_LINE_MAX      (2u * C64SCREEN_COLS)               /* logical line, 80 */
#define C64SCREEN_ORIGIN_X      (32u)
#define C64SCREEN_ORIGIN_Y      (20u)
#define C64SCREEN_CELL_PIXELS   (8u)
#define C64SCREEN_BLINK_FRAMES  (15u)
#define C64SCREEN_REVERSE_BIT   (0x80u)
#define C64SCREEN_SPACE         (0x20u)                             /* screen code of ' ' */

#define C64SCREEN_CHARSET_UPPER (0u)  /* upper case + graphics (power-on) */
#define C64SCREEN_CHARSET_LOWER (1u)  /* lower case + upper case */

/* Boot colours (C64 power-on): border 14, background 6, text 14. */
#define C64SCREEN_BOOT_BORDER     (14u)
#define C64SCREEN_BOOT_BACKGROUND (6u)
#define C64SCREEN_BOOT_TEXT       (14u)

/* A copy of the whole text layer, for screens that replace and later restore it. */
typedef struct
{
    uint8_t code[C64SCREEN_CELLS];
    uint8_t colour[C64SCREEN_CELLS];
    uint8_t link[C64SCREEN_ROWS];
    uint8_t border;
    uint8_t background;
    uint8_t charset;
} c64screen_snapshot_t;

void     c64screen_init(void);
void     c64screen_clear(uint8_t colour);
void     c64screen_set_border(uint8_t colour);
uint8_t  c64screen_border(void);
void     c64screen_set_background(uint8_t colour);
uint8_t  c64screen_background(void);
void     c64screen_set_charset(uint32_t charset);
uint32_t c64screen_charset(void);

void     c64screen_put(uint32_t row, uint32_t col, uint8_t code, uint8_t colour);
uint8_t  c64screen_code(uint32_t row, uint32_t col);
uint8_t  c64screen_colour(uint32_t row, uint32_t col);
void     c64screen_clear_row(uint32_t row, uint8_t colour);
void     c64screen_scroll_up(uint8_t colour);
void     c64screen_insert_row(uint32_t row, uint8_t colour);
void     c64screen_set_link(uint32_t row, int linked);
int      c64screen_linked(uint32_t row);

void     c64screen_set_cursor(uint32_t row, uint32_t col);
void     c64screen_cursor_enable(int on);

uint32_t c64screen_render(void);

/* Overlay: text rows [first_row, first_row + rows) are left to fn, which draws pixels on the
 * back page it is given and returns how many things it changed (the page flips when that is
 * non-zero, like a text change). The text layer never draws those rows while the overlay is
 * set; fn(page) must paint the whole area on a page's first call. c64screen_set_overlay(0, 0,
 * NULL) removes it and marks the rows for redraw. */
typedef uint32_t (*c64screen_overlay_fn)(uint32_t page);
void     c64screen_set_overlay(uint32_t first_row, uint32_t rows, c64screen_overlay_fn fn);

void     c64screen_save(c64screen_snapshot_t *snap);
void     c64screen_restore(const c64screen_snapshot_t *snap);

int      c64screen_petscii_to_code(uint8_t petscii, uint8_t *code);
uint8_t  c64screen_code_to_petscii(uint8_t code);

#endif /* C64SCREEN_H */
