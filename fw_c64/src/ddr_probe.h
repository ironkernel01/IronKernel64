/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: ddr_probe.h
 * Role: boot-time DDR3 check on core 0: wait for MIG calibration, find the populated size
 *   by alias probing, run a short pattern check, and report size and free bytes for the
 *   boot screen ("512M RAM SYSTEM  ... BYTES FREE").
 *
 * Contract:
 *   - Reads C64_SYS_CLK_STATUS (bit C64_SYS_CLK_DDR_CALIB_BIT) read-only; the wait is
 *     bounded by DDR_PROBE_CALIB_TIMEOUT_MS.
 *   - Writes only inside core 0's reservation and above both reservations
 *     (c64_platform.h), and restores every probed word, so core 1's code and data and a
 *     JTAG-loaded bring-up bank in core 0's region survive. Run it before anything else
 *     on core 0 uses the probed words (it is not safe against a concurrent writer of the
 *     same words).
 *   - Size: a power of two between 1 MiB and the BD window (C64_PLAT_DDR_WINDOW).
 *     free_bytes = size - (core 1 + core 0 reservation), 0 when the size is smaller.
 *   - Never fail-stops: the caller decides (the boot screen still comes up).
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef DDR_PROBE_H
#define DDR_PROBE_H

#include <stdint.h> /* uint32_t */

#define DDR_PROBE_CALIB_TIMEOUT_MS  (2000u)
#define DDR_PROBE_K_MIN             (20u)   /* first alias offset 2^20 = 1 MiB */
#define DDR_PROBE_K_MAX             (28u)   /* last alias offset 2^28 = 256 MiB */

typedef enum
{
    DDR_PROBE_OK = 0,
    DDR_PROBE_NO_CALIB,      /* init_calib_complete stayed low */
    DDR_PROBE_NO_MEMORY,     /* a probe word did not read back */
    DDR_PROBE_PATTERN_FAIL   /* size found, pattern check failed */
} ddr_probe_status_t;

typedef struct
{
    uint32_t size_bytes;        /* populated size (0 when unknown) */
    uint32_t free_bytes;        /* size minus both core reservations */
    uint32_t calib_ms;          /* time spent waiting for calibration */
    uint32_t pattern_errors;    /* words that failed the pattern check */
    uint32_t first_bad_addr;    /* first failing address (0 when none) */
} ddr_probe_result_t;

ddr_probe_status_t ddr_probe_run(ddr_probe_result_t *res);
const char *ddr_probe_status_text(ddr_probe_status_t st);

#endif /* DDR_PROBE_H */
