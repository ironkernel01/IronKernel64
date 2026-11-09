/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: basic.c
 * Role: C64 screen editor, command shell, DOS wedge and now-playing screen (contract in
 *   basic.h).
 *
 * Hardware: none directly (c64screen, keyboard, drive_client, video for the flip state).
 * Screen editor model (as the C64 KERNAL editor):
 *   - g_row/g_col is the cursor; c64screen's link table groups rows into logical lines of
 *     up to 80 characters. Typing past column 39 on a one-row line opens a linked row
 *     below (lower rows move down); past column 79 the cursor starts a new line.
 *   - Output and typing share emit(): printable PETSCII goes on screen in the current
 *     colour (reverse with RVS ON); control codes act. In quote mode (after an odd number
 *     of '"') or while INST-opened spaces remain, control codes are shown as reverse
 *     characters instead, and RETURN reads such a reverse character back as the control
 *     code.
 *   - RETURN reads the logical line under the cursor, moves to the next line and runs it.
 * Commands run to completion inside basic_poll(); the only waits are the drive requests
 *   (bounded in drive_client.c) and show_now() (bounded by BASIC_SHOW_POLLS).
 */
#include "basic.h"

#include "c64screen.h"
#include "drive_client.h"
#include "keyboard.h"
#include "video.h"

#include "sleep.h"   /* usleep (show_now pacing) */

#define BASIC_COLS            (C64SCREEN_COLS)
#define BASIC_ROWS            (C64SCREEN_ROWS)
#define BASIC_LINE_MAX        (C64SCREEN_LINE_MAX)
#define BASIC_RAM_LINE_MAX    (39u)       /* RAM line stays on one row */
#define BASIC_KEYS_PER_POLL   (KEYBOARD_QUEUE_DEPTH)
#define BASIC_SHOW_POLLS      (200u)      /* show_now: at most 200 x 500 us = 100 ms */
#define BASIC_SHOW_POLL_US    (500u)
#define BASIC_DIR_CHUNK       (256u)      /* @$ reads the listing in pieces this size */
#define BASIC_MIB             (0x00100000u)
#define BASIC_KIB             (0x00000400u)
#define BASIC_NUM_DIGITS      (10u)       /* uint32_t in decimal */
#define BASIC_SID_MAGIC_BYTES (4u)
#define BASIC_BAR_COL         (10u)
#define BASIC_BAR_CELLS       (26u)
#define BASIC_FIELD_COL       (10u)
#define BASIC_FIELD_CELLS     (BASIC_COLS - BASIC_FIELD_COL)
#define BASIC_LEVEL_MAX       (255u)
#define BASIC_MS_PER_S        (1000u)
#define BASIC_S_PER_MIN       (60u)
#define BASIC_MAX_SONG_KEY    (9u)

#define PET_RETURN            (0x0Du)
#define PET_SHIFT_RETURN      (0x8Du)
#define PET_QUOTE             (0x22u)
#define PET_SPACE             (0x20u)
#define PET_SHIFT_SPACE       (0xA0u)
#define PET_PI                (0xFFu)
#define PET_LEFT_ARROW        (0x5Fu)
#define TOKEN_FIRST           (0x80u)
#define TOKEN_LAST            (0xCBu)
#define SCREEN_REVERSE_SPACE  (0xA0u)

/* Now-playing screen rows. */
#define NP_ROW_TITLE          (1u)
#define NP_ROW_NAME           (3u)
#define NP_ROW_AUTHOR         (4u)
#define NP_ROW_RELEASED       (5u)
#define NP_ROW_SONG           (7u)
#define NP_ROW_TIME           (8u)
#define NP_ROW_VOICE1         (10u)
#define NP_ROW_HELP           (14u)

typedef enum
{
    BASIC_STATE_EDIT = 0,
    BASIC_STATE_PLAYING
} basic_state_t;

/* Streaming detokenizer of a BASIC program image (load address first). */
typedef enum
{
    DT_ADDR_LO = 0,
    DT_ADDR_HI,
    DT_LINK_LO,
    DT_LINK_HI,
    DT_NUM_LO,
    DT_NUM_HI,
    DT_TEXT,
    DT_END
} dt_state_t;

typedef struct
{
    dt_state_t state;
    uint8_t    link_lo;
    uint8_t    num_lo;
    int        quote;
} dt_t;

/* BASIC V2 keywords for tokens $80..$CB. */
static const char *const g_tokens[TOKEN_LAST - TOKEN_FIRST + 1u] = {
    "END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ", "LET", "GOTO", "RUN",
    "IF", "RESTORE", "GOSUB", "RETURN", "REM", "STOP", "ON", "WAIT", "LOAD", "SAVE",
    "VERIFY", "DEF", "POKE", "PRINT#", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN",
    "CLOSE", "GET", "NEW", "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP", "+", "-", "*",
    "/", "^", "AND", "OR", ">", "=", "<", "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR",
    "RND", "LOG", "EXP", "COS", "SIN", "TAN", "ATN", "PEEK", "LEN", "STR$", "VAL", "ASC",
    "CHR$", "LEFT$", "RIGHT$", "MID$", "GO"
};

/* PETSCII colour codes, index = C64 colour number. */
static const uint8_t g_colour_codes[16] = {
    0x90u, 0x05u, 0x1Cu, 0x9Fu, 0x9Cu, 0x1Eu, 0x1Fu, 0x9Eu,
    0x81u, 0x95u, 0x96u, 0x97u, 0x98u, 0x99u, 0x9Au, 0x9Bu
};

/* Voice bar colours on the now-playing screen. */
static const uint8_t g_bar_colour[BASIC_VOICES] = {
    VIDEO_COL_LIGHT_GREEN, VIDEO_COL_YELLOW, VIDEO_COL_LIGHT_RED
};

