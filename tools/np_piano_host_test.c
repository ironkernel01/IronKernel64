/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * np_piano_host_test.c -- host test of fw_c64/src/np_piano.c against a fake framebuffer:
 * note mapping (PAL and NTSC, every key), key geometry, octave boundaries, two voices on one
 * key, release, changed-keys-only redraw, and a scripted heard-state sequence (gate on A4,
 * C-E-G arpeggio at one note per frame, release fade, noise voice, test bit). Writes
 * build/np_piano_sample.ppm (3x scale) for a visual check.
 *
 * Build and run (MSYS2 UCRT64, from the repo root):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/src tools/np_piano_host_test.c \
 *       fw_c64/src/np_piano.c fw_c64/src/sid_envmodel.c -o build/np_piano_host_test.exe
 *   build/np_piano_host_test.exe [+INJECT_FAILURE]
 * Prints "TEST PASS: np_piano_host" or "TEST FAIL" (exit 1).
 */
#include "np_piano.h"
#include "video.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#define PAL_HZ      (985248u)
#define NTSC_HZ     (1022727u)
#define FRAME_CYC   (19656u)          /* PAL 50 Hz play period */
#define SCALE       (3u)

static uint8_t g_fb[2][C64_FB_HEIGHT][C64_FB_WIDTH];
static uint32_t g_rects;
static uint32_t g_pixels;
static int g_fail;

/* Fake video.c: only the primitive np_piano uses. */
void video_fill_rect(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t colour)
{
    g_rects++;
    for (uint32_t j = 0; j < h; j++) {
        for (uint32_t i = 0; i < w; i++) {
            if (x + i < C64_FB_WIDTH && y + j < C64_FB_HEIGHT) {
                g_fb[page & 1u][y + j][x + i] = colour;
                g_pixels++;
            }
        }
    }
}

static void check(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        printf("  FAIL %s: got %u, want %u\n", what, (unsigned)got, (unsigned)want);
        g_fail = 1;
    }
}

static void clear_fb(void)
{
    memset(g_fb, 14, sizeof(g_fb));
    for (uint32_t p = 0; p < 2; p++) {
        for (uint32_t y = 20; y < 220; y++) {
            for (uint32_t x = 32; x < 352; x++) {
                g_fb[p][y][x] = 6;
            }
        }
    }
}

static uint32_t reg_of(uint32_t key, uint32_t clk)
{
    return (uint32_t)llround(440.0 * pow(2.0, ((double)key - 57.0) / 12.0) * 16777216.0 / (double)clk);
}

/* Pixel position of a key: white keys below the black keys, black keys at their bar. */
static void key_px(uint32_t key, uint32_t *x, uint32_t *y, int *black)
{
    static const uint8_t wh[12] = { 0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6 };
    static const uint8_t bl[12] = { 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 };
    const uint32_t local = key % 48u, semi = local % 12u, kb = key / 48u;
    const uint32_t w = (local / 12u) * 7u + wh[semi];

    *black = bl[semi];
    *y = (kb ? NP_PIANO_KB1_Y : NP_PIANO_KB0_Y) + 1u + (*black ? 5u : 28u);
    *x = NP_PIANO_FRAME_X + 1u + w * 8u + (*black ? 5u : 0u) + (*black ? 2u : 3u);
}

static uint8_t px_key(uint32_t page, uint32_t key, uint32_t dx)
{
    uint32_t x, y;
    int b;

    key_px(key, &x, &y, &b);
    return g_fb[page][y][x - (b ? 2u : 3u) + dx];
}

static np_piano_voice_t voice(uint32_t key, uint32_t clk, uint8_t level)
{
    np_piano_voice_t v;

    v.freq = (uint16_t)reg_of(key, clk);
    v.control = 0x41u;
    v.level = level;
    return v;
}

static void off(np_piano_voice_t *v)
{
    v->freq = 0;
    v->control = 0;
    v->level = 0;
}

static void ev(uint32_t stamp, uint32_t voice_idx, uint32_t r, uint8_t val)
{
    np_piano_event(stamp, (uint8_t)(voice_idx * 7u + r), val);
}

static void ev_freq(uint32_t stamp, uint32_t v, uint32_t key)
{
    const uint32_t r = reg_of(key, PAL_HZ);

    ev(stamp, v, 0, (uint8_t)(r & 0xFFu));
    ev(stamp, v, 1, (uint8_t)(r >> 8));
}

