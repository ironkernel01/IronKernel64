/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * sid_host_test.c -- host test of the generated public tunes (tools/mksid.py output) with the real
 * core 0 code: psid.c (header check, load, init, play), c64mem.c + cpu6502.c (the 6502 and its
 * memory map) and the software synthesizer sid.c as the SID sink (WAV rendering).
 *
 * Build and run (MSYS2 UCRT64):
 *   gcc -O2 -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/src tools/sid_host_test.c \
 *       fw_c64/src/psid.c fw_c64/src/c64mem.c fw_c64/src/cpu6502.c fw_c64/src/sid.c \
 *       fw_c64/src/sid_tables.c -o build/sid_host_test.exe
 *   build/sid_host_test.exe [+INJECT_FAILURE] [--wav-dir DIR] <tune.sid> [<tune.sid> ...]
 * Each tune needs its <tune>.info next to it (written by mksid.py --info). Per tune:
 *   1. psid_load accepts the file; name, author and released are set and never contain
 *      "Commodore"; the tune is PSID, 6581, PAL.
 *   2. init returns; every play call (2 loops + 4 s) returns within the play cycle cap; the
 *      worst and the mean play time are printed.
 *   3. All SID writes hit registers 0..24 only; each of the three voices gets a frequency and
 *      at least one gate-on.
 *   4. The base frequency of every gate-on equals the list in the .info file (what the score
 *      says) for the whole run: this proves the notes, the transposition and the loop (the
 *      second pass and the start of the third repeat the list).
 *   5. The loop length is 45..90 s.
 * --wav-dir renders the first loop with sid.c (reSID-model synth, 6581, no filter used by the
 *   tunes) to DIR/<tune>.wav: 48 kHz, 16 bit, mono, 957/958 samples per frame (exact PAL clock).
 * +INJECT_FAILURE changes the expected first note of voice 1: the run must then FAIL (negative
 *   control). Prints "TEST PASS: sid_host" or "TEST FAIL" (exit 1).
 */
#include "c64mem.h"
#include "psid.h"
#include "sid.h"
#include "sidbus.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_TUNE_BYTES   (65536u)
#define MAX_LOG          (512u)
#define MAX_EVENTS       (4096u)
#define CPU_PER_FRAME    (19656u)
#define TAIL_FRAMES      (200u)
#define MIN_SECONDS      (45.0)
#define MAX_SECONDS      (90.0)
#define PAL_SAMPLES_X10  (9576u)     /* 48000 * 19656 / 985248 = 957.6 samples per frame */

static int g_fail;

static void fail(const char *name, const char *what)
{
    printf("  FAIL %s: %s\n", name, what);
    g_fail = 1;
}

/* ---- the SID sink: records the writes of the current frame and the voice state ---- */
static sid_write_t g_log[MAX_LOG];
static uint32_t g_log_n;
static int g_in_init;
static int g_bad_reg;
static uint8_t g_ctrl[3];
static uint16_t g_freq[3];
static uint32_t g_ev[3][MAX_EVENTS];
static uint32_t g_ev_n[3];
static uint32_t g_freq_writes[3];

void sidbus_reset(sidbus_model_t model)
{
    sid_reset((model == SIDBUS_MODEL_8580) ? SID_MODEL_8580 : SID_MODEL_6581);
}

void sidbus_frame_begin(void)
{
    g_log_n = 0u;
}

uint8_t sidbus_read(uint8_t reg)
{
    (void)reg;
    return 0u;
}

void sidbus_write(uint32_t cycle, uint8_t reg, uint8_t val)
{
    if (reg > SIDBUS_REG_LAST_WRITE) {
        g_bad_reg = 1;
    }
    if (g_in_init) {
        sid_write(reg, val);
    } else if (g_log_n < MAX_LOG) {
        g_log[g_log_n].cycle = (uint16_t)cycle;
        g_log[g_log_n].reg = reg;
        g_log[g_log_n].val = val;
        g_log_n++;
    }
    if (reg < 21u) {
        const unsigned v = reg / 7u;
        const unsigned r = reg % 7u;

        if (r == 0u) {
            g_freq[v] = (uint16_t)((g_freq[v] & 0xFF00u) | val);
        } else if (r == 1u) {
            g_freq[v] = (uint16_t)((g_freq[v] & 0x00FFu) | ((uint16_t)val << 8));
            g_freq_writes[v]++;
        } else if (r == 4u) {
            if ((g_ctrl[v] & 1u) == 0u && (val & 1u) != 0u && g_ev_n[v] < MAX_EVENTS) {
                g_ev[v][g_ev_n[v]++] = g_freq[v];
            }
            g_ctrl[v] = val;
        }
    }
}

