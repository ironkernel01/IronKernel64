/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: fatal.h
 * Role: core 1's terminal error handler (embedded_ccoding.md section 5.2,
 *   fail-stop). Every failed BSP/RTOS call prints the API name and the
 *   numeric code, then calls ik64_fatal; the handler logs, disables
 *   interrupts and parks the CPU. Core 0 sees the drive stop answering and
 *   shows ?DEVICE NOT PRESENT; the last log lines name the failing call.
 *
 * Headers hold contracts; per-function commentary lives in fatal.c.
 */
#ifndef FATAL_H
#define FATAL_H

#include <stdint.h> /* int32_t */

void ik64_fatal(const char *api, int32_t code) __attribute__((noreturn));

#endif /* FATAL_H */
