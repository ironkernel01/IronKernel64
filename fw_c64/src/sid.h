/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: sid.h
 * Role: software MOS 6581/8580 SID synthesizer of the core 0 player: 48 kHz
 *   16-bit mono output, PAL timing, integer/fixed-point only (the CPU has no FPU).
 *
 * Model (reSID 0.16 behaviour, Dag Lem, GPL-2.0-or-later; tables in sid_tables.c,
 *   provenance in third_party/resid/SOURCE.txt):
 *   - Oscillator: 24-bit phase accumulator advanced by FREQ per cycle; saw = acc
 *     bits 23..12; triangle from acc bits 22..11 folded by bit 23 (ring mod XORs
 *     bit 23 with the sync source's bit 23); pulse = (acc >> 12) >= PW (12-bit),
 *     held high by TEST; noise = 23-bit LFSR (taps 22 and 17) clocked on each
 *     rising edge of acc bit 19, output bits 22 20 16 13 11 7 4 2; combined
 *     waveforms from reSID's sampled tables; waveforms with noise and another
 *     waveform read 0. TEST clears the accumulator and the LFSR, release of TEST
 *     loads the LFSR with 0x7FFFF8. Hard sync resets the destination accumulator
 *     on the source's bit-23 rising edge, placed at the cycle of the edge.
 *     Sync/ring sources: voice 1 <- voice 3, voice 2 <- voice 1, voice 3 <- voice 2.
 *   - Envelope: 15-bit rate counter with reSID's 6581 period table, exponential
 *     decay/release divider 1/2/4/8/16/30 switched at levels 255/93/54/26/14/6/0,
 *     sustain compare, gate-on attack, gate-off release, freeze at zero.
 *     The ADSR delay bug is modelled: writing a period below the current rate
 *     counter lets the counter run to the 2^15 wrap first (reSID behaviour).
 *   - Voice DAC: (wave12 - wave_zero) * env8 + voice_DC (6581: zero 0x380,
 *     DC 0x800 * 0xFF; 8580: zero 0x800, no DC), scaled by 2^-8 into "voice
 *     units" (6581 voice range about 1147..5226, 8580 about -2040..2032).
 *   - Filter: Chamberlin two-integrator state-variable filter (reSID sign
 *     convention: Vhp = Vbp/Q - Vlp - Vi, Vbp -= w*Vhp, Vlp -= w*Vbp) clocked
 *     twice per output sample (96 kHz). Coefficient F = 2 sin(pi * fc / 96000)
 *     in Q2.14 from the reSID FC -> fc curve of the chip model; 1/Q in Q10 from
 *     reSID's RES map 1/(0.707 + RES/15). Routing per $D417 bits 0-2, 3OFF
 *     ($D418 bit 7) mutes voice 3 when it is not routed to the filter, LP/BP/HP
 *     from $D418 bits 4-6.
 *   - Mixer: (unfiltered + selected filter outputs + mixer DC) * VOL; the 6581
 *     DC terms make $D418 volume writes audible as samples ("digis").
 *   - Output: DC-blocking first-order high-pass (~15 Hz, the C64 output
 *     coupling), then scaled to int16 with saturation.
 *
 * Frame rendering: a frame is SID_FRAME_CYCLES PAL CPU cycles (312 lines x 63).
 *   sid_render spreads them over n_samples output samples with an exact
 *   integer Bresenham split (base = cycles / n, remainder distributed), so the
 *   960-sample frame of the audio path uses 20 or 21 cycles per sample and the
 *   frame sums to exactly 19656 cycles. With 960 samples per 19656 cycles the
 *   effective SID clock is 982,800 Hz (50.000 frames/s), 0.25 % below PAL
 *   985,248 Hz; a caller that alternates 957/958-sample frames (19656 x 48000 /
 *   985248 = 957.6) gets the exact PAL rate.
 *   Register writes in the log are applied at their cycle offsets: the synth
 *   renders the voices in segments between writes inside each sample.
 *
 * Concurrency: one context (core 0 main loop) owns the synthesizer.
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in sid.c and sid_tables.c.
 */
#ifndef SID_H
#define SID_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t, int16_t */

#define SID_REGS               (32u)       /* register window; reg = addr & 0x1F */
#define SID_VOICES             (3u)
#define SID_CLOCK_PAL_HZ       (985248u)
#define SID_SAMPLE_RATE_HZ     (48000u)    /* = C64_AUD_SAMPLE_RATE_HZ (c64_regs.h) */
#define SID_PAL_LINE_CYCLES    (63u)
#define SID_PAL_LINES          (312u)
#define SID_FRAME_CYCLES       (SID_PAL_LINE_CYCLES * SID_PAL_LINES)   /* 19656 */
#define SID_FRAME_SAMPLES      (960u)      /* 48000 / 50 */
#define SID_RENDER_MAX_SAMPLES (2048u)     /* largest n_samples accepted by sid_render */

/* Register numbers. */
#define SID_REG_FC_LO          (0x15u)
#define SID_REG_FC_HI          (0x16u)
#define SID_REG_RES_FILT       (0x17u)
#define SID_REG_MODE_VOL       (0x18u)
#define SID_REG_POTX           (0x19u)
#define SID_REG_POTY           (0x1Au)
#define SID_REG_OSC3           (0x1Bu)
#define SID_REG_ENV3           (0x1Cu)

typedef enum
{
    SID_MODEL_6581 = 0,
    SID_MODEL_8580 = 1
} sid_model_t;

/* One logged register write: cycle offset from the start of the frame. */
typedef struct
{
    uint16_t cycle;
    uint8_t  reg;     /* 0..31 */
    uint8_t  val;
} sid_write_t;

void sid_reset(sid_model_t model);
void sid_write(uint8_t reg, uint8_t val);
void sid_render(const sid_write_t *log, uint32_t n_writes, int16_t *out, uint32_t n_samples);
uint8_t sid_read_osc3(void);
uint8_t sid_read_env3(void);
uint8_t sid_voice_level(uint32_t voice);
sid_model_t sid_model(void);

/* ---- constant tables, defined in sid_tables.c (generated by tools/resid_tables.py) ---- */

#define SID_TAB_MODELS         (2u)
#define SID_TAB_COMBOS         (4u)
#define SID_TAB_ST             (0u)        /* saw + triangle, indexed by saw (acc >> 12) */
#define SID_TAB_PT             (1u)        /* pulse + triangle, indexed by triangle >> 1 */
#define SID_TAB_PS             (2u)        /* pulse + saw, indexed by saw */
#define SID_TAB_PST            (3u)        /* pulse + saw + triangle, indexed by saw */
#define SID_TAB_FC_ENTRIES     (2048u)     /* 11-bit FC */
#define SID_TAB_RES_ENTRIES    (16u)       /* 4-bit RES */

/* Trimmed 8-bit combined-waveform table: value(i) = data[(i & mask) - first] when
 * (i & mask) - first < count, else 0. The value is the upper 8 of 12 output bits. */
typedef struct
{
    const uint8_t *data;
    uint16_t       first;
    uint16_t       count;
    uint16_t       mask;
} sid_wave_tab_t;

const sid_wave_tab_t *sid_tables_wave(sid_model_t model, uint32_t combo);
const uint16_t *sid_tables_cutoff_hz(sid_model_t model);
uint32_t sid_tables_res_q10(uint32_t res);

#endif /* SID_H */
