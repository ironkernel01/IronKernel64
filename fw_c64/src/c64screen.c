/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: c64screen.c
 * Role: the C64 40 x 25 text layer: shadow memories, line links, cursor blink and the
 *   per-page dirty-cell redraw (contract in c64screen.h).
 *
 * Hardware: none directly; every pixel goes through video.h (video.c owns the framebuffer).
 * Redraw: g_drawn[page] records what each framebuffer page shows (glyph, colour, background
 *   and border). c64screen_render() draws the cells whose wanted state differs from the
 *   record of the back page, then flips. A page that has never been drawn starts invalid,
 *   so its first render draws everything.
 */
#include "c64screen.h"

#include "font_openroms.h"
#include "video.h"

#include <string.h>   /* memcpy, memmove, memset */

#define SCR_PAGES          (2u)
#define SCR_COLOUR_MASK    (0x0Fu)
#define SCR_GLYPH_INVALID  (0xFFFFu)
#define SCR_COLOUR_INVALID (0xFFu)
#define SCR_TEXT_W         (C64SCREEN_COLS * C64SCREEN_CELL_PIXELS)   /* 320 */
#define SCR_TEXT_H         (C64SCREEN_ROWS * C64SCREEN_CELL_PIXELS)   /* 200 */

#if (C64SCREEN_ORIGIN_X * 2u + SCR_TEXT_W) != C64_FB_WIDTH
#error "text area plus side borders must fill the framebuffer width"
#endif
#if (C64SCREEN_ORIGIN_Y * 2u + SCR_TEXT_H) != C64_FB_HEIGHT
#error "text area plus top/bottom borders must fill the framebuffer height"
#endif

/* What one framebuffer page shows. */
typedef struct
{
    uint16_t glyph[C64SCREEN_CELLS];
    uint8_t  colour[C64SCREEN_CELLS];
    uint8_t  background;
    uint8_t  border;
} scr_page_t;

static uint8_t    g_code[C64SCREEN_CELLS];    /* screen RAM ($0400) */
static uint8_t    g_colour[C64SCREEN_CELLS];  /* colour RAM ($D800) */
static uint8_t    g_link[C64SCREEN_ROWS];     /* 1: row continues row - 1 */
static uint8_t    g_border;
static uint8_t    g_background;
static uint32_t   g_charset;
static uint32_t   g_cur_row;
static uint32_t   g_cur_col;
static int        g_cur_on;
static uint32_t   g_blink_base;               /* vsync count when the blink phase restarted */
static scr_page_t g_drawn[SCR_PAGES];

/*
 * invalidate_pages -- forget what both pages show, so the next renders redraw everything.
 * Returns: nothing.
 */
static void invalidate_pages(void)
{
    for (uint32_t p = 0u; p < SCR_PAGES; p++) {
        memset(g_drawn[p].glyph, 0xFF, sizeof(g_drawn[p].glyph));
        memset(g_drawn[p].colour, SCR_COLOUR_INVALID, sizeof(g_drawn[p].colour));
        g_drawn[p].background = SCR_COLOUR_INVALID;
        g_drawn[p].border = SCR_COLOUR_INVALID;
    }
}

/*
 * c64screen_init -- power-on state: boot colours, cleared screen, upper-case set.
 * Steps:
 *   1. Border 14, background 6, every cell a space in text colour 14, no links.
 *   2. Cursor at home, enabled; both page records invalid.
 * Returns: nothing. video_init() must have run.
 */
void c64screen_init(void)
{
    g_border = C64SCREEN_BOOT_BORDER;
    g_background = C64SCREEN_BOOT_BACKGROUND;
    g_charset = C64SCREEN_CHARSET_UPPER;
    c64screen_clear(C64SCREEN_BOOT_TEXT);
    g_cur_on = 1;
    invalidate_pages();
}

/*
 * c64screen_clear -- spaces everywhere in the given colour, no links, cursor home.
 * Returns: nothing.
 */
void c64screen_clear(uint8_t colour)
{
    memset(g_code, C64SCREEN_SPACE, sizeof(g_code));
    memset(g_colour, colour & SCR_COLOUR_MASK, sizeof(g_colour));
    memset(g_link, 0, sizeof(g_link));
    c64screen_set_cursor(0u, 0u);
}

/*
 * c64screen_set_border -- border colour ($D020).
 * Returns: nothing.
 */
