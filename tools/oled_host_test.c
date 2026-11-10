/*
 * File: oled_host_test.c
 * Role: host unit test of fw_c64/src/oled.c and oled_ui.c on a fake OLED register file.
 * Build/run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -Werror -DOLED_HOST_TEST -Ifw_c64/src -Icommon tools/oled_host_test.c \
 *       fw_c64/src/oled.c fw_c64/src/oled_ui.c fw_c64/src/font_openroms.c -o oled_host_test
 *   ./oled_host_test [--inject-fail]
 * Prints "TEST PASS: oled_host" or "TEST FAIL" (exit 0 / 1). --inject-fail corrupts one
 * expectation to prove the checks can fail.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "font_openroms.h"
#include "oled.h"
#include "oled_ui.h"

#define BASE     (0x44050000u)
#define FB_WORDS (512u)

static uint32_t g_fb[FB_WORDS];
static uint32_t g_scroll[4];
static uint32_t g_ctrl;
static int      g_fail;
static int      g_inject;

uint32_t Xil_In32(uintptr_t addr)
{
    const uint32_t o = (uint32_t)addr - BASE;

    if (o == 0u) {
        return 0x4F4C4544u;
    }
    if (o >= 0x800u && o < 0x800u + 4u * FB_WORDS) {
        return g_fb[(o - 0x800u) / 4u];
    }
    if (o >= 0x20u && o < 0x30u) {
        return g_scroll[(o - 0x20u) / 4u];
    }
    return (o == 0x8u) ? g_ctrl : 0u;
}

void Xil_Out32(uintptr_t addr, uint32_t val)
{
    const uint32_t o = (uint32_t)addr - BASE;

    if (o >= 0x800u && o < 0x800u + 4u * FB_WORDS) {
        g_fb[(o - 0x800u) / 4u] = val;
    } else if (o >= 0x20u && o < 0x30u) {
        g_scroll[(o - 0x20u) / 4u] = val;
    } else if (o == 0x8u) {
        g_ctrl = val;
    }
}

#define CHECK(cond, msg) do { if (!(cond)) { g_fail = 1; printf("check failed: %s (line %d)\n", msg, __LINE__); } } while (0)

static uint8_t lane(uint32_t page, uint32_t vcol)
{
    return (uint8_t)(g_fb[page * 128u + (vcol >> 2)] >> (8u * (vcol & 3u)));
}

/* Fake player. */
static uint32_t g_ms;
static uint8_t  g_lvl[BASIC_VOICES];
static uint32_t g_song = 1u;
static void f_info(basic_tune_info_t *i)
{
    memset(i, 0, sizeof(*i));
    strcpy(i->name, "AB");
    strcpy(i->author, "CD");
    strcpy(i->released, "1985");
    i->songs = 3u;
    i->start_song = g_song;
}
static uint32_t f_elapsed(void) { return g_ms; }
static void f_levels(uint8_t l[BASIC_VOICES]) { l[0] = g_lvl[0]; l[1] = g_lvl[1]; l[2] = g_lvl[2]; }
static basic_player_ops_t g_ops = { 0, f_info, 0, 0, f_elapsed, f_levels, 0 };
static int g_drive;
static int f_drive(void) { return g_drive; }

static void test_glyph(void)
{
    const uint8_t *g = font_openroms_glyph(oled_ascii_to_screen('A'));
    uint32_t put;

    CHECK(oled_ascii_to_screen('a') == 1u && oled_ascii_to_screen('A') == 1u, "ascii map letters");
    CHECK(oled_ascii_to_screen('5') == 0x35u, "ascii map digit");
    for (uint32_t x = 0u; x < 8u; x++) {
        uint32_t exp = 0u;

        for (uint32_t r = 0u; r < 8u; r++) {
            if ((g[r] & (0x80u >> x)) != 0u) {
                exp |= 1u << r;
            }
        }
        if (g_inject && x == 3u) {
            exp ^= 1u;
        }
        CHECK(oled_glyph_column(g, x, 0) == (uint8_t)exp, "glyph column");
        CHECK(oled_glyph_column(g, x, 1) == (uint8_t)(exp ^ 0xFFu), "glyph column inverted");
    }
    put = oled_put_text(1u, 0u, "A", 0);
    CHECK(put == 8u, "put_text count");
    CHECK(lane(1u, 0u) == oled_glyph_column(g, 0u, 0), "page 1 col 0");
}

static void test_unaligned(void)
{
    const uint8_t *g = font_openroms_glyph(oled_ascii_to_screen('B'));

    oled_clear();
    (void)oled_put_text(2u, 5u, "B", 0);
    for (uint32_t x = 0u; x < 8u; x++) {
        CHECK(lane(2u, 5u + x) == oled_glyph_column(g, x, 0), "unaligned lane");
    }
    CHECK(((g_fb[2u * 128u + 1u] >> 8) & 0xFFu) == oled_glyph_column(g, 0u, 0), "word 1 lane 1");
    CHECK(lane(2u, 4u) == 0u && lane(2u, 13u) == 0u, "neighbours untouched");
    CHECK(lane(1u, 5u) == 0u, "other page untouched");
    CHECK(oled_put_text(0u, 508u, "AB", 0) == 4u, "clip at 512");
}

