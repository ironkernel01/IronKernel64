/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ddr_probe.c
 * Role: DDR3 calibration wait, populated-size alias probe and pattern check (contract in
 *   ddr_probe.h).
 *
 * Hardware: reads the core 0 c64_sysregs CLK_STATUS register (read-only, C64_PLAT_WIN0_BASE +
 *   C64_WIN_SYS_OFS) and the cached DDR3 window (C64_PLAT_DDR_BASE). Every write is followed
 *   by Xil_DCacheFlushRange and every read that must come from the SDRAM is preceded by
 *   Xil_DCacheInvalidateRange, so the cache never answers for the memory.
 *
 * Where the probe writes, and why core 1 is safe:
 *   - Reference word REF = C64_PLAT_DDR_CORE0_BASE (0x8400_0000, start of core 0's region).
 *   - Probe points P(k) = REF + 2^k for k = 20..28. For k <= 25 they lie inside core 0's
 *     64 MiB region; for k >= 26 they lie at or above 0x8800_0000, above both
 *     reservations. Core 1's region [0x8000_0000, 0x8400_0000) is never addressed.
 *   - With a populated size S (a power of two), P(k) and REF hit the same SDRAM word exactly
 *     when S <= 2^k, so the first k whose P(k) write changes REF gives S = 2^k. No alias up
 *     to k = 28 means S = 2^29 = the 512 MiB window.
 *   - All probed words are read first and written back at the end. Only a board with less
 *     than 128 MiB would fold REF or a probe point onto core 1's region; the restore puts
 *     the original value back there too (both aliases saved the same value).
 * Pattern check: DDRP_PATTERN_WORDS words 512 KiB into core 0's region, at the first
 *   free address above both reservations and at the top of the detected memory, each saved,
 *   written with six patterns (zeros, ones, AA, 55, address, ~address), read back from the
 *   SDRAM, and restored.
 */
#include "ddr_probe.h"

#include "c64_platform.h"
#include "c64_regs.h"

#include "sleep.h"      /* usleep (bounded calibration wait) */
#include "xil_cache.h"  /* Xil_DCacheFlushRange, Xil_DCacheInvalidateRange */
#include "xil_io.h"     /* Xil_In32 */

#define DDRP_SYS_STATUS      (C64_PLAT_WIN0_BASE + C64_WIN_SYS_OFS + C64_SYS_CLK_STATUS_OFS)
#define DDRP_CALIB_POLL_US   (100u)
#define DDRP_POLLS_PER_MS    (1000u / DDRP_CALIB_POLL_US)
#define DDRP_REF             (C64_PLAT_DDR_CORE0_BASE)
#define DDRP_RES_END         (C64_PLAT_DDR_CORE0_BASE + C64_PLAT_DDR_CORE0_SIZE)
#define DDRP_RESERVED        (C64_PLAT_DDR_CORE1_SIZE + C64_PLAT_DDR_CORE0_SIZE)
#define DDRP_POINTS          (DDR_PROBE_K_MAX - DDR_PROBE_K_MIN + 1u)
#define DDRP_TAG_REF         (0x52454630u)           /* "REF0" */
#define DDRP_TAG_BASE        (0x50524B00u)           /* "PRK" + k */
#define DDRP_PATTERN_WORDS   (16u)                  /* 64 bytes = 4 cache lines */
#define DDRP_PATTERNS        (6u)
#define DDRP_LINES           (3u)
#define DDRP_WORD_BYTES      (4u)
#define DDRP_MIB             (0x00100000u)

#if (DDRP_REF + (1u << DDR_PROBE_K_MAX) + DDRP_WORD_BYTES) > \
    (C64_PLAT_DDR_BASE + C64_PLAT_DDR_WINDOW)
#error "the largest DDR probe point lies outside the DDR3 window"
#endif
#if (DDRP_REF + (1u << 25) + DDRP_WORD_BYTES) > DDRP_RES_END || (DDRP_REF + (1u << 26)) < DDRP_RES_END
#error "probe points up to 2^25 must lie in core 0's region and from 2^26 above both reservations"
#endif
#if C64_PLAT_DDR_CORE0_BASE != (C64_PLAT_DDR_CORE1_BASE + C64_PLAT_DDR_CORE1_SIZE)
#error "ddr_probe assumes core 0's region directly follows core 1's"
#endif

/*
 * rd -- read one word from the SDRAM (invalidate its line first).
 * Returns: the word.
 */
static uint32_t rd(uint32_t addr)
{
    Xil_DCacheInvalidateRange(addr, DDRP_WORD_BYTES);
    return *(volatile const uint32_t *)addr;
}

/*
 * wr -- write one word and push it to the SDRAM.
 * Returns: nothing.
 */
static void wr(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
    Xil_DCacheFlushRange(addr, DDRP_WORD_BYTES);
}

/*
 * wait_calib -- wait for MIG init_calib_complete.
 * Steps:
 *   1. Poll CLK_STATUS every DDRP_CALIB_POLL_US for at most DDR_PROBE_CALIB_TIMEOUT_MS.
 * Returns: 1 calibrated, 0 timed out; *ms = time waited.
 */
static int wait_calib(uint32_t *ms)
{
    const uint32_t polls = DDR_PROBE_CALIB_TIMEOUT_MS * DDRP_POLLS_PER_MS;

    for (uint32_t i = 0u; i <= polls; i++) {
        if ((Xil_In32(DDRP_SYS_STATUS) & (1u << C64_SYS_CLK_DDR_CALIB_BIT)) != 0u) {
            *ms = i / DDRP_POLLS_PER_MS;
            return 1;
        }
        usleep(DDRP_CALIB_POLL_US);
    }
    *ms = DDR_PROBE_CALIB_TIMEOUT_MS;
    return 0;
}

/*
 * alias_probe -- find the populated size (see the file header for the method).
 * Steps:
 *   1. Save REF and every probe point.
 *   2. For k = 20..28: write the REF tag, then the point tag at P(k); read both back from
 *      the SDRAM. A lost point tag means no memory there; a changed REF means S = 2^k.
 *   3. Restore every saved word.
 * Returns: DDR_PROBE_OK with *size set, or DDR_PROBE_NO_MEMORY.
 */
static ddr_probe_status_t alias_probe(uint32_t *size)
{
    uint32_t saved_ref;
    uint32_t saved[DDRP_POINTS];
    ddr_probe_status_t st = DDR_PROBE_OK;

    *size = C64_PLAT_DDR_WINDOW;
    saved_ref = rd(DDRP_REF);
    for (uint32_t i = 0u; i < DDRP_POINTS; i++) {
        saved[i] = rd(DDRP_REF + (1u << (DDR_PROBE_K_MIN + i)));
    }
    for (uint32_t i = 0u; i < DDRP_POINTS; i++) {
        uint32_t k = DDR_PROBE_K_MIN + i;
        uint32_t p = DDRP_REF + (1u << k);

        wr(DDRP_REF, DDRP_TAG_REF);
        wr(p, DDRP_TAG_BASE + k);
        if (rd(p) != DDRP_TAG_BASE + k) {
            st = DDR_PROBE_NO_MEMORY;
            *size = 0u;
            break;
        }
        if (rd(DDRP_REF) != DDRP_TAG_REF) {
            *size = 1u << k;
            break;
        }
    }
    for (uint32_t i = DDRP_POINTS; i > 0u; i--) {
        wr(DDRP_REF + (1u << (DDR_PROBE_K_MIN + i - 1u)), saved[i - 1u]);
    }
    wr(DDRP_REF, saved_ref);
    return st;
}

/*
 * pattern_word -- pattern p for the word at addr.
 * Returns: the expected word.
 */
static uint32_t pattern_word(uint32_t p, uint32_t addr)
{
    switch (p) {
    case 0u: return 0x00000000u;
    case 1u: return 0xFFFFFFFFu;
    case 2u: return 0xAAAAAAAAu;
    case 3u: return 0x55555555u;
    case 4u: return addr;
    default: return ~addr;
    }
}

/*
 * pattern_line -- save, test with every pattern, and restore one block of words.
 * Steps:
 *   1. Save DDRP_PATTERN_WORDS words.
 *   2. For each pattern: write the block, flush it, invalidate it, read and compare.
 *   3. Restore the saved words.
 * Returns: nothing; mismatches are counted in res.
 */
static void pattern_line(uint32_t base, ddr_probe_result_t *res)
{
    uint32_t saved[DDRP_PATTERN_WORDS];
    const uint32_t bytes = DDRP_PATTERN_WORDS * DDRP_WORD_BYTES;

    Xil_DCacheInvalidateRange(base, bytes);
    for (uint32_t i = 0u; i < DDRP_PATTERN_WORDS; i++) {
        saved[i] = *(volatile const uint32_t *)(base + i * DDRP_WORD_BYTES);
    }
    for (uint32_t p = 0u; p < DDRP_PATTERNS; p++) {
        for (uint32_t i = 0u; i < DDRP_PATTERN_WORDS; i++) {
            uint32_t a = base + i * DDRP_WORD_BYTES;
            *(volatile uint32_t *)a = pattern_word(p, a);
        }
        Xil_DCacheFlushRange(base, bytes);
        Xil_DCacheInvalidateRange(base, bytes);
        for (uint32_t i = 0u; i < DDRP_PATTERN_WORDS; i++) {
            uint32_t a = base + i * DDRP_WORD_BYTES;
            if (*(volatile const uint32_t *)a != pattern_word(p, a)) {
                if (res->pattern_errors == 0u) {
                    res->first_bad_addr = a;
                }
                res->pattern_errors++;
            }
        }
    }
    for (uint32_t i = 0u; i < DDRP_PATTERN_WORDS; i++) {
        *(volatile uint32_t *)(base + i * DDRP_WORD_BYTES) = saved[i];
    }
    Xil_DCacheFlushRange(base, bytes);
}

/*
 * ddr_probe_run -- calibration wait, size probe, pattern check, free bytes.
 * Steps:
 *   1. Wait for calibration (bounded); stop with DDR_PROBE_NO_CALIB.
 *   2. Alias-probe the size; stop with DDR_PROBE_NO_MEMORY.
 *   3. Pattern-check a block 512 KiB into core 0's region and, when memory reaches past both
 *      reservations, the first free block and the last block of memory.
 *   4. free = size - both reservations (0 when smaller).
 * Returns: DDR_PROBE_OK, or the first failure; res is filled as far as the run got.
 */
ddr_probe_status_t ddr_probe_run(ddr_probe_result_t *res)
{
    uint32_t lines[DDRP_LINES];
    uint32_t n = 0u;
    ddr_probe_status_t st;
    const uint32_t block = DDRP_PATTERN_WORDS * DDRP_WORD_BYTES;

    res->size_bytes = 0u;
    res->free_bytes = 0u;
    res->pattern_errors = 0u;
    res->first_bad_addr = 0u;
    if (!wait_calib(&res->calib_ms)) {
        return DDR_PROBE_NO_CALIB;
    }
    st = alias_probe(&res->size_bytes);
    if (st != DDR_PROBE_OK) {
        return st;
    }
    lines[n++] = DDRP_REF + DDRP_MIB / 2u;
    if (res->size_bytes > DDRP_RESERVED) {
        lines[n++] = DDRP_RES_END;
        lines[n++] = C64_PLAT_DDR_BASE + res->size_bytes - block;
        res->free_bytes = res->size_bytes - DDRP_RESERVED;
    }
    for (uint32_t i = 0u; i < n; i++) {
        pattern_line(lines[i], res);
    }
    return (res->pattern_errors == 0u) ? DDR_PROBE_OK : DDR_PROBE_PATTERN_FAIL;
}

/*
 * ddr_probe_status_text -- short text of a status, for the console banner.
 * Returns: a constant string.
 */
const char *ddr_probe_status_text(ddr_probe_status_t st)
{
    switch (st) {
    case DDR_PROBE_OK:           return "OK";
    case DDR_PROBE_NO_CALIB:     return "calibration timeout";
    case DDR_PROBE_NO_MEMORY:    return "no memory at probe point";
    case DDR_PROBE_PATTERN_FAIL: return "pattern check failed";
    default:                     return "unknown";
    }
}
