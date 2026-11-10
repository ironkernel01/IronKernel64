/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: player.c
 * Role: the basic_player_ops_t implementation (contract in player.h).
 *
 * Ownership: calls psid.h, sidbus_fabric.h and audio_out.h; touches no register itself.
 * Concurrency: core 0 main loop only.
 */
#include "player.h"

#include "audio_out.h"
#include "c64_regs.h"
#include "psid.h"
#include "sid_envmodel.h"
#include "sidbus.h"
#include "sidbus_fabric.h"

#include <string.h>   /* memcpy */

#define PLAYER_MS_PER_S   (1000u)
/* Prefill wait limit: 5 ms of phi2 cycles, 5x the 1 ms the FIFO needs to reach
 * AUDIO_OUT_PREFILL_SAMPLES (the stream delivers 48 frames per ms). */
#define PLAYER_PREFILL_TIMEOUT_CYCLES   (C64_SID_PHI2_HZ / 200u)
/* Hard poll bound, independent of the SID clock: one poll is at least one AXI
 * read (>= 10 ns at 100 MHz), so 2,000,000 polls cover the 5 ms limit many times
 * over even if CYCLE never advances. */
#define PLAYER_PREFILL_MAX_POLLS        (2000000u)

static psid_info_t g_info;
static uint32_t g_song;          /* 1-based current song */
static int      g_playing;
static uint32_t g_t0;            /* CYCLE at the end of init */
static uint32_t g_base;          /* base time of the next frame */
static uint32_t g_resyncs;
static uint32_t g_errors;
static sid_envmodel_t g_env;     /* voice 1/2 envelope model (voice 3 comes from hardware ENV3) */
static int      g_tap_set;

/*
 * map_load -- psid_load status to the reason basic.c prints.
 * Returns: the basic_player_reason_t.
 */
static basic_player_reason_t map_load(psid_status_t st)
{
    switch (st) {
    case PSID_OK:
        return BASIC_PLAYER_OK;
    case PSID_ERR_NULL:
    case PSID_ERR_SHORT:
    case PSID_ERR_MAGIC:
    case PSID_ERR_VERSION:
    case PSID_ERR_DATA_OFFSET:
    case PSID_ERR_NO_DATA:
    case PSID_ERR_SONGS:
        return BASIC_PLAYER_BAD_HEADER;
    case PSID_ERR_RSID:
        return BASIC_PLAYER_RSID;
    case PSID_ERR_PLAY_ZERO:
        return BASIC_PLAYER_NO_PLAY;
    default:
        return BASIC_PLAYER_ERROR;
    }
}

/*
 * player_sid_tap -- sidbus write observer: feed the envelope model.
 * Returns: nothing.
 */
static void player_sid_tap(uint32_t stamp, uint8_t reg, uint8_t val)
{
    sid_envmodel_write(&g_env, stamp, reg, val);
}

/*
 * begin_song -- init one song and schedule its frames.
 * Steps:
 *   0. Reset the envelope model to time 0 (psid_init restarts CYCLE at 0).
 *   1. psid_init (resets the SID and its time, runs the init call).
 *   2. t0 = CYCLE; the first frame is due one play period after it.
 * Returns: the psid_init status.
 */
static psid_status_t begin_song(uint32_t song)
{
    psid_status_t st;

    g_playing = 0;
    sid_envmodel_reset(&g_env, 0u);
    st = psid_init((uint16_t)song);
    if (st != PSID_OK) {
        return st;
    }
    g_song = song;
    g_t0 = sidbus_fabric_cycle();
    g_base = g_t0 + psid_play_period_cycles();
    g_playing = 1;
    return PSID_OK;
}

/*
 * player_start -- load a PSID image and start its start song.
 * Steps:
 *   1. sidbus_reset starts the SID clock (CTRL.RUN; after power-up it is 0 and
 *      neither CYCLE nor the 48 kHz stream advances); FIFO flushed, CTRL.SRC = 1 with
 *      ENABLE = 0 and IRQ_EN = 0; wait for LEVEL >= AUDIO_OUT_PREFILL_SAMPLES (at most
 *      PLAYER_PREFILL_TIMEOUT_CYCLES or PLAYER_PREFILL_MAX_POLLS), then ENABLE = 1.
 *   2. psid_load, psid_init of the start song.
 * Returns: BASIC_PLAYER_OK, or why the file was refused (output stopped again).
 */
static basic_player_reason_t player_start(const uint8_t *file, uint32_t len)
{
    psid_status_t st;
    uint32_t t0;
    uint32_t polls = 0u;

    if (!g_tap_set) {
        sidbus_fabric_set_tap(player_sid_tap);
        g_tap_set = 1;
    }
    sidbus_reset(SIDBUS_MODEL_6581);
    sid_envmodel_reset(&g_env, 0u);
    audio_out_enable(0);
    audio_out_flush();
    audio_out_set_source(1);
    t0 = sidbus_fabric_cycle();
    while (audio_out_level() < AUDIO_OUT_PREFILL_SAMPLES &&
           (sidbus_fabric_cycle() - t0) < PLAYER_PREFILL_TIMEOUT_CYCLES &&
           polls < PLAYER_PREFILL_MAX_POLLS) {
        polls++;
    }
    audio_out_stream_start();
    st = psid_load(file, len, &g_info);
    if (st == PSID_OK) {
        st = begin_song(g_info.start_song);
    }
    if (st != PSID_OK) {
        g_playing = 0;
        audio_out_enable(0);
        audio_out_flush();
        audio_out_set_source(0);
        return map_load(st);
    }
    return BASIC_PLAYER_OK;
}