/* ---- .info file ---- */
typedef struct
{
    uint32_t loop_frames;
    double   seconds;
    uint32_t notes[3][MAX_EVENTS];
    uint32_t n[3];
} info_t;

static int read_info(const char *sid_path, info_t *info)
{
    char path[1024];
    char *line = malloc(1u << 20);
    FILE *f;
    size_t len = strlen(sid_path);

    if (line == NULL || len < 4u || len + 6u > sizeof(path)) {
        free(line);
        return -1;
    }
    memcpy(path, sid_path, len - 4u);
    strcpy(path + len - 4u, ".info");
    f = fopen(path, "r");
    if (f == NULL) {
        free(line);
        return -1;
    }
    memset(info, 0, sizeof(*info));
    while (fgets(line, 1 << 20, f) != NULL) {
        if (strncmp(line, "loop_frames=", 12) == 0) {
            info->loop_frames = (uint32_t)strtoul(line + 12, NULL, 10);
        } else if (strncmp(line, "seconds=", 8) == 0) {
            info->seconds = atof(line + 8);
        } else if (strncmp(line, "notes", 5) == 0 && line[5] >= '1' && line[5] <= '3' && line[6] == '=') {
            const unsigned v = (unsigned)(line[5] - '1');
            char *p = line + 7;

            while (*p != '\0' && *p != '\n' && info->n[v] < MAX_EVENTS) {
                char *end;
                unsigned long x = strtoul(p, &end, 16);

                if (end == p) {
                    break;
                }
                info->notes[v][info->n[v]++] = (uint32_t)x;
                p = end;
            }
        }
    }
    fclose(f);
    free(line);
    return 0;
}

/* ---- WAV writer ---- */
static void put16(FILE *f, uint16_t v) { fputc(v & 0xFF, f); fputc(v >> 8, f); }
static void put32(FILE *f, uint32_t v) { put16(f, (uint16_t)(v & 0xFFFFu)); put16(f, (uint16_t)(v >> 16)); }

static void wav_header(FILE *f, uint32_t samples)
{
    fwrite("RIFF", 1, 4, f);
    put32(f, 36u + samples * 2u);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16u);
    put16(f, 1u);
    put16(f, 1u);
    put32(f, SID_SAMPLE_RATE_HZ);
    put32(f, SID_SAMPLE_RATE_HZ * 2u);
    put16(f, 2u);
    put16(f, 16u);
    fwrite("data", 1, 4, f);
    put32(f, samples * 2u);
}

