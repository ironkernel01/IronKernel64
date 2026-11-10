/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * psid_cia_host_test.c -- host test of the PSID play period (CIA 1 timer A latch,
 * VBI PAL/NTSC, NTSC scaling, clamp) with fw_c64's 6502 core, c64mem and psid linked
 * natively and a null SID sink.
 *
 * Build and run (MSYS2 UCRT64):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/src tools/psid_cia_host_test.c \
 *       fw_c64/src/psid.c fw_c64/src/c64mem.c fw_c64/src/cpu6502.c \
 *       -o build/psid_cia_host_test.exe
 *   build/psid_cia_host_test.exe [+INJECT_FAILURE] [file.sid]
 * With a file argument the real tune is parsed, initialised and its period printed
 * (the file is only data for the emulated 6502). Prints "TEST PASS: psid_cia_host" or
 * "TEST FAIL" (exit 1).
 */
#include "c64mem.h"
#include "psid.h"
#include "sidbus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void sidbus_reset(sidbus_model_t model) { (void)model; }
void sidbus_frame_begin(void) {}
void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val) { (void)cycle; (void)reg; (void)val; }
uint8_t sidbus_read(uint8_t reg) { (void)reg; return 0u; }

static int g_fail;

static void check(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        printf("  FAIL %s: got %u (0x%X), want %u (0x%X)\n", what, (unsigned)got, (unsigned)got,
               (unsigned)want, (unsigned)want);
        g_fail = 1;
    }
}

static uint32_t ntsc_scaled(uint32_t p)
{
    return (uint32_t)(((uint64_t)p * 985248u) / 1022727u);
}

/* Build a v2 PSID: load/init $1000, play $1100, one song. */
static uint32_t build(uint8_t *img, uint32_t speed, uint16_t flags, const uint8_t *init_code,
                      uint32_t init_len, const uint8_t *play_code, uint32_t play_len)
{
    memset(img, 0, 0x7Cu + 0x200u);
    memcpy(img, "PSID", 4);
    img[5] = 2; img[7] = 0x7C;
    img[8] = 0x10; img[9] = 0x00;          /* load $1000 */
    img[0x0A] = 0x10; img[0x0B] = 0x00;    /* init $1000 */
    img[0x0C] = 0x11; img[0x0D] = 0x00;    /* play $1100 */
    img[0x0F] = 1; img[0x11] = 1;
    img[0x12] = (uint8_t)(speed >> 24); img[0x13] = (uint8_t)(speed >> 16);
    img[0x14] = (uint8_t)(speed >> 8);  img[0x15] = (uint8_t)speed;
    img[0x76] = (uint8_t)(flags >> 8); img[0x77] = (uint8_t)flags;
    memcpy(&img[0x7C], init_code, init_len);
    memcpy(&img[0x7C + 0x100u], play_code, play_len);
    return 0x7Cu + 0x100u + play_len;
}

static psid_status_t start(const uint8_t *img, uint32_t len)
{
    psid_info_t info;
    psid_status_t st = psid_load(img, len, &info);

    return (st == PSID_OK) ? psid_init(1u) : st;
}

static const uint8_t RTS_ONLY[] = { 0x60 };
static const uint8_t SET_4CC7[] = { 0xA9, 0xC7, 0x8D, 0x04, 0xDC, 0xA9, 0x4C, 0x8D, 0x05, 0xDC, 0x60 };
static const uint8_t SET_1000[] = { 0xA9, 0x00, 0x8D, 0x04, 0xDC, 0xA9, 0x10, 0x8D, 0x05, 0xDC, 0x60 };
static const uint8_t SET_0005[] = { 0xA9, 0x05, 0x8D, 0x04, 0xDC, 0xA9, 0x00, 0x8D, 0x05, 0xDC, 0x60 };

