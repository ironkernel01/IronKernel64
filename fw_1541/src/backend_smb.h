/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: backend_smb.h
 * Role: the network-share backend of core 1: implements backend.h over
 *   libsmb2's synchronous API (third_party/libsmb2) against the share in
 *   fw_1541/netshare_config.h (gitignored; template netshare_config.example.h).
 *
 * Owner: backend_smb.c is the only file that calls libsmb2.
 * Context: the drive task only (backend.h). libsmb2 blocks the caller in
 *   poll() on its lwIP socket; every command is bounded by the libsmb2
 *   timeout NETSHARE_TIMEOUT_S.
 * Mount: bounded retries at session entry only (BACKEND_SMB_MOUNT_TRIES,
 *   BACKEND_SMB_RETRY_DELAY_MS). Logon refusals (wrong password, unknown
 *   share) are not retried. A failed command on a mounted share that is not
 *   a plain "not found" / "not a directory" drops the connection; the next
 *   mount reconnects.
 * Logging: server, share, user, dialect and NTSTATUS codes; never the
 *   password.
 *
 * Headers hold contracts; per-function commentary lives in backend_smb.c.
 */
#ifndef BACKEND_SMB_H
#define BACKEND_SMB_H

#include "backend.h"   /* backend_status_t, backend_dirent_t, backend_file_t */

#include <stddef.h>    /* size_t */
#include <stdint.h>    /* uint8_t, uint32_t, uint64_t */

/* Connect attempts per mount call, and the pause between them. 3 x
 * (NETSHARE_TIMEOUT_S + 1 s) bounds a mount on a dead link to about 33 s. */
#define BACKEND_SMB_MOUNT_TRIES      (3u)
#define BACKEND_SMB_RETRY_DELAY_MS   (1000u)

/* Largest single SMB2 READ backend_smb.c issues: the drive data area
 * (common/drive_proto.h DRIVE_DATA_BYTES = 61,440). With sealing, libsmb2
 * buffers a whole READ transform, so smb_alloc.c's largest class must hold
 * this plus the headers (checked there). Also clipped to the server's
 * negotiated max read size. */
#define BACKEND_SMB_READ_CHUNK       (61440u)

/* smb2_read calls one backend_smb_read may make: each call returns at least
 * one byte or ends the loop, so this bounds a read that the server answers
 * in short pieces. */
#define BACKEND_SMB_READ_MAX_CALLS   (64u)

backend_status_t backend_smb_init(void);
backend_status_t backend_smb_mount(void);
backend_status_t backend_smb_unmount(void);
backend_status_t backend_smb_opendir(const char *path);
backend_status_t backend_smb_readdir(backend_dirent_t *ent);
backend_status_t backend_smb_closedir(void);
backend_status_t backend_smb_open(const char *path, backend_file_t *fh, uint64_t *size);
backend_status_t backend_smb_read(backend_file_t fh, uint8_t *buf, uint32_t max,
                                  uint32_t *got, int *eof);
backend_status_t backend_smb_close(backend_file_t fh);
backend_status_t backend_smb_free_bytes(uint64_t *bytes);
backend_status_t backend_smb_status_text(char *buf, size_t n);

#endif /* BACKEND_SMB_H */
