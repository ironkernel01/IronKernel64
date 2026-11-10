/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * cbmdos_host_test.c -- builds fw_1541/src/cbmdos.c against a fake backend and
 * checks the 1541 directory bytes, wildcards, chunked READ with EOI, status
 * handling and backend failure.
 *
 * Build and run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -Werror -DIK64_BACKEND_RAM -Ifw_1541/src \
 *       tools/cbmdos_host_test.c fw_1541/src/cbmdos.c -o build/cbmdos_host_test.exe
 *   build/cbmdos_host_test.exe [+INJECT_FAILURE]
 * Prints "TEST PASS: cbmdos_host" or "TEST FAIL" (exit 1).
 */
#include "cbmdos.h"

#include <stdio.h>
#include <string.h>

typedef struct
{
    const char *name;
    uint64_t    size;
    backend_ent_type_t type;
} fake_ent_t;

static const fake_ent_t g_set_two[] = {
    { "Another.sid",     3512u, BACKEND_ENT_FILE },
    { "Sid_Factory.sid", 4646u, BACKEND_ENT_FILE },
};
static const fake_ent_t g_set_long[] = {
    { "a_very_long_filename.prg", 100u, BACKEND_ENT_FILE },
    { "Games",                    0u,   BACKEND_ENT_DIR },
    { "link.lnk",                 5u,   BACKEND_ENT_OTHER },
};

static const fake_ent_t *g_set = g_set_two;
static unsigned g_set_n = 2u;
static unsigned g_dir_idx;
static unsigned g_open_idx;
static uint64_t g_pos;
static int g_fail;               /* backend returns NOT_READY */
static int g_checks;
static int g_errors;

static uint8_t fake_byte(uint64_t i)
{
    return (uint8_t)((i * 7u + 3u) & 0xFFu);
}

backend_status_t backend_fake_init(void) { return BACKEND_OK; }
backend_status_t backend_fake_mount(void) { return BACKEND_OK; }
backend_status_t backend_fake_unmount(void) { return BACKEND_OK; }
backend_status_t backend_fake_opendir(const char *path)
{
    (void)path;
    g_dir_idx = 0u;
    return g_fail ? BACKEND_ERR_NOT_READY : BACKEND_OK;
}
backend_status_t backend_fake_readdir(backend_dirent_t *ent)
{
    if (g_dir_idx >= g_set_n) {
        return BACKEND_END;
    }
    memset(ent, 0, sizeof(*ent));
    strcpy(ent->name, g_set[g_dir_idx].name);
    ent->size = g_set[g_dir_idx].size;
    ent->type = g_set[g_dir_idx].type;
    g_dir_idx++;
    return BACKEND_OK;
}
backend_status_t backend_fake_closedir(void) { return BACKEND_OK; }
backend_status_t backend_fake_open(const char *path, backend_file_t *fh, uint64_t *size)
{
    for (unsigned i = 0u; i < g_set_n; i++) {
        if (strcmp(path, g_set[i].name) == 0) {
            g_open_idx = i;
            g_pos = 0u;
            *fh = 0u;
            *size = g_set[i].size;
            return BACKEND_OK;
        }
    }
    return BACKEND_ERR_NOT_FOUND;
}
backend_status_t backend_fake_read(backend_file_t fh, uint8_t *buf, uint32_t max, uint32_t *got, int *eof)
{
    const uint64_t size = g_set[g_open_idx].size;
    uint64_t n = size - g_pos;

    (void)fh;
    if (n > max) {
        n = max;
    }
    for (uint64_t i = 0u; i < n; i++) {
        buf[i] = fake_byte(g_pos + i);
    }
    g_pos += n;
    *got = (uint32_t)n;
    *eof = (g_pos == size) ? 1 : 0;
    return BACKEND_OK;
}
backend_status_t backend_fake_close(backend_file_t fh) { (void)fh; return BACKEND_OK; }
backend_status_t backend_fake_free_bytes(uint64_t *bytes) { *bytes = 1000000u; return BACKEND_OK; }
backend_status_t backend_fake_status_text(char *buf, size_t n) { (void)snprintf(buf, n, "OK"); return BACKEND_OK; }

static const backend_ops_t g_ops = BACKEND_OPS(fake);

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_errors++;
        printf("  CHECK FAILED: %s\n", what);
    }
}

