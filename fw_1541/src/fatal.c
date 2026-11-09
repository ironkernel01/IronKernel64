/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: fatal.c
 * Role: core 1's fail-stop handler and the FreeRTOS hooks that end in it.
 */
#include "fatal.h"

#include "drive_log.h"     /* drive_log_printf */

#include "FreeRTOS.h"      /* TaskHandle_t, taskDISABLE_INTERRUPTS */
#include "task.h"          /* vApplicationStackOverflowHook prototype */

/*
 * ik64_fatal -- log the failing API and code, then park core 1.
 * Steps:
 *   1. Log "FATAL: <api> code <code> (0x<code>)" to the shared-BRAM ring.
 *   2. Disable interrupts so no task or ISR runs on corrupt state.
 *   3. Park in wfi; the loop never exits (a debugger can inspect state).
 * Returns: never.
 */
void ik64_fatal(const char *api, int32_t code)
{
    drive_log_printf("FATAL: %s code %ld (0x%08lx)\r\n", (api != NULL) ? api : "?",
                     (long)code, (unsigned long)(uint32_t)code);
    taskDISABLE_INTERRUPTS();
    for (;;) {
        __asm volatile("wfi");
    }
}

/*
 * ik64_freertos_assert -- configASSERT target (net/FreeRTOSConfig.h).
 * Steps:
 *   1. Log the file and line of the failed assertion.
 *   2. ik64_fatal("configASSERT", line).
 * Returns: never.
 */
void ik64_freertos_assert(const char *file, int line)
{
    drive_log_printf("configASSERT failed at %s:%d\r\n", (file != NULL) ? file : "?", line);
    ik64_fatal("configASSERT", (int32_t)line);
}

/*
 * vApplicationStackOverflowHook -- FreeRTOS stack-overflow check (method 2).
 * Steps:
 *   1. Log the task name; ik64_fatal.
 * Returns: never.
 */
void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task;
    drive_log_printf("stack overflow in task %s\r\n", (name != NULL) ? name : "?");
    ik64_fatal("vApplicationStackOverflowHook", 0);
}

/*
 * vApplicationMallocFailedHook -- pvPortMalloc found its bounded arena full
 *   (lwIP sys_arch objects, IK64_DEVIATION 3).
 * Steps:
 *   1. ik64_fatal: the arena size in FreeRTOSConfig.h is the contract.
 * Returns: never.
 */
void vApplicationMallocFailedHook(void)
{
    ik64_fatal("pvPortMalloc", (int32_t)configTOTAL_HEAP_SIZE);
}
