/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: drive_proto.h
 * Role: the request/reply protocol between core 0 ("C64") and core 1 ("1541"
 *   drive, device 8), carried in the shared 128 KiB BRAM with an AXI Mailbox
 *   doorbell.
 *
 * Devices: 8 is the network share, 9 the built-in tune bank. Core 1 answers device 9 from boot, with or
 *   without the network; an unknown device number is answered 74,DRIVE NOT READY.
 *
 * Owner: this file. Peers that use it: fw_c64/src/drive_client.c (core 0, the
 *   only requester) and fw_1541/src/drive_server.c (core 1, the only server).
 *   The shared BRAM size is owned by fpga/bd/c64_bd.tcl (DRIVE_SHM_BYTES must
 *   equal the BD's shared-BRAM range); change both together.
 *
 * Transaction (one outstanding request at a time):
 *   1. Core 0 fills the request block, then writes its seq to the mailbox.
 *   2. Core 1 takes the doorbell interrupt, reads the request, works, fills the
 *      reply block and the data area, then writes the same seq back through the
 *      mailbox.
 *   3. Core 0 takes the reply doorbell, checks reply.seq == request.seq, and
 *      reads the reply and data. A seq mismatch is a protocol fault (fail-stop
 *      on core 0's side: print and park, see drive_client.c).
 *   Drift failure mode: if the two cores disagree on a field offset, core 1
 *   reads a garbage op/length and replies with a DOS error, or core 0 copies a
 *   wrong length out of the data area; both are caught by the magic and seq
 *   checks only when the header moves, so keep both sides built from this file.
 *
 * Memory: the shared BRAM sits outside both cores' cacheable ranges, so plain
 *   volatile accesses are coherent; no cache maintenance is needed.
 * Byte order: little-endian native words on both cores (both RV32).
 * Headers hold contracts and constants; per-function commentary lives in the
 *   .c files.
 */
#ifndef DRIVE_PROTO_H
#define DRIVE_PROTO_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

/* Shared BRAM geometry (bytes). */
#define DRIVE_SHM_BYTES          (131072u) /* = BD shared-BRAM range (C64_PLAT_SHM_RANGE) */
#define DRIVE_REQ_OFS            (0x0000u) /* drive_req_t */
#define DRIVE_REQ_BYTES          (0x0100u)
#define DRIVE_REP_OFS            (0x0100u) /* drive_rep_t */
#define DRIVE_REP_BYTES          (0x0100u)
#define DRIVE_DATA_OFS           (0x1000u) /* bulk payload, both directions */
#define DRIVE_DATA_BYTES         (DRIVE_LOG_OFS - DRIVE_DATA_OFS) /* 61,440 */
/* Core 1 log ring: core 1 has no UART, so its console text goes here and core 0
 * prints it (CLI). Layout: drive_log_t header, then DRIVE_LOG_TEXT_BYTES of
 * text used as a ring. Core 1 is the only writer of the text and of `head`;
 * core 0 is the only writer of `tail`. Free-running byte counters; the byte
 * at counter c lives at text[c % DRIVE_LOG_TEXT_BYTES]. When head - tail would
 * exceed the ring, core 1 drops the new text and counts it in `dropped`. */
#define DRIVE_LOG_OFS            (0x10000u)
#define DRIVE_LOG_BYTES          (0x10000u)
#define DRIVE_LOG_HDR_BYTES      (0x0040u)
#define DRIVE_LOG_TEXT_BYTES     (DRIVE_LOG_BYTES - DRIVE_LOG_HDR_BYTES) /* 65,472 */
#define DRIVE_LOG_MAGIC          (0x4C4F4731u) /* "LOG1" */

#define DRIVE_MAGIC              (0x31353431u) /* "1541" */
#define DRIVE_PROTO_VERSION      (1u)

#define DRIVE_DEVICE_SMB         (8u)          /* the network share (backend_smb) */
#define DRIVE_DEVICE_BANK        (9u)          /* the built-in tune bank in DDR3 (backend_ram), read-only */
#define DRIVE_DEVICE             (DRIVE_DEVICE_SMB) /* default device when a command names none */
#define DRIVE_NAME_BYTES         (128u)        /* PETSCII name or DOS command, NUL-terminated */
#define DRIVE_STATUS_TEXT_BYTES  (48u)         /* "62,FILE NOT FOUND,00,00" style, NUL-terminated */

/* Channels (CBM DOS secondary addresses). */
#define DRIVE_CH_LOAD            (0u)
#define DRIVE_CH_SAVE            (1u)
#define DRIVE_CH_DATA_FIRST      (2u)
#define DRIVE_CH_DATA_LAST       (14u)
#define DRIVE_CH_COMMAND         (15u)

/* Request opcodes. */
typedef enum
{
    DRIVE_OP_PING   = 1, /* device present? reply status 0 */
    DRIVE_OP_OPEN   = 2, /* name on channel; "$" on DRIVE_CH_LOAD = directory listing program */
    DRIVE_OP_READ   = 3, /* up to len bytes into the data area; rep.eoi on the last byte */
    DRIVE_OP_CLOSE  = 4,
    DRIVE_OP_CMD    = 5, /* DOS command text on channel 15 (CD:, CD//, CD:<-, I, UI) */
    DRIVE_OP_STATUS = 6  /* read the channel 15 status line */
} drive_op_t;

/* CBM DOS status codes used by the drive (1541 manual numbering). */
#define DRIVE_ST_OK              (0u)
#define DRIVE_ST_SCRATCHED       (1u)
#define DRIVE_ST_SYNTAX          (30u)
#define DRIVE_ST_FILE_NOT_FOUND  (62u)
#define DRIVE_ST_FILE_TYPE       (64u)
#define DRIVE_ST_NO_CHANNEL      (70u)
#define DRIVE_ST_DRIVE_NOT_READY (74u)
#define DRIVE_ST_DOS_VERSION     (73u)  /* power-on / UI message */

/* Request block, written by core 0 only. */
typedef struct
{
    uint32_t magic;                    /* DRIVE_MAGIC */
    uint32_t seq;                      /* increments per request; echoed in the reply */
    uint8_t  op;                       /* drive_op_t */
    uint8_t  device;                   /* DRIVE_DEVICE_SMB or DRIVE_DEVICE_BANK; other: 74 */
    uint8_t  channel;                  /* 0..15 */
    uint8_t  reserved0;
    uint32_t len;                      /* READ: bytes wanted (<= DRIVE_DATA_BYTES) */
    char     name[DRIVE_NAME_BYTES];   /* OPEN name / CMD text, PETSCII, NUL-terminated */
} drive_req_t;

/* Reply block, written by core 1 only. */
typedef struct
{
    uint32_t magic;                    /* DRIVE_MAGIC */
    uint32_t seq;                      /* = request seq */
    uint8_t  status;                   /* CBM DOS code, DRIVE_ST_* */
    uint8_t  track;                    /* status line track field */
    uint8_t  sector;                   /* status line sector field */
    uint8_t  eoi;                      /* READ: 1 when the returned data ends the file */
    uint32_t len;                      /* READ: bytes placed in the data area */
    char     text[DRIVE_STATUS_TEXT_BYTES]; /* full status line for channel 15 */
} drive_rep_t;

/* Log ring header at DRIVE_LOG_OFS; the text follows at DRIVE_LOG_OFS + DRIVE_LOG_HDR_BYTES. */
typedef struct
{
    uint32_t magic;                    /* DRIVE_LOG_MAGIC, written by core 1 at start */
    uint32_t head;                     /* bytes ever written (core 1) */
    uint32_t tail;                     /* bytes ever read (core 0) */
    uint32_t dropped;                  /* bytes discarded because the ring was full (core 1) */
} drive_log_t;

#if (DRIVE_REQ_OFS + DRIVE_REQ_BYTES) > DRIVE_REP_OFS
#error "drive request area overlaps the reply area"
#endif
#if (DRIVE_REP_OFS + DRIVE_REP_BYTES) > DRIVE_DATA_OFS
#error "drive reply area overlaps the data area"
#endif
#if DRIVE_DATA_BYTES < 65536u - 4096u
#error "drive data area smaller than the 60 KiB a full C64 program needs"
#endif
#if (DRIVE_LOG_OFS + DRIVE_LOG_BYTES) > DRIVE_SHM_BYTES
#error "drive log ring runs past the shared BRAM"
#endif

/* Struct sizes are checked where a C11 compiler sees them (drive_client.c and
 * drive_server.c) with _Static_assert(sizeof(drive_req_t) <= DRIVE_REQ_BYTES). */

#endif /* DRIVE_PROTO_H */
