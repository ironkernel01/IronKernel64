/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: audio_out.c
 * Role: driver of the sid_audio_out sample FIFO (contract in audio_out.h).
 *
 * Ownership: this file is the only one that accesses the sid_audio_out registers
 *   (C64_PLAT_WIN0_BASE + C64_WIN_AUD_OFS).
 * Concurrency: CTRL is written from the main context (enable, flush, unmask) and from
 *   audio_out_isr (mask). g_ctrl is its shadow; main-context updates run with machine
 *   interrupts held off (mstatus.MIE) so the ISR cannot interleave a read-modify-write.
 *   g_refill is set by the ISR and cleared by audio_out_refill_due (main).
 */
#include "audio_out.h"

#include "c64_platform.h"

#include "xil_io.h"   /* Xil_In32, Xil_Out32 */

#define AUD_REG(ofs)        (C64_PLAT_WIN0_BASE + C64_WIN_AUD_OFS + (uint32_t)(ofs))
#define AUD_LEVEL_MASK      ((1u << C64_AUD_LEVEL_W) - 1u)   /* LEVEL is 0..2048 in 12 bits */
#define AUD_SAMPLE_MASK     (0xFFFFu)
#define AUD_RIGHT_SHIFT     (16u)
#define AUD_MSTATUS_MIE     (8u)

static uint32_t g_ctrl;               /* CTRL shadow */
static uint32_t g_thresh;
static volatile int g_refill;         /* set by audio_out_isr, cleared by the main loop */

/*
 * irq_hold -- hold off machine interrupts.
 * Returns: the previous mstatus.MIE bit.
 */
static inline uint32_t irq_hold(void)
{
    uint32_t old;

    __asm__ volatile ("csrrci %0, mstatus, 8" : "=r"(old) : : "memory");
    return old & AUD_MSTATUS_MIE;
}

/*
 * irq_release -- restore mstatus.MIE as returned by irq_hold.
 * Returns: nothing.
 */
static inline void irq_release(uint32_t mie)
{
    if (mie != 0u) {
        __asm__ volatile ("csrsi mstatus, 8" : : : "memory");
    }
}

/*
 * ctrl_update -- set and clear CTRL bits atomically with respect to the ISR.
 * Returns: nothing.
 */
static void ctrl_update(uint32_t set, uint32_t clear)
{
    uint32_t mie = irq_hold();

    g_ctrl = (g_ctrl & ~clear) | set;
    Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl);
    irq_release(mie);
}

/*
 * audio_out_init -- stopped, empty, threshold at half the FIFO.
 * Steps:
 *   1. CTRL = 0 (silence, interrupt off), flush the FIFO.
 *   2. THRESH = AUDIO_OUT_THRESHOLD; clear stale IRQ/underrun flags (W1C).
 * Returns: nothing.
 */
void audio_out_init(void)
{
    g_ctrl = 0u;
    g_refill = 0;
    Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl);
    Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl | (1u << C64_AUD_CTRL_FLUSH_BIT));
    audio_out_set_threshold(AUDIO_OUT_THRESHOLD);
    Xil_Out32(AUD_REG(C64_AUD_STATUS_OFS),
              (1u << C64_AUD_STATUS_IRQ_BIT) | (1u << C64_AUD_STATUS_UNDERRUN_BIT));
}

/*
 * audio_out_enable -- start (play FIFO, interrupt enabled) or stop (silence) the output.
 * Returns: nothing.
 */
void audio_out_enable(int on)
{
    const uint32_t bits = (1u << C64_AUD_CTRL_ENABLE_BIT) | (1u << C64_AUD_CTRL_IRQ_EN_BIT);

    if (on) {
        ctrl_update(bits, 0u);
    } else {
        ctrl_update(0u, bits);
        g_refill = 0;
    }
}

/*
 * audio_out_set_source -- select the sample source of the FIFO.
 * Steps:
 *   1. CTRL.SRC = 1: the FIFO takes the 48 kHz stream of sid_player (the SAMPLE register is
 *      then ignored); 0: the SAMPLE register (audio_out_push_block).
 * Returns: nothing.
 */
void audio_out_set_source(int fabric)
{
    const uint32_t src = 1u << C64_AUD_CTRL_SRC_BIT;

    if (fabric) {
        ctrl_update(src, 0u);
    } else {
        ctrl_update(0u, src);
    }
}

/*
 * audio_out_flush -- empty the FIFO (FLUSH is self-clearing).
 * Returns: nothing.
 */
