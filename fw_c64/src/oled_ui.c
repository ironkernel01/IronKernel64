/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: oled_ui.c
 * Role: OLED idle and now-playing screens (contract: oled_ui.h).
 */
#include "oled_ui.h"

#include <stddef.h>

#include "oled.h"

#define UI_PAGE_TITLE        (0u)
#define UI_PAGE_INFO         (1u)
#define UI_PAGE_CHART_TOP    (2u)
#define UI_PAGE_CHART_BOT    (3u)
#define UI_SEP               " - "
#define UI_SEP_CHARS         (3u)
#define UI_ONE_LINE_CHARS    (OLED_TEXT_CHARS)                       /* 64 */
#define UI_REPEAT_MAX_CHARS  ((OLED_VCOLS - OLED_WIDTH) / OLED_GLYPH_COLS)  /* 48 */
#define UI_INFO_PAD_CHARS    (20u)
#define UI_MS_PER_S          (1000u)
#define UI_S_PER_MIN         (60u)
#define UI_ENV_MAX           (255u)
#define UI_VOICE3            (2u)
#define UI_HALF_PIXELS       (8u)

typedef enum
{
    UI_UNINIT = 0,
    UI_IDLE,
    UI_PLAYING
} ui_mode_t;

static const basic_player_ops_t *g_player;
static int      (*g_drive_ready)(void);
static ui_mode_t g_mode = UI_UNINIT;
static uint32_t g_last_frame;
static int      g_have_frame;

static int      g_drive_known;       /* g_drive_ok is valid */
static int      g_drive_ok;
static uint32_t g_drive_next_ms;     /* earliest next ping */

static uint32_t g_period;            /* marquee period in columns */
static uint32_t g_mq_off;
static uint32_t g_chart_wc;          /* next chart write column */
static uint32_t g_secs = 0xFFFFFFFFu;
static uint32_t g_song_shown = 0xFFFFFFFFu;

/*
 * ui_copy -- append a string to a buffer (bounded).
 * Returns: the new length.
 */
static uint32_t ui_copy(char *out, uint32_t len, uint32_t cap, const char *s)
{
    while (*s != '\0' && (len + 1u) < cap) {
        out[len++] = *s++;
    }
    out[len] = '\0';
    return len;
}

/*
 * ui_number -- append a decimal number with at least min_digits digits.
 * Returns: the new length.
 */
static uint32_t ui_number(char *out, uint32_t len, uint32_t v, uint32_t min_digits)
{
    char tmp[10];
    uint32_t n = 0u;

    do {
        tmp[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v != 0u && n < sizeof(tmp));
    while (n < min_digits && n < sizeof(tmp)) {
        tmp[n++] = '0';
    }
    while (n > 0u) {
        out[len++] = tmp[--n];
    }
    out[len] = '\0';
    return len;
}

/*
 * oled_ui_marquee_text -- "<NAME> - <AUTHOR> - <RELEASED> - " fitted to one virtual line.
 * Steps: build the text; above 64 characters cut to 61 and add " - "; 49..64 characters are
 *   padded with spaces to 64 (period 512); up to 48 repeat with period 8 * length.
 * Returns: the text length in characters; *period_cols = scroll period in columns.
 */
uint32_t oled_ui_marquee_text(char *out, const char *name, const char *author, const char *released,
                              uint32_t *period_cols)
{
    uint32_t len = 0u;

    out[0] = '\0';
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, name);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, author);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, released);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    if (len > UI_ONE_LINE_CHARS) {
        len = UI_ONE_LINE_CHARS - UI_SEP_CHARS;
        out[len] = '\0';
        len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    }
    if (len > UI_REPEAT_MAX_CHARS) {
        while (len < UI_ONE_LINE_CHARS) {
            out[len++] = ' ';
        }
        out[len] = '\0';
    }
    *period_cols = len * OLED_GLYPH_COLS;
    return len;
}

/*
 * oled_ui_chart_height -- envelope 0..255 to bar height 0..16 pixels (rounded).
 * Returns: the height.
 */