void c64screen_set_border(uint8_t colour)
{
    g_border = colour & SCR_COLOUR_MASK;
}

/*
 * c64screen_border -- current border colour.
 * Returns: 0..15.
 */
uint8_t c64screen_border(void)
{
    return g_border;
}

/*
 * c64screen_set_background -- background colour ($D021).
 * Returns: nothing.
 */
void c64screen_set_background(uint8_t colour)
{
    g_background = colour & SCR_COLOUR_MASK;
}

/*
 * c64screen_background -- current background colour.
 * Returns: 0..15.
 */
uint8_t c64screen_background(void)
{
    return g_background;
}

/*
 * c64screen_set_charset -- select the character set (C64SCREEN_CHARSET_*).
 * Returns: nothing.
 */
void c64screen_set_charset(uint32_t charset)
{
    g_charset = (charset == C64SCREEN_CHARSET_LOWER) ? C64SCREEN_CHARSET_LOWER
                                                     : C64SCREEN_CHARSET_UPPER;
}

/*
 * c64screen_charset -- selected character set.
 * Returns: C64SCREEN_CHARSET_UPPER or C64SCREEN_CHARSET_LOWER.
 */
uint32_t c64screen_charset(void)
{
    return g_charset;
}

/*
 * c64screen_put -- write one cell (ignored outside the screen).
 * Returns: nothing.
 */
void c64screen_put(uint32_t row, uint32_t col, uint8_t code, uint8_t colour)
{
    if (row < C64SCREEN_ROWS && col < C64SCREEN_COLS) {
        g_code[row * C64SCREEN_COLS + col] = code;
        g_colour[row * C64SCREEN_COLS + col] = colour & SCR_COLOUR_MASK;
    }
}

/*
 * c64screen_code -- screen code of one cell.
 * Returns: the code, or a space outside the screen.
 */
uint8_t c64screen_code(uint32_t row, uint32_t col)
{
    if (row < C64SCREEN_ROWS && col < C64SCREEN_COLS) {
        return g_code[row * C64SCREEN_COLS + col];
    }
    return C64SCREEN_SPACE;
}

/*
 * c64screen_colour -- colour of one cell.
 * Returns: 0..15, or 0 outside the screen.
 */
uint8_t c64screen_colour(uint32_t row, uint32_t col)
{
    if (row < C64SCREEN_ROWS && col < C64SCREEN_COLS) {
        return g_colour[row * C64SCREEN_COLS + col];
    }
    return 0u;
}

/*
 * c64screen_clear_row -- fill one row with spaces in a colour (its link is unchanged).
 * Returns: nothing.
 */
void c64screen_clear_row(uint32_t row, uint8_t colour)
{
    if (row < C64SCREEN_ROWS) {
        memset(&g_code[row * C64SCREEN_COLS], C64SCREEN_SPACE, C64SCREEN_COLS);
        memset(&g_colour[row * C64SCREEN_COLS], colour & SCR_COLOUR_MASK, C64SCREEN_COLS);
    }
}

/*
 * c64screen_scroll_up -- move every row up by one; the bottom row becomes blank.
 * Steps:
 *   1. Move cells, colours and links of rows 1..24 to rows 0..23.
 *   2. Row 0 is never linked; clear row 24 and its link.
 * Returns: nothing. The cursor row is the caller's (screen editor's) to adjust.
 */
void c64screen_scroll_up(uint8_t colour)
{
    const uint32_t keep = C64SCREEN_CELLS - C64SCREEN_COLS;

    memmove(g_code, &g_code[C64SCREEN_COLS], keep);
    memmove(g_colour, &g_colour[C64SCREEN_COLS], keep);
    memmove(g_link, &g_link[1], C64SCREEN_ROWS - 1u);
    g_link[0] = 0u;
    g_link[C64SCREEN_ROWS - 1u] = 0u;
    c64screen_clear_row(C64SCREEN_ROWS - 1u, colour);
}

/*
 * c64screen_insert_row -- open a blank row at `row`, pushing rows row..23 down by one.
 * Steps:
 *   1. Row 24 is lost; rows row..23 move to row+1..24 with their links.
 *   2. Clear row `row`; its link is 0 (the caller sets it).
 * Returns: nothing.
 */
