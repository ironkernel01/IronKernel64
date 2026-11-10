/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_log.h
 * Role: the console of core 1. Core 1 has no UART and no JTAG UART; its text
 *   goes into the log ring in the shared BRAM (common/drive_proto.h
 *   DRIVE_LOG_OFS, drive_log_t) and core 0 prints it.
 *
 * Owner: drive_log.c is the only writer of the ring's text, head and dropped
 *   fields on core 1 (core 0 owns tail). drive_server.c owns the rest of the
 *   shared BRAM.
 * Ring full: new text is dropped and counted in drive_log_t.dropped; logging
 *   never blocks and never waits for core 0.
 * Context: the main superloop only (core 1 has no RTOS and no ISR that logs;
 *   it formats with vsnprintf and takes no lock).
 * Never log credentials (they stay in the uncommitted netshare_config.h).
 *
 * Headers hold contracts; per-function commentary lives in drive_log.c.
 */
#ifndef DRIVE_LOG_H
#define DRIVE_LOG_H

#include <stdint.h> /* uint32_t */

/* Longest line drive_log_printf formats (NUL included); longer text is cut. */
#define DRIVE_LOG_LINE_BYTES     (160u)

void drive_log_init(void);
void drive_log_write(const char *s, uint32_t n);
uint32_t drive_log_free_bytes(void);
void drive_log_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif /* DRIVE_LOG_H */
