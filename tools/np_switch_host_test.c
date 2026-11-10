/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * np_switch_host_test.c -- host test of the HDMI now-playing screen and its UART mirror across a
 * tune switch (LOAD + RUN after a tune played) and song switches (+, -, 1-9): the real basic.c and
 * c64screen.c run against a fake drive, keyboard, video and player. The text rows are read back
 * from the c64screen cell RAM, so a leftover character of an earlier, longer text is caught.
 *
 * Build and run (MSYS2 UCRT64, from the repo root):
 *   gcc -std=c11 -Wall -Wextra -Werror -Ifw_c64/src -Icommon -Itools/host_stubs tools/np_switch_host_test.c \
 *       fw_c64/src/basic.c fw_c64/src/c64screen.c -o build/np_switch_host_test.exe
 *   build/np_switch_host_test.exe [+INJECT_FAILURE]
 * Prints "TEST PASS: np_switch_host" or "TEST FAIL" (exit 1).
 */
#include "basic.h"
#include "c64screen.h"
#include "drive_client.h"
#include "font_openroms.h"
#include "keyboard.h"
#include "np_piano.h"
#include "video.h"

#include <stdio.h>
#include <string.h>

#define NP_ROW_NAME      (3u)
#define NP_ROW_AUTHOR    (4u)
#define NP_ROW_RELEASED  (5u)
#define NP_ROW_SONG      (7u)
#define NP_ROW_TIME      (8u)
#define FIELD_COL        (10u)

static int g_checks;
static int g_errors;
static int g_inject;

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_errors++;
        printf("  CHECK FAILED: %s\n", what);
    }
}

/* ---- fake keyboard ---------------------------------------------------------------------------- */
static uint8_t g_keys[256];
static uint32_t g_key_r;
static uint32_t g_key_w;

int keyboard_getkey(uint8_t *petscii)
{
    if (g_key_r == g_key_w) {
        return 0;
    }
    *petscii = g_keys[g_key_r++ & 255u];
    return 1;
}
void keyboard_flush(void) { g_key_r = g_key_w; }

static void type(const char *s)
{
    for (; *s != '\0'; s++) {
        g_keys[g_key_w++ & 255u] = (uint8_t)*s;
    }
}

/* ---- fake video / font / piano ---------------------------------------------------------------- */
static const uint8_t g_solid[8] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const uint8_t *font_openroms_glyph(uint32_t index) { (void)index; return g_solid; }
uint32_t video_back_page(void) { return 0u; }
int      video_flip_pending(void) { return 0; }
uint32_t video_vsync_count(void) { return 0u; }
uint32_t video_poll(void) { return 0u; }
void     video_flip(void) {}
void     video_fill_rect(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t c)
{
    (void)page; (void)x; (void)y; (void)w; (void)h; (void)c;
}
void video_glyph(uint32_t page, uint32_t x, uint32_t y, const uint8_t *rows, uint8_t fg, uint8_t bg, int reverse)
{
    (void)page; (void)x; (void)y; (void)rows; (void)fg; (void)bg; (void)reverse;
}
void     np_piano_set_colours(const uint8_t bright[NP_PIANO_VOICES], const uint8_t dim[NP_PIANO_VOICES])
{
    (void)bright; (void)dim;
}
uint32_t np_piano_overlay(uint32_t page) { (void)page; return 0u; }

/* ---- fake drive: files "A" and "B"; the first bytes after "PSID" are "name|author|released|songs" - */
typedef struct
{
    const char *name;
    const char *content;
} fake_file_t;

static const fake_file_t g_files[] = {
    { "A", "PSIDSidemu Test Tune|A LONG AUTHOR NAME HERE|2026 Long Releasing Company|3" },
    { "B", "PSIDX|Y|1|1" },
};
static const fake_file_t *g_open;
static uint32_t g_pos;

void drive_client_set_device(uint8_t device) { (void)device; }
drive_client_result_t drive_client_ping(void) { return DRIVE_CLIENT_OK; }
drive_client_result_t drive_client_open(uint8_t channel, const char *name)
{
    (void)channel;
    g_open = NULL;
    for (uint32_t i = 0u; i < sizeof(g_files) / sizeof(g_files[0]); i++) {
        if (strcmp(name, g_files[i].name) == 0) {
            g_open = &g_files[i];
            g_pos = 0u;
            return DRIVE_CLIENT_OK;
        }
    }
    return DRIVE_CLIENT_DOS_ERROR;
}
drive_client_result_t drive_client_read(uint8_t channel, uint8_t *buf, uint32_t max, uint32_t *len, int *eoi)
{
    const uint32_t n = (uint32_t)strlen(g_open->content);
    uint32_t take = n - g_pos;

    (void)channel;
    if (take > max) {
        take = max;
    }
    memcpy(buf, g_open->content + g_pos, take);
    g_pos += take;
    *len = take;
    *eoi = (g_pos == n) ? 1 : 0;
    return DRIVE_CLIENT_OK;
}
drive_client_result_t drive_client_close(uint8_t channel) { (void)channel; return DRIVE_CLIENT_OK; }
drive_client_result_t drive_client_cmd(const char *text) { (void)text; return DRIVE_CLIENT_OK; }
drive_client_result_t drive_client_status(void) { return DRIVE_CLIENT_OK; }
uint8_t drive_client_last_status(void) { return 0u; }
void    drive_client_last_text(char *text, uint32_t size) { if (size > 0u) { text[0] = '\0'; } }