uint32_t oled_ui_chart_height(uint8_t env)
{
    return (((uint32_t)env * OLED_UI_CHART_PIXELS) + (UI_ENV_MAX / 2u)) / UI_ENV_MAX;
}

/*
 * oled_ui_chart_bytes -- page bytes of a bar of height pixels, filled from the bottom.
 * Page 3 holds rows 8..15 (bit 7 = bottom pixel), page 2 rows 0..7.
 * Returns: nothing.
 */
void oled_ui_chart_bytes(uint32_t height, uint8_t *top, uint8_t *bottom)
{
    const uint32_t nb = (height > UI_HALF_PIXELS) ? UI_HALF_PIXELS : height;
    const uint32_t nt = (height > UI_HALF_PIXELS) ? (height - UI_HALF_PIXELS) : 0u;

    *bottom = (uint8_t)((0xFFu << (UI_HALF_PIXELS - nb)) & 0xFFu);
    *top = (uint8_t)((0xFFu << (UI_HALF_PIXELS - nt)) & 0xFFu);
}

/*
 * ui_line -- clear a page and draw a text from column 0.
 * Returns: nothing.
 */
static void ui_line(uint32_t page, const char *text)
{
    for (uint32_t c = 0u; c < OLED_VCOLS; c++) {
        oled_put_column(page, c, 0u);
    }
    (void)oled_put_text(page, 0u, text, 0);
}

/*
 * ui_draw_drive -- idle page 2.
 * Returns: nothing.
 */
static void ui_draw_drive(void)
{
    ui_line(UI_PAGE_CHART_TOP, g_drive_ok ? "DRIVE 8: PRESENT" : "DRIVE 8: NOT READY");
}

/*
 * ui_enter_idle -- idle screen.
 * Returns: nothing.
 */
static void ui_enter_idle(uint32_t now_ms)
{
    oled_clear();
    for (uint32_t p = 0u; p < OLED_PAGES; p++) {
        oled_set_scroll(p, 0u);
    }
    (void)oled_put_text(UI_PAGE_TITLE, 0u, "IRONKERNEL 64", 0);
    (void)oled_put_text(UI_PAGE_INFO, 0u, "BASIC V2 READY", 0);
    g_drive_known = 0;
    g_drive_next_ms = now_ms;
    g_mode = UI_IDLE;
}

/*
 * ui_idle_poll -- refresh the drive line from a cached ping (at most every OLED_UI_PING_MS).
 * Returns: nothing.
 */
static void ui_idle_poll(uint32_t now_ms)
{
    if (g_drive_ready != NULL && (!g_drive_known || (int32_t)(now_ms - g_drive_next_ms) >= 0)) {
        const int ok = (g_drive_ready() != 0) ? 1 : 0;

        g_drive_next_ms = now_ms + OLED_UI_PING_MS;
        if (!g_drive_known || ok != g_drive_ok) {
            g_drive_ok = ok;
            g_drive_known = 1;
            ui_draw_drive();
        }
    }
}

/*
 * ui_draw_info -- "SONG nn/mm  mm:ss" on page 1.
 * Returns: nothing.
 */
static void ui_draw_info(uint32_t song, uint32_t songs, uint32_t secs)
{
    char buf[40];
    uint32_t n = ui_copy(buf, 0u, sizeof(buf), "SONG ");

    n = ui_number(buf, n, song, 2u);
    buf[n++] = '/';
    n = ui_number(buf, n, songs, 2u);
    n = ui_copy(buf, n, sizeof(buf), "  ");
    n = ui_number(buf, n, secs / UI_S_PER_MIN, 2u);
    buf[n++] = ':';
    n = ui_number(buf, n, secs % UI_S_PER_MIN, 2u);
    while (n < UI_INFO_PAD_CHARS && (n + 1u) < sizeof(buf)) {
        buf[n++] = ' ';
    }
    buf[n] = '\0';
    (void)oled_put_text(UI_PAGE_INFO, 0u, buf, 0);
}

/*
 * ui_chart_scroll -- SCROLL2/3 so that column (wc) shows at display column 127.
 * Returns: nothing.
 */