static basic_config_t g_cfg;
static basic_state_t  g_state;
static uint32_t g_row;
static uint32_t g_col;
static uint32_t g_shown_row;
static uint32_t g_shown_col;
static uint8_t  g_colour;
static int      g_rvs;
static int      g_quote;
static uint32_t g_insert;
static uint32_t g_load_len;
static uint8_t  g_line[BASIC_LINE_MAX + 1u];
static uint8_t  g_dir_chunk[BASIC_DIR_CHUNK];
static char     g_status_text[DRIVE_STATUS_TEXT_BYTES];
static char     g_name[DRIVE_NAME_BYTES];

/* Now-playing state. */
static c64screen_snapshot_t g_saved_screen;
static uint32_t g_saved_row;
static uint32_t g_saved_col;
static uint8_t  g_saved_colour;
static basic_tune_info_t g_tune;
static uint32_t g_song;

/* ---------------------------------------------------------------------------------------
 * Screen editor primitives
 * ------------------------------------------------------------------------------------- */

/*
 * line_start -- first row of the logical line that holds a row.
 * Returns: the row number.
 */
static uint32_t line_start(uint32_t row)
{
    for (uint32_t i = 0u; i < BASIC_ROWS && row > 0u && c64screen_linked(row); i++) {
        row--;
    }
    return row;
}

/*
 * line_rows -- rows of the logical line that starts on `start`.
 * Returns: 1 or 2.
 */
static uint32_t line_rows(uint32_t start)
{
    return (start + 1u < BASIC_ROWS && c64screen_linked(start + 1u)) ? 2u : 1u;
}

/*
 * cell_code / cell_colour / cell_put -- a cell addressed by logical position.
 * Returns: the screen code / colour; cell_put returns nothing.
 */
static uint8_t cell_code(uint32_t start, uint32_t pos)
{
    return c64screen_code(start + pos / BASIC_COLS, pos % BASIC_COLS);
}

static uint8_t cell_colour(uint32_t start, uint32_t pos)
{
    return c64screen_colour(start + pos / BASIC_COLS, pos % BASIC_COLS);
}

static void cell_put(uint32_t start, uint32_t pos, uint8_t code, uint8_t colour)
{
    c64screen_put(start + pos / BASIC_COLS, pos % BASIC_COLS, code, colour);
}

/*
 * scroll -- scroll the screen up one row; the cursor row follows its text.
 * Returns: nothing.
 */
static void scroll(void)
{
    c64screen_scroll_up(g_colour);
    if (g_row > 0u) {
        g_row--;
    }
}

/*
 * extend_line -- give a one-row logical line a linked second row.
 * Steps:
 *   1. At the bottom row, scroll first.
 *   2. Insert a blank row below the line (lower rows move down) and link it.
 * Returns: the (possibly moved) first row of the line.
 */
static uint32_t extend_line(uint32_t start)
{
    if (start + 1u >= BASIC_ROWS) {
        scroll();
        start--;
    }
    c64screen_insert_row(start + 1u, g_colour);
    c64screen_set_link(start + 1u, 1);
    return start;
}

/*
 * advance -- move the cursor one cell right after printing.
 * Steps:
 *   1. Inside the row: next column.
 *   2. Past column 39 on the first row of a line: continue on the linked row, creating it
 *      when missing.
 *   3. Past column 79: start a new line below (scrolling at the bottom).
 * Returns: nothing.
 */
static void advance(void)
{
    uint32_t start;

    g_col++;
    if (g_col < BASIC_COLS) {
        return;
    }
    g_col = 0u;
    start = line_start(g_row);
    if (g_row == start) {
        if (line_rows(start) == 1u) {
            start = extend_line(start);
        }
        g_row = start + 1u;
    } else {
        if (g_row + 1u >= BASIC_ROWS) {
            scroll();
        }
        g_row++;
    }
}

/*
 * next_line -- cursor to column 0 of the line after the current logical line.
 * Steps:
 *   1. Go to the last row of the logical line, then one row down (scroll at the bottom).
 *   2. RETURN ends quote mode, insert mode and reverse mode.
 * Returns: nothing.
 */
static void next_line(void)
{
    uint32_t start = line_start(g_row);

    g_row = start + line_rows(start) - 1u;
    if (g_row + 1u >= BASIC_ROWS) {
        scroll();
    }
    g_row++;
    g_col = 0u;
    g_rvs = 0;
    g_quote = 0;
    g_insert = 0u;
}

/*
 * cursor_down / cursor_up / cursor_right / cursor_left -- free cursor movement.
 * Returns: nothing.
 */
static void cursor_down(void)
{
    if (g_row + 1u >= BASIC_ROWS) {
        scroll();
    }
    g_row++;
}

static void cursor_up(void)
{
    if (g_row > 0u) {
        g_row--;
    }
}

static void cursor_right(void)
{
    g_col++;
    if (g_col >= BASIC_COLS) {
        g_col = 0u;
        cursor_down();
    }
}

static void cursor_left(void)
{
    if (g_col > 0u) {
        g_col--;
    } else if (g_row > 0u) {
        g_row--;
        g_col = BASIC_COLS - 1u;
    }
}

/*
 * delete_char -- DEL: remove the character left of the cursor within the logical line.
 * Steps:
 *   1. At the start of the logical line nothing happens.
 *   2. Shift the rest of the line left by one, blank the last cell, cursor left.
 * Returns: nothing.
 */
static void delete_char(void)
{
    uint32_t start = line_start(g_row);
    uint32_t len = line_rows(start) * BASIC_COLS;
    uint32_t pos = (g_row - start) * BASIC_COLS + g_col;

    if (pos == 0u) {
        return;
    }
    for (uint32_t i = pos; i < len; i++) {
        cell_put(start, i - 1u, cell_code(start, i), cell_colour(start, i));
    }
    cell_put(start, len - 1u, C64SCREEN_SPACE, g_colour);
    pos--;
    g_row = start + pos / BASIC_COLS;
    g_col = pos % BASIC_COLS;
}

/*
 * insert_char -- INST: open a space at the cursor within the logical line.
 * Steps:
 *   1. If the last cell is in use: extend a one-row line, or do nothing on a full
 *      80-character line.
 *   2. Shift the rest of the line right by one and blank the cursor cell.
 *   3. Count the opened space (insert mode quotes control codes typed into it).
 * Returns: nothing.
 */