/* Read the open channel to the end in chunks; EOI must come with the last chunk only. */
static uint32_t read_all(uint8_t ch, uint8_t *out, uint32_t cap, uint32_t chunk, int *eoi_ok)
{
    uint32_t total = 0u;
    int eoi = 0;

    *eoi_ok = 1;
    for (unsigned guard = 0u; guard < 100000u && !eoi; guard++) {
        uint32_t got = 0u;
        uint8_t st = cbmdos_read(ch, out + total, (cap - total < chunk) ? cap - total : chunk, &got, &eoi);

        if (st != CBMDOS_OK) {
            *eoi_ok = 0;
            return total;
        }
        total += got;
    }
    if (!eoi) {
        *eoi_ok = 0;
    }
    return total;
}

static void use_set(const fake_ent_t *set, unsigned n)
{
    g_set = set;
    g_set_n = n;
}

int main(int argc, char **argv)
{
    /* Hand-derived 1541 directory program for the two-file set, 1,000,000 bytes free.
     * Address of image byte i is $03FF + i; line = link(2) number(2) text NUL.
     *   header  idx 2   30 bytes -> next idx 32  -> link $041F
     *   file 1  idx 32  31 bytes -> next idx 63  -> link $043E, 14 blocks (ceil(3512/254))
     *   file 2  idx 63  31 bytes -> next idx 94  -> link $045D, 19 blocks (ceil(4646/254))
     *   footer  idx 94  30 bytes -> next idx 124 -> link $047B, 3937 blocks (1000000/254)
     *   end     idx 124 00 00 */
    static const uint8_t expect[] = {
        0x01, 0x04,
        0x1F, 0x04, 0x00, 0x00, 0x12, 0x22,
        'I', 'R', 'O', 'N', 'K', 'E', 'R', 'N', 'E', 'L', ' ', 'N', 'E', 'T', ' ', ' ',
        0x22, 0x20, '6', '4', 0x20, '2', 'A', 0x00,
        0x3E, 0x04, 0x0E, 0x00, 0x20, 0x20, 0x22,
        'A', 'N', 'O', 'T', 'H', 'E', 'R', '.', 'S', 'I', 'D',
        0x22, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 'P', 'R', 'G', 0x20, 0x20, 0x00,
        0x5D, 0x04, 0x13, 0x00, 0x20, 0x20, 0x22,
        'S', 'I', 'D', '_', 'F', 'A', 'C', 'T', 'O', 'R', 'Y', '.', 'S', 'I', 'D',
        0x22, 0x20, 0x20, 'P', 'R', 'G', 0x20, 0x20, 0x00,
        0x7B, 0x04, 0x61, 0x0F,
        'B', 'L', 'O', 'C', 'K', 'S', ' ', 'F', 'R', 'E', 'E', '.',
        0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00,
        0x00, 0x00
    };
    static uint8_t buf[CBMDOS_DIR_BYTES];
    uint8_t exp[sizeof(expect)];
    uint32_t n;
    int eoi_ok;
    int inject = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            inject = 1;
        }
    }
    memcpy(exp, expect, sizeof(exp));
    if (inject) {
        exp[10] ^= 0x01u;
    }

    cbmdos_init(&g_ops);

    /* 1. "$" byte by byte, read in 7-byte chunks. */
    check(cbmdos_open(0u, "$") == CBMDOS_OK, "open $");
    n = read_all(0u, buf, sizeof(buf), 7u, &eoi_ok);
    check(eoi_ok, "$ EOI only on the last chunk");
    check(n == sizeof(exp), "$ length 126");
    check(n == sizeof(exp) && memcmp(buf, exp, sizeof(exp)) == 0, "$ bytes");
    check(cbmdos_close(0u) == CBMDOS_OK, "close $");

    /* 2. "$" with a pattern and the "0:" forms. */
    check(cbmdos_open(0u, "$:SID*") == CBMDOS_OK, "open $:SID*");
    n = read_all(0u, buf, sizeof(buf), 1000u, &eoi_ok);
    check(n == 95u && buf[2 + 30 + 4] == 0x20, "$:SID* has the header, one file and the footer");
    check(cbmdos_open(0u, "$0") == CBMDOS_OK, "open $0");
    n = read_all(0u, buf, sizeof(buf), 1000u, &eoi_ok);
    check(n == sizeof(exp), "$0 lists everything");
    check(cbmdos_open(0u, "$0:X*") == CBMDOS_OK, "open $0:X*");
    n = read_all(0u, buf, sizeof(buf), 1000u, &eoi_ok);
    check(n == 2u + 30u + 30u + 2u, "$0:X* has no file lines");

    /* 3. LOAD by wildcard. */
    check(cbmdos_open(0u, "SID F*") == CBMDOS_OK, "SID F* opens");
    check(strcmp(cbmdos_info(), "Sid_Factory.sid 4646 B") == 0, "info of SID F*");
    n = read_all(0u, buf, sizeof(buf), 1000u, &eoi_ok);
    check(eoi_ok && n == 4646u, "SID F* reads 4646 bytes, EOI on the last chunk");
    {
        int same = 1;
        for (uint32_t i = 0u; i < n; i++) {
            if (buf[i] != fake_byte(i)) {
                same = 0;
            }
        }
        check(same, "SID F* data");
    }
    check(cbmdos_close(0u) == CBMDOS_OK, "close");

    check(cbmdos_open(0u, "*") == CBMDOS_OK, "* opens");
    check(strcmp(cbmdos_info(), "Another.sid 3512 B") == 0, "* is the first file");
    n = read_all(0u, buf, sizeof(buf), 61440u, &eoi_ok);
    check(eoi_ok && n == 3512u, "* reads 3512 bytes");
    check(cbmdos_close(0u) == CBMDOS_OK, "close *");

    check(cbmdos_open(0u, "X*") == CBMDOS_FILE_NOT_FOUND, "X* is 62");
    check(strcmp(cbmdos_text(cbmdos_take_status()), "62,FILE NOT FOUND,00,00") == 0, "status line 62");
    check(strcmp(cbmdos_text(cbmdos_take_status()), "00, OK,00,00") == 0, "status resets to OK");
    check(cbmdos_open(0u, "sid f*") == CBMDOS_OK, "lowercase pattern");
    check(cbmdos_open(0u, "SID?FACTORY.SID,P,R") == CBMDOS_OK, "? and ,P,R suffix");
    check(cbmdos_open(0u, "SID F") == CBMDOS_FILE_NOT_FOUND, "prefix without * does not match");
    check(cbmdos_open(0u, "0:ANOTHER.SID") == CBMDOS_OK, "0: prefix, exact name");

    /* 4. Channels and commands. */
    check(cbmdos_read(5u, buf, 10u, &n, &eoi_ok) == CBMDOS_NO_CHANNEL, "read on wrong channel is 70");
    check(cbmdos_cmd("CD:GAMES") == CBMDOS_SYNTAX, "command is 31");
    check(strcmp(cbmdos_text(CBMDOS_SYNTAX), "31,SYNTAX ERROR,00,00") == 0, "31 text");
    check(cbmdos_open(1u, "OUT") == CBMDOS_WRITE_PROTECT, "write is 26");

    /* 5. 16-character truncation, DIR type, hidden OTHER. */
    use_set(g_set_long, 3u);
    check(cbmdos_open(0u, "A VERY LONG FILE") == CBMDOS_OK, "truncated name matches 16 characters");
    check(cbmdos_open(0u, "GAMES") == CBMDOS_FILE_NOT_FOUND, "a directory does not LOAD");
    check(cbmdos_open(0u, "$") == CBMDOS_OK, "open $ (long set)");
    n = read_all(0u, buf, sizeof(buf), 1000u, &eoi_ok);
    check(memcmp(&buf[39], "\"A_VERY_LONG_FILE\"", 18) == 0, "name cut to 16");
    check(n == 128u, "long set listing: header 30, two lines of 32, footer 30, load address and end");
    {
        int has_dir = 0;
        int has_link = 0;
        for (uint32_t i = 0u; i + 4u < n; i++) {
            if (memcmp(&buf[i], "DIR", 3) == 0) {
                has_dir = 1;
            }
            if (memcmp(&buf[i], "LINK", 4) == 0) {
                has_link = 1;
            }
        }
        check(has_dir, "subdirectory shows as DIR");
        check(!has_link, "OTHER entry hidden");
    }
    use_set(g_set_two, 2u);

    /* 6. Backend failure: 74 and the lost flag. */
    (void)cbmdos_take_backend_lost();
    g_fail = 1;
    check(cbmdos_open(0u, "$") == CBMDOS_NOT_READY, "backend down: 74");
    check(cbmdos_take_backend_lost() == 1, "lost flag raised");
    check(cbmdos_take_backend_lost() == 0, "lost flag clears");
    check(strcmp(cbmdos_text(CBMDOS_NOT_READY), "74,DRIVE NOT READY,00,00") == 0, "74 text");
    g_fail = 0;

    if (g_errors == 0) {
        printf("TEST PASS: cbmdos_host (%d checks)\n", g_checks);
        return 0;
    }
    printf("TEST FAIL (%d of %d checks)\n", g_errors, g_checks);
    return 1;
}
