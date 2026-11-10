/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: backend.h
 * Role: the storage-backend surface of core 1 ("1541" drive). cbmdos.c (the
 *   CBM-DOS emulation) reaches files only through this surface and never
 *   knows which backend serves them.
 *
 * Backends: backend_smb.c (network share, libsmb2), backend_ram.c (bring-up
 *   RAM disk in DDR3), later backend_sd.c (microSD + FatFs). Each backend
 *   implements every function below under the prefix backend_<name>_ (for
 *   example backend_smb_open). BACKEND_OPS(name) builds the dispatch table
 *   by token pasting, so a backend that lacks one entry point fails the
 *   build; that symmetry is the point (embedded_ccoding.md section 2).
 *
 * Paths: '/'-separated, relative to the backend root (the SMB base folder),
 *   no leading slash; "" is the root. Names are the backend's native names
 *   (UTF-8 for SMB); PETSCII mapping belongs to cbmdos.c.
 *
 * Concurrency: one context (the superloop, fw_1541/src/main.c) calls a
 *   backend; no entry point is reentrant or callable from an ISR.
 *
 * Errors: every entry point returns backend_status_t. BACKEND_OK is success;
 *   cbmdos.c maps the rest to CBM DOS status codes (common/drive_proto.h):
 *   NOT_READY -> 74, NOT_FOUND -> 62, the rest -> 74 with the backend's
 *   status text on the core 1 log. A backend never limps: after
 *   BACKEND_ERR_NOT_READY every call except mount and status_text returns
 *   NOT_READY until a mount succeeds (retry is confined to mount, the
 *   session entry).
 *
 * Headers hold contracts and constants; per-function commentary lives in the
 *   backend .c files.
 */
#ifndef BACKEND_H
#define BACKEND_H

#include <stddef.h> /* size_t */
#include <stdint.h> /* uint8_t, uint32_t, uint64_t */

/* Longest native name a directory entry returns, NUL included. Longer names
 * are skipped by readdir (cbmdos shows 16 PETSCII characters in any case). */
#define BACKEND_NAME_BYTES       (256u)

/* Longest path (root-relative, NUL included) a caller may pass. */
#define BACKEND_PATH_BYTES       (512u)

/* Open files at once. CBM DOS channels 0..14 can each hold one, but the
 * C64 side opens one at a time (LOAD) and D64 mounts hold one more:
 * 4 covers LOAD + D64 image + two data channels. */
#define BACKEND_MAX_FILES        (4u)

/* Status text buffer a caller passes to status_text (NUL included). */
#define BACKEND_STATUS_TEXT_BYTES (128u)

typedef enum
{
    BACKEND_OK = 0,
    BACKEND_END,                /* readdir: no more entries */
    BACKEND_ERR_NOT_READY,      /* not mounted, link lost, server unreachable */
    BACKEND_ERR_AUTH,           /* logon or share access refused */
    BACKEND_ERR_NOT_FOUND,      /* path does not exist */
    BACKEND_ERR_NOT_DIR,        /* opendir on a file / open on a directory */
    BACKEND_ERR_NO_HANDLE,      /* BACKEND_MAX_FILES or the one directory slot in use */
    BACKEND_ERR_ARG,            /* bad handle, path too long, NULL pointer */
    BACKEND_ERR_IO              /* any other backend failure (see status_text) */
} backend_status_t;

typedef enum
{
    BACKEND_ENT_FILE = 0,
    BACKEND_ENT_DIR,
    BACKEND_ENT_OTHER           /* links, devices: cbmdos hides them */
} backend_ent_type_t;

typedef struct
{
    char               name[BACKEND_NAME_BYTES];
    uint64_t           size;    /* bytes; 0 for directories */
    backend_ent_type_t type;
} backend_dirent_t;

/* Handle of an open file: 0 .. BACKEND_MAX_FILES - 1. */
typedef uint32_t backend_file_t;

/* Entry points of one backend. The prototypes each backend header declares:
 *   backend_<name>_init(void)
 *       one-time setup at boot; no network or media access.
 *   backend_<name>_mount(void)
 *       connect and mount the root (session entry; bounded retries inside).
 *       Already mounted: BACKEND_OK without traffic.
 *   backend_<name>_unmount(void)
 *       close every handle and disconnect; always leaves the backend
 *       unmounted.
 *   backend_<name>_opendir(const char *path)
 *       one directory listing open at a time.
 *   backend_<name>_readdir(backend_dirent_t *ent)
 *       next entry of the open listing ("." and ".." skipped); BACKEND_END
 *       at the end.
 *   backend_<name>_closedir(void)
 *   backend_<name>_open(const char *path, backend_file_t *fh, uint64_t *size)
 *       read-only open; *size = file length in bytes.
 *   backend_<name>_read(backend_file_t fh, uint8_t *buf, uint32_t max,
 *                       uint32_t *got, int *eof)
 *       up to max bytes from the current position; *eof = 1 when the bytes
 *       returned end the file (the CBM EOI flag rides on the last byte).
 *   backend_<name>_close(backend_file_t fh)
 *   backend_<name>_free_bytes(uint64_t *bytes)
 *       free space of the volume that holds the root.
 *   backend_<name>_status_text(char *buf, size_t n)
 *       one line describing the last failure (or "OK"), for the log and
 *       DRIVE STATUS; never contains credentials. */
typedef struct
{
    backend_status_t (*init)(void);
    backend_status_t (*mount)(void);
    backend_status_t (*unmount)(void);
    backend_status_t (*opendir)(const char *path);
    backend_status_t (*readdir)(backend_dirent_t *ent);
    backend_status_t (*closedir)(void);
    backend_status_t (*open)(const char *path, backend_file_t *fh, uint64_t *size);
    backend_status_t (*read)(backend_file_t fh, uint8_t *buf, uint32_t max,
                             uint32_t *got, int *eof);
    backend_status_t (*close)(backend_file_t fh);
    backend_status_t (*free_bytes)(uint64_t *bytes);
    backend_status_t (*status_text)(char *buf, size_t n);
} backend_ops_t;

/* Dispatch table of backend <name>, e.g.
 *   static const backend_ops_t g_smb_ops = BACKEND_OPS(smb);
 * Every backend_<name>_<fn> must exist with the prototype above. */
#define BACKEND_OPS(name)                       \
    {                                           \
        backend_##name##_init,                  \
        backend_##name##_mount,                 \
        backend_##name##_unmount,               \
        backend_##name##_opendir,               \
        backend_##name##_readdir,               \
        backend_##name##_closedir,              \
        backend_##name##_open,                  \
        backend_##name##_read,                  \
        backend_##name##_close,                 \
        backend_##name##_free_bytes,            \
        backend_##name##_status_text            \
    }

/* At least one backend must be built (build.ps1 defines the IK64_BACKEND_*). */
#if !defined(IK64_BACKEND_SMB) && !defined(IK64_BACKEND_RAM) && !defined(IK64_BACKEND_SD)
#error "no drive backend selected: define IK64_BACKEND_SMB, IK64_BACKEND_RAM or IK64_BACKEND_SD"
#endif

#endif /* BACKEND_H */