static void insert_char(void)
{
    uint32_t start = line_start(g_row);
    uint32_t len = line_rows(start) * BASIC_COLS;
    uint32_t pos = (g_row - start) * BASIC_COLS + g_col;

    if ((cell_code(start, len - 1u) & 0x7Fu) != C64SCREEN_SPACE) {
        if (len >= BASIC_LINE_MAX) {
            return;
        }
        start = extend_line(start);
        g_row = start + pos / BASIC_COLS;
        len = BASIC_LINE_MAX;
    }
    for (uint32_t i = len - 1u; i > pos; i--) {
        cell_put(start, i, cell_code(start, i - 1u), cell_colour(start, i - 1u));
    }
    cell_put(start, pos, C64SCREEN_SPACE, g_colour);
    if (g_insert < BASIC_LINE_MAX) {
        g_insert++;
    }
}

/*
 * colour_of_code -- C64 colour number of a PETSCII colour code.
 * Returns: 0..15, or -1 when c is not a colour code.
 */
static int colour_of_code(uint8_t c)
{
    for (uint32_t i = 0u; i < 16u; i++) {
        if (g_colour_codes[i] == c) {
            return (int)i;
        }
    }
    return -1;
}

/*
 * is_control -- PETSCII control code ($00-$1F, $80-$9F).
 * Returns: 1 or 0.
 */
static int is_control(uint8_t c)
{
    return (c < 0x20u || (c >= 0x80u && c < 0xA0u)) ? 1 : 0;
}

/*
 * put_quoted -- show a control code as its reverse character (quote / insert mode).
 * Steps:
 *   1. $00-$1F show as reverse screen codes $00-$1F; $80-$9F as reverse $40-$5F.
 * Returns: nothing.
 */
static void put_quoted(uint8_t c)
{
    uint8_t code = (c < 0x20u) ? c : (uint8_t)(c - 0x40u);

    c64screen_put(g_row, g_col, (uint8_t)(code | C64SCREEN_REVERSE_BIT), g_colour);
    if (g_insert > 0u) {
        g_insert--;
    }
    advance();
}

/*
 * emit -- print one PETSCII character at the cursor (the CHROUT of this editor).
 * Steps:
 *   1. RETURN / Shift+RETURN: next line.
 *   2. Other control codes: shown reversed in quote or insert mode, otherwise acted on
 *      (cursor keys, HOME, CLR, DEL, INST, RVS, character set, colours).
 *   3. Printable characters: screen code in the current colour (reverse with RVS ON);
 *      '"' toggles quote mode.
 * Returns: nothing.
 */
static void emit(uint8_t c)
{
    uint8_t code;
    int colour;

    if (c == PET_RETURN || c == PET_SHIFT_RETURN) {
        next_line();
        return;
    }
    if (is_control(c)) {
        if (g_quote || g_insert > 0u) {
            put_quoted(c);
            return;
        }
        colour = colour_of_code(c);
        if (colour >= 0) {
            g_colour = (uint8_t)colour;
            return;
        }
        switch (c) {
        case KEYBOARD_KEY_DOWN:       cursor_down(); break;
        case KEYBOARD_KEY_UP:         cursor_up(); break;
        case KEYBOARD_KEY_RIGHT:      cursor_right(); break;
        case KEYBOARD_KEY_LEFT:       cursor_left(); break;
        case KEYBOARD_KEY_HOME:       g_row = 0u; g_col = 0u; break;
        case KEYBOARD_KEY_CLR:        c64screen_clear(g_colour); g_row = 0u; g_col = 0u; break;
        case KEYBOARD_KEY_DEL:        delete_char(); break;
        case KEYBOARD_KEY_INST:       insert_char(); break;
        case KEYBOARD_KEY_RVS_ON:     g_rvs = 1; break;
        case KEYBOARD_KEY_RVS_OFF:    g_rvs = 0; break;
        case KEYBOARD_KEY_LOWER_CASE: c64screen_set_charset(C64SCREEN_CHARSET_LOWER); break;
        case KEYBOARD_KEY_UPPER_CASE: c64screen_set_charset(C64SCREEN_CHARSET_UPPER); break;
        default:                      break;
        }
        return;
    }
    if (!c64screen_petscii_to_code(c, &code)) {
        return;
    }
    if (g_rvs) {
        code |= C64SCREEN_REVERSE_BIT;
    }
    c64screen_put(g_row, g_col, code, g_colour);
    if (c == PET_QUOTE) {
        g_quote = !g_quote;
    }
    if (g_insert > 0u) {
        g_insert--;
    }
    advance();
}

/*
 * put_text -- emit an ASCII string ('\r' = RETURN; upper-case ASCII equals PETSCII).
 * Returns: nothing.
 */
static void put_text(const char *s)
{
    for (uint32_t i = 0u; s[i] != '\0' && i < BASIC_LINE_MAX * BASIC_ROWS; i++) {
        emit((s[i] == '\r') ? PET_RETURN : (uint8_t)s[i]);
    }
}

/*
 * print_u32 -- emit an unsigned number in decimal.
 * Returns: nothing.
 */
static void print_u32(uint32_t v)
{
    char digits[BASIC_NUM_DIGITS + 1u];
    uint32_t n = BASIC_NUM_DIGITS;

    digits[n] = '\0';
    do {
        digits[--n] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v != 0u && n > 0u);
    put_text(&digits[n]);
}

/*
 * print_error -- "?<message>  ERROR" on its own line (C64 wording).
 * Returns: nothing.
 */
static void print_error(const char *message)
{
    put_text("?");
    put_text(message);
    put_text("  ERROR\r");
}

/*
 * show_now -- get the current text onto the display before a slow step.
 * Steps:
 *   1. Render and wait for the flip, repeating until a render has nothing left to draw;
 *      at most BASIC_SHOW_POLLS rounds of BASIC_SHOW_POLL_US.
 * Returns: nothing.
 */
