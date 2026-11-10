/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * bank_host_test.c -- host test of the device 9 tune bank: the bank parser (bank_format.c), the
 * backend (backend_ram.c) and the directory/LOAD behavior of device 9 through cbmdos.c.
 *
 * Build and run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -Werror -DIK64_BACKEND_RAM -DIK64_HOST_TEST -Ifw_1541/src -Icommon \
 *       tools/bank_host_test.c fw_1541/src/bank_format.c fw_1541/src/backend_ram.c \
 *       fw_1541/src/cbmdos.c -o build/bank_host_test.exe
 *   build/bank_host_test.exe [+INJECT_FAILURE]
 *   build/bank_host_test.exe --image <bank.bin> --file <tune.sid> [--file ...] [+INJECT_FAILURE]
 *       image mode (driven by tools/bank_roundtrip_test.py): the image made by mkbank.py must parse,
 *       list the given files in order under their base names, and serve their exact bytes.
 * Prints "TEST PASS: bank_host" (or "bank_roundtrip") or "TEST FAIL" (exit 1).
 */
#include "backend_ram.h"
#include "bank_format.h"
#include "cbmdos.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TEST_IMG_BYTES    (65536u)
#define TEST_MAX_FILES    (64u)

static int g_checks;
static int g_errors;

/* Core 1 log sink used by backend_ram.c: kept as text so tests can count the "BANK:" lines. */
static char g_log[4096];

void drive_log_printf(const char *fmt, ...)
{
    va_list ap;
    size_t n = strlen(g_log);

    va_start(ap, fmt);
    (void)vsnprintf(g_log + n, sizeof(g_log) - n, fmt, ap);
    va_end(ap);
}

static unsigned log_lines(void)
{
    unsigned n = 0u;

    for (const char *p = g_log; (p = strstr(p, "BANK:")) != NULL; p++) {
        n++;
    }
    return n;
}

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_errors++;
        printf("  CHECK FAILED: %s\n", what);
    }
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

typedef struct
{
    const char *name;
    uint32_t    size;
} tune_t;

/* Test-only packer (the firmware only unpacks; tools/mkbank.py is the real one). Data bytes of tune t
 * are (t * 31 + i * 7 + 1) & 0xFF. Returns the image length. */
static uint32_t make_bank(uint8_t *img, const tune_t *t, uint32_t n)
{
    uint32_t off = BANK_HDR_BYTES + n * BANK_ENTRY_BYTES;
    uint32_t crc;

    memset(img, 0, TEST_IMG_BYTES);
    for (uint32_t k = 0u; k < n; k++) {
        uint8_t *e = img + BANK_HDR_BYTES + k * BANK_ENTRY_BYTES;

        strncpy((char *)e, t[k].name, BANK_NAME_BYTES - 1u);
        for (uint32_t i = 0u; i < t[k].size; i++) {
            img[off + i] = (uint8_t)(k * 31u + i * 7u + 1u);
        }
        put32(e + 32, off);
        put32(e + 36, t[k].size);
        put32(e + 40, bank_crc32(0u, img + off, t[k].size));
        off += (t[k].size + 3u) & ~3u;
    }
    memcpy(img, "IK64BANK", 8);
    put32(img + 8, BANK_VERSION);
    put32(img + 12, n);
    put32(img + 16, off);
    crc = bank_crc32(0u, img, BANK_CRC_SPAN_BYTES);
    crc = bank_crc32(crc, img + BANK_HDR_BYTES, n * BANK_ENTRY_BYTES);
    put32(img + 20, crc);
    return off;
}

/* Recompute the header CRC after a deliberate table edit, so only the edited field is wrong. */
static void refresh_crc(uint8_t *img)
{
    uint32_t n = (uint32_t)img[12] | ((uint32_t)img[13] << 8);
    uint32_t crc = bank_crc32(0u, img, BANK_CRC_SPAN_BYTES);

    crc = bank_crc32(crc, img + BANK_HDR_BYTES, n * BANK_ENTRY_BYTES);
    put32(img + 20, crc);
}

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

