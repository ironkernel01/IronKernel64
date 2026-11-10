/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: bank_format.h
 * Role: the tune bank image served as device 9: format, constants and the one unpack/validate
 *   helper (bank_format.c). Peers: tools/mkbank.py (the only packer; keep the two in step),
 *   backend_ram.c (the reader), tools/bank_host_test.c.
 *
 * Image layout (little endian, byte offsets from the start of the image):
 *   header, BANK_HDR_BYTES (32):
 *       0  magic       8 bytes "IK64BANK"
 *       8  version     u32, BANK_VERSION
 *      12  count       u32 entries, 0 .. BANK_MAX_ENTRIES
 *      16  total       u32 bytes of the whole image (header + table + data)
 *      20  crc         u32 CRC-32 over header bytes 0..19 followed by the entry table
 *      24  reserved    8 bytes, zero
 *   entry table, count * BANK_ENTRY_BYTES (48), sorted by name:
 *       0  name        32 bytes, the file name as on the share ("Airwolf.sid"), NUL padded
 *      32  offset      u32 of the data from the image start
 *      36  size        u32 data bytes
 *      40  crc         u32 CRC-32 of the data
 *      44  reserved    u32, zero
 *   data: the files back to back, each starting on a 4-byte boundary.
 * Deviation from the first sketch (name up to 16 characters): the name field keeps the whole file
 *   name with its ".sid" extension, so cbmdos hides the extension and matches exactly as on the
 *   share; 16 bytes could not hold "Axel_F_Huelsbeck.sid".
 * CRC-32 is the zlib/IEEE one (reflected, polynomial 0xEDB88320, init and final xor 0xFFFFFFFF).
 *
 * Validation (bank_parse): magic, version, count, total <= available bytes, header CRC, every
 *   entry's name non-empty, offset aligned and >= end of table, offset + size <= total.
 *   Data CRCs are checked by the reader when a file is opened (bank_data_ok).
 * Headers hold contracts and constants; per-function commentary lives in bank_format.c.
 *
 * Revision: 11-10-2026
 *   * 11-10-2026: initial version.
 */
#ifndef BANK_FORMAT_H
#define BANK_FORMAT_H

#include <stddef.h> /* size_t */
#include <stdint.h> /* uint8_t, uint32_t */

#define BANK_MAGIC_BYTES         (8u)      /* the magic is the text IK64BANK */
#define BANK_VERSION             (1u)
#define BANK_HDR_BYTES           (32u)
#define BANK_ENTRY_BYTES         (48u)
#define BANK_NAME_BYTES          (32u)     /* NUL included: names are at most 31 characters */
#define BANK_MAX_ENTRIES         (256u)
#define BANK_ALIGN               (4u)
#define BANK_CRC_SPAN_BYTES      (20u)     /* header bytes covered by the header CRC, before the table */

typedef enum
{
    BANK_OK = 0,
    BANK_ERR_ABSENT,        /* image smaller than a header, or wrong magic */
    BANK_ERR_VERSION,
    BANK_ERR_COUNT,
    BANK_ERR_SIZE,          /* total larger than the available bytes or smaller than header + table */
    BANK_ERR_HEADER_CRC,
    BANK_ERR_ENTRY,         /* bad name, offset or size */
    BANK_ERR_DATA_CRC
} bank_status_t;

typedef struct
{
    char     name[BANK_NAME_BYTES];
    uint32_t offset;
    uint32_t size;
    uint32_t crc;
} bank_entry_t;

typedef struct
{
    uint32_t count;
    uint32_t total;
} bank_info_t;

uint32_t      bank_crc32(uint32_t crc, const uint8_t *data, size_t len);
bank_status_t bank_parse(const uint8_t *img, uint32_t avail, bank_info_t *info);
void          bank_entry_get(const uint8_t *img, uint32_t index, bank_entry_t *out);
bank_status_t bank_data_ok(const uint8_t *img, const bank_entry_t *e);
const char   *bank_status_name(bank_status_t st);

#endif /* BANK_FORMAT_H */
