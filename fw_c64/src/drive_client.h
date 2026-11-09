/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_client.h
 * Role: core 0 side of the drive protocol (common/drive_proto.h): requests to the emulated
 *   1541 (device 8) on core 1 through the shared BRAM and the AXI Mailbox doorbell.
 *
 * Ownership: drive_client.c is the only core 0 file that touches the mailbox (mailbox_0,
 *   XMbox driver) and the shared BRAM (C64_PLAT_SHM_BASE). Peer: fw_1541 drive_server.c.
 *
 * Contract:
 *   - One request at a time, synchronous: every call returns after the reply or after its
 *     timeout. DRIVE_CLIENT_PING_TIMEOUT_MS bounds PING; DRIVE_CLIENT_OP_TIMEOUT_MS bounds
 *     every other request (the drive may reconnect to the network share first).
 *   - DRIVE_CLIENT_TIMEOUT means the drive did not answer: the C64 reports
 *     ?DEVICE NOT PRESENT  ERROR. A reply arriving after its timeout is discarded when the
 *     next request starts.
 *   - DRIVE_CLIENT_DOS_ERROR means the drive answered with a CBM DOS status >= 20
 *     (drive_client_last_status(): 62 = FILE NOT FOUND, 74 = DRIVE NOT READY, ...).
 *   - A reply with a wrong magic, a seq that belongs to no request, or a READ length larger
 *     than requested is a protocol fault: fail-stop (print and park).
 *   - Names and command text are PETSCII, NUL-terminated, at most DRIVE_NAME_BYTES - 1
 *     characters (longer text is rejected with DRIVE_CLIENT_BAD_ARG).
 * Headers hold contracts and constants; per-function commentary lives in the .c files.
 */
#ifndef DRIVE_CLIENT_H
#define DRIVE_CLIENT_H

#include <stdint.h> /* uint8_t, uint32_t */

#include "drive_proto.h"

#define DRIVE_CLIENT_PING_TIMEOUT_MS  (250u)
#define DRIVE_CLIENT_OP_TIMEOUT_MS    (15000u)
#define DRIVE_CLIENT_DOS_ERROR_MIN    (20u)    /* CBM DOS codes below 20 are not errors */

typedef enum
{
    DRIVE_CLIENT_OK = 0,
    DRIVE_CLIENT_DOS_ERROR,    /* reply status >= 20 */
    DRIVE_CLIENT_TIMEOUT,      /* no reply: device not present */
    DRIVE_CLIENT_TOO_BIG,      /* drive_client_load: file larger than the buffer */
    DRIVE_CLIENT_BAD_ARG       /* name too long, length 0, channel out of range */
} drive_client_result_t;

void     drive_client_init(void);
drive_client_result_t drive_client_ping(void);
drive_client_result_t drive_client_open(uint8_t channel, const char *name);
drive_client_result_t drive_client_read(uint8_t channel, uint8_t *buf, uint32_t max,
                                        uint32_t *len, int *eoi);
drive_client_result_t drive_client_close(uint8_t channel);
drive_client_result_t drive_client_cmd(const char *text);
drive_client_result_t drive_client_status(void);
drive_client_result_t drive_client_load(const char *name, uint8_t *buf, uint32_t max,
                                        uint32_t *len);
uint8_t  drive_client_last_status(void);
void     drive_client_last_text(char *text, uint32_t size);
uint32_t drive_client_log_drain(void (*put)(char c), uint32_t max);

#endif /* DRIVE_CLIENT_H */