static void show_now(void)
{
    c64screen_set_cursor(g_row, g_col);
    for (uint32_t i = 0u; i < BASIC_SHOW_POLLS; i++) {
        (void)video_poll();
        if (!video_flip_pending() && c64screen_render() == 0u && !video_flip_pending()) {
            break;
        }
        usleep(BASIC_SHOW_POLL_US);
    }
}

/* ---------------------------------------------------------------------------------------
 * Logical line input and command parsing
 * ------------------------------------------------------------------------------------- */

/*
 * read_line -- the logical line under the cursor as PETSCII (as RETURN reads it).
 * Steps:
 *   1. Walk the 40 or 80 cells of the line; a '"' toggles quote mode.
 *   2. Inside quotes, a reverse cell standing for a control code reads back as that code;
 *      every other cell reads as the character it shows.
 *   3. Strip trailing spaces; NUL-terminate in g_line.
 * Returns: the number of characters.
 */
static uint32_t read_line(void)
{
    uint32_t start = line_start(g_row);
    uint32_t len = line_rows(start) * BASIC_COLS;
    int quote = 0;

    for (uint32_t i = 0u; i < len; i++) {
        uint8_t code = cell_code(start, i);
        uint8_t base = (uint8_t)(code & 0x7Fu);
        uint8_t c;

        if (quote && (code & C64SCREEN_REVERSE_BIT) != 0u && base < 0x20u) {
            c = base;
        } else if (quote && (code & C64SCREEN_REVERSE_BIT) != 0u && base >= 0x40u &&
                   base < 0x60u) {
            c = (uint8_t)(base + 0x40u);
        } else {
            c = c64screen_code_to_petscii(code);
        }
        if (c == PET_QUOTE) {
            quote = !quote;
        }
        g_line[i] = c;
    }
    while (len > 0u && (g_line[len - 1u] == PET_SPACE || g_line[len - 1u] == PET_SHIFT_SPACE)) {
        len--;
    }
    g_line[len] = 0u;
    return len;
}

/*
 * skip_spaces -- advance past spaces.
 * Returns: the new index.
 */
static uint32_t skip_spaces(const uint8_t *s, uint32_t i)
{
    while (i < BASIC_LINE_MAX && s[i] == PET_SPACE) {
        i++;
    }
    return i;
}

/*
 * match_keyword -- keyword at s[i], spelled out or in C64 abbreviated form.
 * Steps:
 *   1. Compare letter by letter; the first shifted letter (PETSCII letter + $80) ends an
 *      abbreviation (e.g. L + shifted O = LOAD).
 * Returns: index after the keyword, or 0 when it does not match.
 */
static uint32_t match_keyword(const uint8_t *s, uint32_t i, const char *kw)
{
    uint32_t k;

    for (k = 0u; kw[k] != '\0' && i + k < BASIC_LINE_MAX; k++) {
        uint8_t c = s[i + k];
        if (c == (uint8_t)kw[k]) {
            continue;
        }
        if (k > 0u && c == (uint8_t)((uint8_t)kw[k] | 0x80u)) {
            return i + k + 1u;
        }
        return 0u;
    }
    return (kw[k] == '\0') ? i + k : 0u;
}

/* ---------------------------------------------------------------------------------------
 * Detokenizer (LIST, @$)
 * ------------------------------------------------------------------------------------- */

/*
 * dt_reset -- start a new program image (load address first).
 * Returns: nothing.
 */
static void dt_reset(dt_t *dt)
{
    dt->state = DT_ADDR_LO;
    dt->quote = 0;
}

/*
 * dt_feed -- one byte of a BASIC program image.
 * Steps:
 *   1. Skip the 2-byte load address; read the line link (0/0 ends the program) and the
 *      line number, then print the number and a space.
 *   2. Text bytes: 0 ends the line; outside quotes tokens $80-$CB print their keyword
 *      and $FF prints pi; everything else is emitted as PETSCII ('"' toggles quotes).
 * Returns: 1 while more bytes are expected, 0 after the end of the program.
 */
static int dt_feed(dt_t *dt, uint8_t b)
{
    switch (dt->state) {
    case DT_ADDR_LO: dt->state = DT_ADDR_HI; break;
    case DT_ADDR_HI: dt->state = DT_LINK_LO; break;
    case DT_LINK_LO: dt->link_lo = b; dt->state = DT_LINK_HI; break;
    case DT_LINK_HI:
        dt->state = (dt->link_lo == 0u && b == 0u) ? DT_END : DT_NUM_LO;
        break;
    case DT_NUM_LO: dt->num_lo = b; dt->state = DT_NUM_HI; break;
    case DT_NUM_HI:
        print_u32((uint32_t)dt->num_lo | ((uint32_t)b << 8));
        emit(PET_SPACE);
        dt->quote = 0;
        dt->state = DT_TEXT;
        break;
    case DT_TEXT:
        if (b == 0u) {
            emit(PET_RETURN);
            dt->state = DT_LINK_LO;
        } else if (b == PET_QUOTE) {
            dt->quote = !dt->quote;
            emit(b);
        } else if (!dt->quote && b >= TOKEN_FIRST && b <= TOKEN_LAST) {
            put_text(g_tokens[b - TOKEN_FIRST]);
        } else {
            emit(b);
        }
        break;
    default:
        break;
    }
    return (dt->state == DT_END) ? 0 : 1;
}

/* ---------------------------------------------------------------------------------------
 * Commands
 * ------------------------------------------------------------------------------------- */

/*
 * is_sid -- the loaded file starts with "PSID" or "RSID".
 * Returns: 1 or 0.
 */
static int is_sid(void)
{
    const uint8_t *b = g_cfg.load_buf;

    if (g_load_len < BASIC_SID_MAGIC_BYTES) {
        return 0;
    }
    return ((b[0] == 'P' || b[0] == 'R') && b[1] == 'S' && b[2] == 'I' && b[3] == 'D') ? 1 : 0;
}

/*
 * print_dos_failure -- C64 error for a failed drive request.
 * Returns: nothing.
 */
