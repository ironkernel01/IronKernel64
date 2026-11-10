/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cbmdos.c
 * Role: CBM DOS emulation over backend.h; contract and scope in cbmdos.h.
 *
 * Directory image (1541 format, load address $0401): bytes 0..1 are the load
 *   address; every line is link(2) number(2) text NUL; the link of a line is
 *   the C64 address of the next line, so the byte at image index i has address
 *   $03FF + i; two zero bytes end the program.
 */
#include "cbmdos.h"

#include <stdio.h>   /* snprintf (log info text) */

#define CBMDOS_NAME_CHARS        (16u)
#define CBMDOS_BLOCK_BYTES       (254u)
#define CBMDOS_BLOCKS_MAX        (65535u)
#define CBMDOS_PATTERN_BYTES     (128u)
#define CBMDOS_LOAD_ADDR         (0x0401u)
#define CBMDOS_ADDR_BIAS         (0x03FFu)   /* address of image byte i = bias + i */
#define CBMDOS_LINE_TEXT_MAX     (40u)
#define CBMDOS_FOOTER_BYTES      (32u)       /* blocks-free line (30) + end marker (2) */
#define CBMDOS_INFO_BYTES        (96u)
#define CBMDOS_INFO_NAME_MAX     (48u)

typedef enum
{
    CH_CLOSED = 0,
    CH_DIR,
    CH_FILE
} ch_kind_t;

static const backend_ops_t *g_ops;
static uint8_t  g_dir[CBMDOS_DIR_BYTES];
static uint32_t g_dir_len;
static ch_kind_t g_kind;
static uint8_t  g_channel;
static uint32_t g_dir_pos;
static int      g_file_open;            /* backend handle g_fh is live */
static int      g_file_done;            /* EOF delivered */
static backend_file_t g_fh;
static uint8_t  g_status;
static int      g_lost;
static char     g_info[CBMDOS_INFO_BYTES];

/*
 * cbmdos_init -- select the backend and clear all state.
 * Returns: nothing.
 */
void cbmdos_init(const backend_ops_t *ops)
{
    g_ops = ops;
    g_kind = CH_CLOSED;
    g_file_open = 0;
    g_file_done = 0;
    g_status = CBMDOS_OK;
    g_lost = 0;
    g_info[0] = '\0';
}

/*
 * cbmdos_abort -- forget the open channel without calling the backend (its
 *   unmount closes the handles).
 * Returns: nothing.
 */
void cbmdos_abort(void)
{
    g_kind = CH_CLOSED;
    g_file_open = 0;
}

/*
 * note_backend -- map a backend status to a DOS status and raise "lost" for
 *   the failures that drop the session.
 * Returns: CBMDOS_FILE_NOT_FOUND for NOT_FOUND, CBMDOS_NOT_READY otherwise.
 */
static uint8_t note_backend(backend_status_t st)
{
    if (st == BACKEND_ERR_NOT_READY || st == BACKEND_ERR_IO || st == BACKEND_ERR_AUTH) {
        g_lost = 1;
    }
    return (st == BACKEND_ERR_NOT_FOUND) ? CBMDOS_FILE_NOT_FOUND : CBMDOS_NOT_READY;
}

/*
 * pet_upper -- fold a typed PETSCII name character to unshifted upper case.
 * Returns: the character ('a'-'z' and the shifted letters $C1-$DA become 'A'-'Z').
 */
static uint8_t pet_upper(uint8_t c)
{
    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - 32u);
    }
    if (c >= 0xC1u && c <= 0xDAu) {
        return (uint8_t)(c - 0x80u);
    }
    return c;
}

/*
 * share_to_pet -- map one share-name byte to PETSCII upper case.
 * Returns: the character; quotes, controls and bytes above '~' become '?'.
 */
static uint8_t share_to_pet(char ch)
{
    const uint8_t c = (uint8_t)ch;

    if (c >= 'a' && c <= 'z') {
        return (uint8_t)(c - 32u);
    }
    if (c == '"' || c < 0x20u || c > 0x7Eu) {
        return (uint8_t)'?';
    }
    return c;
}

