/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: cbmdos.h
 * Role: the CBM DOS emulation of core 1 ("1541" drive, device 8), backend
 *   neutral: it reaches files only through backend.h.
 *
 * Covered (everything else is out of scope for now):
 *   - OPEN by name on channel 0 / 2..14 with CBM wildcards '*' and '?', matched
 *     case-insensitively against the share names mapped to PETSCII upper case
 *     and cut to 16 characters ('_' in a share name equals a space in the
 *     pattern, because CBM users type spaces). Only regular files match; the
 *     first match in share order wins. A ",P,R"-style suffix and a leading
 *     "0:" are ignored.
 *   - OPEN "$" (also "$0", "$:pat", "$0:pat"): the directory as the 1541's
 *     BASIC program (load address $0401, line links, line number = blocks =
 *     ceil(size/254), header 0 "IRONKERNEL NET  " 64 2A in reverse, every
 *     regular file PRG, subdirectories DIR, BLOCKS FREE. = min(free/254,
 *     65535)). Built in a static buffer of CBMDOS_DIR_BYTES; a listing that
 *     does not fit is cut (the footer is always written).
 *   - READ (EOI on the last chunk; a file streams through backend_read, no
 *     file buffer), CLOSE, STATUS.
 *   - CMD: every DOS command (CD, I, UI, wedge commands) answers
 *     31,SYNTAX ERROR for now. Writing (channel 1) answers 26,WRITE PROTECT ON.
 * One channel is open at a time; a new OPEN closes the previous one.
 * Backend failure (NOT_READY, IO, AUTH) answers 74,DRIVE NOT READY and raises
 * the lost flag that drive_server turns into "not ready" until main remounts.
 *
 * Context: the main superloop only; no heap, no waits of its own (the backend
 * bounds every wait).
 *
 * Headers hold contracts; per-function commentary lives in cbmdos.c.
 */
#ifndef CBMDOS_H
#define CBMDOS_H

#include "backend.h"

#include <stdint.h>

/* Static directory image: about 1,000 entries of 32 bytes plus header and footer. */
#define CBMDOS_DIR_BYTES         (32768u)

/* DOS status codes returned by the calls below (1541 numbering). */
#define CBMDOS_OK                (0u)
#define CBMDOS_WRITE_PROTECT     (26u)
#define CBMDOS_SYNTAX            (31u)
#define CBMDOS_FILE_NOT_FOUND    (62u)
#define CBMDOS_NO_CHANNEL        (70u)
#define CBMDOS_NOT_READY         (74u)

void cbmdos_init(const backend_ops_t *ops);
void cbmdos_abort(void);
uint8_t cbmdos_open(uint8_t channel, const char *name);
uint8_t cbmdos_read(uint8_t channel, uint8_t *out, uint32_t want, uint32_t *got, int *eoi);
uint8_t cbmdos_close(uint8_t channel);
uint8_t cbmdos_cmd(const char *text);
uint8_t cbmdos_take_status(void);
const char *cbmdos_text(uint8_t status);
const char *cbmdos_info(void);
int cbmdos_take_backend_lost(void);

#endif /* CBMDOS_H */