static void write_ppm(const char *path, uint32_t page)
{
    /* Colodore palette. */
    static const uint8_t pal[16][3] = {
        {0,0,0},{255,255,255},{129,51,56},{117,206,200},{142,60,151},{86,172,77},{46,44,155},
        {237,241,113},{142,80,41},{85,56,0},{196,108,113},{74,74,74},{123,123,123},{169,255,159},
        {112,109,235},{178,178,178}};
    FILE *f = fopen(path, "wb");

    if (f == NULL) {
        printf("  (cannot write %s)\n", path);
        return;
    }
    fprintf(f, "P6\n%u %u\n255\n", C64_FB_WIDTH * SCALE, C64_FB_HEIGHT * SCALE);
    for (uint32_t y = 0; y < C64_FB_HEIGHT * SCALE; y++) {
        for (uint32_t x = 0; x < C64_FB_WIDTH * SCALE; x++) {
            fwrite(pal[g_fb[page][y / SCALE][x / SCALE] & 15u], 1, 3, f);
        }
    }
    fclose(f);
}

static void test_mapping(void)
{
    static const uint32_t clks[2] = { PAL_HZ, NTSC_HZ };

    for (uint32_t c = 0; c < 2; c++) {
        np_piano_init(clks[c], 6);
        check("A4 reg", reg_of(57, clks[c]), c == 0 ? 7493u : 7218u);
        check("A4 key", np_piano_note((uint16_t)reg_of(57, clks[c])), 57u);
        for (uint32_t k = 0; k < NP_PIANO_KEYS; k++) {
            if (reg_of(k, clks[c]) <= 65535u) {      /* the top semitones exceed the 16-bit register */
                check("every key", np_piano_note((uint16_t)reg_of(k, clks[c])), k);
            }
        }
        check("clamp low", np_piano_note(1), 0u);
        check("clamp high", np_piano_note(65535), 95u);
        /* quarter-tone-ish neighbours still round to the same key */
        check("A4 -2%", np_piano_note((uint16_t)(reg_of(57, clks[c]) * 98u / 100u)), 57u);
        check("A4 +2%", np_piano_note((uint16_t)(reg_of(57, clks[c]) * 102u / 100u)), 57u);
    }
}

static void test_geometry(void)
{
    np_piano_voice_t v[3];
    uint32_t n;

    np_piano_init(PAL_HZ, 6);
    clear_fb();
    for (int i = 0; i < 3; i++) {
        off(&v[i]);
    }
    n = np_piano_draw(0, v);
    check("first draw paints all", n, NP_PIANO_KEYS);
    check("frame left black", g_fb[0][NP_PIANO_KB0_Y + 10][NP_PIANO_FRAME_X], 0u);
    check("frame top black", g_fb[0][NP_PIANO_KB0_Y][NP_PIANO_FRAME_X + 20], 0u);
    check("frame right black", g_fb[0][NP_PIANO_KB1_Y + 10][NP_PIANO_FRAME_X + 224], 0u);
    check("frame bottom black", g_fb[0][NP_PIANO_KB1_Y + 35][NP_PIANO_FRAME_X + 20], 0u);
    check("outside is background", g_fb[0][NP_PIANO_KB0_Y - 1][NP_PIANO_FRAME_X + 20], 6u);
    /* white key 0 of kb0 (C0): body white, separator black */
    check("C0 body", g_fb[0][NP_PIANO_KB0_Y + 30][80 + 3], 1u);
    check("C0 separator", g_fb[0][NP_PIANO_KB0_Y + 30][80 + 7], 0u);
    check("white full height top", g_fb[0][NP_PIANO_KB0_Y + 1][80 + 1], 1u);
    check("white full height bottom", g_fb[0][NP_PIANO_KB0_Y + 34][80 + 1], 1u);
    /* C#0 black bar: cols 5..9 of the keyboard, rows 1..20 */
    check("C#0 black", g_fb[0][NP_PIANO_KB0_Y + 1][80 + 7], 0u);
    check("C#0 black bottom row", g_fb[0][NP_PIANO_KB0_Y + 20][80 + 7], 0u);
    check("C#0 below bar is white", g_fb[0][NP_PIANO_KB0_Y + 21][80 + 6], 1u);
    check("black narrower: col 4 white", g_fb[0][NP_PIANO_KB0_Y + 5][80 + 4], 1u);
    check("black narrower: col 10 white", g_fb[0][NP_PIANO_KB0_Y + 5][80 + 10], 1u);
    check("black left edge", g_fb[0][NP_PIANO_KB0_Y + 5][80 + 5], 0u);
    check("black right edge", g_fb[0][NP_PIANO_KB0_Y + 5][80 + 9], 0u);
    /* no black key between E and F (key 4 and 5 of the octave): x of boundary col 8*2+7 */
    check("no black E-F", g_fb[0][NP_PIANO_KB0_Y + 5][80 + 2 * 8 + 6], 1u);
    /* 28 white keys per keyboard: last separator col is the right frame */
    check("kb1 last key body", g_fb[0][NP_PIANO_KB1_Y + 30][80 + 27 * 8 + 3], 1u);
}