/* Expected double-height marquee column pair of text column pos (pos mod 8 * length). */
static void expect_col(const char *text, uint32_t pos, uint8_t *top, uint8_t *bottom)
{
    const uint32_t cols = (uint32_t)strlen(text) * 8u;
    const uint32_t p = pos % cols;
    const uint8_t *g = font_openroms_glyph(oled_ascii_to_screen(text[p / 8u]));

    oled_ui_double_column(oled_glyph_column(g, p % 8u, 0), top, bottom);
}

/* The 256 drawn columns from the scroll offset show the text from text column s0. */
static int window_matches(const char *text, uint32_t s0)
{
    for (uint32_t k = 0u; k < 256u; k++) {
        uint8_t t;
        uint8_t b;
        const uint32_t v = (g_scroll[0] + k) & 511u;

        expect_col(text, s0 + k, &t, &b);
        if (lane(0u, v) != t || lane(1u, v) != b) {
            return 0;
        }
    }
    return 1;
}

static void test_double(void)
{
    uint8_t t;
    uint8_t b;

    oled_ui_double_column(0x01u, &t, &b);
    CHECK(t == 0x03u && b == 0x00u, "double row 0");
    oled_ui_double_column(0x10u, &t, &b);
    CHECK(t == 0x00u && b == 0x03u, "double row 4");
    oled_ui_double_column(0x81u, &t, &b);
    CHECK(t == 0x03u && b == 0xC0u, "double rows 0 and 7");
    oled_ui_double_column(0xFFu, &t, &b);
    CHECK(t == 0xFFu && b == 0xFFu, "double full");
    oled_ui_double_column(0x00u, &t, &b);
    CHECK(t == 0x00u && b == 0x00u, "double empty");
}

static void test_marquee(void)
{
    char text[OLED_UI_TEXT_MAX];
    char text2[OLED_UI_TEXT_MAX];
    char longs[40];
    uint32_t len;
    uint32_t s0 = 0u;
    uint32_t before;
    const char *want = "AB  *  CD  *  1985  *  SONG 01/03  *  TIME 00:15  *  ";

    len = oled_ui_marquee_text(text, "AB", "CD", "1985", 1u, 3u, 15u);
    CHECK(strcmp(text, want) == 0 && len == strlen(want), "marquee composition");
    len = oled_ui_marquee_text(text, "LIVIN' ON A PRAYER", "SAMI SEPPA (ROCK)", "2016 FINNISH GOLD", 1u, 1u, 15u);
    CHECK(strcmp(text, "LIVIN' ON A PRAYER  *  SAMI SEPPA (ROCK)  *  2016 FINNISH GOLD  *  SONG 01/01  *  TIME 00:15  *  ") == 0,
          "marquee example");
    len = oled_ui_marquee_text(text, "AB", "", "", 12u, 120u, 754u);
    CHECK(strcmp(text, "AB  *  SONG 12/120  *  TIME 12:34  *  ") == 0 && len == strlen(text), "marquee empty fields, 3 digits");
    (void)oled_ui_marquee_text(text, "AB", "CD", "EF", 1u, 1u, 99999u);
    CHECK(strstr(text, "TIME 99:59") != NULL, "marquee time clamp");
    memset(longs, 'X', 32);
    longs[32] = '\0';
    len = oled_ui_marquee_text(text, longs, longs, longs, 1u, 1u, 0u);
    CHECK(len < OLED_UI_TEXT_MAX && strstr(text, "SONG 01/01") != NULL && strstr(text, "TIME 00:00") != NULL,
          "marquee 32-char fields fit");
    (void)oled_ui_marquee_text(text, "AB", "CD", "1985", 1u, 3u, 0u);
    (void)oled_ui_marquee_text(text2, "AB", "CD", "1985", 1u, 3u, 3599u);
    CHECK(strlen(text) == strlen(text2), "time keeps the length");

    /* Playing: the scroll advances one column per frame, wraps on the 512 ring, and the drawn
     * window always shows the text at the matching text column (seamless over many wraps). */
    memset(g_fb, 0, sizeof(g_fb));
    g_ms = 15000u;
    g_song = 1u;
    oled_ui_init(&g_ops, f_drive);
    oled_ui_poll(1, 100u, 0u);
    CHECK(g_scroll[0] == 0u && g_scroll[1] == 0u, "scroll start");
    CHECK(window_matches(want, 0u), "window at start");
    for (uint32_t f = 1u; f <= 1500u; f++) {
        oled_ui_poll(1, 100u + f, 0u);
        s0 = f;
        CHECK(g_scroll[0] == (f % 512u) && g_scroll[1] == g_scroll[0], "scroll steps and wraps at 512");
        if ((f % 61u) == 0u || f > 1490u) {
            CHECK(window_matches(want, s0), "window follows the text");
        }
    }
    CHECK(lane(2u, 0u) == 0u && lane(3u, 0u) == 0u, "bars idle at 0");

    /* TIME ticks: same frame (no scroll step), the second changes. Offset and text position stay. */
    before = g_scroll[0];
    g_ms = 16000u;
    oled_ui_poll(1, 100u + 1500u, 0u);
    CHECK(g_scroll[0] == before, "time update keeps the scroll offset");
    CHECK(window_matches("AB  *  CD  *  1985  *  SONG 01/03  *  TIME 00:16  *  ", s0), "time update redraws in place");
    CHECK(!window_matches(want, s0), "old time is gone");
    oled_ui_poll(1, 100u + 1501u, 0u);
    CHECK(g_scroll[0] == ((before + 1u) & 511u), "scroll continues after the time update");
    CHECK(window_matches("AB  *  CD  *  1985  *  SONG 01/03  *  TIME 00:16  *  ", s0 + 1u), "continues seamlessly");

    /* Song change restarts the time but not the scroll. */
    before = g_scroll[0];
    g_song = 2u;
    g_ms = 0u;
    oled_ui_poll(1, 100u + 1501u, 0u);
    CHECK(g_scroll[0] == before, "song change keeps the scroll offset");
    CHECK(window_matches("AB  *  CD  *  1985  *  SONG 02/03  *  TIME 00:00  *  ", s0 + 1u), "song change text");
}