/*
 * player_info -- tune texts for the now-playing screen.
 * Returns: nothing.
 */
static void player_info(basic_tune_info_t *info)
{
    memcpy(info->name, g_info.name, BASIC_TUNE_TEXT_BYTES - 1u);
    memcpy(info->author, g_info.author, BASIC_TUNE_TEXT_BYTES - 1u);
    memcpy(info->released, g_info.released, BASIC_TUNE_TEXT_BYTES - 1u);
    info->name[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    info->author[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    info->released[BASIC_TUNE_TEXT_BYTES - 1u] = '\0';
    info->songs = g_info.songs;
    info->start_song = g_song;
}

/*
 * player_select_song -- restart on another song of the loaded tune.
 * Returns: 0 on success, -1 when the song cannot be played (playback is then stopped).
 */
static int player_select_song(uint32_t song)
{
    return (begin_song(song) == PSID_OK) ? 0 : -1;
}

/*
 * player_service -- run the play calls that are due.
 * Steps:
 *   1. Behind by a whole play period or more: restart the schedule at CYCLE (count it).
 *   2. While the next frame's base time is at most PLAYER_LEAD_FRAMES periods ahead of CYCLE
 *      (signed difference), at most PLAYER_MAX_FRAMES_PER_SERVICE times: set the base,
 *      psid_play_frame, advance the base by the period as the play call left it (the tune may
 *      have changed the CIA timer). A play failure stops the song (SID silenced).
 * Returns: nothing.
 */
static void player_service(void)
{
    if (!g_playing) {
        return;
    }
    if ((int32_t)(sidbus_fabric_cycle() - g_base) >= (int32_t)psid_play_period_cycles()) {
        g_base = sidbus_fabric_cycle();
        g_resyncs++;
    }
    for (uint32_t i = 0u; i < PLAYER_MAX_FRAMES_PER_SERVICE; i++) {
        const int32_t ahead = (int32_t)(g_base - sidbus_fabric_cycle());

        if (ahead > (int32_t)(PLAYER_LEAD_FRAMES * psid_play_period_cycles())) {
            break;
        }
        sidbus_fabric_set_base(g_base);
        if (psid_play_frame() != PSID_OK) {
            g_errors++;
            g_playing = 0;
            sidbus_reset(SIDBUS_MODEL_6581);
            sid_envmodel_reset(&g_env, 0u);
            return;
        }
        g_base += psid_play_period_cycles();
    }
}

/*
 * player_elapsed_ms -- time since the song started playing.
 * Returns: milliseconds from CYCLE (0 before the first cycle after init).
 */
static uint32_t player_elapsed_ms(void)
{
    const int32_t d = (int32_t)(sidbus_fabric_cycle() - g_t0);
    uint32_t c;

    if (!g_playing || d <= 0) {
        return 0u;
    }
    c = (uint32_t)d;
    return (c / C64_SID_PHI2_HZ) * PLAYER_MS_PER_S +
           ((c % C64_SID_PHI2_HZ) * PLAYER_MS_PER_S) / C64_SID_PHI2_HZ;
}

/*
 * player_voice_levels -- envelope per voice.
 * Steps: advance the envelope model to the present CYCLE (it already stands at the latest
 *   write stamp when that is ahead), then voices 1 and 2 from the model and voice 3 from the
 *   hardware ENV3 (the fabric SID reads back only OSC3/ENV3).
 * Returns: nothing; all 0 when not playing.
 */
static void player_voice_levels(uint8_t level[BASIC_VOICES])
{
    if (!g_playing) {
        level[0] = 0u;
        level[1] = 0u;
        level[2] = 0u;
        return;
    }
    sid_envmodel_advance(&g_env, sidbus_fabric_cycle());
    level[0] = sid_envmodel_level(&g_env, 0u);
    level[1] = sid_envmodel_level(&g_env, 1u);
    level[2] = sidbus_fabric_env3();
}

/*
 * player_stop -- stop the song: SID reset, audio output off, source back to the SAMPLE register.
 * Returns: nothing.
 */
static void player_stop(void)
{
    g_playing = 0;
    sidbus_reset(SIDBUS_MODEL_6581);
    sid_envmodel_reset(&g_env, 0u);
    audio_out_enable(0);
    audio_out_flush();
    audio_out_set_source(0);
}

const basic_player_ops_t g_player_ops = {
    player_start,
    player_info,
    player_select_song,
    player_service,
    player_elapsed_ms,
    player_voice_levels,
    player_stop
};

/*
 * player_resyncs -- schedule restarts after a stalled main loop.
 * Returns: the count since boot.
 */
uint32_t player_resyncs(void)
{
    return g_resyncs;
}

/*
 * player_errors -- songs stopped by a failing play call.
 * Returns: the count since boot.
 */
uint32_t player_errors(void)
{
    return g_errors;
}