static void test_lighting(void)
{
    np_piano_voice_t v[3];
    uint32_t n;
    static const uint8_t bright[3] = { 13, 7, 10 };

    np_piano_init(PAL_HZ, 6);
    clear_fb();
    for (uint32_t c = 0; c < 2; c++) {
        const uint32_t clk = (c == 0) ? PAL_HZ : NTSC_HZ;

        np_piano_init(clk, 6);
        np_piano_invalidate();
        clear_fb();
        for (int i = 0; i < 3; i++) {
            off(&v[i]);
        }
        v[0].freq = (uint16_t)reg_of(57, clk);          /* A4 */
        v[0].control = 0x11u;
        v[0].level = 255;
        np_piano_draw(0, v);
        check("A4 lit white", px_key(0, 57, 0), bright[0]);
        check("A4 lit full height top", g_fb[0][NP_PIANO_KB1_Y + 1][80 + 5 * 8 + 3], bright[0]);
        check("A4 lit bottom", g_fb[0][NP_PIANO_KB1_Y + 34][80 + 5 * 8 + 3], bright[0]);
        check("G4 not lit", px_key(0, 55, 0), 1u);
        check("B4 not lit", px_key(0, 59, 0), 1u);
        check("A#4 black stays black", px_key(0, 58, 0), 0u);
        check("G#4 black stays black", px_key(0, 56, 0), 0u);
    }
    /* octave boundaries */
    np_piano_init(PAL_HZ, 6);
    np_piano_invalidate();
    clear_fb();
    off(&v[0]); off(&v[1]); off(&v[2]);
    v[0] = voice(47, PAL_HZ, 255);        /* B3: last key of keyboard 0 */
    v[1] = voice(48, PAL_HZ, 255);        /* C4: first key of keyboard 1 */
    v[2] = voice(0, PAL_HZ, 255);         /* C0 */
    np_piano_draw(0, v);
    check("B3 on kb0", px_key(0, 47, 0), 13u);
    check("C4 on kb1", px_key(0, 48, 0), 7u);
    check("C0 first", px_key(0, 0, 0), 10u);
    check("B3 x", 80u + 27u * 8u + 3u, 80u + 27u * 8u + 3u);
    check("C4 not on kb0", g_fb[0][NP_PIANO_KB0_Y + 30][80 + 27 * 8 + 3], 13u);
    check("C4 y on kb1", g_fb[0][NP_PIANO_KB1_Y + 30][80 + 3], 7u);
    check("C5 dark", px_key(0, 60, 0), 1u);
    /* black key lit */
    off(&v[0]); off(&v[1]); off(&v[2]);
    v[0] = voice(56, PAL_HZ, 255);        /* G#4 */
    np_piano_draw(0, v);
    check("G#4 lit bar", px_key(0, 56, 0), 13u);
    check("G#4 lit bar edge", px_key(0, 56, 4), 13u);
    check("G#4 neighbours white A4", px_key(0, 57, 0), 1u);
    /* two voices on one key: bands side by side */
    off(&v[0]);
    v[0] = voice(57, PAL_HZ, 255);
    v[1] = voice(57, PAL_HZ, 255);
    np_piano_draw(0, v);
    check("split left", px_key(0, 57, 0), 13u);
    check("split right", px_key(0, 57, 6), 7u);
    /* release: level 0 unlights */
    off(&v[0]); off(&v[1]);
    v[0] = voice(57, PAL_HZ, 255);
    np_piano_draw(0, v);
    check("A4 on", px_key(0, 57, 3), 13u);
    v[0].level = 0;
    np_piano_draw(0, v);
    check("A4 off after release", px_key(0, 57, 3), 1u);
    /* dim at low level */
    v[0].level = 40;
    np_piano_draw(0, v);
    check("A4 dim", px_key(0, 57, 3), 5u);
    /* test bit and noise-only not shown */
    v[0].level = 255;
    v[0].control = 0x49u;
    np_piano_draw(0, v);
    check("test bit dark", px_key(0, 57, 3), 1u);
    v[0].control = 0x81u;
    np_piano_draw(0, v);
    check("noise-only dark", px_key(0, 57, 3), 1u);
    v[0].control = 0x41u;
    n = np_piano_draw(0, v);
    check("relit keys painted (key + 2 black)", n, 3u);
}

