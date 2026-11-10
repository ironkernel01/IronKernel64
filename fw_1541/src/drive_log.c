/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_log.c
 * Role: core 1's console: writes text into the shared-BRAM log ring that
 *   core 0 drains and prints (common/drive_proto.h, drive_log_t).
 *
 * Owner of: the ring header fields magic, head and dropped, and the ring
 *   text, on core 1. Core 0 (fw_c64) is the only writer of tail.
 * Memory: the shared BRAM is uncached on both cores (c64_platform.h), so
 *   plain volatile accesses reach it; a fence orders the text stores before
 *   the head store that publishes them.
 */
#include "drive_log.h"

#include "c64_platform.h"  /* C64_PLAT_SHM_BASE */
#include "drive_proto.h"   /* DRIVE_LOG_*, drive_log_t */

#include <stdarg.h>        /* va_list for drive_log_printf */
#include <stdio.h>         /* vsnprintf */

#define DRIVE_LOG_HDR_ADDR   (C64_PLAT_SHM_BASE + DRIVE_LOG_OFS)
#define DRIVE_LOG_TEXT_ADDR  (C64_PLAT_SHM_BASE + DRIVE_LOG_OFS + DRIVE_LOG_HDR_BYTES)

_Static_assert(sizeof(drive_log_t) <= DRIVE_LOG_HDR_BYTES, "drive_log_t exceeds its header area");

static volatile drive_log_t *const g_hdr = (volatile drive_log_t *)DRIVE_LOG_HDR_ADDR;
static volatile char *const g_text = (volatile char *)DRIVE_LOG_TEXT_ADDR;

/*
 * drive_log_init -- reset the ring and publish the magic.
 * Steps:
 *   1. Zero head, tail and dropped (core 0 has not started reading: core 1
 *      calls this before it answers its first mailbox request).
 *   2. Fence, then write DRIVE_LOG_MAGIC so core 0 sees a consistent header.
 * Returns: nothing.
 */
void drive_log_init(void)
{
    g_hdr->magic = 0u;
    g_hdr->head = 0u;
    g_hdr->tail = 0u;
    g_hdr->dropped = 0u;
    __asm volatile("fence" ::: "memory");
    g_hdr->magic = DRIVE_LOG_MAGIC;
}

/*
 * drive_log_write -- append n bytes of text to the ring.
 * Steps:
 *   1. Read head and tail and compute the free space (single-threaded
 *      superloop: no lock, IK64_DEVIATION 11; tail is core 0's, read once).
 *   2. If the text does not fit, count it in dropped and return (logging
 *      never waits for core 0).
 *   3. Copy the bytes to text[(head + i) % DRIVE_LOG_TEXT_BYTES], fence,
 *      then advance head.
 * Returns: nothing.
 */
void drive_log_write(const char *s, uint32_t n)
{
    uint32_t head;
    uint32_t used;
    uint32_t i;

    if ((s == NULL) || (n == 0u)) {
        return;
    }
    head = g_hdr->head;
    used = head - g_hdr->tail;
    if ((used > DRIVE_LOG_TEXT_BYTES) || (n > (DRIVE_LOG_TEXT_BYTES - used))) {
        g_hdr->dropped = g_hdr->dropped + n;
    } else {
        for (i = 0u; i < n; i++) {
            g_text[(head + i) % DRIVE_LOG_TEXT_BYTES] = s[i];
        }
        __asm volatile("fence" ::: "memory");
        g_hdr->head = head + n;
    }
}

/*
 * drive_log_free_bytes -- free space in the ring (core 0 drains it).
 * Steps:
 *   1. Read head and tail once; used = head - tail (clamped to the ring size).
 * Returns: DRIVE_LOG_TEXT_BYTES minus the bytes waiting.
 */
uint32_t drive_log_free_bytes(void)
{
    uint32_t used = g_hdr->head - g_hdr->tail;

    return (used > DRIVE_LOG_TEXT_BYTES) ? 0u : (DRIVE_LOG_TEXT_BYTES - used);
}

/*
 * drive_log_printf -- format one line (at most DRIVE_LOG_LINE_BYTES - 1
 *   characters) and append it to the ring.
 * Steps:
 *   1. vsnprintf into a stack buffer; a longer line is cut at the buffer size.
 *   2. drive_log_write the formatted length.
 * Returns: nothing.
 */
void drive_log_printf(const char *fmt, ...)
{
    char line[DRIVE_LOG_LINE_BYTES];
    va_list ap;
    int len;

    va_start(ap, fmt);
    len = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (len < 0) {
        return;
    }
    if ((uint32_t)len >= sizeof(line)) {
        len = (int)(sizeof(line) - 1u);
    }
    drive_log_write(line, (uint32_t)len);
}