static void ui_chart_scroll(uint32_t wc)
{
    const uint32_t off = (wc + OLED_VCOLS + 1u - OLED_WIDTH) % OLED_VCOLS;

    oled_set_scroll(UI_PAGE_CHART_TOP, off);
    oled_set_scroll(UI_PAGE_CHART_BOT, off);
}

/*
 * ui_enter_playing -- now-playing screen: marquee, song line, empty chart.
 * Returns: nothing.
 */
static void ui_enter_playing(void)
{
    basic_tune_info_t info;
    char text[OLED_UI_TEXT_MAX];
    uint32_t secs = g_player->elapsed_ms() / UI_MS_PER_S;

    g_player->info(&info);
    (void)oled_ui_marquee_text(text, info.name, info.author, info.released, &g_period);
    oled_clear();
    for (uint32_t base = 0u; base < OLED_VCOLS; base += g_period) {
        (void)oled_put_text(UI_PAGE_TITLE, base, text, 0);
    }
    g_mq_off = 0u;
    oled_set_scroll(UI_PAGE_TITLE, 0u);
    oled_set_scroll(UI_PAGE_INFO, 0u);
    g_chart_wc = 0u;
    ui_chart_scroll(g_chart_wc - 1u + OLED_VCOLS);
    ui_draw_info(info.start_song, info.songs, secs);
    g_secs = secs;
    g_song_shown = info.start_song;
    g_mode = UI_PLAYING;
}

/*
 * ui_playing_frame -- one vsync frame: marquee step and one chart column.
 * Returns: nothing.
 */
static void ui_playing_frame(void)
{
    uint8_t level[BASIC_VOICES] = { 0u, 0u, 0u };
    uint8_t top;
    uint8_t bottom;

    g_mq_off = (g_mq_off + 1u) % g_period;
    oled_set_scroll(UI_PAGE_TITLE, g_mq_off);

    g_player->voice_levels(level);
    oled_ui_chart_bytes(oled_ui_chart_height(level[UI_VOICE3]), &top, &bottom);
    oled_put_column(UI_PAGE_CHART_TOP, g_chart_wc, top);
    oled_put_column(UI_PAGE_CHART_BOT, g_chart_wc, bottom);
    ui_chart_scroll(g_chart_wc);
    g_chart_wc = (g_chart_wc + 1u) % OLED_VCOLS;
}

/*
 * oled_ui_init -- remember the player and the drive probe.
 * Returns: nothing.
 */
void oled_ui_init(const basic_player_ops_t *player, int (*drive_ready)(void))
{
    g_player = player;
    g_drive_ready = drive_ready;
    g_mode = UI_UNINIT;
    g_have_frame = 0;
}

/*
 * oled_ui_poll -- switch screens on the playing flag; per frame update when playing; idle
 *   drive refresh otherwise.
 * Returns: nothing.
 */
void oled_ui_poll(int playing, uint32_t frame, uint32_t now_ms)
{
    uint32_t steps = 0u;

    if (!oled_present() || g_player == NULL) {
        return;
    }
    if (g_have_frame) {
        steps = frame - g_last_frame;
        if (steps > OLED_UI_MAX_CATCHUP) {
            steps = OLED_UI_MAX_CATCHUP;
        }
    }
    g_last_frame = frame;
    g_have_frame = 1;

    if (playing && g_mode != UI_PLAYING) {
        ui_enter_playing();
        return;
    }
    if (!playing && g_mode != UI_IDLE) {
        ui_enter_idle(now_ms);
    }
    if (g_mode == UI_IDLE) {
        ui_idle_poll(now_ms);
        return;
    }
    for (uint32_t i = 0u; i < steps; i++) {
        ui_playing_frame();
    }
    {
        const uint32_t secs = g_player->elapsed_ms() / UI_MS_PER_S;

        if (secs != g_secs) {
            basic_tune_info_t info;

            g_secs = secs;
            g_player->info(&info);   /* song number follows select_song, which restarts the time */
            g_song_shown = info.start_song;
            ui_draw_info(info.start_song, info.songs, secs);
        }
    }
}
