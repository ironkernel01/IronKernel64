/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: oled_ui.c
 * Role: OLED idle and now-playing screens (contract: oled_ui.h).
 */
#include "oled_ui.h"

#include <stddef.h>
#include <string.h>   /* memcpy, strcmp */

#include "font_openroms.h"
#include "oled.h"

#define UI_PAGE_MQ_TOP       (0u)    /* double-height marquee: upper half */
#define UI_PAGE_MQ_BOT       (1u)    /* lower half */
#define UI_PAGE_BAR_TOP      (2u)    /* voice bars, pixel rows 0..7 of the 16 */
#define UI_PAGE_BAR_BOT      (3u)    /* rows 8..15 */
#define UI_PAGE_TITLE        (0u)    /* idle screen */
#define UI_PAGE_INFO         (1u)
#define UI_PAGE_DRIVE        (2u)
#define UI_SEP               "  *  "
#define UI_MQ_AHEAD          (256u)  /* columns kept drawn from the scroll offset (window is 128) */
#define UI_MS_PER_S          (1000u)
#define UI_S_PER_MIN         (60u)
#define UI_TIME_MAX_S        ((99u * 60u) + 59u)
#define UI_LEVEL_MAX         (255u)
#define UI_HALF_PIXELS       (8u)
#define UI_BAR_ROWS          (4u)    /* pixel rows per bar */
#define UI_BAR_STRIDE        (5u)    /* bar pitch: 4 rows + 1 gap */
#define UI_BAR_FIRST_ROW     (1u)
#define UI_FIELDS            (3u)    /* name, author, released */
#define UI_TAIL_CHARS        (40u)   /* room kept for "SONG nn/mm  *  TIME mm:ss  *  " */

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

static char     g_text[OLED_UI_TEXT_MAX];   /* marquee text of the playing screen */
static uint32_t g_text_len;
static uint32_t g_s0;                /* text column (mod 8 * length) at the scroll offset */
static uint32_t g_mq_off;            /* marquee scroll register value (ring position, mod 512) */
static uint32_t g_bar_len[BASIC_VOICES];   /* bar lengths drawn */
static uint32_t g_secs = 0xFFFFFFFFu;
static uint32_t g_song_shown = 0xFFFFFFFFu;
static basic_tune_info_t g_tune_shown;   /* header texts the marquee was built from */

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
 * oled_ui_marquee_text -- "<NAME>  *  <AUTHOR>  *  <RELEASED>  *  SONG nn/mm  *  TIME mm:ss  *  ".
 * Steps: empty name/author/released fields are left out; the three fields are limited to what
 *   leaves UI_TAIL_CHARS for the rest (never reached with 32-character fields); song and total
 *   use at least 2 digits, minutes are limited to 99 (the length stays the same while the time
 *   counts); the text ends with the separator so the endless scroll joins its end to its start.
 * Returns: the text length in characters.
 */
uint32_t oled_ui_marquee_text(char *out, const char *name, const char *author, const char *released,
                              uint32_t song, uint32_t songs, uint32_t secs)
{
    const char *const field[UI_FIELDS] = { name, author, released };
    uint32_t len = 0u;

    out[0] = '\0';
    for (uint32_t i = 0u; i < UI_FIELDS; i++) {
        if (field[i] != NULL && field[i][0] != '\0' &&
            (len + strlen(field[i]) + UI_TAIL_CHARS) < OLED_UI_TEXT_MAX) {
            len = ui_copy(out, len, OLED_UI_TEXT_MAX, field[i]);
            len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
        }
    }
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, "SONG ");
    len = ui_number(out, len, song, 2u);
    out[len++] = '/';
    len = ui_number(out, len, songs, 2u);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    if (secs > UI_TIME_MAX_S) {
        secs = UI_TIME_MAX_S;
    }
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, "TIME ");
    len = ui_number(out, len, secs / UI_S_PER_MIN, 2u);
    out[len++] = ':';
    len = ui_number(out, len, secs % UI_S_PER_MIN, 2u);
    len = ui_copy(out, len, OLED_UI_TEXT_MAX, UI_SEP);
    return len;
}

/*
 * oled_ui_double_column -- double a glyph column vertically.
 * Steps: bit r of the 8-row column fills rows 2r and 2r+1 of the 16-row result; rows 0..7 go to
 *   the upper page, rows 8..15 to the lower page.
 * Returns: nothing.
 */