void c64screen_insert_row(uint32_t row, uint8_t colour)
{
    if (row >= C64SCREEN_ROWS) {
        return;
    }
    if (row < C64SCREEN_ROWS - 1u) {
        uint32_t n = (C64SCREEN_ROWS - 1u - row) * C64SCREEN_COLS;
        memmove(&g_code[(row + 1u) * C64SCREEN_COLS], &g_code[row * C64SCREEN_COLS], n);
        memmove(&g_colour[(row + 1u) * C64SCREEN_COLS], &g_colour[row * C64SCREEN_COLS], n);
        memmove(&g_link[row + 1u], &g_link[row], C64SCREEN_ROWS - 1u - row);
    }
    g_link[row] = 0u;
    c64screen_clear_row(row, colour);
}

/*
 * c64screen_set_link -- mark a row as the continuation of the row above (row 0 never).
 * Returns: nothing.
 */
void c64screen_set_link(uint32_t row, int linked)
{
    if (row > 0u && row < C64SCREEN_ROWS) {
        g_link[row] = linked ? 1u : 0u;
    }
}

/*
 * c64screen_linked -- row continues the logical line of the row above.
 * Returns: 1 or 0.
 */
int c64screen_linked(uint32_t row)
{
    return (row < C64SCREEN_ROWS && g_link[row] != 0u) ? 1 : 0;
}

/*
 * c64screen_set_cursor -- move the cursor (clamped) and restart its blink phase (on).
 * Returns: nothing.
 */
void c64screen_set_cursor(uint32_t row, uint32_t col)
{
    g_cur_row = (row < C64SCREEN_ROWS) ? row : C64SCREEN_ROWS - 1u;
    g_cur_col = (col < C64SCREEN_COLS) ? col : C64SCREEN_COLS - 1u;
    g_blink_base = video_vsync_count();
}

/*
 * c64screen_cursor_enable -- show (blinking) or hide the cursor.
 * Returns: nothing.
 */
void c64screen_cursor_enable(int on)
{
    g_cur_on = on;
    g_blink_base = video_vsync_count();
}

/*
 * draw_border -- the four border rectangles around the text area.
 * Returns: nothing.
 */
static void draw_border(uint32_t page, uint8_t colour)
{
    video_fill_rect(page, 0u, 0u, C64_FB_WIDTH, C64SCREEN_ORIGIN_Y, colour);
    video_fill_rect(page, 0u, C64SCREEN_ORIGIN_Y + SCR_TEXT_H, C64_FB_WIDTH,
                    C64SCREEN_ORIGIN_Y, colour);
    video_fill_rect(page, 0u, C64SCREEN_ORIGIN_Y, C64SCREEN_ORIGIN_X, SCR_TEXT_H, colour);
    video_fill_rect(page, C64SCREEN_ORIGIN_X + SCR_TEXT_W, C64SCREEN_ORIGIN_Y,
                    C64SCREEN_ORIGIN_X, SCR_TEXT_H, colour);
}

/*
 * c64screen_render -- bring the back page up to date and show it.
 * Steps:
 *   1. Return 0 while a flip is pending (both pages busy).
 *   2. Work out the cursor phase: on for C64SCREEN_BLINK_FRAMES vsyncs, off for as many.
 *   3. Redraw the border if its colour differs from the page record; a background change
 *      invalidates every cell record of the page.
 *   4. For each cell, compute the wanted glyph (cursor cell: screen code with bit 7
 *      flipped) and colour; draw the cells whose record differs.
 *   5. Flip when anything was drawn.
 * Returns: number of cells drawn (0 when nothing changed or a flip is pending).
 */