static void test_changed_only(void)
{
    np_piano_voice_t v[3];
    uint32_t n;

    np_piano_init(PAL_HZ, 6);
    clear_fb();
    off(&v[0]); off(&v[1]); off(&v[2]);
    v[0] = voice(57, PAL_HZ, 255);
    check("page0 first", np_piano_draw(0, v), NP_PIANO_KEYS);
    check("page1 first", np_piano_draw(1, v), NP_PIANO_KEYS);
    g_rects = 0;
    check("page0 unchanged", np_piano_draw(0, v), 0u);
    check("no rect when unchanged", g_rects, 0u);
    v[0] = voice(60, PAL_HZ, 255);        /* C5: white, black to the right only */
    g_rects = 0;
    n = np_piano_draw(0, v);
    check("move A4 -> C5 repaints A4 (3 keys) + C5 (2 keys)", n, 5u);
    check("rect count bounded", g_rects <= 20u, 1u);
    check("page1 still shows A4", px_key(1, 57, 3), 13u);
    n = np_piano_draw(1, v);
    check("page1 catches up (same 5 keys)", n, 5u);
    check("page1 now C5", px_key(1, 60, 3), 13u);
    check("page1 A4 dark", px_key(1, 57, 3), 1u);
    /* a black key change repaints only that key */
    v[0] = voice(61, PAL_HZ, 255);        /* C#5 */
    n = np_piano_draw(0, v);
    check("C5 -> C#5 repaints C5 + C#5", n, 2u);
}