/*
 * map_name -- share name to at most 16 PETSCII characters.
 * Returns: the number of characters written to out.
 */
static uint32_t map_name(const char *name, uint8_t *out)
{
    uint32_t n = 0u;

    while (name[n] != '\0' && n < CBMDOS_NAME_CHARS) {
        out[n] = share_to_pet(name[n]);
        n++;
    }
    return n;
}

static uint8_t fold(uint8_t c)
{
    return (c == (uint8_t)'_') ? (uint8_t)' ' : c;
}

/*
 * wild_match -- CBM wildcard match: '?' is one character, '*' ends the
 *   pattern and matches the rest.
 * Returns: 1 when the pattern matches the n-character name.
 */
static int wild_match(const uint8_t *pat, const uint8_t *name, uint32_t n)
{
    uint32_t i = 0u;

    for (;; pat++) {
        if (*pat == (uint8_t)'*') {
            return 1;
        }
        if (*pat == 0u) {
            return (i == n) ? 1 : 0;
        }
        if (i == n) {
            return 0;
        }
        if (*pat != (uint8_t)'?' && fold(*pat) != fold(name[i])) {
            return 0;
        }
        i++;
    }
}

/*
 * parse_name -- split an OPEN name into the directory flag and a pattern.
 * Steps:
 *   1. "$" starts a directory request: an optional drive digit and ':' follow.
 *      Otherwise an optional "d:" prefix is dropped.
 *   2. Copy the pattern up to ',' or the end, folding letters to upper case.
 *   3. An empty directory pattern is "*".
 * Returns: 1 for a directory request, 0 for a file.
 */
static int parse_name(const char *raw, uint8_t *pat)
{
    const char *s = raw;
    uint32_t n = 0u;
    int dir = 0;

    if (s[0] == '$') {
        dir = 1;
        s++;
        if (s[0] >= '0' && s[0] <= '9' && (s[1] == ':' || s[1] == '\0')) {
            s++;
        }
        if (s[0] == ':') {
            s++;
        }
    } else if (s[0] >= '0' && s[0] <= '9' && s[1] == ':') {
        s += 2;
    }
    while (*s != '\0' && *s != ',' && n < CBMDOS_PATTERN_BYTES - 1u) {
        pat[n++] = pet_upper((uint8_t)*s++);
    }
    if (dir && n == 0u) {
        pat[n++] = (uint8_t)'*';
    }
    pat[n] = 0u;
    return dir;
}

/* Put a 16-bit little-endian value at image index i. */
static void put16(uint32_t i, uint32_t v)
{
    g_dir[i] = (uint8_t)v;
    g_dir[i + 1u] = (uint8_t)(v >> 8);
}

/*
 * dir_line -- append one directory line (link, number, text, NUL).
 * Returns: nothing.
 */
static void dir_line(uint32_t number, const uint8_t *text, uint32_t n)
{
    const uint32_t s = g_dir_len;
    const uint32_t next = s + 4u + n + 1u;

    put16(s, CBMDOS_ADDR_BIAS + next);
    put16(s + 2u, number);
    for (uint32_t i = 0u; i < n; i++) {
        g_dir[s + 4u + i] = text[i];
    }
    g_dir[s + 4u + n] = 0u;
    g_dir_len = next;
}

/*
 * dir_entry -- append the line of one file or directory.
 * Text: blocks-dependent spaces (3, 2, 1, 0 for 1, 2, 3, 4+ digits), the name
 *   in quotes (closing quote right after the name), spaces up to the type
 *   column, the 3-character type and two spaces.
 * Returns: nothing.
 */
