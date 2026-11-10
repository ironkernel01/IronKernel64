/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * c64screen_overlay_host_test.c -- host test of the c64screen overlay hook (fw_c64/src/c64screen.c)
 * against a fake video layer: text outside the overlay rows still renders, overlay rows are
 * skipped by the text layer, the overlay callback runs on the back page and forces a flip, and
 * removing the overlay redraws the text over it.
 *
 * Build and run (MSYS2 UCRT64, from the repo root):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/src tools/c64screen_overlay_host_test.c \
 *       fw_c64/src/c64screen.c -o build/c64screen_overlay_host_test.exe
 *   build/c64screen_overlay_host_test.exe [+INJECT_FAILURE]
 * Prints "TEST PASS: c64screen_overlay_host" or "TEST FAIL" (exit 1).
 */
#include "c64screen.h"
#include "font_openroms.h"
#include "video.h"

#include <stdio.h>
#include <string.h>

static uint8_t  g_fb[2][C64_FB_HEIGHT][C64_FB_WIDTH];
static uint32_t g_back;
static uint32_t g_flips;
static uint32_t g_glyphs;
static uint32_t g_ovl_calls;
static uint32_t g_ovl_ret;
static uint32_t g_ovl_page;
static int g_fail;
static const uint8_t g_solid[8] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

const uint8_t *font_openroms_glyph(uint32_t index) { (void)index; return g_solid; }
uint32_t video_back_page(void) { return g_back; }
int      video_flip_pending(void) { return 0; }
uint32_t video_vsync_count(void) { return 0; }
void     video_flip(void) { g_flips++; g_back ^= 1u; }

void video_fill_rect(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t c)
{
    for (uint32_t j = 0; j < h; j++) {
        for (uint32_t i = 0; i < w; i++) {
            g_fb[page][y + j][x + i] = c;
        }
    }
}

void video_glyph(uint32_t page, uint32_t x, uint32_t y, const uint8_t *rows, uint8_t fg, uint8_t bg,
                 int reverse)
{
    (void)rows; (void)bg; (void)reverse;
    g_glyphs++;
    for (uint32_t j = 0; j < 8; j++) {
        for (uint32_t i = 0; i < 8; i++) {
            g_fb[page][y + j][x + i] = fg;
        }
    }
}

static uint32_t overlay(uint32_t page)
{
    g_ovl_calls++;
    g_ovl_page = page;
    video_fill_rect(page, 40, 20 + 14 * 8, 8, 8, 99);
    return g_ovl_ret;
}

static void check(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        printf("  FAIL %s: got %u, want %u\n", what, (unsigned)got, (unsigned)want);
        g_fail = 1;
    }
}

/* Colour of the top-left pixel of text cell (row, col) on a page. */
static uint8_t cell(uint32_t page, uint32_t row, uint32_t col)
{
    return g_fb[page][C64SCREEN_ORIGIN_Y + row * 8u][C64SCREEN_ORIGIN_X + col * 8u];
}

int main(int argc, char **argv)
{
    c64screen_init();
    c64screen_put(2, 0, 1, 7);        /* outside the overlay */
    c64screen_put(15, 0, 1, 8);       /* inside rows 14..23 */
    c64screen_put(24, 0, 1, 9);       /* below the overlay */
    c64screen_set_overlay(14, 10, overlay);
    g_ovl_ret = 0;

    check("render returns text cells", c64screen_render() > 0u, 1u);
    check("overlay called once", g_ovl_calls, 1u);
    check("overlay got the back page (0)", g_ovl_page, 0u);
    check("text row 2 drawn", cell(0, 2, 0), 7u);
    check("text row 24 drawn", cell(0, 24, 0), 9u);
    check("overlay row 15 not drawn by text", cell(0, 15, 0), 0u);
    check("overlay pixels present", g_fb[0][20 + 14 * 8][40], 99u);
    check("flipped once", g_flips, 1u);

    /* Nothing changed: the overlay is still called, and a zero return does not flip. */
    check("page 1 first render draws its text", c64screen_render() > 0u, 1u);
    check("overlay got page 1", g_ovl_page, 1u);
    check("text row 2 drawn on page 1", cell(1, 2, 0), 7u);
    check("flipped twice", g_flips, 2u);
    check("settled render draws no text", c64screen_render(), 0u);
    check("overlay called every render", g_ovl_calls, 3u);
    check("no flip when overlay returns 0", g_flips, 2u);
    /* Overlay changes something: flip even though no text changed. */
    g_ovl_ret = 1u;
    (void)c64screen_render();
    check("overlay change flips", g_flips, 3u);
    g_ovl_ret = 0u;
    for (int i = 0; i < 4; i++) {
        (void)c64screen_render();
    }
    check("overlay row still undrawn on page 1", cell(1, 15, 0), 0u);

    /* Removing the overlay hands the rows back: the text redraws on both pages. */
    c64screen_set_overlay(0, 0, NULL);
    (void)c64screen_render();
    (void)c64screen_render();
    check("row 15 redrawn on page 0", cell(0, 15, 0), 8u);
    check("row 15 redrawn on page 1", cell(1, 15, 0), 8u);
    check("overlay not called after removal", g_ovl_calls, 8u);

    if (argc > 1 && strcmp(argv[1], "+INJECT_FAILURE") == 0) {
        g_fail = 1;
    }
    printf(g_fail ? "TEST FAIL: c64screen_overlay_host\n" : "TEST PASS: c64screen_overlay_host\n");
    return g_fail ? 1 : 0;
}