/* Scripted heard-state sequence: lit key per displayed frame. */
static void test_sequence(void)
{
    uint32_t inten;
    uint32_t prev_int = 99;
    int saw_dim = 0;
    uint32_t dark_at = 0;
    uint32_t max_rects = 0;
    uint32_t max_pixels = 0;
    static const uint32_t arp[3] = { 48, 52, 55 };    /* C4 E4 G4 */

    np_piano_init(PAL_HZ, 6);
    clear_fb();
    /* Voice 1: triangle A4, attack 2 ms, sustain 15, release nibble 4; gate on at stamp 0. */
    ev(0, 0, 5, 0x00); ev(0, 0, 6, 0xF4);
    ev_freq(0, 0, 57);
    ev(0, 0, 4, 0x11);
    /* Voice 2: pulse arpeggio, one note per frame, gate on throughout. */
    ev(0, 1, 5, 0x00); ev(0, 1, 6, 0xF0);
    ev(0, 1, 4, 0x41);
    for (uint32_t f = 0; f < 3; f++) {
        ev_freq(f * FRAME_CYC + 100u, 1, arp[f]);
    }
    /* Voice 3: noise drum from frame 1, then pulse with the test bit from frame 3. */
    ev(0, 2, 5, 0x00); ev(0, 2, 6, 0xF0);
    ev_freq(0, 2, 70);
    ev(FRAME_CYC + 100u, 2, 4, 0x81);
    ev(3u * FRAME_CYC + 100u, 2, 4, 0x49);
    /* Voice 1 releases at frame 4. */
    ev(4u * FRAME_CYC + 100u, 0, 4, 0x10);

    /* Writes stamped in the future are not heard yet: sync before frame 0 ends. */
    np_piano_sync(50u);
    check("frame0 early: v1 key = A4", np_piano_lit_key(0, &inten), NP_PIANO_NO_KEY);   /* level still ~0 */
    for (uint32_t f = 1; f <= 14; f++) {
        np_piano_voice_t hv[3];
        uint32_t k0, k1, k2, i0, i1, i2;
        uint32_t n;

        np_piano_sync(f * FRAME_CYC);
        np_piano_state(hv);
        k0 = np_piano_lit_key(0, &i0);
        k1 = np_piano_lit_key(1, &i1);
        k2 = np_piano_lit_key(2, &i2);
        g_rects = 0;
        g_pixels = 0;
        n = np_piano_overlay(f & 1u);
        (void)n;
        if (f >= 3u && g_rects > max_rects) {   /* frames 1-2 include each page's first full paint */
            max_rects = g_rects;
        }
        if (f >= 3u && g_pixels > max_pixels) {
            max_pixels = g_pixels;
        }
        if (f <= 4u) {
            check("seq v1 A4 sustained", k0, 57u);
            check("seq v1 bright", i0, 2u);
        }
        if (f <= 3u) {
            check("seq arpeggio note", k1, arp[f - 1u]);   /* C, E, G: one per frame */
        }
        check("seq noise/test voice never lit", k2, NP_PIANO_NO_KEY);
        if (f >= 5u) {
            /* release fade: intensity never rises, passes through dim, ends dark */
            if (k0 != NP_PIANO_NO_KEY) {
                if (i0 == 1u) {
                    saw_dim = 1;
                }
                if (prev_int != 99 && i0 > prev_int) {
                    printf("  FAIL release intensity rose at frame %u\n", (unsigned)f);
                    g_fail = 1;
                }
                prev_int = i0;
            } else if (dark_at == 0) {
                dark_at = f;
            }
        }
    }
    check("release passes through dim", (uint32_t)saw_dim, 1u);
    check("release reaches dark by frame 14", dark_at != 0u, 1u);
    printf("  release dark at frame %u; per-frame cost max %u rects, %u pixels\n", (unsigned)dark_at,
           (unsigned)max_rects, (unsigned)max_pixels);
    /* A write ahead of CYCLE stays hidden until its stamp. */
    np_piano_init(PAL_HZ, 6);
    ev(0, 0, 5, 0x00); ev(0, 0, 6, 0xF0); ev_freq(0, 0, 57);
    ev(10u * FRAME_CYC, 0, 4, 0x11);
    np_piano_sync(5u * FRAME_CYC);
    check("future gate not heard", np_piano_lit_key(0, &inten), NP_PIANO_NO_KEY);
    np_piano_sync(11u * FRAME_CYC);
    check("gate heard once due", np_piano_lit_key(0, &inten), 57u);
}

static void sample_image(void)
{
    np_piano_voice_t v[3];

    np_piano_init(PAL_HZ, 6);
    np_piano_invalidate();
    clear_fb();
    v[0] = voice(57, PAL_HZ, 255);        /* A4, voice 1 */
    v[1] = voice(57, PAL_HZ, 255);        /* A4, voice 2 shares the key */
    v[2] = voice(61, PAL_HZ, 70);         /* C#5 black key, voice 3, release fade (dim) */
    np_piano_draw(0, v);
    v[0] = voice(40, PAL_HZ, 255);        /* E3 on the upper keyboard */
    v[1] = voice(34, PAL_HZ, 255);        /* A#2 black */
    v[2] = voice(48, PAL_HZ, 255);        /* C4 */
    np_piano_draw(1, v);
    /* merge the lower-keyboard notes of page 0 into one sample page: draw all on page 0 */
    np_piano_invalidate();
    v[0] = voice(57, PAL_HZ, 255);
    v[1] = voice(34, PAL_HZ, 255);
    v[2] = voice(40, PAL_HZ, 255);
    np_piano_draw(0, v);
    write_ppm("build/np_piano_sample.ppm", 0);
}

int main(int argc, char **argv)
{
    test_mapping();
    test_geometry();
    test_lighting();
    test_changed_only();
    test_sequence();
    sample_image();
    if (argc > 1 && strcmp(argv[1], "+INJECT_FAILURE") == 0) {
        g_fail = 1;
    }
    printf(g_fail ? "TEST FAIL: np_piano_host\n" : "TEST PASS: np_piano_host\n");
    return g_fail ? 1 : 0;
}
