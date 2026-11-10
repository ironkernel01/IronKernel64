/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: player.h
 * Role: the SID tune player of core 0: implements basic_player_ops_t (basic.h) with the PSID
 *   driver (psid.h) and the fabric SID (sidbus_fabric.h).
 *
 * Contract:
 *   - Timing: a play call is scheduled at the previous call's base time plus the period
 *     psid_play_period_cycles() gave after that call (CIA timer or VBI; NTSC tunes scaled to the
 *     PAL SID clock), in phi2 cycles of the sid_player CYCLE register; the first call is one
 *     period after the end of the init call. service() runs a call when its base time is at most
 *     PLAYER_LEAD_FRAMES periods ahead of CYCLE, so the FIFO always holds about two periods of
 *     writes. When the main loop stalls for more than a period the schedule restarts at the
 *     current CYCLE (player_resyncs() counts it).
 *   - Audio: start() selects the fabric stream as the audio FIFO source and enables the output;
 *     the SID output reaches the codec without CPU involvement.
 *   - Voice levels: ENV3 only (read back from the SID); voices 1 and 2 report 0 until the
 *     fabric reads their envelopes.
 *   - elapsed_ms counts from the end of the init call, derived from CYCLE (985,248 Hz).
 * Concurrency: core 0 main loop only.
 * Headers hold contracts and constants; per-function commentary lives in player.c.
 */
#ifndef PLAYER_H
#define PLAYER_H

#include <stdint.h> /* uint32_t */

#include "basic.h"  /* basic_player_ops_t */

#define PLAYER_LEAD_FRAMES   (2u)
#define PLAYER_MAX_FRAMES_PER_SERVICE (PLAYER_LEAD_FRAMES + 1u)

extern const basic_player_ops_t g_player_ops;

uint32_t player_resyncs(void);
uint32_t player_errors(void);

#endif /* PLAYER_H */
