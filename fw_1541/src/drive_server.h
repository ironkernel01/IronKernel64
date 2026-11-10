/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_server.h
 * Role: core 1 server of the drive protocol (common/drive_proto.h): takes the
 *   request doorbell from core 0, runs it through cbmdos and answers in the
 *   reply block, the data area and the reply doorbell.
 *
 * Owner: drive_server.c is the only core 1 file that touches the AXI Mailbox
 *   (S1 interface) and the shared BRAM request, reply and data areas; the log
 *   ring stays drive_log's.
 * Devices: the request's device field selects the backend: 8 = SMB share, 9 = tune bank
 *   (backend_ram), anything else is answered 74.
 * Ready: until main calls drive_server_set_ready(1) (SMB share mounted) every device 8
 *   request except CLOSE is answered 74,DRIVE NOT READY, PING included. Device 9 has no ready
 *   flag of its own: it is served whenever the bank validates (also while the network is down). A
 *   backend failure inside a request clears ready again; main then remounts.
 * Context: the main superloop only; drive_server_poll never waits (the
 *   backend bounds its own waits). drive_server_idle is the same poll for the wait loops of
 *   the bring-up; it returns at once while a request is being served.
 *
 * Headers hold contracts; per-function commentary lives in drive_server.c.
 */
#ifndef DRIVE_SERVER_H
#define DRIVE_SERVER_H

#include "backend.h" /* backend_ops_t */

void drive_server_init(const backend_ops_t *smb_ops, const backend_ops_t *bank_ops);
void drive_server_set_ready(int ready);
int  drive_server_ready(void);
void drive_server_poll(void);
void drive_server_idle(void);

#endif /* DRIVE_SERVER_H */