void oled_ui_double_column(uint8_t col, uint8_t *top, uint8_t *bottom)
{
    uint32_t t = 0u;
    uint32_t b = 0u;
    const uint32_t half = UI_HALF_PIXELS / 2u;

    for (uint32_t r = 0u; r < half; r++) {
        if ((col & (1u << r)) != 0u) {
            t |= 3u << (2u * r);
        }
        if ((col & (1u << (r + half))) != 0u) {
            b |= 3u << (2u * r);
        }
    }
    *top = (uint8_t)t;
    *bottom = (uint8_t)b;
}

/*
 * oled_ui_bar_len -- level 0..255 to a bar length 0..128 columns (rounded up, so any
 *   level above 0 shows).
 * Returns: the length.
 */
uint32_t oled_ui_bar_len(uint8_t level)
{
    return (((uint32_t)level * OLED_WIDTH) + (UI_LEVEL_MAX - 1u)) / UI_LEVEL_MAX;
}

/*
 * oled_ui_bar_bytes -- page bytes of display column col of the three bars.
 * Steps: bar v covers pixel rows 1 + 5v .. 4 + 5v (v = 0..2); its pixels are on where
 *   col < len[v]. Rows 0..7 are the top page byte, rows 8..15 the bottom page byte.
 * Returns: nothing.
 */
void oled_ui_bar_bytes(uint32_t col, const uint32_t len[BASIC_VOICES], uint8_t *top, uint8_t *bottom)
{
    uint32_t rows = 0u;

    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        if (col < len[v]) {
            rows |= ((1u << UI_BAR_ROWS) - 1u) << (UI_BAR_FIRST_ROW + (UI_BAR_STRIDE * v));
        }
    }
    *top = (uint8_t)(rows & 0xFFu);
    *bottom = (uint8_t)((rows >> UI_HALF_PIXELS) & 0xFFu);
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
    ui_line(UI_PAGE_DRIVE, g_drive_ok ? "DRIVE 8: PRESENT" : "DRIVE 8: NOT READY");
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
 * ui_mq_put -- draw text column pos of the marquee at ring column vcol on pages 0 and 1.
 * Returns: nothing.
 */
static void ui_mq_put(uint32_t vcol, uint32_t pos)
{
    const uint8_t *glyph = font_openroms_glyph(oled_ascii_to_screen(g_text[pos / OLED_GLYPH_COLS]));
    uint8_t top;
    uint8_t bottom;

    oled_ui_double_column(oled_glyph_column(glyph, pos % OLED_GLYPH_COLS, 0), &top, &bottom);
    oled_put_column(UI_PAGE_MQ_TOP, vcol, top);
    oled_put_column(UI_PAGE_MQ_BOT, vcol, bottom);
}

/*
 * ui_mq_fill -- draw the UI_MQ_AHEAD columns that start at the scroll offset.
 * Returns: nothing.
 */
static void ui_mq_fill(void)
{
    const uint32_t cols = g_text_len * OLED_GLYPH_COLS;

    for (uint32_t k = 0u; k < UI_MQ_AHEAD; k++) {
        ui_mq_put((g_mq_off + k) % OLED_VCOLS, (g_s0 + k) % cols);
    }
}

/*
 * ui_mq_set -- install the marquee text for the given fields.
 * Steps: build the text; when it equals the one shown do nothing; otherwise keep the scroll
 *   position (text column modulo the new length) and redraw the drawn window, so a changing
 *   TIME does not move or restart the scroll.
 * Returns: nothing.
 */
static void ui_mq_set(const basic_tune_info_t *info, uint32_t song, uint32_t secs)
{
    char text[OLED_UI_TEXT_MAX];
    const uint32_t len = oled_ui_marquee_text(text, info->name, info->author, info->released, song,
                                              info->songs, secs);

    if (len == g_text_len && strcmp(text, g_text) == 0) {
        return;
    }
    memcpy(g_text, text, len + 1u);
    g_text_len = len;
    g_s0 %= (len * OLED_GLYPH_COLS);
    ui_mq_fill();
}

/*
 * ui_bars_update -- bring the three bars to the levels (only the changed columns are written).
 * Returns: nothing.
 */