static void dir_entry(const backend_dirent_t *e)
{
    uint8_t t[CBMDOS_LINE_TEXT_MAX];
    uint8_t nm[CBMDOS_NAME_CHARS];
    const uint32_t nlen = map_name(e->name, nm);
    const uint64_t blocks64 = (e->type == BACKEND_ENT_DIR) ? 0u
                              : (e->size + CBMDOS_BLOCK_BYTES - 1u) / CBMDOS_BLOCK_BYTES;
    const uint32_t blocks = (blocks64 > CBMDOS_BLOCKS_MAX) ? CBMDOS_BLOCKS_MAX : (uint32_t)blocks64;
    const char *type = (e->type == BACKEND_ENT_DIR) ? "DIR" : "PRG";
    uint32_t n = 0u;
    uint32_t sp = (blocks < 10u) ? 3u : (blocks < 100u) ? 2u : (blocks < 1000u) ? 1u : 0u;

    while (sp-- > 0u) {
        t[n++] = (uint8_t)' ';
    }
    t[n++] = (uint8_t)'"';
    for (uint32_t i = 0u; i < nlen; i++) {
        t[n++] = nm[i];
    }
    t[n++] = (uint8_t)'"';
    for (uint32_t i = nlen; i < CBMDOS_NAME_CHARS + 1u; i++) {
        t[n++] = (uint8_t)' ';
    }
    for (uint32_t i = 0u; i < 3u; i++) {
        t[n++] = (uint8_t)type[i];
    }
    t[n++] = (uint8_t)' ';
    t[n++] = (uint8_t)' ';
    dir_line(blocks, t, n);
}

/*
 * dir_build -- build the directory program for a pattern.
 * Steps:
 *   1. Load address, header line (reverse "IRONKERNEL NET  " 64 2A).
 *   2. opendir "" and readdir to the end; files and directories whose
 *      truncated PETSCII name matches become lines while the footer still fits.
 *   3. Footer "BLOCKS FREE." (a failed free-space query shows 0) and the two
 *      zero bytes that end the program.
 * Returns: CBMDOS_OK, or the mapped backend failure.
 */
static uint8_t dir_build(const uint8_t *pat)
{
    static const char hdr[] = "\x12\"IRONKERNEL NET  \" 64 2A";
    static const char foot[] = "BLOCKS FREE.             ";
    uint8_t t[CBMDOS_LINE_TEXT_MAX];
    backend_dirent_t ent;
    backend_status_t st;
    uint64_t freeb = 0u;
    uint32_t n;
    uint32_t free_blocks;

    g_dir[0] = (uint8_t)CBMDOS_LOAD_ADDR;
    g_dir[1] = (uint8_t)(CBMDOS_LOAD_ADDR >> 8);
    g_dir_len = 2u;
    for (n = 0u; hdr[n] != '\0'; n++) {
        t[n] = (uint8_t)hdr[n];
    }
    dir_line(0u, t, n);

    st = g_ops->opendir("");
    if (st != BACKEND_OK) {
        return note_backend(st);
    }
    for (;;) {
        uint8_t nm[CBMDOS_NAME_CHARS];
        uint32_t nlen;

        st = g_ops->readdir(&ent);
        if (st == BACKEND_END) {
            break;
        }
        if (st != BACKEND_OK) {
            (void)g_ops->closedir();
            return note_backend(st);
        }
        if (ent.type == BACKEND_ENT_OTHER) {
            continue;
        }
        nlen = map_name(ent.name, nm);
        if (wild_match(pat, nm, nlen) &&
            g_dir_len + CBMDOS_LINE_TEXT_MAX + 5u + CBMDOS_FOOTER_BYTES <= CBMDOS_DIR_BYTES) {
            dir_entry(&ent);
        }
    }
    (void)g_ops->closedir();

    if (g_ops->free_bytes(&freeb) != BACKEND_OK) {
        freeb = 0u;
    }
    free_blocks = ((freeb / CBMDOS_BLOCK_BYTES) > CBMDOS_BLOCKS_MAX)
                      ? CBMDOS_BLOCKS_MAX : (uint32_t)(freeb / CBMDOS_BLOCK_BYTES);
    for (n = 0u; foot[n] != '\0'; n++) {
        t[n] = (uint8_t)foot[n];
    }
    dir_line(free_blocks, t, n);
    g_dir[g_dir_len++] = 0u;
    g_dir[g_dir_len++] = 0u;
    return CBMDOS_OK;
}