static void print_dos_failure(drive_client_result_t r)
{
    switch (r) {
    case DRIVE_CLIENT_TIMEOUT:   print_error("DEVICE NOT PRESENT"); break;
    case DRIVE_CLIENT_DOS_ERROR: print_error("FILE NOT FOUND"); break;
    case DRIVE_CLIENT_TOO_BIG:   print_error("OUT OF MEMORY"); break;
    default:                     print_error("SYNTAX"); break;
    }
}

/*
 * cmd_load -- LOAD"name"[,device[,secondary]].
 * Steps:
 *   1. Parse the quoted name (closing quote optional), device (default 8) and secondary
 *      address; text after them is ignored.
 *   2. Device other than 8: ?DEVICE NOT PRESENT. Empty name: ?MISSING FILE NAME.
 *   3. Print SEARCHING FOR <name>, show it, PING (no answer: DEVICE NOT PRESENT) and OPEN
 *      channel 0 (DOS error: FILE NOT FOUND).
 *   4. Print LOADING, READ until EOI into the load buffer (bounded by its size), CLOSE.
 * Returns: nothing; g_load_len holds the loaded length (0 after a failure).
 */
static void cmd_load(const uint8_t *s, uint32_t i)
{
    uint32_t n = 0u;
    uint32_t device = DRIVE_DEVICE;
    uint32_t total = 0u;
    int eoi = 0;
    drive_client_result_t r;

    i = skip_spaces(s, i);
    if (s[i] == PET_QUOTE) {
        i++;
        while (s[i] != 0u && s[i] != PET_QUOTE && n < DRIVE_NAME_BYTES - 1u) {
            g_name[n++] = (char)s[i++];
        }
        if (s[i] == PET_QUOTE) {
            i++;
        }
    }
    g_name[n] = '\0';
    i = skip_spaces(s, i);
    if (s[i] == ',') {
        i = skip_spaces(s, i + 1u);
        if (s[i] < '0' || s[i] > '9') {
            print_error("SYNTAX");
            return;
        }
        device = 0u;
        while (s[i] >= '0' && s[i] <= '9' && device < 100u) {
            device = device * 10u + (uint32_t)(s[i++] - '0');
        }
    }
    if (n == 0u) {
        print_error("MISSING FILE NAME");
        return;
    }
    if (device != DRIVE_DEVICE) {
        print_error("DEVICE NOT PRESENT");
        return;
    }

    g_load_len = 0u;
    emit(PET_RETURN);
    put_text("SEARCHING FOR ");
    for (uint32_t k = 0u; k < n; k++) {
        emit((uint8_t)g_name[k]);
    }
    emit(PET_RETURN);
    show_now();
    r = drive_client_ping();
    if (r == DRIVE_CLIENT_OK) {
        r = drive_client_open(DRIVE_CH_LOAD, g_name);
    }
    if (r != DRIVE_CLIENT_OK) {
        print_dos_failure(r);
        return;
    }
    put_text("LOADING\r");
    show_now();
    for (uint32_t reads = 0u; reads < g_cfg.load_buf_bytes && !eoi; reads++) {
        uint32_t got = 0u;
        if (total == g_cfg.load_buf_bytes) {
            r = DRIVE_CLIENT_TOO_BIG;
            break;
        }
        r = drive_client_read(DRIVE_CH_LOAD, &g_cfg.load_buf[total],
                              g_cfg.load_buf_bytes - total, &got, &eoi);
        if (r != DRIVE_CLIENT_OK) {
            break;
        }
        total += got;
    }
    (void)drive_client_close(DRIVE_CH_LOAD);
    if (r == DRIVE_CLIENT_OK && !eoi) {
        r = DRIVE_CLIENT_TOO_BIG;
    }
    if (r == DRIVE_CLIENT_TIMEOUT) {
        print_error("LOAD");
        return;
    }
    if (r != DRIVE_CLIENT_OK) {
        print_dos_failure(r);
        return;
    }
    g_load_len = total;
}

/*
 * cmd_list -- LIST the loaded BASIC program (a directory listing is one).
 * Steps:
 *   1. Nothing loaded, or a SID file: print nothing.
 *   2. Feed the image to the detokenizer until its end marker or the end of the data.
 * Returns: nothing.
 */
static void cmd_list(void)
{
    dt_t dt;

    if (g_load_len == 0u || is_sid()) {
        return;
    }
    dt_reset(&dt);
    for (uint32_t i = 0u; i < g_load_len && dt_feed(&dt, g_cfg.load_buf[i]); i++) {
    }
    if (dt.state == DT_TEXT) {
        emit(PET_RETURN);
    }
}

/*
 * wedge_dir -- @$[pattern]: list the directory without touching the loaded program.
 * Steps:
 *   1. PING and OPEN "$..." on channel 0 (no answer: DEVICE NOT PRESENT; DOS error:
 *      FILE NOT FOUND).
 *   2. READ BASIC_DIR_CHUNK bytes at a time into the detokenizer until EOI or its end
 *      marker (each READ returns at least one byte, so the loop ends within the drive's
 *      data area size divided by one byte; it is also capped at DRIVE_DATA_BYTES reads).
 *   3. CLOSE channel 0.
 * Returns: nothing.
 */
static void wedge_dir(const uint8_t *s, uint32_t i)
{
    uint32_t n = 0u;
    int eoi = 0;
    int more = 1;
    dt_t dt;
    drive_client_result_t r;

    while (s[i] != 0u && n < DRIVE_NAME_BYTES - 1u) {
        g_name[n++] = (char)s[i++];
    }
    g_name[n] = '\0';
    show_now();
    r = drive_client_ping();
    if (r == DRIVE_CLIENT_OK) {
        r = drive_client_open(DRIVE_CH_LOAD, g_name);
    }
    if (r != DRIVE_CLIENT_OK) {
        print_dos_failure(r);
        return;
    }
    dt_reset(&dt);
    for (uint32_t reads = 0u; reads < DRIVE_DATA_BYTES && !eoi && more; reads++) {
        uint32_t got = 0u;
        r = drive_client_read(DRIVE_CH_LOAD, g_dir_chunk, BASIC_DIR_CHUNK, &got, &eoi);
        if (r != DRIVE_CLIENT_OK) {
            break;
        }
        for (uint32_t k = 0u; k < got && more; k++) {
            more = dt_feed(&dt, g_dir_chunk[k]);
        }
    }
    (void)drive_client_close(DRIVE_CH_LOAD);
    if (dt.state == DT_TEXT) {
        emit(PET_RETURN);
    }
    if (r == DRIVE_CLIENT_TIMEOUT) {
        print_error("DEVICE NOT PRESENT");
    }
}