/* ---- one tune ---- */
static int run_tune(const char *path, const char *wav_dir, int inject)
{
    static uint8_t image[MAX_TUNE_BYTES];
    static info_t info;
    psid_info_t pi;
    psid_status_t st;
    FILE *f = fopen(path, "rb");
    size_t len;
    const char *base = path;
    uint32_t frames, fr, worst = 0u;
    uint64_t sum = 0u;
    FILE *wav = NULL;
    uint32_t wav_samples = 0u, acc = 0u;
    int before = g_fail;

    for (const char *p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') {
            base = p + 1;
        }
    }
    if (f == NULL) {
        fail(base, "cannot open");
        return 1;
    }
    len = fread(image, 1, sizeof(image), f);
    fclose(f);
    if (read_info(path, &info) != 0) {
        fail(base, "no .info file next to the tune");
        return 1;
    }
    if (inject) {
        info.notes[0][0] ^= 1u;
    }

    st = psid_load(image, (uint32_t)len, &pi);
    if (st != PSID_OK) {
        printf("  psid_load: %d\n", (int)st);
        fail(base, "psid_load rejected the file");
        return 1;
    }
    if (pi.name[0] == '\0' || pi.author[0] == '\0' || pi.released[0] == '\0') {
        fail(base, "empty name/author/released");
    }
    if (strstr(pi.name, "ommodore") || strstr(pi.author, "ommodore") || strstr(pi.released, "ommodore")) {
        fail(base, "metadata mentions Commodore");
    }
    if (pi.version != 2u || pi.sid_model != PSID_MODEL_6581 || pi.clock != PSID_CLOCK_PAL
        || psid_song_is_vbi(&pi, 1u) == 0) {
        fail(base, "not a v2 / 6581 / PAL / VBI tune");
    }
    if (info.seconds < MIN_SECONDS || info.seconds > MAX_SECONDS) {
        fail(base, "loop length outside 45..90 s");
    }

    memset(g_ctrl, 0, sizeof(g_ctrl));
    memset(g_freq, 0, sizeof(g_freq));
    memset(g_ev_n, 0, sizeof(g_ev_n));
    memset(g_freq_writes, 0, sizeof(g_freq_writes));
    g_bad_reg = 0;
    g_in_init = 1;
    st = psid_init(1u);
    g_in_init = 0;
    if (st != PSID_OK) {
        printf("  psid_init: %d\n", (int)st);
        fail(base, "init did not return");
        return 1;
    }

    frames = info.loop_frames * 2u + TAIL_FRAMES;
    if (wav_dir != NULL) {
        char wp[1200];
        char stem[256];
        size_t n = strlen(base);

        snprintf(stem, sizeof(stem), "%s", base);
        if (n > 4u) {
            stem[n - 4u] = '\0';
        }
        snprintf(wp, sizeof(wp), "%s/%s.wav", wav_dir, stem);
        wav = fopen(wp, "wb");
        if (wav == NULL) {
            fail(base, "cannot create the WAV");
        } else {
            wav_header(wav, 0u);
        }
    }
    for (fr = 0u; fr < frames; fr++) {
        uint32_t cyc;

        st = psid_play_frame();
        if (st != PSID_OK) {
            printf("  frame %u: psid_play_frame status %d\n", (unsigned)fr, (int)st);
            fail(base, "a play call failed (cap, JAM or BRK)");
            break;
        }
        cyc = c64mem_call_cycles();
        sum += cyc;
        if (cyc > worst) {
            worst = cyc;
        }
        if (wav != NULL && fr < info.loop_frames) {
            static int16_t out[SID_RENDER_MAX_SAMPLES];
            uint32_t n;

            acc += PAL_SAMPLES_X10;
            n = acc / 10u;
            acc -= n * 10u;
            sid_render(g_log, g_log_n, out, n);
            for (uint32_t i = 0u; i < n; i++) {
                put16(wav, (uint16_t)out[i]);
            }
            wav_samples += n;
        }
    }
    if (wav != NULL) {
        fseek(wav, 0, SEEK_SET);
        wav_header(wav, wav_samples);
        fclose(wav);
    }

    if (g_bad_reg) {
        fail(base, "write outside SID registers 0..24");
    }
    for (unsigned v = 0u; v < 3u; v++) {
        if (g_ev_n[v] == 0u || g_freq_writes[v] == 0u) {
            fail(base, "a voice never gets a frequency and a gate");
            continue;
        }
        if (info.n[v] == 0u || g_ev_n[v] < 2u * info.n[v]) {
            printf("  voice %u: %u gate-ons, score has %u per loop\n", v + 1u, (unsigned)g_ev_n[v],
                   (unsigned)info.n[v]);
            fail(base, "fewer gate-ons than two loops");
            continue;
        }
        for (uint32_t i = 0u; i < g_ev_n[v]; i++) {
            if (g_ev[v][i] != info.notes[v][i % info.n[v]]) {
                printf("  voice %u gate-on %u: freq %04X, expected %04X\n", v + 1u, (unsigned)i,
                       (unsigned)g_ev[v][i], (unsigned)info.notes[v][i % info.n[v]]);
                fail(base, "note sequence differs from the score or does not loop");
                break;
            }
        }
    }
    printf("  %-24s %5.1f s  %5u frames/loop  play worst %4u mean %4u cycles  gate-ons %u/%u/%u  %s\n", base,
           info.seconds, (unsigned)info.loop_frames, (unsigned)worst, (unsigned)(sum / (fr ? fr : 1u)),
           (unsigned)g_ev_n[0], (unsigned)g_ev_n[1], (unsigned)g_ev_n[2],
           (g_fail == before) ? "ok" : "FAIL");
    (void)CPU_PER_FRAME;
    return g_fail != before;
}

int main(int argc, char **argv)
{
    const char *wav_dir = NULL;
    int inject = 0;
    int tunes = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            inject = 1;
        } else if (strcmp(argv[i], "--wav-dir") == 0 && i + 1 < argc) {
            wav_dir = argv[++i];
        }
    }
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            continue;
        }
        if (strcmp(argv[i], "--wav-dir") == 0) {
            i++;
            continue;
        }
        (void)run_tune(argv[i], wav_dir, inject);
        tunes++;
    }
    if (tunes == 0) {
        printf("TEST FAIL: no tunes given\n");
        return 1;
    }
    if (g_fail) {
        printf("TEST FAIL: sid_host (%d tunes)\n", tunes);
        return 1;
    }
    printf("TEST PASS: sid_host (%d tunes)\n", tunes);
    return 0;
}
