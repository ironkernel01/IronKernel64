/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: backend_ram.c
 * Role: tune bank backend (device 9); contract in backend_ram.h, image format in bank_format.h.
 *
 * Cache: core 1 caches DDR3. The bank is written behind the caches by JTAG, so mount invalidates
 *   the cache lines over the image (header area first, then the validated total). Nothing else
 *   writes that region, so no dirty line is lost.
 */
#include "backend_ram.h"

#include "bank_format.h"
#include "drive_log.h"

#include "c64_platform.h"

#include <stdio.h>   /* snprintf */
#include <string.h>  /* strcmp, strncpy */

#ifndef IK64_HOST_TEST
#include "xil_cache.h"   /* Xil_DCacheInvalidateRange */
#define BANK_CACHE_INVALIDATE(addr, len) Xil_DCacheInvalidateRange((UINTPTR)(addr), (u32)(len))
#else
#define BANK_CACHE_INVALIDATE(addr, len) ((void)(addr), (void)(len))
#endif

#define BR_TABLE_AREA_BYTES   (BANK_HDR_BYTES + BANK_MAX_ENTRIES * BANK_ENTRY_BYTES)
#define BR_CACHE_LINE_BYTES   (64u)
#define BR_LOG_UNSET          (-1)
#define BR_STATUS_BYTES       (64u)

typedef struct
{
    int          used;
    uint32_t     pos;
    bank_entry_t ent;
} br_file_t;

static const uint8_t *g_img;
static uint32_t       g_avail;
static int            g_mounted;
static bank_info_t    g_info;
static int            g_dir_open;
static uint32_t       g_dir_idx;
static br_file_t      g_files[BACKEND_MAX_FILES];
static int            g_logged = BR_LOG_UNSET;   /* last logged bank_status_t */
static char           g_status[BR_STATUS_BYTES] = "OK";

/*
 * backend_ram_set_image -- choose the image and its readable size; forgets the mount.
 * Returns: nothing.
 */
void backend_ram_set_image(const uint8_t *img, uint32_t avail)
{
    g_img = img;
    g_avail = avail;
    g_mounted = 0;
}

/*
 * backend_ram_init -- default image: the fixed bank region. No hardware access.
 * Returns: BACKEND_OK.
 */
backend_status_t backend_ram_init(void)
{
    backend_ram_set_image((const uint8_t *)(uintptr_t)C64_PLAT_BANK_BASE, C64_PLAT_BANK_SIZE);
    g_dir_open = 0;
    g_logged = BR_LOG_UNSET;
    for (uint32_t i = 0u; i < BACKEND_MAX_FILES; i++) {
        g_files[i].used = 0;
    }
    return BACKEND_OK;
}

/*
 * invalidate -- drop cached lines over the first len bytes of the image (line rounded up).
 * Returns: nothing.
 */
static void invalidate(uint32_t len)
{
    const uint32_t rounded = (len + BR_CACHE_LINE_BYTES - 1u) & ~(BR_CACHE_LINE_BYTES - 1u);

    BANK_CACHE_INVALIDATE(g_img, (rounded > g_avail) ? g_avail : rounded);
}

/*
 * backend_ram_mount -- (re)validate the image.
 * Steps:
 *   1. Invalidate the header and table area, bank_parse. A failure clears the mount, sets the
 *      status text and logs one line when the failure differs from the last logged state.
 *   2. Invalidate the validated total; log "bank ok" once per change from failed or unset.
 *   Open files keep working across a successful re-mount only if the image did not change; the
 *   server mounts when no channel is open.
 * Returns: BACKEND_OK or BACKEND_ERR_NOT_READY.
 */
backend_status_t backend_ram_mount(void)
{
    bank_status_t bs;

    invalidate(BR_TABLE_AREA_BYTES);
    bs = bank_parse(g_img, g_avail, &g_info);
    if (bs != BANK_OK) {
        g_mounted = 0;
        (void)snprintf(g_status, sizeof(g_status), "bank: %s", bank_status_name(bs));
        if (g_logged != (int)bs) {
            drive_log_printf("BANK: device 9 not ready, %s\r\n", bank_status_name(bs));
            g_logged = (int)bs;
        }
        return BACKEND_ERR_NOT_READY;
    }
    invalidate(g_info.total);
    g_mounted = 1;
    (void)snprintf(g_status, sizeof(g_status), "OK");
    if (g_logged != (int)BANK_OK) {
        drive_log_printf("BANK: device 9 ready, %lu tunes, %lu bytes\r\n", (unsigned long)g_info.count,
                         (unsigned long)g_info.total);
        g_logged = (int)BANK_OK;
    }
    return BACKEND_OK;
}

/*
 * backend_ram_unmount -- close everything; the next mount validates again.
 * Returns: BACKEND_OK.
 */
backend_status_t backend_ram_unmount(void)
{
    g_dir_open = 0;
    for (uint32_t i = 0u; i < BACKEND_MAX_FILES; i++) {
        g_files[i].used = 0;
    }
    g_mounted = 0;
    return BACKEND_OK;
}

/*
 * backend_ram_opendir -- the flat root only.
 * Returns: BACKEND_OK, NOT_READY (not mounted), NOT_FOUND (any other path) or NO_HANDLE.
 */