/*
 * wedge -- DOS wedge: "@" status, "@$..." directory, "@<command>" to channel 15.
 * Steps:
 *   1. "@" alone: read the status channel and print its line.
 *   2. "@$...": wedge_dir.
 *   3. Otherwise send the text as a DOS command (CD:NAME, CD:<left arrow>, CD//, I, UI)
 *      and print the status line when it reports an error.
 * Returns: nothing.
 */
static void wedge(const uint8_t *s, uint32_t i)
{
    drive_client_result_t r;
    uint32_t n = 0u;

    i = skip_spaces(s, i);
    if (s[i] == '$') {
        wedge_dir(s, i);
        return;
    }
    show_now();
    if (s[i] == 0u) {
        r = drive_client_status();
    } else {
        while (s[i] != 0u && n < DRIVE_NAME_BYTES - 1u) {
            g_name[n++] = (char)s[i++];
        }
        g_name[n] = '\0';
        r = drive_client_cmd(g_name);
        if (r == DRIVE_CLIENT_OK) {
            return;
        }
    }
    if (r == DRIVE_CLIENT_TIMEOUT) {
        print_error("DEVICE NOT PRESENT");
        return;
    }
    drive_client_last_text(g_status_text, sizeof(g_status_text));
    put_text(g_status_text);
    emit(PET_RETURN);
}

/* ---------------------------------------------------------------------------------------
 * Now-playing screen
 * ------------------------------------------------------------------------------------- */

/*
 * np_text -- write ASCII text into a row of the now-playing screen (clipped to the row).
 * Steps:
 *   1. Letters fold to upper case; characters without a screen code show as '?'.
 * Returns: nothing.
 */
static void np_text(uint32_t row, uint32_t col, const char *s, uint32_t max, uint8_t colour)
{
    for (uint32_t i = 0u; i < max && s[i] != '\0' && col + i < BASIC_COLS; i++) {
        uint8_t c = (uint8_t)s[i];
        uint8_t code;
        if (c >= 'a' && c <= 'z') {
            c = (uint8_t)(c - 0x20u);
        }
        if (!c64screen_petscii_to_code(c, &code)) {
            code = 0x3Fu;
        }
        c64screen_put(row, col + i, code, colour);
    }
}

/*
 * np_number -- two-digit (or longer) zero-padded decimal into a char buffer.
 * Returns: number of characters written (no NUL).
 */
static uint32_t np_number(char *out, uint32_t v)
{
    char tmp[BASIC_NUM_DIGITS];
    uint32_t n = 0u;
    uint32_t k = 0u;

    do {
        tmp[n++] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v != 0u && n < BASIC_NUM_DIGITS);
    if (n < 2u) {
        tmp[n++] = '0';
    }
    while (n > 0u) {
        out[k++] = tmp[--n];
    }
    return k;
}

/*
 * np_update -- refresh song number, time and the three voice bars.
 * Steps:
 *   1. SONG nn/mm; TIME mm:ss from player->elapsed_ms.
 *   2. Each voice bar is BASIC_BAR_CELLS cells: reverse spaces for level * cells / 255,
 *      plain spaces for the rest.
 * Returns: nothing.
 */
static void np_update(void)
{
    char buf[BASIC_COLS];
    uint32_t n;
    uint32_t secs = g_cfg.player->elapsed_ms() / BASIC_MS_PER_S;
    uint8_t level[BASIC_VOICES] = { 0u, 0u, 0u };

    n = np_number(buf, g_song);
    buf[n++] = '/';
    n += np_number(&buf[n], g_tune.songs);
    buf[n++] = ' ';
    buf[n] = '\0';
    np_text(NP_ROW_SONG, BASIC_FIELD_COL, buf, BASIC_FIELD_CELLS, C64SCREEN_BOOT_TEXT);
    n = np_number(buf, secs / BASIC_S_PER_MIN);
    buf[n++] = ':';
    n += np_number(&buf[n], secs % BASIC_S_PER_MIN);
    buf[n] = '\0';
    np_text(NP_ROW_TIME, BASIC_FIELD_COL, buf, BASIC_FIELD_CELLS, C64SCREEN_BOOT_TEXT);

    g_cfg.player->voice_levels(level);
    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        uint32_t cells = ((uint32_t)level[v] * BASIC_BAR_CELLS) / BASIC_LEVEL_MAX;
        for (uint32_t k = 0u; k < BASIC_BAR_CELLS; k++) {
            c64screen_put(NP_ROW_VOICE1 + v, BASIC_BAR_COL + k,
                          (k < cells) ? SCREEN_REVERSE_SPACE : C64SCREEN_SPACE,
                          g_bar_colour[v]);
        }
    }
}

/*
 * np_open -- replace the editor screen with the now-playing screen.
 * Steps:
 *   1. Save the editor screen and cursor; clear; hide the cursor.
 *   2. Write the static labels and the tune's name, author and released fields.
 * Returns: nothing.
 */