/* ---- fake player: the header comes from the loaded file's text, song 3 changes the author ---------- */
static char     g_nm[33];
static char     g_au[33];
static char     g_rl[33];
static uint32_t g_songs;
static uint32_t g_cur;
static uint32_t g_ms;

static basic_player_reason_t f_start(const uint8_t *file, uint32_t len)
{
    char text[128];
    char *f[4];
    uint32_t k = 0u;

    if (len < 6u || len >= sizeof(text) + 4u) {
        return BASIC_PLAYER_BAD_HEADER;
    }
    memcpy(text, file + 4, len - 4u);
    text[len - 4u] = '\0';
    f[k++] = text;
    for (char *p = text; *p != '\0' && k < 4u; p++) {
        if (*p == '|') {
            *p = '\0';
            f[k++] = p + 1;
        }
    }
    strcpy(g_nm, f[0]);
    strcpy(g_au, f[1]);
    strcpy(g_rl, f[2]);
    g_songs = (uint32_t)(f[3][0] - '0');
    g_cur = 1u;
    g_ms = 0u;
    return BASIC_PLAYER_OK;
}
static void f_info(basic_tune_info_t *i)
{
    memset(i, 0, sizeof(*i));
    strcpy(i->name, g_nm);
    strcpy(i->author, (g_cur == 3u) ? "S3" : g_au);   /* only to prove the header is read again per song */
    strcpy(i->released, g_rl);
    i->songs = g_songs;
    i->start_song = g_cur;
}
static int f_select(uint32_t song)
{
    g_cur = song;
    g_ms = 0u;
    return 0;
}
static void f_service(void) {}
static uint32_t f_elapsed(void) { return g_ms; }
static void f_levels(uint8_t l[BASIC_VOICES]) { l[0] = 0u; l[1] = 0u; l[2] = 0u; }
static void f_stop(void) {}
static const basic_player_ops_t g_ops = { f_start, f_info, f_select, f_service, f_elapsed, f_levels, f_stop };

/* ---- harness ---------------------------------------------------------------------------------- */
static char     g_uart[8192];
static uint32_t g_uart_n;
static uint8_t  g_load_buf[1024];

static void uart_out(char c)
{
    if (g_uart_n + 1u < sizeof(g_uart)) {
        g_uart[g_uart_n++] = c;
        g_uart[g_uart_n] = '\0';
    }
}

static void mem_info(uint32_t *ram, uint32_t *free_bytes)
{
    *ram = 512u * 1024u * 1024u;
    *free_bytes = *ram;
}

static void run_keys(const char *s)
{
    type(s);
    for (unsigned guard = 0u; guard < 100u && g_key_r != g_key_w; guard++) {
        basic_poll();
    }
    basic_poll();
}

/* Screen text of a row from col to the end of the row as ASCII. */
static void row_text(uint32_t row, uint32_t col, char *out)
{
    uint32_t n = 0u;

    for (uint32_t c = col; c < C64SCREEN_COLS; c++) {
        const uint8_t code = c64screen_code(row, c);

        out[n++] = (code >= 1u && code <= 26u) ? (char)('A' + code - 1u) : (char)code;
    }
    out[n] = '\0';
}

/* The field area of a row must read exactly "text" followed by spaces. */
static int field_is(uint32_t row, const char *text)
{
    char got[C64SCREEN_COLS + 1u];
    char want[C64SCREEN_COLS + 1u];

    row_text(row, FIELD_COL, got);
    memset(want, ' ', sizeof(want));
    want[C64SCREEN_COLS - FIELD_COL] = '\0';
    memcpy(want, text, strlen(text));
    return strcmp(got, want) == 0;
}

static void show(const char *label, uint32_t row)
{
    char got[C64SCREEN_COLS + 1u];

    row_text(row, FIELD_COL, got);
    printf("    %s row %u: [%s]\n", label, (unsigned)row, got);
}

