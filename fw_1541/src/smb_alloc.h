/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: smb_alloc.h
 * Role: the bounded static-pool allocator that stands in for the C library
 *   heap on core 1. libsmb2 allocates with malloc/calloc/realloc/free (and
 *   newlib's strdup/asprintf, which reach _malloc_r); smb_alloc.c defines
 *   those symbols, so the newlib allocator and its sbrk heap are never
 *   linked. This is IK64_DEVIATION 2 against the no-heap rule
 *   (fw_1541/DEVIATIONS.md).
 *
 * Contract:
 *   - Fixed size classes, each a static array of equal blocks in .bss (core
 *     1's DDR3 partition). No splitting or merging, so no fragmentation;
 *     malloc and free are O(classes).
 *   - A request larger than the largest class is REJECTED: NULL, counted in
 *     the stats. libsmb2 turns that into a failed command (the server sent
 *     an oversized reply); the drive reports 74,DRIVE NOT READY.
 *   - A request whose class (and every larger class) has no free block is
 *     REJECTED the same way, logged with the class and size and counted in
 *     the class's exhausted counter. The usual cause is external data (a
 *     share folder with more entries than the directory classes hold,
 *     smb_alloc.c sizing notes); the reject makes that command fail at its
 *     source instead of corrupting state, and the counters make it loud.
 *   - free() or realloc() of a pointer that is not a block start, or of a
 *     block that is already free, is memory corruption: fail-stop.
 *   - Single-threaded: core 1 has no RTOS; never call it from an ISR.
 *
 * Headers hold contracts; per-function commentary lives in smb_alloc.c.
 */
#ifndef SMB_ALLOC_H
#define SMB_ALLOC_H

#include <stddef.h> /* size_t */
#include <stdint.h> /* uint32_t */

/* Number of size classes (smb_alloc.c g_class table). */
#define SMB_ALLOC_CLASSES        (8u)

typedef struct
{
    uint32_t block_bytes;   /* payload size of one block */
    uint32_t blocks;        /* blocks in the class */
    uint32_t in_use;        /* blocks allocated now */
    uint32_t high_water;    /* most blocks ever allocated at once */
    uint32_t allocs;        /* successful allocations from this class */
    uint32_t exhausted;     /* requests of this class rejected: no free block here or above */
} smb_alloc_class_stats_t;

typedef struct
{
    smb_alloc_class_stats_t cls[SMB_ALLOC_CLASSES];
    uint32_t rejected_oversize; /* requests above the largest class */
    uint32_t largest_request;   /* largest size ever requested (bytes) */
    uint32_t pool_bytes;        /* total static pool size */
} smb_alloc_stats_t;

void smb_alloc_get_stats(smb_alloc_stats_t *st);
void smb_alloc_log_stats(void);

#endif /* SMB_ALLOC_H */