static void ui_bars_update(const uint8_t level[BASIC_VOICES])
{
    uint32_t len[BASIC_VOICES];
    uint32_t lo = OLED_WIDTH;
    uint32_t hi = 0u;

    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        len[v] = oled_ui_bar_len(level[v]);
        if (len[v] != g_bar_len[v]) {
            const uint32_t a = (len[v] < g_bar_len[v]) ? len[v] : g_bar_len[v];
            const uint32_t b = (len[v] < g_bar_len[v]) ? g_bar_len[v] : len[v];

            lo = (a < lo) ? a : lo;
            hi = (b > hi) ? b : hi;
        }
    }
    for (uint32_t col = lo; col < hi; col++) {
        uint8_t top;
        uint8_t bottom;

        oled_ui_bar_bytes(col, len, &top, &bottom);
        oled_put_column(UI_PAGE_BAR_TOP, col, top);
        oled_put_column(UI_PAGE_BAR_BOT, col, bottom);
    }
    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        g_bar_len[v] = len[v];
    }
}

/*
 * ui_marquee_restart -- start the marquee over with the text of this tune and song.
 * Steps: forget the old text, scroll position and ring offset (both marquee pages to 0), build
 *   and draw the new text from its first column.
 * Returns: nothing.
 */
static void ui_marquee_restart(const basic_tune_info_t *info, uint32_t song, uint32_t secs)
{
    g_text_len = 0u;
    g_text[0] = '\0';
    g_s0 = 0u;
    g_mq_off = 0u;
    oled_set_scroll(UI_PAGE_MQ_TOP, 0u);
    oled_set_scroll(UI_PAGE_MQ_BOT, 0u);
    ui_mq_set(info, song, secs);
    g_tune_shown = *info;
    g_secs = secs;
    g_song_shown = song;
}

/*
 * ui_tune_changed -- do the header texts differ from the ones the marquee shows?
 * Returns: 1 when name, author, released or the song count changed.
 */
static int ui_tune_changed(const basic_tune_info_t *info)
{
    return (strcmp(info->name, g_tune_shown.name) != 0 || strcmp(info->author, g_tune_shown.author) != 0 ||
            strcmp(info->released, g_tune_shown.released) != 0 || info->songs != g_tune_shown.songs) ? 1 : 0;
}

/*
 * ui_enter_playing -- now-playing screen: double-height marquee (pages 0-1), empty bars.
 * Returns: nothing.
 */
static void ui_enter_playing(void)
{
    basic_tune_info_t info;
    const uint32_t secs = g_player->elapsed_ms() / UI_MS_PER_S;

    g_player->info(&info);
    oled_clear();
    for (uint32_t p = 0u; p < OLED_PAGES; p++) {
        oled_set_scroll(p, 0u);
    }
    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        g_bar_len[v] = 0u;
    }
    ui_marquee_restart(&info, info.start_song, secs);
    g_mode = UI_PLAYING;
}

/*
 * ui_playing_frame -- one vsync frame: marquee step by one column, bars to the new levels.
 * Steps: the ring offset and the text column advance by one; the column that enters the drawn
 *   window (UI_MQ_AHEAD - 1 ahead) is drawn; both marquee pages scroll together.
 * Returns: nothing.
 */
static void ui_playing_frame(void)
{
    uint8_t level[BASIC_VOICES] = { 0u, 0u, 0u };
    const uint32_t cols = g_text_len * OLED_GLYPH_COLS;

    g_mq_off = (g_mq_off + 1u) % OLED_VCOLS;
    g_s0 = (g_s0 + 1u) % cols;
    ui_mq_put((g_mq_off + UI_MQ_AHEAD - 1u) % OLED_VCOLS, (g_s0 + UI_MQ_AHEAD - 1u) % cols);
    oled_set_scroll(UI_PAGE_MQ_TOP, g_mq_off);
    oled_set_scroll(UI_PAGE_MQ_BOT, g_mq_off);

    g_player->voice_levels(level);
    ui_bars_update(level);
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
 * Steps (playing): per counted frame (at most OLED_UI_MAX_CATCHUP) one marquee column and the
 *   bars; then, when the second or the song changed, rebuild the marquee text in place.
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
        basic_tune_info_t info;

        g_player->info(&info);   /* the song number follows select_song, which restarts the time */
        if (info.start_song != g_song_shown || ui_tune_changed(&info) || secs < g_secs) {
            ui_marquee_restart(&info, info.start_song, secs);   /* other song or tune: new text from column 0 */
        } else if (secs != g_secs) {
            g_secs = secs;
            ui_mq_set(&info, info.start_song, secs);
        }
    }
}