static const backend_ops_t g_ram_ops = BACKEND_OPS(ram);

/* ---- unit mode ------------------------------------------------------------------------------- */

static void test_parser(void)
{
    static uint8_t img[TEST_IMG_BYTES];
    static const tune_t two[] = { { "Airwolf.sid", 1964u }, { "Axel_F_Huelsbeck.sid", 11346u } };
    bank_info_t info = { 0u, 0u };
    bank_entry_t e;
    uint32_t len = make_bank(img, two, 2u);

    check(bank_crc32(0u, (const uint8_t *)"123456789", 9u) == 0xCBF43926u, "CRC-32 check value");
    check(bank_parse(img, len, &info) == BANK_OK && info.count == 2u && info.total == len, "valid bank");
    check(bank_parse(img, len - 1u, &info) == BANK_ERR_SIZE, "total larger than the available bytes");
    check(bank_parse(img, 10u, &info) == BANK_ERR_ABSENT, "shorter than a header");
    check(bank_parse(NULL, len, &info) == BANK_ERR_ABSENT, "no image");
    bank_entry_get(img, 1u, &e);
    check(strcmp(e.name, "Axel_F_Huelsbeck.sid") == 0 && e.size == 11346u && e.offset == 128u + 1964u, "entry 1 unpacked");
    check(bank_data_ok(img, &e) == BANK_OK, "data CRC ok");
    img[e.offset + 5u] ^= 1u;
    check(bank_data_ok(img, &e) == BANK_ERR_DATA_CRC, "data CRC mismatch");
    img[e.offset + 5u] ^= 1u;

    img[0] = 'X';
    check(bank_parse(img, len, &info) == BANK_ERR_ABSENT, "bad magic");
    img[0] = 'I';
    img[8] = 2u;
    check(bank_parse(img, len, &info) == BANK_ERR_VERSION, "bad version");
    img[8] = 1u;
    img[BANK_HDR_BYTES + 3u] ^= 0x20u;
    check(bank_parse(img, len, &info) == BANK_ERR_HEADER_CRC, "table byte flipped: header CRC");
    img[BANK_HDR_BYTES + 3u] ^= 0x20u;
    check(bank_parse(img, len, &info) == BANK_OK, "restored bank parses");
    img[20] ^= 1u;
    check(bank_parse(img, len, &info) == BANK_ERR_HEADER_CRC, "CRC field flipped");
    img[20] ^= 1u;

    put32(img + BANK_HDR_BYTES + BANK_ENTRY_BYTES + 36, len);   /* entry 1: size past the end */
    refresh_crc(img);
    check(bank_parse(img, len, &info) == BANK_ERR_ENTRY, "entry size out of bounds");
    put32(img + BANK_HDR_BYTES + BANK_ENTRY_BYTES + 36, 0xFFFFFFFFu);
    refresh_crc(img);
    check(bank_parse(img, len, &info) == BANK_ERR_ENTRY, "entry size 0xFFFFFFFF does not wrap");
    put32(img + BANK_HDR_BYTES + BANK_ENTRY_BYTES + 36, 11346u);
    put32(img + BANK_HDR_BYTES + BANK_ENTRY_BYTES + 32, len + 4u);   /* offset past total */
    refresh_crc(img);
    check(bank_parse(img, len, &info) == BANK_ERR_ENTRY, "entry offset out of bounds");
    put32(img + BANK_HDR_BYTES + BANK_ENTRY_BYTES + 32, 8u);          /* offset inside the header */
    refresh_crc(img);
    check(bank_parse(img, len, &info) == BANK_ERR_ENTRY, "entry offset inside the table");
    len = make_bank(img, two, 2u);
    img[BANK_HDR_BYTES] = '\0';
    refresh_crc(img);
    check(bank_parse(img, len, &info) == BANK_ERR_ENTRY, "empty entry name");
    len = make_bank(img, two, 2u);
    put32(img + 12, BANK_MAX_ENTRIES + 1u);
    check(bank_parse(img, len, &info) == BANK_ERR_COUNT, "entry count over the limit");

    len = make_bank(img, two, 0u);
    check(bank_parse(img, len, &info) == BANK_OK && info.count == 0u && info.total == BANK_HDR_BYTES, "empty bank");
    memset(img, 0, 64u);
    check(bank_parse(img, 64u, &info) == BANK_ERR_ABSENT, "erased (zero) memory is no bank");
    memset(img, 0xFF, 64u);
    check(bank_parse(img, 64u, &info) == BANK_ERR_ABSENT, "erased (0xFF) memory is no bank");
}

