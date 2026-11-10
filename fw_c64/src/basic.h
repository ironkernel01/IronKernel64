/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: basic.h
 * Role: the C64 screen editor and command shell of core 0: boot screen, full-screen line
 *   editing with RETURN reading the logical line under the cursor, the commands
 *   LOAD / LIST / RUN / NEW, the DOS wedge (@, @$, @CD:...) and the now-playing screen.
 *
 * Hardware: none directly. Text goes through c64screen.h, keys come from keyboard.h, the
 *   drive is reached through drive_client.h. The SID player is reached only through the
 *   basic_player_ops_t callbacks, so this module does not depend on the SID code.
 *
 * Contract:
 *   - basic_init() draws the boot screen (border 14, background 6, text 14):
 *         **** IRONKERNEL 64 BASIC V2 ****
 *      512M RAM SYSTEM  402653184 BYTES FREE
 *     READY.
 *     The size is cfg->mem_info's RAM size as nnnM (whole MiB) or nnnK; the word BASIC is
 *     dropped when the line would not fit in 39 columns.
 *   - basic_poll() is called from the main loop: it takes queued keys, edits the screen,
 *     runs a command on RETURN (commands block until done; a drive request is bounded by
 *     drive_client's timeouts), serves the player while the now-playing screen is up, and
 *     renders the text layer. The caller runs keyboard_poll() itself (it owns the CLI
 *     toggle).
 *   - Loaded files live in cfg->load_buf (cfg->load_buf_bytes, at least
 *     BASIC_LOAD_MIN_BYTES); a file that does not fit gives ?OUT OF MEMORY  ERROR.
 *   - RUN on a file starting with "PSID" or "RSID" calls player->start(file, len); any
 *     other file gives ?FILE TYPE MISMATCH  ERROR. While playing, '+' / '-' / '1'..'9'
 *     select songs and RUN/STOP calls player->stop() and prints BREAK and READY.
 *   - Deviations from a real C64 (no BASIC interpreter here): a line that starts with a
 *     line number is accepted silently and not stored; LOAD without a device number uses
 *     device 8 (no tape); text after LOAD's device / secondary address is ignored, so a
 *     directory line edited into LOAD"NAME",8 works even with the rest of the old line
 *     still on screen; LIST ignores line ranges; LIST of a SID file prints nothing.
 *   - UART mirror (cfg->uart_out, called once per ASCII byte; main.c wires it to the BSP's
 *     outbyte()): everything printed on the screen is also sent as ASCII, in keyboard and CLI
 *     mode alike. PETSCII letters/digits/punctuation map to ASCII (case follows the current
 *     character set); graphics without an ASCII equivalent become '?', pound '#', pi '~'.
 *     RETURN -> CR LF, DEL -> BS SP BS, CLR -> CR LF, colour / reverse / cursor / home /
 *     insert codes -> nothing. When a line was edited with cursor, home, insert or delete
 *     keys, RETURN first sends CR LF and the logical line as executed. The now-playing
 *     screen sends NAME / AUTHOR / RELEASED / SONG nn/mm on open and on song change, and
 *     "\rTIME mm:ss" whenever the shown time changes (no voice bars); closing ends the line
 *     with CR LF before BREAK / READY.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef BASIC_H
#define BASIC_H

#include <stdint.h> /* uint8_t, uint32_t */

#define BASIC_TUNE_TEXT_BYTES  (33u)     /* PSID name / author / released: 32 chars + NUL */
#define BASIC_VOICES           (3u)
#define BASIC_LOAD_MIN_BYTES   (256u)

/* Why the player refused a file (printed as a C64-style error). */
typedef enum
{
    BASIC_PLAYER_OK = 0,
    BASIC_PLAYER_BAD_HEADER,   /* not a valid PSID header */
    BASIC_PLAYER_RSID,         /* RSID (needs a full C64 environment) */
    BASIC_PLAYER_NO_PLAY,      /* play address 0 */
    BASIC_PLAYER_ERROR         /* anything else */
} basic_player_reason_t;

typedef struct
{
    char     name[BASIC_TUNE_TEXT_BYTES];      /* ASCII/PETSCII, NUL-terminated */
    char     author[BASIC_TUNE_TEXT_BYTES];
    char     released[BASIC_TUNE_TEXT_BYTES];
    uint32_t songs;                            /* 1..256 */
    uint32_t start_song;                       /* 1-based */
} basic_tune_info_t;

/* Player interface, implemented outside this module (wired by main.c). */
typedef struct
{
    basic_player_reason_t (*start)(const uint8_t *file, uint32_t len); /* basic_player_start */
    void     (*info)(basic_tune_info_t *info);          /* after a successful start */
    int      (*select_song)(uint32_t song);             /* 1-based; 0 = OK */
    void     (*service)(void);                          /* render/push audio, every poll */
    uint32_t (*elapsed_ms)(void);                       /* since the current song started */
    void     (*voice_levels)(uint8_t level[BASIC_VOICES]); /* envelope 0..255 per voice */
    void     (*stop)(void);
} basic_player_ops_t;

typedef struct
{
    void (*mem_info)(uint32_t *ram_bytes, uint32_t *free_bytes); /* probed DDR3 size, free */
    const basic_player_ops_t *player;  /* NULL: RUN on a SID gives ?FILE TYPE MISMATCH */
    uint8_t  *load_buf;                /* LOAD target (caller-owned, static) */
    uint32_t  load_buf_bytes;
    void (*uart_out)(char c);          /* ASCII mirror of the screen; NULL = off */
} basic_config_t;

void basic_init(const basic_config_t *cfg);
void basic_poll(void);
int  basic_playing(void);

#endif /* BASIC_H */
