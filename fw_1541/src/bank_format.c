/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: bank_format.c
 * Role: unpack and validate the tune bank image; format and contract in bank_format.h.
 *   The reads are byte-wise little endian, so an image at any alignment parses.
 *
 * Revision: 11-10-2026
 *   * 11-10-2026: initial version.
 */
#include "bank_format.h"

static const char g_magic[BANK_MAGIC_BYTES] = { 'I', 'K', '6', '4', 'B', 'A', 'N', 'K' };

/* Offsets inside the header and an entry (see bank_format.h). */
#define HDR_VERSION_OFS          (8u)
#define HDR_COUNT_OFS            (12u)
#define HDR_TOTAL_OFS            (16u)
#define HDR_CRC_OFS              (20u)
#define ENT_OFFSET_OFS           (32u)
#define ENT_SIZE_OFS             (36u)
#define ENT_CRC_OFS              (40u)

/*
 * get32 -- little-endian u32 at p.
 * Returns: the value.
 */
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/*
 * bank_crc32 -- continue a CRC-32 (zlib) over len bytes; start with crc = 0.
 * Returns: the updated CRC. Nibble table: 64 bytes of constants, no 1 KiB table.
 */
uint32_t bank_crc32(uint32_t crc, const uint8_t *data, size_t len)
{
    static const uint32_t tab[16] = {
        0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu, 0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
        0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu, 0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu
    };

    crc = ~crc;
    for (size_t i = 0u; i < len; i++) {
        crc ^= data[i];
        crc = (crc >> 4) ^ tab[crc & 0xFu];
        crc = (crc >> 4) ^ tab[crc & 0xFu];
    }
    return ~crc;
}

/*
 * bank_entry_get -- unpack entry index (the caller checked index < count after bank_parse).
 * Returns: nothing; out is filled, name always NUL terminated.
 */
void bank_entry_get(const uint8_t *img, uint32_t index, bank_entry_t *out)
{
    const uint8_t *e = img + BANK_HDR_BYTES + (size_t)index * BANK_ENTRY_BYTES;

    for (uint32_t i = 0u; i < BANK_NAME_BYTES; i++) {
        out->name[i] = (char)e[i];
    }
    out->name[BANK_NAME_BYTES - 1u] = '\0';
    out->offset = get32(e + ENT_OFFSET_OFS);
    out->size = get32(e + ENT_SIZE_OFS);
    out->crc = get32(e + ENT_CRC_OFS);
}

/*
 * bank_parse -- validate an image of avail readable bytes.
 * Steps:
 *   1. Header present, magic, version, count <= BANK_MAX_ENTRIES.
 *   2. total between header + table and avail.
 *   3. CRC over header bytes 0..19 and the table equals the stored one.
 *   4. Every entry: non-empty name, offset aligned and not before the table end,
 *      offset + size not past total (checked without overflow).
 * Returns: BANK_OK with *info set, or the first failure (*info untouched).
 */
bank_status_t bank_parse(const uint8_t *img, uint32_t avail, bank_info_t *info)
{
    uint32_t count;
    uint32_t total;
    uint32_t table_end;
    uint32_t crc;

    if (img == NULL || avail < BANK_HDR_BYTES) {
        return BANK_ERR_ABSENT;
    }
    for (uint32_t i = 0u; i < BANK_MAGIC_BYTES; i++) {
        if ((char)img[i] != g_magic[i]) {
            return BANK_ERR_ABSENT;
        }
    }
    if (get32(img + HDR_VERSION_OFS) != BANK_VERSION) {
        return BANK_ERR_VERSION;
    }
    count = get32(img + HDR_COUNT_OFS);
    if (count > BANK_MAX_ENTRIES) {
        return BANK_ERR_COUNT;
    }
    total = get32(img + HDR_TOTAL_OFS);
    table_end = BANK_HDR_BYTES + count * BANK_ENTRY_BYTES;
    if (total < table_end || total > avail) {
        return BANK_ERR_SIZE;
    }
    crc = bank_crc32(0u, img, BANK_CRC_SPAN_BYTES);
    crc = bank_crc32(crc, img + BANK_HDR_BYTES, (size_t)count * BANK_ENTRY_BYTES);
    if (crc != get32(img + HDR_CRC_OFS)) {
        return BANK_ERR_HEADER_CRC;
    }
    for (uint32_t i = 0u; i < count; i++) {
        bank_entry_t e;

        bank_entry_get(img, i, &e);
        if (e.name[0] == '\0' || e.offset < table_end || (e.offset % BANK_ALIGN) != 0u ||
            e.offset > total || e.size > total - e.offset) {
            return BANK_ERR_ENTRY;
        }
    }
    info->count = count;
    info->total = total;
    return BANK_OK;
}

/*
 * bank_data_ok -- does the entry's data match its stored CRC?
 * Returns: BANK_OK or BANK_ERR_DATA_CRC (the entry was bounds-checked by bank_parse).
 */
bank_status_t bank_data_ok(const uint8_t *img, const bank_entry_t *e)
{
    return (bank_crc32(0u, img + e->offset, e->size) == e->crc) ? BANK_OK : BANK_ERR_DATA_CRC;
}

/*
 * bank_status_name -- short text of a status for the log.
 * Returns: a constant string.
 */
const char *bank_status_name(bank_status_t st)
{
    switch (st) {
    case BANK_OK:             return "ok";
    case BANK_ERR_ABSENT:     return "no bank (bad magic)";
    case BANK_ERR_VERSION:    return "unsupported version";
    case BANK_ERR_COUNT:      return "bad entry count";
    case BANK_ERR_SIZE:       return "bad total size";
    case BANK_ERR_HEADER_CRC: return "header CRC mismatch";
    case BANK_ERR_ENTRY:      return "bad entry";
    default:                  return "data CRC mismatch";
    }
}
