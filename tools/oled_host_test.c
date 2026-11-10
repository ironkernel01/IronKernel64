/*
 * File: oled_host_test.c
 * Role: host unit test of fw_c64/src/oled.c and oled_ui.c on a fake OLED register file.
 * Build/run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -DOLED_HOST_TEST -Ifw_c64/src -Icommon tools/oled_host_test.c \
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
static uint8_t  g_env;
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
static void f_levels(uint8_t l[BASIC_VOICES]) { l[0] = 0u; l[1] = 0u; l[2] = g_env; }
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

static void test_marquee(void)
{
    char text[OLED_UI_TEXT_MAX];
    uint32_t period;
    uint32_t len;
    char longs[40];

    len = oled_ui_marquee_text(text, "AB", "CD", "1985", &period);
    CHECK(strcmp(text, "AB - CD - 1985 - ") == 0 && len == 17u && period == 136u, "marquee short");
    memset(longs, 'X', 32);
    longs[32] = '\0';
    len = oled_ui_marquee_text(text, longs, longs, longs, &period);
    CHECK(len == 64u && period == 512u && strcmp(&text[61], " - ") == 0, "marquee truncated");
    len = oled_ui_marquee_text(text, longs, "Y", "", &period);   /* 32+3+1+3+0+3 = 42 */
    CHECK(len == 42u && period == 336u, "marquee 42");
    len = oled_ui_marquee_text(text, longs, longs, "", &period); /* 73 -> cut */
    CHECK(len == 64u && period == 512u, "marquee cut 73");
    len = oled_ui_marquee_text(text, longs, "YYYYYYYYYYYY", "", &period); /* 32+3+12+3+3 = 53 */
    CHECK(len == 64u && period == 512u && text[53] == ' ', "marquee padded");

    /* Playing: wrap of the scroll at the period (period 136, text "AB - CD - 1985 - "). */
    memset(g_fb, 0, sizeof(g_fb));
    g_ms = 0u;
    oled_ui_init(&g_ops, f_drive);
    oled_ui_poll(1, 100u, 0u);
    CHECK(g_scroll[0] == 0u, "scroll0 start");
    for (uint32_t f = 1u; f <= 136u; f++) {
        oled_ui_poll(1, 100u + f, 0u);
        CHECK(g_scroll[0] == (f % 136u), "scroll0 wraps at period");
    }
    /* seamless: virtual column i equals column i + period */
    for (uint32_t i = 0u; i + 136u < 512u; i++) {
        CHECK(lane(0u, i) == lane(0u, i + 136u), "marquee repeat");
    }
    CHECK(lane(0u, 0u) == oled_glyph_column(font_openroms_glyph(1u), 0u, 0), "marquee first glyph 'A'");
}

static void test_chart(void)
{
    uint8_t t;
    uint8_t b;

    CHECK(oled_ui_chart_height(0u) == 0u && oled_ui_chart_height(255u) == 16u &&
          oled_ui_chart_height(128u) == 8u, "chart height");
    oled_ui_chart_bytes(0u, &t, &b);
    CHECK(t == 0u && b == 0u, "bytes h0");
    oled_ui_chart_bytes(3u, &t, &b);
    CHECK(t == 0u && b == 0xE0u, "bytes h3");
    oled_ui_chart_bytes(8u, &t, &b);
    CHECK(t == 0u && b == 0xFFu, "bytes h8");
    oled_ui_chart_bytes(11u, &t, &b);
    CHECK(t == 0xE0u && b == 0xFFu, "bytes h11");
    oled_ui_chart_bytes(16u, &t, &b);
    CHECK(t == 0xFFu && b == 0xFFu, "bytes h16");

    /* Stepping: two idle-to-playing runs; the newest column sits at display column 127. */
    memset(g_fb, 0, sizeof(g_fb));
    oled_ui_init(&g_ops, f_drive);
    oled_ui_poll(0, 1000u, 0u);
    oled_ui_poll(1, 1001u, 0u);
    CHECK(g_scroll[2] == 384u && g_scroll[3] == 384u, "chart scroll initial");
    g_env = 255u;
    oled_ui_poll(1, 1002u, 0u);
    CHECK(lane(2u, 0u) == 0xFFu && lane(3u, 0u) == 0xFFu, "chart column 0 full");
    CHECK(g_scroll[2] == 385u, "scroll step");
    CHECK(((127u + g_scroll[2]) & 511u) == 0u, "newest column at x=127");
    g_env = 128u;
    for (uint32_t f = 1003u; f < 1003u + 520u; f++) {
        oled_ui_poll(1, f, 0u);
        CHECK(((127u + g_scroll[2]) & 511u) == ((f - 1002u) & 511u), "newest column tracks write column");
        CHECK(g_scroll[2] == g_scroll[3], "scroll2 == scroll3");
    }
    CHECK(lane(3u, 5u) == 0xFFu && lane(2u, 5u) == 0u, "chart h8");
    /* back to idle */
    g_drive = 1;
    oled_ui_poll(0, 2000u, 10u);
    CHECK(g_scroll[0] == 0u && g_scroll[2] == 0u, "idle scrolls reset");
    CHECK(lane(0u, 0u) == oled_glyph_column(font_openroms_glyph(oled_ascii_to_screen('I')), 0u, 0), "idle title");
}

int main(int argc, char **argv)
{
    g_inject = (argc > 1 && strcmp(argv[1], "--inject-fail") == 0) ? 1 : 0;
    CHECK(oled_init() == 1 && (g_ctrl & 1u) == 1u, "init powers up");
    test_glyph();
    test_unaligned();
    test_marquee();
    test_chart();
    printf(g_fail ? "TEST FAIL\n" : "TEST PASS: oled_host\n");
    return g_fail ? 1 : 0;
}