uint32_t c64screen_render(void)
{
    uint32_t page;
    scr_page_t *rec;
    uint32_t drawn = 0u;
    int cursor_shown;
    int border_drawn = 0;

    if (video_flip_pending()) {
        return 0u;
    }
    page = video_back_page();
    rec = &g_drawn[page];
    cursor_shown = g_cur_on &&
        ((((video_vsync_count() - g_blink_base) / C64SCREEN_BLINK_FRAMES) & 1u) == 0u);

    if (rec->border != g_border) {
        draw_border(page, g_border);
        rec->border = g_border;
        border_drawn = 1;
    }
    if (rec->background != g_background) {
        memset(rec->glyph, 0xFF, sizeof(rec->glyph));
        rec->background = g_background;
    }
    for (uint32_t i = 0u; i < C64SCREEN_CELLS; i++) {
        uint8_t code = g_code[i];
        uint16_t glyph;

        if (cursor_shown && i == g_cur_row * C64SCREEN_COLS + g_cur_col) {
            code ^= C64SCREEN_REVERSE_BIT;
        }
        glyph = (uint16_t)(g_charset * FONT_OPENROMS_SET_GLYPHS + code);
        if (rec->glyph[i] != glyph || rec->colour[i] != g_colour[i]) {
            uint32_t row = i / C64SCREEN_COLS;
            uint32_t col = i % C64SCREEN_COLS;
            video_glyph(page, C64SCREEN_ORIGIN_X + col * C64SCREEN_CELL_PIXELS,
                        C64SCREEN_ORIGIN_Y + row * C64SCREEN_CELL_PIXELS,
                        font_openroms_glyph(glyph), g_colour[i], g_background, 0);
            rec->glyph[i] = glyph;
            rec->colour[i] = g_colour[i];
            drawn++;
        }
    }
    if (drawn != 0u || border_drawn) {
        video_flip();
    }
    return drawn;
}

/*
 * c64screen_save -- copy the text layer (cells, colours, links, colours, charset).
 * Returns: nothing.
 */
void c64screen_save(c64screen_snapshot_t *snap)
{
    memcpy(snap->code, g_code, sizeof(g_code));
    memcpy(snap->colour, g_colour, sizeof(g_colour));
    memcpy(snap->link, g_link, sizeof(g_link));
    snap->border = g_border;
    snap->background = g_background;
    snap->charset = (uint8_t)g_charset;
}

/*
 * c64screen_restore -- put back a saved text layer (the next renders redraw what differs).
 * Returns: nothing.
 */
void c64screen_restore(const c64screen_snapshot_t *snap)
{
    memcpy(g_code, snap->code, sizeof(g_code));
    memcpy(g_colour, snap->colour, sizeof(g_colour));
    memcpy(g_link, snap->link, sizeof(g_link));
    g_link[0] = 0u;
    c64screen_set_border(snap->border);
    c64screen_set_background(snap->background);
    c64screen_set_charset(snap->charset);
}

/*
 * c64screen_petscii_to_code -- screen code of a printable PETSCII character.
 * Steps:
 *   1. Map the printable PETSCII ranges as the C64 KERNAL does:
 *        $20-$3F -> $20-$3F   $40-$5F -> $00-$1F   $60-$7F -> $40-$5F
 *        $A0-$BF -> $60-$7F   $C0-$DF -> $40-$5F   $E0-$FE -> $60-$7E   $FF -> $5E
 *   2. $00-$1F and $80-$9F are control codes: no screen code.
 * Returns: 1 and *code set for a printable character, else 0.
 */
int c64screen_petscii_to_code(uint8_t petscii, uint8_t *code)
{
    if (petscii >= 0x20u && petscii <= 0x3Fu) {
        *code = petscii;
    } else if (petscii >= 0x40u && petscii <= 0x5Fu) {
        *code = (uint8_t)(petscii - 0x40u);
    } else if (petscii >= 0x60u && petscii <= 0x7Fu) {
        *code = (uint8_t)(petscii - 0x20u);
    } else if (petscii >= 0xA0u && petscii <= 0xBFu) {
        *code = (uint8_t)(petscii - 0x40u);
    } else if (petscii >= 0xC0u && petscii <= 0xFEu) {
        *code = (uint8_t)(petscii - 0x80u);
    } else if (petscii == 0xFFu) {
        *code = 0x5Eu;
    } else {
        return 0;
    }
    return 1;
}

/*
 * c64screen_code_to_petscii -- PETSCII character shown by a screen code (bit 7 ignored).
 * Steps:
 *   1. $00-$1F -> $40-$5F, $20-$3F -> $20-$3F, $40-$5F -> $C0-$DF, $60-$7F -> $A0-$BF.
 * Returns: the PETSCII code.
 */
uint8_t c64screen_code_to_petscii(uint8_t code)
{
    uint8_t c = (uint8_t)(code & 0x7Fu);

    if (c < 0x20u) {
        return (uint8_t)(c + 0x40u);
    }
    if (c < 0x40u) {
        return c;
    }
    if (c < 0x60u) {
        return (uint8_t)(c + 0x80u);
    }
    return (uint8_t)(c + 0x40u);
}