static void test_device(int inject)
{
    static uint8_t img[TEST_IMG_BYTES];
    static uint8_t buf[CBMDOS_DIR_BYTES];
    static uint8_t exp[] = {
        0x01, 0x04,
        0x1F, 0x04, 0x00, 0x00, 0x12, 0x22,
        'I', 'R', 'O', 'N', 'K', 'E', 'R', 'N', 'E', 'L', ' ', 'R', 'O', 'M', ' ', ' ',
        0x22, 0x20, '6', '4', 0x20, '2', 'A', 0x00,
        0x3F, 0x04, 0x08, 0x00, 0x20, 0x20, 0x20, 0x22,
        'A', 'I', 'R', 'W', 'O', 'L', 'F',
        0x22, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 'P', 'R', 'G', 0x20, 0x20, 0x00,
        0x5E, 0x04, 0x2D, 0x00, 0x20, 0x20, 0x22,
        'A', 'X', 'E', 'L', '_', 'F', '_', 'H', 'U', 'E', 'L', 'S', 'B', 'E', 'C', 'K',
        0x22, 0x20, 'P', 'R', 'G', 0x20, 0x20, 0x00,
        0x7C, 0x04, 0x00, 0x00,
        'B', 'L', 'O', 'C', 'K', 'S', ' ', 'F', 'R', 'E', 'E', '.',
        0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00,
        0x00, 0x00
    };
    static const tune_t set[] = { { "Airwolf.sid", 1964u }, { "Axel_F_Huelsbeck.sid", 11346u }, { "Commando.sid", 4126u } };
    uint32_t len;
    uint32_t n;
    int eoi_ok;
    uint8_t st;

    if (inject) {
        exp[10] ^= 1u;
    }
    /* Two-tune bank first: byte-exact directory. */
    len = make_bank(img, set, 2u);
    g_log[0] = '\0';
    backend_ram_set_image(img, len);
    check(backend_ram_init() == BACKEND_OK, "init");
    backend_ram_set_image(img, len);
    cbmdos_init(&g_ram_ops);
    cbmdos_select(&g_ram_ops, CBMDOS_LABEL_ROM);

    check(cbmdos_open(0u, "$") == CBMDOS_NOT_READY, "directory before mount: 74");
    check(backend_ram_mount() == BACKEND_OK, "mount");
    check(backend_ram_mount() == BACKEND_OK, "second mount");
    check(cbmdos_open(0u, "$") == CBMDOS_OK, "open $");
    n = read_all(0u, buf, sizeof(buf), 7u, &eoi_ok);
    check(eoi_ok, "$ EOI only on the last chunk");
    check(n == sizeof(exp), "$ length");
    check(n == sizeof(exp) && memcmp(buf, exp, sizeof(exp)) == 0, "$ bytes: header IRONKERNEL ROM, 2 tunes, 0 blocks free");
    check(cbmdos_close(0u) == CBMDOS_OK, "close $");
    check(log_lines() == 1u, "one log line for the good bank");

    /* Name matching: extension hidden, wildcards, '_' = space, case-insensitive. */
    check(cbmdos_open(0u, "AIRWOLF") == CBMDOS_OK && strcmp(cbmdos_info(), "Airwolf.sid 1964 B") == 0, "AIRWOLF");
    n = read_all(0u, buf, sizeof(buf), 4096u, &eoi_ok);
    check(eoi_ok && n == 1964u, "AIRWOLF reads 1964 bytes, EOI on the last chunk");
    {
        int same = 1;

        for (uint32_t i = 0u; i < n; i++) {
            if (buf[i] != (uint8_t)(i * 7u + 1u)) {
                same = 0;
            }
        }
        check(same, "AIRWOLF data");
    }
    check(cbmdos_open(0u, "airwolf") == CBMDOS_OK, "lower case");
    check(cbmdos_open(0u, "AIRWOLF.SID") == CBMDOS_OK, "with extension");
    check(cbmdos_open(0u, "AIR*") == CBMDOS_OK, "AIR*");
    check(cbmdos_open(0u, "*") == CBMDOS_OK && strcmp(cbmdos_info(), "Airwolf.sid 1964 B") == 0, "* picks the first");
    check(cbmdos_open(0u, "AXEL F*") == CBMDOS_OK && strcmp(cbmdos_info(), "Axel_F_Huelsbeck.sid 11346 B") == 0,
          "AXEL F* ('_' equals a space)");
    check(cbmdos_open(0u, "AXEL?F*") == CBMDOS_OK, "?");
    check(cbmdos_open(0u, "AIRWOL") == CBMDOS_FILE_NOT_FOUND, "prefix without * does not match");
    check(cbmdos_open(0u, "COMMANDO") == CBMDOS_FILE_NOT_FOUND, "tune not in this bank");
    check(cbmdos_open(0u, "$:AX*") == CBMDOS_OK, "$:AX*");
    n = read_all(0u, buf, sizeof(buf), 4096u, &eoi_ok);
    check(n == 2u + 30u + 31u + 30u + 2u, "$:AX* lists one tune");
    check(cbmdos_open(1u, "AIRWOLF") == CBMDOS_WRITE_PROTECT, "writing is refused (26)");

    /* A longer bank, remounted while the same backend stays selected. */
    len = make_bank(img, set, 3u);
    backend_ram_set_image(img, len);
    check(backend_ram_mount() == BACKEND_OK, "remount of a 3-tune bank");
    check(cbmdos_open(0u, "COMMANDO") == CBMDOS_OK, "COMMANDO found after the reload");
    (void)cbmdos_close(0u);

    /* Corrupt data: open fails with 74 and one more log line. */
    img[len - 3u] ^= 0x55u;
    {
        const unsigned before = log_lines();

        st = cbmdos_open(0u, "COMMANDO");
        check(st == CBMDOS_NOT_READY, "data CRC failure answers 74");
        check(log_lines() == before + 1u, "one log line for the CRC failure");
    }
    img[len - 3u] ^= 0x55u;

    /* Bad header: not ready, one log line however often it is asked. */
    g_log[0] = '\0';
    img[BANK_HDR_BYTES + 5u] ^= 0x01u;
    check(backend_ram_mount() == BACKEND_ERR_NOT_READY, "bad header CRC: not ready");
    check(cbmdos_open(0u, "$") == CBMDOS_NOT_READY, "directory of a bad bank: 74");
    check(backend_ram_mount() == BACKEND_ERR_NOT_READY, "still not ready");
    check(log_lines() == 1u, "a repeated failure logs once");
    img[BANK_HDR_BYTES + 5u] ^= 0x01u;
    check(backend_ram_mount() == BACKEND_OK, "repaired bank mounts");
    check(log_lines() == 2u, "recovery logs once");

    /* Absent bank (erased DDR3) and empty bank. */
    memset(img, 0, 256u);
    check(backend_ram_mount() == BACKEND_ERR_NOT_READY, "zeroed memory: not ready");
    len = make_bank(img, set, 0u);
    backend_ram_set_image(img, len);
    check(backend_ram_mount() == BACKEND_OK, "empty bank mounts");
    check(cbmdos_open(0u, "$") == CBMDOS_OK, "empty directory opens");
    n = read_all(0u, buf, sizeof(buf), 4096u, &eoi_ok);
    check(n == 2u + 30u + 30u + 2u, "empty directory is header and footer only");
    check(cbmdos_open(0u, "AIRWOLF") == CBMDOS_FILE_NOT_FOUND, "nothing in an empty bank");
}