static void test_bars(void)
{
    uint32_t len[3];
    uint8_t t;
    uint8_t b;

    CHECK(oled_ui_bar_len(0u) == 0u && oled_ui_bar_len(1u) == 1u && oled_ui_bar_len(255u) == 128u, "bar len");
    len[0] = 1u; len[1] = 1u; len[2] = 1u;
    oled_ui_bar_bytes(0u, len, &t, &b);
    CHECK(t == 0xDEu && b == 0x7Bu, "bars all three: rows 1-4, 6-9, 11-14");
    len[0] = 0u; len[1] = 5u; len[2] = 0u;
    oled_ui_bar_bytes(4u, len, &t, &b);
    CHECK(t == 0xC0u && b == 0x03u, "bar 2 only");
    oled_ui_bar_bytes(5u, len, &t, &b);
    CHECK(t == 0u && b == 0u, "past the bar end");

    /* Playing screen: levels of the three voices reach the three bars. */
    memset(g_fb, 0, sizeof(g_fb));
    g_ms = 0u;
    g_song = 1u;
    g_lvl[0] = 0u; g_lvl[1] = 0u; g_lvl[2] = 0u;
    oled_ui_init(&g_ops, f_drive);
    oled_ui_poll(0, 1000u, 0u);
    oled_ui_poll(1, 1001u, 0u);
    CHECK(g_scroll[2] == 0u && g_scroll[3] == 0u, "bar pages do not scroll");
    g_lvl[0] = 255u; g_lvl[1] = 128u; g_lvl[2] = 1u;
    oled_ui_poll(1, 1002u, 0u);
    CHECK(lane(2u, 0u) == 0xDEu && lane(3u, 0u) == 0x7Bu, "all bars at column 0");
    CHECK(lane(2u, 127u) == 0x1Eu && lane(3u, 127u) == 0x00u, "voice 1 reaches column 127 only");
    CHECK(lane(2u, 64u) == 0xDEu && lane(2u, 65u) == 0x1Eu, "voice 2 ends at column 65");
    CHECK(lane(3u, 0u) == 0x7Bu && lane(3u, 1u) == 0x03u, "voice 3 one column");
    g_lvl[0] = 0u; g_lvl[1] = 0u; g_lvl[2] = 0u;
    oled_ui_poll(1, 1003u, 0u);
    CHECK(lane(2u, 0u) == 0u && lane(3u, 0u) == 0u && lane(2u, 127u) == 0u, "bars fall back to 0");

    /* back to idle */
    g_drive = 1;
    oled_ui_poll(0, 2000u, 10u);
    CHECK(g_scroll[0] == 0u && g_scroll[1] == 0u && g_scroll[2] == 0u, "idle scrolls reset");
    CHECK(lane(0u, 0u) == oled_glyph_column(font_openroms_glyph(oled_ascii_to_screen('I')), 0u, 0), "idle title");
}

int main(int argc, char **argv)
{
    g_inject = (argc > 1 && strcmp(argv[1], "--inject-fail") == 0) ? 1 : 0;
    CHECK(oled_init() == 1 && (g_ctrl & 1u) == 1u, "init powers up");
    test_glyph();
    test_unaligned();
    test_double();
    test_marquee();
    test_bars();
    printf(g_fail ? "TEST FAIL\n" : "TEST PASS: oled_host\n");
    return g_fail ? 1 : 0;
}