/*
 * info_set -- the one-line description of the last OPEN, for the log
 *   (printable ASCII only).
 * Returns: nothing.
 */
static void info_set(const char *name, uint64_t size)
{
    char clean[CBMDOS_INFO_NAME_MAX + 1u];
    uint32_t i;

    for (i = 0u; name[i] != '\0' && i < CBMDOS_INFO_NAME_MAX; i++) {
        clean[i] = (name[i] >= 0x20 && name[i] < 0x7F) ? name[i] : '?';
    }
    clean[i] = '\0';
    (void)snprintf(g_info, sizeof(g_info), "%s %lu B", clean, (unsigned long)size);
}

/*
 * file_open -- open the first regular file whose name matches the pattern.
 * Steps:
 *   1. opendir "" / readdir until a regular file matches; closedir.
 *   2. No match: 62. Otherwise backend open of that native name.
 * Returns: CBMDOS_OK, FILE_NOT_FOUND or NOT_READY.
 */
static uint8_t file_open(const uint8_t *pat)
{
    backend_dirent_t ent;
    backend_status_t st;
    uint64_t size = 0u;
    int found = 0;

    st = g_ops->opendir("");
    if (st != BACKEND_OK) {
        return note_backend(st);
    }
    for (;;) {
        uint8_t nm[CBMDOS_NAME_CHARS];
        uint32_t nlen;

        st = g_ops->readdir(&ent);
        if (st == BACKEND_END) {
            break;
        }
        if (st != BACKEND_OK) {
            (void)g_ops->closedir();
            return note_backend(st);
        }
        nlen = map_name(ent.name, nm);
        if (ent.type == BACKEND_ENT_FILE && wild_match(pat, nm, nlen)) {
            found = 1;
            break;
        }
    }
    (void)g_ops->closedir();
    if (!found) {
        return CBMDOS_FILE_NOT_FOUND;
    }
    st = g_ops->open(ent.name, &g_fh, &size);
    if (st != BACKEND_OK) {
        return note_backend(st);
    }
    g_file_open = 1;
    g_file_done = 0;
    info_set(ent.name, size);
    return CBMDOS_OK;
}

/*
 * close_channel -- drop the open channel (backend close errors are ignored).
 * Returns: nothing.
 */
static void close_channel(void)
{
    if (g_file_open) {
        (void)g_ops->close(g_fh);
        g_file_open = 0;
    }
    g_kind = CH_CLOSED;
}

/*
 * cbmdos_open -- OPEN a channel by name.
 * Steps:
 *   1. Channel 15 is a command; channel 1 (write) is refused; >15 is 70.
 *   2. Close the previous channel, parse the name.
 *   3. "$": build the directory image; else open the first matching file.
 * Returns: the DOS status (also kept for STATUS); cbmdos_info() describes it.
 */
uint8_t cbmdos_open(uint8_t channel, const char *name)
{
    uint8_t pat[CBMDOS_PATTERN_BYTES];
    uint8_t st;

    g_info[0] = '\0';
    if (channel == 15u) {
        return cbmdos_cmd(name);
    }
    if (channel > 15u) {
        g_status = CBMDOS_NO_CHANNEL;
        return g_status;
    }
    if (channel == 1u) {
        g_status = CBMDOS_WRITE_PROTECT;
        return g_status;
    }
    close_channel();
    if (parse_name(name, pat)) {
        st = dir_build(pat);
        if (st == CBMDOS_OK) {
            g_kind = CH_DIR;
            g_dir_pos = 0u;
            (void)snprintf(g_info, sizeof(g_info), "$ directory %lu B", (unsigned long)g_dir_len);
        }
    } else {
        st = file_open(pat);
        if (st == CBMDOS_OK) {
            g_kind = CH_FILE;
        }
    }
    if (st == CBMDOS_OK) {
        g_channel = channel;
    }
    g_status = st;
    return st;
}