static void np_open(void)
{
    static const char *const labels[BASIC_VOICES] = { " VOICE 1", " VOICE 2", " VOICE 3" };

    c64screen_save(&g_saved_screen);
    g_saved_row = g_row;
    g_saved_col = g_col;
    g_saved_colour = g_colour;
    c64screen_clear(C64SCREEN_BOOT_TEXT);
    c64screen_cursor_enable(0);
    np_text(NP_ROW_TITLE, 0u, "    **** IRONKERNEL 64 SID PLAYER ****", BASIC_COLS,
            VIDEO_COL_WHITE);
    np_text(NP_ROW_NAME, 0u, " NAME", BASIC_COLS, C64SCREEN_BOOT_TEXT);
    np_text(NP_ROW_AUTHOR, 0u, " AUTHOR", BASIC_COLS, C64SCREEN_BOOT_TEXT);
    np_text(NP_ROW_RELEASED, 0u, " RELEASED", BASIC_COLS, C64SCREEN_BOOT_TEXT);
    np_text(NP_ROW_SONG, 0u, " SONG", BASIC_COLS, C64SCREEN_BOOT_TEXT);
    np_text(NP_ROW_TIME, 0u, " TIME", BASIC_COLS, C64SCREEN_BOOT_TEXT);
    for (uint32_t v = 0u; v < BASIC_VOICES; v++) {
        np_text(NP_ROW_VOICE1 + v, 0u, labels[v], BASIC_COLS, C64SCREEN_BOOT_TEXT);
    }
    np_text(NP_ROW_HELP, 0u, " +/- 1-9 SONG     RUN/STOP BREAK", BASIC_COLS,
            VIDEO_COL_LIGHT_GREY);
    np_text(NP_ROW_NAME, BASIC_FIELD_COL, g_tune.name, BASIC_FIELD_CELLS, VIDEO_COL_WHITE);
    np_text(NP_ROW_AUTHOR, BASIC_FIELD_COL, g_tune.author, BASIC_FIELD_CELLS, VIDEO_COL_WHITE);
    np_text(NP_ROW_RELEASED, BASIC_FIELD_COL, g_tune.released, BASIC_FIELD_CELLS,
            VIDEO_COL_WHITE);
    np_update();
}

/*
 * np_close -- RUN/STOP: stop the player, restore the editor screen, print BREAK / READY.
 * Returns: nothing.
 */
static void np_close(void)
{
    g_cfg.player->stop();
    c64screen_restore(&g_saved_screen);
    g_row = g_saved_row;
    g_col = g_saved_col;
    g_colour = g_saved_colour;
    g_state = BASIC_STATE_EDIT;
    keyboard_flush();
    if (g_col != 0u) {
        next_line();
    }
    put_text("BREAK\rREADY.\r");
    c64screen_cursor_enable(1);
}

/*
 * np_select -- switch to another song when it exists.
 * Returns: nothing.
 */
static void np_select(uint32_t song)
{
    if (song >= 1u && song <= g_tune.songs && g_cfg.player->select_song(song) == 0) {
        g_song = song;
    }
}

/*
 * np_poll -- one pass of the now-playing loop.
 * Steps:
 *   1. Serve the player (audio rendering).
 *   2. Keys: RUN/STOP closes, '+' / '-' step the song, '1'..'9' pick one.
 *   3. Refresh the changing fields.
 * Returns: nothing.
 */
static void np_poll(void)
{
    uint8_t k;

    g_cfg.player->service();
    for (uint32_t i = 0u; i < BASIC_KEYS_PER_POLL && keyboard_getkey(&k); i++) {
        if (k == KEYBOARD_KEY_RUN_STOP) {
            np_close();
            return;
        }
        if (k == '+') {
            np_select(g_song + 1u);
        } else if (k == '-') {
            np_select(g_song - 1u);
        } else if (k >= '1' && k <= '0' + BASIC_MAX_SONG_KEY) {
            np_select((uint32_t)(k - '0'));
        }
    }
    np_update();
}

/*
 * cmd_run -- RUN: start the SID player on a loaded PSID/RSID file.
 * Steps:
 *   1. Nothing loaded: nothing to do. Not a SID, or no player: ?FILE TYPE MISMATCH.
 *   2. player->start; a refusal prints its reason as a C64-style error.
 *   3. On success read the tune info and open the now-playing screen.
 * Returns: 1 when the player runs (no READY now), else 0.
 */