backend_status_t backend_ram_opendir(const char *path)
{
    if (!g_mounted) {
        return BACKEND_ERR_NOT_READY;
    }
    if (path == NULL || path[0] != '\0') {
        return BACKEND_ERR_NOT_FOUND;
    }
    if (g_dir_open) {
        return BACKEND_ERR_NO_HANDLE;
    }
    g_dir_open = 1;
    g_dir_idx = 0u;
    return BACKEND_OK;
}

/*
 * backend_ram_readdir -- next table entry.
 * Returns: BACKEND_OK, BACKEND_END, NOT_READY or ARG (no open listing).
 */
backend_status_t backend_ram_readdir(backend_dirent_t *ent)
{
    bank_entry_t e;

    if (!g_mounted) {
        return BACKEND_ERR_NOT_READY;
    }
    if (!g_dir_open || ent == NULL) {
        return BACKEND_ERR_ARG;
    }
    if (g_dir_idx >= g_info.count) {
        return BACKEND_END;
    }
    bank_entry_get(g_img, g_dir_idx, &e);
    g_dir_idx++;
    memset(ent->name, 0, sizeof(ent->name));
    strncpy(ent->name, e.name, sizeof(ent->name) - 1u);
    ent->size = e.size;
    ent->type = BACKEND_ENT_FILE;
    return BACKEND_OK;
}

/*
 * backend_ram_closedir -- end the listing.
 * Returns: BACKEND_OK.
 */
backend_status_t backend_ram_closedir(void)
{
    g_dir_open = 0;
    return BACKEND_OK;
}

/*
 * backend_ram_open -- open the entry with exactly this name.
 * Steps:
 *   1. Find a free slot and the entry; the data CRC must match (else a log line, BACKEND_ERR_IO).
 * Returns: BACKEND_OK with *fh and *size, NOT_READY, NOT_FOUND, NO_HANDLE or IO.
 */
backend_status_t backend_ram_open(const char *path, backend_file_t *fh, uint64_t *size)
{
    bank_entry_t e;
    bank_status_t bs;
    uint32_t slot;

    if (!g_mounted) {
        return BACKEND_ERR_NOT_READY;
    }
    if (path == NULL || fh == NULL || size == NULL) {
        return BACKEND_ERR_ARG;
    }
    for (slot = 0u; slot < BACKEND_MAX_FILES && g_files[slot].used; slot++) {
    }
    if (slot == BACKEND_MAX_FILES) {
        return BACKEND_ERR_NO_HANDLE;
    }
    for (uint32_t i = 0u; i < g_info.count; i++) {
        bank_entry_get(g_img, i, &e);
        if (strcmp(e.name, path) != 0) {
            continue;
        }
        bs = bank_data_ok(g_img, &e);
        if (bs != BANK_OK) {
            (void)snprintf(g_status, sizeof(g_status), "bank: %s", bank_status_name(bs));
            drive_log_printf("BANK: %s in \"%s\"\r\n", bank_status_name(bs), e.name);
            return BACKEND_ERR_IO;
        }
        g_files[slot].used = 1;
        g_files[slot].pos = 0u;
        g_files[slot].ent = e;
        *fh = slot;
        *size = e.size;
        return BACKEND_OK;
    }
    return BACKEND_ERR_NOT_FOUND;
}

/*
 * backend_ram_read -- copy up to max bytes; *eof when the file ends with them.
 * Returns: BACKEND_OK, NOT_READY or ARG (bad handle).
 */
backend_status_t backend_ram_read(backend_file_t fh, uint8_t *buf, uint32_t max, uint32_t *got, int *eof)
{
    br_file_t *f;
    uint32_t n;

    if (!g_mounted) {
        return BACKEND_ERR_NOT_READY;
    }
    if (fh >= BACKEND_MAX_FILES || !g_files[fh].used || buf == NULL || got == NULL || eof == NULL) {
        return BACKEND_ERR_ARG;
    }
    f = &g_files[fh];
    n = f->ent.size - f->pos;
    if (n > max) {
        n = max;
    }
    memcpy(buf, g_img + f->ent.offset + f->pos, n);
    f->pos += n;
    *got = n;
    *eof = (f->pos == f->ent.size) ? 1 : 0;
    return BACKEND_OK;
}

/*
 * backend_ram_close -- release a handle (an unused one is not an error).
 * Returns: BACKEND_OK, or ARG for a handle out of range.
 */
backend_status_t backend_ram_close(backend_file_t fh)
{
    if (fh >= BACKEND_MAX_FILES) {
        return BACKEND_ERR_ARG;
    }
    g_files[fh].used = 0;
    return BACKEND_OK;
}

/*
 * backend_ram_free_bytes -- the bank is read-only: no free space.
 * Returns: BACKEND_OK with 0.
 */
backend_status_t backend_ram_free_bytes(uint64_t *bytes)
{
    *bytes = 0u;
    return BACKEND_OK;
}

/*
 * backend_ram_status_text -- last failure line, or "OK".
 * Returns: BACKEND_OK.
 */
backend_status_t backend_ram_status_text(char *buf, size_t n)
{
    (void)snprintf(buf, n, "%s", g_status);
    return BACKEND_OK;
}