int main(int argc, char **argv)
{
    basic_config_t cfg;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            g_inject = 1;
        }
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.mem_info = mem_info;
    cfg.player = &g_ops;
    cfg.load_buf = g_load_buf;
    cfg.load_buf_bytes = sizeof(g_load_buf);
    cfg.uart_out = uart_out;
    c64screen_init();
    basic_init(&cfg);

    /* Tune A: LOAD, RUN. */
    run_keys("LOAD\"A\",8\r");
    run_keys("RUN\r");
    check(basic_playing() == 1, "tune A plays");
    check(field_is(NP_ROW_NAME, "SIDEMU TEST TUNE"), "A: name");
    check(field_is(NP_ROW_AUTHOR, "A LONG AUTHOR NAME HERE"), "A: author");
    check(field_is(NP_ROW_RELEASED, "2026 LONG RELEASING COMPANY"), "A: released");
    check(field_is(NP_ROW_SONG, "01/03"), "A: song 01/03");
    check(field_is(NP_ROW_TIME, "00:00"), "A: time 00:00");
    check(strstr(g_uart, "NAME Sidemu Test Tune\r\nAUTHOR A LONG AUTHOR NAME HERE\r\nRELEASED 2026 Long Releasing Company\r\nSONG 01/03\r\n") != NULL,
          "A: UART mirror of the header and song");

    /* Time runs, then a song change restarts it. */
    g_ms = 12000u;
    basic_poll();
    check(field_is(NP_ROW_TIME, "00:12"), "A: time runs to 00:12");
    g_uart_n = 0u;
    g_uart[0] = '\0';
    run_keys("2");
    check(field_is(NP_ROW_SONG, "02/03"), "song 2: SONG 02/03");
    check(field_is(NP_ROW_TIME, "00:00"), "song 2: time restarted");
    check(strstr(g_uart, "SONG 02/03\r\n") != NULL, "song 2: UART mirror line");
    check(field_is(NP_ROW_NAME, "SIDEMU TEST TUNE") && field_is(NP_ROW_AUTHOR, "A LONG AUTHOR NAME HERE"),
          "song 2: name and author still shown");
    g_ms = 7000u;
    run_keys("+");
    check(field_is(NP_ROW_SONG, "03/03") && field_is(NP_ROW_TIME, "00:00"), "+: song 3, time restarted");
    check(field_is(NP_ROW_AUTHOR, "S3"), "song 3: author redrawn from the player, no leftover of the longer text");
    check(strstr(g_uart, "SONG 03/03\r\n") != NULL, "+: UART mirror line");
    run_keys("+");
    check(field_is(NP_ROW_SONG, "03/03"), "+ past the last song does nothing");
    g_ms = 9000u;
    run_keys("-");
    check(field_is(NP_ROW_SONG, "02/03") && field_is(NP_ROW_TIME, "00:00"), "-: song 2, time restarted");
    check(field_is(NP_ROW_AUTHOR, "A LONG AUTHOR NAME HERE"), "song 2 again: author back");
    g_ms = 4000u;
    run_keys("1");
    check(field_is(NP_ROW_SONG, "01/03") && field_is(NP_ROW_TIME, "00:00"), "1: song 1, time restarted");
    run_keys("9");
    check(field_is(NP_ROW_SONG, "01/03"), "9: no such song, unchanged");
    show("song", NP_ROW_SONG);

    /* Break, then another tune with shorter texts: nothing of tune A may remain. */
    run_keys("\x03");
    check(basic_playing() == 0, "RUN/STOP leaves the player");
    g_uart_n = 0u;
    g_uart[0] = '\0';
    run_keys("LOAD\"B\",8\r");
    run_keys("RUN\r");
    check(basic_playing() == 1, "tune B plays");
    check(field_is(NP_ROW_NAME, "X"), "B: name, no leftover of tune A");
    check(field_is(NP_ROW_AUTHOR, g_inject ? "Z" : "Y"), "B: author, no leftover");
    check(field_is(NP_ROW_RELEASED, "1"), "B: released, no leftover");
    check(field_is(NP_ROW_SONG, "01/01"), "B: song 01/01");
    check(field_is(NP_ROW_TIME, "00:00"), "B: time 00:00");
    check(strstr(g_uart, "NAME X\r\nAUTHOR Y\r\nRELEASED 1\r\nSONG 01/01\r\n") != NULL, "B: UART mirror");
    check(strstr(g_uart, "Sidemu") == NULL, "B: no text of tune A in the UART mirror");
    show("name", NP_ROW_NAME);

    /* And back to A. */
    run_keys("\x03");
    run_keys("LOAD\"A\",8\r");
    run_keys("RUN\r");
    check(field_is(NP_ROW_NAME, "SIDEMU TEST TUNE") && field_is(NP_ROW_AUTHOR, "A LONG AUTHOR NAME HERE") &&
              field_is(NP_ROW_SONG, "01/03"),
          "A again after B");

    if (g_errors == 0) {
        printf("TEST PASS: np_switch_host (%d checks)\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: np_switch_host (%d of %d checks failed)\n", g_errors, g_checks);
    return 1;
}