static int cmd_run(void)
{
    basic_player_reason_t why;

    if (g_load_len == 0u) {
        return 0;
    }
    if (!is_sid() || g_cfg.player == NULL) {
        print_error("FILE TYPE MISMATCH");
        return 0;
    }
    why = g_cfg.player->start(g_cfg.load_buf, g_load_len);
    switch (why) {
    case BASIC_PLAYER_OK:
        break;
    case BASIC_PLAYER_BAD_HEADER: print_error("FILE TYPE MISMATCH"); return 0;
    case BASIC_PLAYER_RSID:       print_error("RSID NOT SUPPORTED"); return 0;
    case BASIC_PLAYER_CIA_SPEED:  print_error("CIA SPEED NOT SUPPORTED"); return 0;
    case BASIC_PLAYER_NO_PLAY:    print_error("NO PLAY ADDRESS"); return 0;
    default:                      print_error("PLAYER"); return 0;
    }
    g_cfg.player->info(&g_tune);
    g_tune.name[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    g_tune.author[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    g_tune.released[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    g_song = (g_tune.start_song >= 1u) ? g_tune.start_song : 1u;
    g_state = BASIC_STATE_PLAYING;
    np_open();
    return 1;
}

/*
 * execute -- run the line just read by RETURN.
 * Steps:
 *   1. Empty line: nothing. Line number first: accepted silently (not stored).
 *   2. '@': DOS wedge. LOAD / LIST / RUN / NEW (full or abbreviated); other text:
 *      ?SYNTAX  ERROR.
 *   3. Print READY. unless the player took over.
 * Returns: nothing.
 */
static void execute(void)
{
    const uint8_t *s = g_line;
    uint32_t i = skip_spaces(s, 0u);
    uint32_t j;

    if (s[i] == 0u || (s[i] >= '0' && s[i] <= '9')) {
        return;
    }
    c64screen_cursor_enable(0);
    if (s[i] == '@') {
        wedge(s, i + 1u);
    } else if ((j = match_keyword(s, i, "LOAD")) != 0u) {
        cmd_load(s, j);
    } else if (match_keyword(s, i, "LIST") != 0u) {
        cmd_list();
    } else if (match_keyword(s, i, "RUN") != 0u) {
        if (cmd_run()) {
            return;
        }
    } else if (match_keyword(s, i, "NEW") != 0u) {
        g_load_len = 0u;
    } else {
        print_error("SYNTAX");
    }
    put_text("READY.\r");
    c64screen_cursor_enable(1);
}

/*
 * handle_key -- one key in the screen editor.
 * Steps:
 *   1. RETURN: read the logical line, go to the next line, execute.
 *   2. DEL / INST always edit; RUN/STOP does nothing in the editor.
 *   3. Everything else is emitted (control codes quoted in quote / insert mode).
 * Returns: nothing.
 */
static void handle_key(uint8_t k)
{
    switch (k) {
    case PET_RETURN:
        (void)read_line();
        next_line();
        execute();
        return;
    case KEYBOARD_KEY_DEL:
        delete_char();
        g_insert = 0u;
        return;
    case KEYBOARD_KEY_INST:
        insert_char();
        return;
    case KEYBOARD_KEY_RUN_STOP:
        return;
    default:
        emit(k);
        return;
    }
}

/* ---------------------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------------------- */

/*
 * append -- append a string to a bounded buffer.
 * Returns: the new length.
 */
static uint32_t append(char *buf, uint32_t n, uint32_t cap, const char *s)
{
    for (uint32_t i = 0u; s[i] != '\0' && n + 1u < cap; i++) {
        buf[n++] = s[i];
    }
    buf[n] = '\0';
    return n;
}

/*
 * append_u32 -- append a decimal number to a bounded buffer.
 * Returns: the new length.
 */
static uint32_t append_u32(char *buf, uint32_t n, uint32_t cap, uint32_t v)
{
    char digits[BASIC_NUM_DIGITS + 1u];
    uint32_t k = BASIC_NUM_DIGITS;

    digits[k] = '\0';
    do {
        digits[--k] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v != 0u && k > 0u);
    return append(buf, n, cap, &digits[k]);
}

/*
 * ram_line -- " <size> RAM SYSTEM  <free> BASIC BYTES FREE", BASIC dropped when too long.
 * Steps:
 *   1. Size in whole MiB as nnnM, else in KiB as nnnK.
 *   2. Build the line with BASIC; if longer than BASIC_RAM_LINE_MAX, build it without.
 * Returns: nothing; buf holds the line.
 */
static void ram_line(char *buf, uint32_t cap, uint32_t ram, uint32_t free_bytes)
{
    for (uint32_t pass = 0u; pass < 2u; pass++) {
        uint32_t n = append(buf, 0u, cap, " ");
        if (ram >= BASIC_MIB && (ram % BASIC_MIB) == 0u) {
            n = append_u32(buf, n, cap, ram / BASIC_MIB);
            n = append(buf, n, cap, "M");
        } else {
            n = append_u32(buf, n, cap, ram / BASIC_KIB);
            n = append(buf, n, cap, "K");
        }
        n = append(buf, n, cap, " RAM SYSTEM  ");
        n = append_u32(buf, n, cap, free_bytes);
        n = append(buf, n, cap, (pass == 0u) ? " BASIC BYTES FREE" : " BYTES FREE");
        if (n <= BASIC_RAM_LINE_MAX) {
            return;
        }
    }
}

/*
 * basic_init -- keep the configuration and draw the C64 boot screen.
 * Steps:
 *   1. Copy cfg; reset editor and load state.
 *   2. Boot colours and a clear screen (c64screen_init).
 *   3. Print the banner, the RAM line from cfg->mem_info, and READY.
 * Returns: nothing.
 */
void basic_init(const basic_config_t *cfg)
{
    char line[BASIC_COLS + 1u];
    uint32_t ram = 0u;
    uint32_t free_bytes = 0u;

    g_cfg = *cfg;
    if (g_cfg.load_buf == NULL || g_cfg.load_buf_bytes < BASIC_LOAD_MIN_BYTES) {
        g_cfg.load_buf_bytes = 0u;
    }
    g_state = BASIC_STATE_EDIT;
    g_load_len = 0u;
    g_row = 0u;
    g_col = 0u;
    g_rvs = 0;
    g_quote = 0;
    g_insert = 0u;
    c64screen_init();
    g_colour = C64SCREEN_BOOT_TEXT;
    if (g_cfg.mem_info != NULL) {
        g_cfg.mem_info(&ram, &free_bytes);
    }
    ram_line(line, sizeof(line), ram, free_bytes);
    put_text("\r    **** COMMODORE 64 BASIC V2 ****\r\r");
    put_text(line);
    put_text("\r\rREADY.\r");
    g_shown_row = BASIC_ROWS;
    c64screen_cursor_enable(1);
}

/*
 * basic_poll -- one pass of the shell (call from the main loop).
 * Steps:
 *   1. While the player runs: np_poll.
 *   2. Otherwise take up to BASIC_KEYS_PER_POLL keys into the editor.
 *   3. Move the drawn cursor when it moved (restarting its blink), then render.
 * Returns: nothing.
 */
void basic_poll(void)
{
    uint8_t k;

    if (g_state == BASIC_STATE_PLAYING) {
        np_poll();
    } else {
        for (uint32_t i = 0u; i < BASIC_KEYS_PER_POLL && keyboard_getkey(&k); i++) {
            handle_key(k);
            if (g_state == BASIC_STATE_PLAYING) {
                break;
            }
        }
    }
    if (g_row != g_shown_row || g_col != g_shown_col) {
        c64screen_set_cursor(g_row, g_col);
        g_shown_row = g_row;
        g_shown_col = g_col;
    }
    (void)c64screen_render();
}

/*
 * basic_playing -- the now-playing screen is up.
 * Returns: 1 or 0.
 */
int basic_playing(void)
{
    return (g_state == BASIC_STATE_PLAYING) ? 1 : 0;
}