/* ---- image mode (mkbank.py round trip) ------------------------------------------------------- */

static uint8_t *slurp(const char *path, uint32_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *p;
    long sz;

    if (f == NULL) {
        return NULL;
    }
    (void)fseek(f, 0, SEEK_END);
    sz = ftell(f);
    (void)fseek(f, 0, SEEK_SET);
    p = (uint8_t *)malloc((size_t)sz + 1u);
    if (p != NULL && fread(p, 1u, (size_t)sz, f) != (size_t)sz) {
        free(p);
        p = NULL;
    }
    (void)fclose(f);
    *len = (uint32_t)sz;
    return p;
}

static const char *base_name(const char *path)
{
    const char *b = path;

    for (const char *p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') {
            b = p + 1;
        }
    }
    return b;
}

static void test_image(const char *image, const char *const *files, unsigned nfiles, int inject)
{
    uint32_t len = 0u;
    uint8_t *img = slurp(image, &len);
    bank_info_t info = { 0u, 0u };
    static uint8_t buf[TEST_IMG_BYTES * 2u];

    check(img != NULL, "image readable");
    if (img == NULL) {
        return;
    }
    if (inject && len > 100u) {
        img[len - 1u] ^= 0x01u;
    }
    check(bank_parse(img, len, &info) == BANK_OK, "mkbank image parses");
    check(info.count == nfiles, "entry count equals the number of tunes");
    backend_ram_set_image(img, len);
    cbmdos_init(&g_ram_ops);
    cbmdos_select(&g_ram_ops, CBMDOS_LABEL_ROM);
    check(backend_ram_mount() == BACKEND_OK, "backend mounts the mkbank image");
    for (unsigned k = 0u; k < nfiles && k < info.count; k++) {
        bank_entry_t e;
        uint32_t flen = 0u;
        uint8_t *fdata = slurp(files[k], &flen);
        int eoi_ok;
        uint32_t n;

        bank_entry_get(img, k, &e);
        check(fdata != NULL, "tune file readable");
        check(strcmp(e.name, base_name(files[k])) == 0, "entry name is the file name, in order");
        check(fdata != NULL && e.size == flen, "entry size");
        check(bank_data_ok(img, &e) == BANK_OK, "entry CRC");
        if (fdata != NULL) {
            char pat[BANK_NAME_BYTES];

            (void)snprintf(pat, sizeof(pat), "%s", e.name);
            pat[strlen(pat) - 4u] = 0;   /* the shown name, as a C64 user types it ... */
            if (strlen(pat) > 16u) {
                pat[16] = 0;               /* ... cut to the 16 characters a C64 name has */
            }
            check(cbmdos_open(0u, pat) == CBMDOS_OK, "open by the shown name");
            n = read_all(0u, buf, sizeof(buf), 1024u, &eoi_ok);
            check(eoi_ok && n == flen && memcmp(buf, fdata, flen) == 0, "served bytes equal the file");
            (void)cbmdos_close(0u);
        }
        free(fdata);
    }
    check(cbmdos_open(0u, "$") == CBMDOS_OK, "directory of the mkbank image");
    free(img);
}

int main(int argc, char **argv)
{
    const char *image = NULL;
    const char *files[TEST_MAX_FILES];
    unsigned nfiles = 0u;
    int inject = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            inject = 1;
        } else if (strcmp(argv[i], "--image") == 0 && i + 1 < argc) {
            image = argv[++i];
        } else if (strcmp(argv[i], "--file") == 0 && i + 1 < argc && nfiles < TEST_MAX_FILES) {
            files[nfiles++] = argv[++i];
        }
    }
    if (image != NULL) {
        test_image(image, files, nfiles, inject);
    } else {
        test_parser();
        test_device(inject);
    }
    if (g_errors != 0) {
        printf("TEST FAIL: %s (%d of %d checks failed)\n", (image != NULL) ? "bank_roundtrip" : "bank_host", g_errors, g_checks);
        return 1;
    }
    printf("TEST PASS: %s (%d checks)\n", (image != NULL) ? "bank_roundtrip" : "bank_host", g_checks);
    return 0;
}