static int real_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    static uint8_t buf[70000];
    size_t n;
    psid_info_t info;
    psid_status_t st;

    if (f == NULL) {
        printf("cannot open %s\n", path);
        return 1;
    }
    n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    st = psid_load(buf, (uint32_t)n, &info);
    printf("load: %s\n", psid_status_text(st));
    if (st != PSID_OK) {
        return 1;
    }
    printf("name='%s' ver=%u clock=%u speed=%08X init=%04X play=%04X load=%04X len=%u\n", info.name,
           info.version, info.clock, (unsigned)info.speed, info.init_addr, info.play_addr,
           info.load_addr, (unsigned)info.data_len);
    st = psid_init(0u);
    printf("init: %s (cycles used %u, cap %u)\n", psid_status_text(st),
           (unsigned)c64mem_call_cycles(), (unsigned)PSID_INIT_MAX_CYCLES);
    printf("latch after init: 0x%04X, period: %u\n", c64mem_cia1_ta_latch(),
           (unsigned)psid_play_period_cycles());
    if (st == PSID_OK) {
        st = psid_play_frame();
        printf("play: %s (cycles %u), latch 0x%04X, period %u\n", psid_status_text(st),
               (unsigned)c64mem_call_cycles(), c64mem_cia1_ta_latch(),
               (unsigned)psid_play_period_cycles());
    }
    return 0;
}

int main(int argc, char **argv)
{
    static uint8_t img[0x7Cu + 0x200u];
    uint32_t len;
    int inject = 0;
    const char *file = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            inject = 1;
        } else {
            file = argv[i];
        }
    }
    if (file != NULL) {
        return real_file(file);
    }

    /* 1. CIA tune whose init sets $4CC7 -> period $4CC8. */
    len = build(img, 1u, 0x0014u, SET_4CC7, sizeof(SET_4CC7), RTS_ONLY, 1u);
    check("cia init start", (uint32_t)start(img, len), PSID_OK);
    check("cia latch $4CC7 period", psid_play_period_cycles(), 0x4CC8u);

    /* 2. CIA tune that never writes the timer -> $4026. */
    len = build(img, 1u, 0x0014u, RTS_ONLY, 1u, RTS_ONLY, 1u);
    check("cia default start", (uint32_t)start(img, len), PSID_OK);
    check("cia default period", psid_play_period_cycles(), 0x4026u);

    /* 3. VBI PAL. */
    len = build(img, 0u, 0x0004u, RTS_ONLY, 1u, RTS_ONLY, 1u);
    check("vbi pal start", (uint32_t)start(img, len), PSID_OK);
    check("vbi pal period", psid_play_period_cycles(), 19656u);

    /* 4. VBI NTSC, scaled. */
    len = build(img, 0u, 0x0008u, RTS_ONLY, 1u, RTS_ONLY, 1u);
    check("vbi ntsc start", (uint32_t)start(img, len), PSID_OK);
    check("vbi ntsc period", psid_play_period_cycles(), ntsc_scaled(17095u));

    /* 5. Play routine rewrites the latch: the next period changes. */
    len = build(img, 1u, 0x0014u, SET_4CC7, sizeof(SET_4CC7), SET_1000, sizeof(SET_1000));
    check("rewrite start", (uint32_t)start(img, len), PSID_OK);
    check("rewrite before play", psid_play_period_cycles(), 0x4CC8u);
    check("rewrite play", (uint32_t)psid_play_frame(), PSID_OK);
    check("rewrite after play", psid_play_period_cycles(), 0x1001u);

    /* 6. NTSC CIA tune scales; a garbage latch clamps. */
    len = build(img, 1u, 0x0008u, SET_4CC7, sizeof(SET_4CC7), RTS_ONLY, 1u);
    check("ntsc cia start", (uint32_t)start(img, len), PSID_OK);
    check("ntsc cia period", psid_play_period_cycles(), ntsc_scaled(0x4CC8u));
    len = build(img, 1u, 0x0004u, SET_0005, sizeof(SET_0005), RTS_ONLY, 1u);
    check("clamp start", (uint32_t)start(img, len), PSID_OK);
    check("clamp min", psid_play_period_cycles(), PSID_PERIOD_MIN_CYCLES);

    if (inject != 0) {
        check("injected failure", 1u, 2u);
    }
    if (g_fail != 0) {
        printf("TEST FAIL\n");
        return 1;
    }
    printf("TEST PASS: psid_cia_host\n");
    return 0;
}
