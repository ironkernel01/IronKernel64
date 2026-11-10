/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: smb_alloc.c
 * Role: bounded static-pool allocator in place of newlib's malloc family on
 *   core 1 (IK64_DEVIATION 2, fw_1541/DEVIATIONS.md). Contract: smb_alloc.h.
 *
 * Symbols defined here (they replace newlib's, so newlib's allocator and its
 * _sbrk heap are not linked): malloc, free, calloc, realloc and the
 * reentrant _malloc_r, _free_r, _calloc_r, _realloc_r that newlib's own
 * strdup/strndup/asprintf/stdio call.
 *
 * Sizing (rv32, GCC 13.4, -Os; sizes measured with a sizeof probe compiled
 * against third_party/libsmb2 at SOURCE.txt's commit, NETWORK_SPIKE.md):
 *   struct smb2_context        4,200 B  one per connection            -> 8 KiB class
 *   struct smb2_pdu            6,392 B  one per request in flight;     -> 8 KiB class
 *                                       a compound open+query+close
 *                                       holds 3, the sync API waits
 *                                       for one command at a time
 *   struct smb2_io_vectors     3,084 B  embedded in context and pdu (no own allocation)
 *   struct smb2_dirent_internal  112 B  one per directory entry; opendir
 *                                       reads the WHOLE listing      -> 128 B class
 *   entry name (strdup)        <= 64 B typical, <= 255 B max     -> 64 / 256 B classes
 *   struct sync_cb_data           12 B, struct smb2_url 20 B     -> 32 B class
 *   receive buffers: QUERY_DIRECTORY / QUERY_INFO replies of up to the
 *     65,535 B output buffer libsmb2 requests (DEFAULT_OUTPUT_BUFFER_LENGTH),
 *     and with sealing the whole transform payload of a READ (<= the chunk
 *     backend_smb.c requests, BACKEND_SMB_READ_CHUNK = 61,440 B) plus its
 *     64 B header and a 52 B transform header                -> 72 KiB class
 *   NTLMSSP blobs, signing/sealing keys, iovec fixed parts   -> 256 B .. 4 KiB
 * Counts: directory classes hold a 2,048-entry folder (a 1541 disk holds
 *   144; the largest HVSC folder is well under 2,048); the rest are 2..8x the
 *   peak the analysis above gives. Total pool: SMB_ALLOC_POOL_BYTES below,
 *   about 1 MiB of the 64 MiB core 1 DDR3 partition (c64_platform.h).
 * The first board session confirms the sizing with smb_alloc_log_stats()
 * (DRIVE STATUS): high_water per class against blocks.
 */
#include "smb_alloc.h"

#include "backend_smb.h"   /* BACKEND_SMB_READ_CHUNK (largest-class check) */
#include "drive_log.h"     /* drive_log_printf */
#include "fatal.h"         /* ik64_fatal */

#include <errno.h>         /* ENOMEM */
#include <reent.h>         /* struct _reent for the _r entry points */
#include <stdlib.h>        /* malloc family prototypes */
#include <string.h>        /* memset, memcpy */

/* Size classes: payload bytes (multiples of 16 for 16-byte alignment) and
 * block counts. Derivations: the sizing table in the file header. */
#define SMB_ALLOC_C0_BYTES       (32u)
#define SMB_ALLOC_C0_BLOCKS      (512u)
#define SMB_ALLOC_C1_BYTES       (64u)
#define SMB_ALLOC_C1_BLOCKS      (2048u)
#define SMB_ALLOC_C2_BYTES       (128u)
#define SMB_ALLOC_C2_BLOCKS      (2048u)
#define SMB_ALLOC_C3_BYTES       (256u)
#define SMB_ALLOC_C3_BLOCKS      (256u)
#define SMB_ALLOC_C4_BYTES       (1024u)
#define SMB_ALLOC_C4_BLOCKS      (32u)
#define SMB_ALLOC_C5_BYTES       (4096u)
#define SMB_ALLOC_C5_BLOCKS      (16u)
#define SMB_ALLOC_C6_BYTES       (8192u)
#define SMB_ALLOC_C6_BLOCKS      (16u)
#define SMB_ALLOC_C7_BYTES       (73728u)  /* 72 KiB */
#define SMB_ALLOC_C7_BLOCKS      (4u)

#define SMB_ALLOC_POOL_BYTES                                                   \
    ((SMB_ALLOC_C0_BYTES * SMB_ALLOC_C0_BLOCKS) + (SMB_ALLOC_C1_BYTES * SMB_ALLOC_C1_BLOCKS) + \
     (SMB_ALLOC_C2_BYTES * SMB_ALLOC_C2_BLOCKS) + (SMB_ALLOC_C3_BYTES * SMB_ALLOC_C3_BLOCKS) + \
     (SMB_ALLOC_C4_BYTES * SMB_ALLOC_C4_BLOCKS) + (SMB_ALLOC_C5_BYTES * SMB_ALLOC_C5_BLOCKS) + \
     (SMB_ALLOC_C6_BYTES * SMB_ALLOC_C6_BLOCKS) + (SMB_ALLOC_C7_BYTES * SMB_ALLOC_C7_BLOCKS))

/* Free-index stacks are uint16_t: every class must stay below 65,536 blocks. */
#if (SMB_ALLOC_C1_BLOCKS > 65535u) || (SMB_ALLOC_C2_BLOCKS > 65535u)
#error "a size class exceeds the uint16_t free-index stack"
#endif
/* Reads with sealing must fit the largest class (backend_smb.c BACKEND_SMB_READ_CHUNK). */
#if SMB_ALLOC_C7_BYTES < (BACKEND_SMB_READ_CHUNK + 64u + 52u)
#error "largest class smaller than one sealed READ transform payload"
#endif
#if SMB_ALLOC_C7_BYTES < (65535u + 64u)
#error "largest class smaller than one QUERY_DIRECTORY reply"
#endif

#define SMB_ALLOC_ALIGN __attribute__((aligned(16)))

static uint8_t g_pool0[SMB_ALLOC_C0_BLOCKS * SMB_ALLOC_C0_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool1[SMB_ALLOC_C1_BLOCKS * SMB_ALLOC_C1_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool2[SMB_ALLOC_C2_BLOCKS * SMB_ALLOC_C2_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool3[SMB_ALLOC_C3_BLOCKS * SMB_ALLOC_C3_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool4[SMB_ALLOC_C4_BLOCKS * SMB_ALLOC_C4_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool5[SMB_ALLOC_C5_BLOCKS * SMB_ALLOC_C5_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool6[SMB_ALLOC_C6_BLOCKS * SMB_ALLOC_C6_BYTES] SMB_ALLOC_ALIGN;
static uint8_t g_pool7[SMB_ALLOC_C7_BLOCKS * SMB_ALLOC_C7_BYTES] SMB_ALLOC_ALIGN;

static uint16_t g_free0[SMB_ALLOC_C0_BLOCKS];
static uint16_t g_free1[SMB_ALLOC_C1_BLOCKS];
static uint16_t g_free2[SMB_ALLOC_C2_BLOCKS];
static uint16_t g_free3[SMB_ALLOC_C3_BLOCKS];
static uint16_t g_free4[SMB_ALLOC_C4_BLOCKS];
static uint16_t g_free5[SMB_ALLOC_C5_BLOCKS];
static uint16_t g_free6[SMB_ALLOC_C6_BLOCKS];
static uint16_t g_free7[SMB_ALLOC_C7_BLOCKS];

static uint8_t g_used0[SMB_ALLOC_C0_BLOCKS];
static uint8_t g_used1[SMB_ALLOC_C1_BLOCKS];
static uint8_t g_used2[SMB_ALLOC_C2_BLOCKS];
static uint8_t g_used3[SMB_ALLOC_C3_BLOCKS];
static uint8_t g_used4[SMB_ALLOC_C4_BLOCKS];
static uint8_t g_used5[SMB_ALLOC_C5_BLOCKS];
static uint8_t g_used6[SMB_ALLOC_C6_BLOCKS];
static uint8_t g_used7[SMB_ALLOC_C7_BLOCKS];

typedef struct
{
    uint8_t  *base;        /* first block */
    uint16_t *free_stack;  /* indices of free blocks, [0, free_top) */
    uint8_t  *used;        /* 1 = allocated, per block (double-free check) */
    uint32_t  bytes;       /* block payload size */
    uint32_t  blocks;      /* block count */
    uint32_t  free_top;    /* free blocks on the stack */
    uint32_t  high_water;
    uint32_t  allocs;
    uint32_t  exhausted;
} pool_class_t;

#define POOL_CLASS(n) { g_pool##n, g_free##n, g_used##n, SMB_ALLOC_C##n##_BYTES, \
                        SMB_ALLOC_C##n##_BLOCKS, 0u, 0u, 0u, 0u }

static pool_class_t g_class[SMB_ALLOC_CLASSES] = {
    POOL_CLASS(0), POOL_CLASS(1), POOL_CLASS(2), POOL_CLASS(3),
    POOL_CLASS(4), POOL_CLASS(5), POOL_CLASS(6), POOL_CLASS(7)
};

static int g_ready;                  /* free stacks filled (first call) */
static uint32_t g_rejected_oversize; /* requests above the largest class */
static uint32_t g_largest_request;   /* bytes */

/* Locking: none (IK64_DEVIATION 11). Core 1 runs one superloop with no RTOS and no allocating
 * ISR, so pool updates cannot interleave. The hooks stay as the one place to
 * add protection if a second context ever allocates. */
static void lock(void)
{
}

static void unlock(void)
{
}

/*
 * pool_init -- fill every class's free stack (once, under the lock).
 * Steps:
 *   1. For each class push indices blocks-1 .. 0 so block 0 is handed out
 *      first (bounded by the class's block count).
 * Returns: nothing.
 */
static void pool_init(void)
{
    uint32_t c;
    uint32_t i;

    for (c = 0u; c < SMB_ALLOC_CLASSES; c++) {
        pool_class_t *pc = &g_class[c];
        for (i = 0u; i < pc->blocks; i++) {
            pc->free_stack[i] = (uint16_t)(pc->blocks - 1u - i);
            pc->used[i] = 0u;
        }
        pc->free_top = pc->blocks;
    }
    g_ready = 1;
}

/*
 * pool_alloc -- take one block of at least n bytes.
 * Steps:
 *   1. Under the lock: initialize on first use; record the largest request.
 *   2. Reject n above the largest class (count, NULL).
 *   3. Walk the classes from the smallest that fits upward; take the first
 *      free block, mark it used, update in_use high water and allocs.
 *   4. None free: count exhausted on the fitting class, log outside the
 *      lock, NULL.
 * Returns: block pointer, or NULL (errno-style reason left to the caller).
 */
static void *pool_alloc(size_t n)
{
    void *p = NULL;
    uint32_t c;
    uint32_t fit = SMB_ALLOC_CLASSES;
    int oversize = 0;

    lock();
    if (g_ready == 0) {
        pool_init();
    }
    if (n > g_largest_request) {
        g_largest_request = (uint32_t)n;
    }
    for (c = 0u; c < SMB_ALLOC_CLASSES; c++) {
        if (n <= g_class[c].bytes) {
            fit = c;
            break;
        }
    }
    if (fit == SMB_ALLOC_CLASSES) {
        g_rejected_oversize++;
        oversize = 1;
    } else {
        for (c = fit; c < SMB_ALLOC_CLASSES; c++) {
            pool_class_t *pc = &g_class[c];
            if (pc->free_top > 0u) {
                uint32_t idx;
                uint32_t in_use;
                pc->free_top--;
                idx = pc->free_stack[pc->free_top];
                pc->used[idx] = 1u;
                in_use = pc->blocks - pc->free_top;
                if (in_use > pc->high_water) {
                    pc->high_water = in_use;
                }
                pc->allocs++;
                p = pc->base + ((size_t)idx * pc->bytes);
                break;
            }
        }
        if (p == NULL) {
            g_class[fit].exhausted++;
        }
    }
    unlock();

    if (oversize != 0) {
        drive_log_printf("smb_alloc: reject %lu B (largest class %lu B)\r\n",
                         (unsigned long)n, (unsigned long)SMB_ALLOC_C7_BYTES);
    } else if (p == NULL) {
        drive_log_printf("smb_alloc: class %lu (%lu B) exhausted, %lu B request rejected\r\n",
                         (unsigned long)fit, (unsigned long)g_class[fit].bytes, (unsigned long)n);
    }
    return p;
}

/*
 * pool_find -- class and index of a block pointer.
 * Steps:
 *   1. Find the class whose array contains p (bounded by SMB_ALLOC_CLASSES).
 *   2. The offset must be a whole number of blocks; otherwise p is not a
 *      block start: fail-stop (corruption).
 * Returns: class pointer and *idx set; never returns for a foreign pointer.
 */
static pool_class_t *pool_find(const void *p, uint32_t *idx)
{
    uint32_t c;
    const uint8_t *b = (const uint8_t *)p;

    for (c = 0u; c < SMB_ALLOC_CLASSES; c++) {
        pool_class_t *pc = &g_class[c];
        const uint8_t *end = pc->base + ((size_t)pc->blocks * pc->bytes);
        if ((b >= pc->base) && (b < end)) {
            size_t ofs = (size_t)(b - pc->base);
            if ((ofs % pc->bytes) != 0u) {
                ik64_fatal("smb_alloc: pointer inside a block", (int32_t)(uintptr_t)p);
            }
            *idx = (uint32_t)(ofs / pc->bytes);
            return pc;
        }
    }
    ik64_fatal("smb_alloc: pointer outside the pools", (int32_t)(uintptr_t)p);
}

/*
 * pool_free -- return a block.
 * Steps:
 *   1. NULL: nothing to do.
 *   2. Under the lock: pool_find (fail-stop on a foreign pointer); a block
 *      already free is a double free: fail-stop.
 *   3. Clear its used flag and push its index.
 * Returns: nothing.
 */
static void pool_free(void *p)
{
    pool_class_t *pc;
    uint32_t idx = 0u;

    if (p == NULL) {
        return;
    }
    lock();
    pc = pool_find(p, &idx);
    if (pc->used[idx] == 0u) {
        ik64_fatal("smb_alloc: double free", (int32_t)(uintptr_t)p);
    }
    pc->used[idx] = 0u;
    pc->free_stack[pc->free_top] = (uint16_t)idx;
    pc->free_top++;
    unlock();
}

/*
 * pool_block_bytes -- payload size of the block that holds p.
 * Steps:
 *   1. Under the lock: pool_find; a free block is a use-after-free:
 *      fail-stop.
 * Returns: the class block size in bytes.
 */
static uint32_t pool_block_bytes(const void *p)
{
    pool_class_t *pc;
    uint32_t idx = 0u;
    uint32_t bytes;

    lock();
    pc = pool_find(p, &idx);
    if (pc->used[idx] == 0u) {
        ik64_fatal("smb_alloc: realloc of a free block", (int32_t)(uintptr_t)p);
    }
    bytes = pc->bytes;
    unlock();
    return bytes;
}

/*
 * pool_calloc -- zeroed array of n elements of sz bytes.
 * Steps:
 *   1. Reject n * sz overflow (NULL).
 *   2. pool_alloc and zero the requested bytes.
 * Returns: block pointer or NULL.
 */
static void *pool_calloc(size_t n, size_t sz)
{
    void *p;

    if ((sz != 0u) && (n > (SIZE_MAX / sz))) {
        return NULL;
    }
    p = pool_alloc(n * sz);
    if (p != NULL) {
        memset(p, 0, n * sz);
    }
    return p;
}

/*
 * pool_realloc -- resize a block.
 * Steps:
 *   1. p NULL: pool_alloc(n). n 0: pool_free(p), NULL.
 *   2. n fits the current block: return p unchanged.
 *   3. Otherwise pool_alloc(n), copy the old block's payload (the new block
 *      is larger), pool_free(p). On failure p stays valid (C semantics).
 * Returns: block pointer or NULL.
 */
static void *pool_realloc(void *p, size_t n)
{
    void *q;
    uint32_t old_bytes;

    if (p == NULL) {
        return pool_alloc(n);
    }
    if (n == 0u) {
        pool_free(p);
        return NULL;
    }
    old_bytes = pool_block_bytes(p);
    if (n <= old_bytes) {
        return p;
    }
    q = pool_alloc(n);
    if (q == NULL) {
        return NULL;
    }
    memcpy(q, p, old_bytes);
    pool_free(p);
    return q;
}

/* C library entry points (replace newlib's; IK64_DEVIATION 2). */

void *malloc(size_t n)
{
    void *p = pool_alloc(n);
    if (p == NULL) {
        errno = ENOMEM;
    }
    return p;
}

void free(void *p)
{
    pool_free(p);
}

void *calloc(size_t n, size_t sz)
{
    void *p = pool_calloc(n, sz);
    if (p == NULL) {
        errno = ENOMEM;
    }
    return p;
}

void *realloc(void *p, size_t n)
{
    void *q = pool_realloc(p, n);
    if ((q == NULL) && (n != 0u)) {
        errno = ENOMEM;
    }
    return q;
}

void *_malloc_r(struct _reent *r, size_t n)
{
    void *p = pool_alloc(n);
    if ((p == NULL) && (r != NULL)) {
        r->_errno = ENOMEM;
    }
    return p;
}

void _free_r(struct _reent *r, void *p)
{
    (void)r;
    pool_free(p);
}

void *_calloc_r(struct _reent *r, size_t n, size_t sz)
{
    void *p = pool_calloc(n, sz);
    if ((p == NULL) && (r != NULL)) {
        r->_errno = ENOMEM;
    }
    return p;
}

void *_realloc_r(struct _reent *r, void *p, size_t n)
{
    void *q = pool_realloc(p, n);
    if ((q == NULL) && (n != 0u) && (r != NULL)) {
        r->_errno = ENOMEM;
    }
    return q;
}

/*
 * smb_alloc_get_stats -- snapshot of the pool counters.
 * Steps:
 *   1. Under the lock copy each class's size, count, in use, high water,
 *      allocs and exhausted, and the global counters.
 * Returns: nothing (*st filled).
 */
void smb_alloc_get_stats(smb_alloc_stats_t *st)
{
    uint32_t c;

    if (st == NULL) {
        return;
    }
    lock();
    if (g_ready == 0) {
        pool_init();
    }
    for (c = 0u; c < SMB_ALLOC_CLASSES; c++) {
        const pool_class_t *pc = &g_class[c];
        st->cls[c].block_bytes = pc->bytes;
        st->cls[c].blocks = pc->blocks;
        st->cls[c].in_use = pc->blocks - pc->free_top;
        st->cls[c].high_water = pc->high_water;
        st->cls[c].allocs = pc->allocs;
        st->cls[c].exhausted = pc->exhausted;
    }
    st->rejected_oversize = g_rejected_oversize;
    st->largest_request = g_largest_request;
    st->pool_bytes = (uint32_t)SMB_ALLOC_POOL_BYTES;
    unlock();
}

/*
 * smb_alloc_log_stats -- one log line per class plus a summary.
 * Steps:
 *   1. smb_alloc_get_stats, then drive_log_printf each row.
 * Returns: nothing.
 */
void smb_alloc_log_stats(void)
{
    smb_alloc_stats_t st;
    uint32_t c;

    smb_alloc_get_stats(&st);
    drive_log_printf("smb_alloc: pool %lu B, largest request %lu B, oversize rejects %lu\r\n",
                     (unsigned long)st.pool_bytes, (unsigned long)st.largest_request,
                     (unsigned long)st.rejected_oversize);
    for (c = 0u; c < SMB_ALLOC_CLASSES; c++) {
        drive_log_printf("  %6lu B x %4lu: in use %4lu, high %4lu, allocs %lu, exhausted %lu\r\n",
                         (unsigned long)st.cls[c].block_bytes, (unsigned long)st.cls[c].blocks,
                         (unsigned long)st.cls[c].in_use, (unsigned long)st.cls[c].high_water,
                         (unsigned long)st.cls[c].allocs, (unsigned long)st.cls[c].exhausted);
    }
}
