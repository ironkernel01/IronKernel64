/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: backend_ram.h
 * Role: the read-only tune bank backend of core 1 (device 9): serves the bank image in DDR3 at
 *   C64_PLAT_BANK_BASE (common/c64_platform.h) through backend.h. Format: bank_format.h.
 *
 * Behavior:
 *   - The directory is the bank's entry table, one flat folder (path "" only); every entry is a
 *     regular file. cbmdos does the PETSCII mapping, extension hiding and wildcards, exactly as
 *     for device 8.
 *   - mount validates the image again every time it is called (magic, version, bounds, header
 *     CRC), after invalidating the D-cache over the bank, so a bank that JTAG wrote while core 1
 *     was running is picked up at the next OPEN. A bad or absent image answers
 *     BACKEND_ERR_NOT_READY (DOS 74,DRIVE NOT READY) and logs one line per change of state.
 *   - open verifies the file's data CRC; a mismatch is BACKEND_ERR_IO and one log line.
 *   - Never touches the network and needs no other service: device 9 works from boot.
 * Host builds (-DIK64_HOST_TEST) skip the cache call and take the image from
 *   backend_ram_set_image.
 *
 * Revision: 11-10-2026
 *   * 11-10-2026: initial version.
 */
#ifndef BACKEND_RAM_H
#define BACKEND_RAM_H

#include "backend.h"

#include <stdint.h>

backend_status_t backend_ram_init(void);
backend_status_t backend_ram_mount(void);
backend_status_t backend_ram_unmount(void);
backend_status_t backend_ram_opendir(const char *path);
backend_status_t backend_ram_readdir(backend_dirent_t *ent);
backend_status_t backend_ram_closedir(void);
backend_status_t backend_ram_open(const char *path, backend_file_t *fh, uint64_t *size);
backend_status_t backend_ram_read(backend_file_t fh, uint8_t *buf, uint32_t max, uint32_t *got, int *eof);
backend_status_t backend_ram_close(backend_file_t fh);
backend_status_t backend_ram_free_bytes(uint64_t *bytes);
backend_status_t backend_ram_status_text(char *buf, size_t n);

/* Point the backend at another image (host tests; the firmware uses the fixed bank address). */
void backend_ram_set_image(const uint8_t *img, uint32_t avail);

#endif /* BACKEND_RAM_H */
