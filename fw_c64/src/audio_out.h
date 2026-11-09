/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: audio_out.h
 * Role: the sid_audio_out block: 2048-frame sample FIFO in front of the I2S transmitter to
 *   the ADAU1761 (48 kHz, 16-bit, stereo frames).
 *
 * Ownership: audio_out.c is the only file that touches the sid_audio_out registers
 *   (C64_PLAT_WIN0_BASE + C64_WIN_AUD_OFS, offsets in c64_regs.h).
 *
 * Contract:
 *   - Samples are signed 16-bit mono; audio_out_push_block() writes each as one stereo
 *     frame (left = right = the sample; SAMPLE register [15:0] left, [31:16] right).
 *   - audio_out_push_block() never blocks: it writes at most the free FIFO space and
 *     returns the number written. The caller renders 960 samples per PAL frame
 *     (C64_AUD_SAMPLE_RATE_HZ / 50) and pushes them when audio_out_refill_due() says so.
 *   - Low-level interrupt: the FIFO raises it while LEVEL <= THRESH (default
 *     AUDIO_OUT_THRESHOLD = half the FIFO). audio_out_isr() (connected by the caller to the
 *     INTC) clears it, masks it (the condition stays true until the main loop refills) and
 *     sets the refill flag; audio_out_push_block() unmasks it again.
 *   - Without the interrupt, audio_out_refill_due() also reports due when LEVEL <= THRESH.
 *   - audio_out_set_source(1) selects the fabric stream of sid_player as the FIFO source; the
 *     level then settles near empty (48 kHz in, 48 kHz out), so the low-level interrupt stays
 *     true: the ISR masks it once and nothing unmasks it.
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef AUDIO_OUT_H
#define AUDIO_OUT_H

#include <stdint.h> /* int16_t, uint32_t */

#include "c64_regs.h"

#define AUDIO_OUT_THRESHOLD     (C64_AUD_FIFO_DEPTH / 2u)          /* 1024 frames, 21 ms */
#define AUDIO_OUT_PAL_BLOCK     (C64_AUD_SAMPLE_RATE_HZ / 50u)     /* 960 samples */

void     audio_out_init(void);
void     audio_out_enable(int on);
void     audio_out_set_source(int fabric);  /* 1: sid_player stream (CTRL.SRC), 0: SAMPLE reg */
void     audio_out_flush(void);
void     audio_out_set_threshold(uint32_t frames);
void     audio_out_isr(void *ref);
int      audio_out_refill_due(void);
uint32_t audio_out_level(void);
uint32_t audio_out_space(void);
uint32_t audio_out_push_block(const int16_t *mono, uint32_t n);
uint32_t audio_out_underruns(void);
uint32_t audio_out_status(void);

#endif /* AUDIO_OUT_H */