void audio_out_flush(void)
{
    uint32_t mie = irq_hold();

    Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl | (1u << C64_AUD_CTRL_FLUSH_BIT));
    Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl);
    irq_release(mie);
}

/*
 * audio_out_set_threshold -- interrupt / refill level in frames (clamped to the FIFO).
 * Returns: nothing.
 */
void audio_out_set_threshold(uint32_t frames)
{
    g_thresh = (frames < C64_AUD_FIFO_DEPTH) ? frames : C64_AUD_FIFO_DEPTH - 1u;
    Xil_Out32(AUD_REG(C64_AUD_THRESH_OFS), g_thresh);
}

/*
 * audio_out_isr -- low-level interrupt handler (connect to the INTC input of sid_audio_out).
 * Steps:
 *   1. If STATUS shows the interrupt: mask it in CTRL (the level condition stays true until
 *      the refill), clear it (W1C), set the refill flag.
 * Returns: nothing. Must not render or push samples.
 */
void audio_out_isr(void *ref)
{
    (void)ref;
    if ((Xil_In32(AUD_REG(C64_AUD_STATUS_OFS)) & (1u << C64_AUD_STATUS_IRQ_BIT)) != 0u) {
        g_ctrl &= ~(1u << C64_AUD_CTRL_IRQ_EN_BIT);
        Xil_Out32(AUD_REG(C64_AUD_CTRL_OFS), g_ctrl);
        Xil_Out32(AUD_REG(C64_AUD_STATUS_OFS), 1u << C64_AUD_STATUS_IRQ_BIT);
        g_refill = 1;
    }
}

/*
 * audio_out_refill_due -- time to render and push the next block.
 * Returns: 1 when the ISR flagged it (flag cleared) or LEVEL <= THRESH, else 0.
 */
int audio_out_refill_due(void)
{
    if (g_refill) {
        g_refill = 0;
        return 1;
    }
    return (audio_out_level() <= g_thresh) ? 1 : 0;
}

/*
 * audio_out_level -- frames waiting in the FIFO.
 * Returns: 0..C64_AUD_FIFO_DEPTH.
 */
uint32_t audio_out_level(void)
{
    return Xil_In32(AUD_REG(C64_AUD_LEVEL_OFS)) & AUD_LEVEL_MASK;
}

/*
 * audio_out_space -- frames that fit into the FIFO now.
 * Returns: C64_AUD_FIFO_DEPTH - level (0 when the level reads above the depth).
 */
uint32_t audio_out_space(void)
{
    uint32_t level = audio_out_level();

    return (level < C64_AUD_FIFO_DEPTH) ? C64_AUD_FIFO_DEPTH - level : 0u;
}

/*
 * audio_out_push_block -- write mono samples as stereo frames.
 * Steps:
 *   1. Limit n to the free space (no blocking).
 *   2. Write each sample to SAMPLE as {right = s, left = s}.
 *   3. Unmask the low-level interrupt again if the output is enabled.
 * Returns: number of samples written.
 */
uint32_t audio_out_push_block(const int16_t *mono, uint32_t n)
{
    uint32_t space = audio_out_space();

    if (n > space) {
        n = space;
    }
    for (uint32_t i = 0u; i < n; i++) {
        uint32_t s = (uint32_t)(uint16_t)mono[i] & AUD_SAMPLE_MASK;
        Xil_Out32(AUD_REG(C64_AUD_SAMPLE_OFS), s | (s << AUD_RIGHT_SHIFT));
    }
    if ((g_ctrl & (1u << C64_AUD_CTRL_ENABLE_BIT)) != 0u) {
        ctrl_update(1u << C64_AUD_CTRL_IRQ_EN_BIT, 0u);
    }
    return n;
}

/*
 * audio_out_underruns -- frames sent while the FIFO was empty (saturating hardware count).
 * Returns: the UNDERRUNS register.
 */
uint32_t audio_out_underruns(void)
{
    return Xil_In32(AUD_REG(C64_AUD_UNDERRUNS_OFS));
}

/*
 * audio_out_status -- STATUS register; clears the latched underrun flag (W1C).
 * Returns: STATUS as read (C64_AUD_STATUS_* bits).
 */
uint32_t audio_out_status(void)
{
    uint32_t st = Xil_In32(AUD_REG(C64_AUD_STATUS_OFS));

    if ((st & (1u << C64_AUD_STATUS_UNDERRUN_BIT)) != 0u) {
        Xil_Out32(AUD_REG(C64_AUD_STATUS_OFS), 1u << C64_AUD_STATUS_UNDERRUN_BIT);
    }
    return st;
}