/*
 * cbmdos_read -- up to want bytes from the open channel.
 * Steps:
 *   1. Wrong or closed channel: 70.
 *   2. Directory: copy from the image; EOI with the last byte.
 *   3. File: one backend read; EOI when the backend reports the end, then the
 *      backend handle is closed; later reads return 0 bytes with EOI.
 * Returns: the DOS status (OK leaves the kept status unchanged).
 */
uint8_t cbmdos_read(uint8_t channel, uint8_t *out, uint32_t want, uint32_t *got, int *eoi)
{
    backend_status_t st;
    int eof = 0;
    uint32_t n = 0u;

    *got = 0u;
    *eoi = 0;
    if (g_kind == CH_CLOSED || channel != g_channel) {
        g_status = CBMDOS_NO_CHANNEL;
        return g_status;
    }
    if (g_kind == CH_DIR) {
        n = g_dir_len - g_dir_pos;
        if (n > want) {
            n = want;
        }
        for (uint32_t i = 0u; i < n; i++) {
            out[i] = g_dir[g_dir_pos + i];
        }
        g_dir_pos += n;
        *got = n;
        *eoi = (g_dir_pos == g_dir_len) ? 1 : 0;
        return CBMDOS_OK;
    }
    if (g_file_done) {
        *eoi = 1;
        return CBMDOS_OK;
    }
    st = g_ops->read(g_fh, out, want, &n, &eof);
    if (st != BACKEND_OK || (n == 0u && !eof)) {
        g_status = (st != BACKEND_OK) ? note_backend(st) : CBMDOS_NOT_READY;
        return g_status;
    }
    *got = n;
    if (eof) {
        *eoi = 1;
        g_file_done = 1;
        (void)g_ops->close(g_fh);
        g_file_open = 0;
    }
    return CBMDOS_OK;
}

/*
 * cbmdos_close -- CLOSE a channel (closing one that is not open is not an error).
 * Returns: CBMDOS_OK.
 */
uint8_t cbmdos_close(uint8_t channel)
{
    if (g_kind != CH_CLOSED && channel == g_channel) {
        close_channel();
    }
    return CBMDOS_OK;
}

/*
 * cbmdos_cmd -- DOS command: none implemented yet.
 * Returns: CBMDOS_SYNTAX.
 */
uint8_t cbmdos_cmd(const char *text)
{
    (void)text;
    g_status = CBMDOS_SYNTAX;
    return g_status;
}

/*
 * cbmdos_take_status -- the error channel: the kept status, then reset to OK.
 * Returns: the DOS status.
 */
uint8_t cbmdos_take_status(void)
{
    const uint8_t s = g_status;

    g_status = CBMDOS_OK;
    return s;
}

/*
 * cbmdos_text -- the status line of a DOS code ("62,FILE NOT FOUND,00,00").
 * Returns: a constant string.
 */
const char *cbmdos_text(uint8_t status)
{
    switch (status) {
    case CBMDOS_OK:             return "00, OK,00,00";
    case CBMDOS_WRITE_PROTECT:  return "26,WRITE PROTECT ON,00,00";
    case CBMDOS_SYNTAX:         return "31,SYNTAX ERROR,00,00";
    case CBMDOS_FILE_NOT_FOUND: return "62,FILE NOT FOUND,00,00";
    case CBMDOS_NO_CHANNEL:     return "70,NO CHANNEL,00,00";
    default:                    return "74,DRIVE NOT READY,00,00";
    }
}

/*
 * cbmdos_info -- description of the last OPEN ("Sid_Factory.sid 4646 B"), "" when none.
 * Returns: a NUL-terminated string valid until the next OPEN.
 */
const char *cbmdos_info(void)
{
    return g_info;
}

/*
 * cbmdos_take_backend_lost -- has a backend call failed in a way that drops the session?
 * Returns: 1 once per failure, then 0.
 */
int cbmdos_take_backend_lost(void)
{
    const int l = g_lost;

    g_lost = 0;
    return l;
}
