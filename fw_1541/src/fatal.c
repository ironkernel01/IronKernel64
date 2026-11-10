/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: fatal.c
 * Role: core 1's fail-stop handler.
 *   No RTOS hooks (IK64_DEVIATION 11, DEVIATIONS.md).
 */
#include "fatal.h"

#include <stddef.h> /* NULL */

#include "drive_log.h"     /* drive_log_printf */

/*
 * ik64_fatal -- log the failing API and code, then park core 1.
 * Steps:
 *   1. Log "FATAL: <api> code <code> (0x<code>)" to the shared-BRAM ring.
 *   2. Disable interrupts so no ISR runs on corrupt state.
 *   3. Park in wfi; the loop never exits (a debugger can inspect state).
 * Returns: never.
 */
void ik64_fatal(const char *api, int32_t code)
{
    drive_log_printf("FATAL: %s code %ld (0x%08lx)\r\n", (api != NULL) ? api : "?",
                     (long)code, (unsigned long)(uint32_t)code);
    __asm volatile("csrci mstatus, 8" ::: "memory");   /* clear MIE */
    for (;;) {
        __asm volatile("wfi");
    }
}
