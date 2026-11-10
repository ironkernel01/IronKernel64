/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: psid.c
 * Role: PSID/RSID header parser and PSID tune driver (contract in psid.h).
 *
 * Uses c64mem.c for the address space and the 6502 calls, and sidbus.h for the
 *   chip reset with the tune's model. psid_unpack is the only function that decodes the
 *   big-endian header.
 */
#include "psid.h"

#include "c64mem.h"
#include "sidbus.h"

#include <stddef.h> /* NULL */
#include <string.h> /* memset */

/* Header field offsets (psid.h wire format). */
#define PSID_OFS_MAGIC     (0x00u)
#define PSID_OFS_VERSION   (0x04u)
#define PSID_OFS_DATA      (0x06u)
#define PSID_OFS_LOAD      (0x08u)
#define PSID_OFS_INIT      (0x0Au)
#define PSID_OFS_PLAY      (0x0Cu)
#define PSID_OFS_SONGS     (0x0Eu)
#define PSID_OFS_START     (0x10u)
#define PSID_OFS_SPEED     (0x12u)
#define PSID_OFS_NAME      (0x16u)
#define PSID_OFS_AUTHOR    (0x36u)
#define PSID_OFS_RELEASED  (0x56u)
#define PSID_OFS_FLAGS     (0x76u)
#define PSID_OFS_START_PG  (0x78u)
#define PSID_OFS_PAGE_LEN  (0x79u)
#define PSID_OFS_SID2      (0x7Au)
#define PSID_OFS_SID3      (0x7Bu)
#define PSID_VERSION_MIN   (1u)
#define PSID_VERSION_MAX   (4u)
#define PSID_LOAD_BYTES    (2u)    /* embedded little-endian load address */

static const char *const g_status_text[] = {
    "OK",
    "NULL ARGUMENT",
    "FILE TOO SHORT",
    "NOT A SID FILE",
    "RSID NOT SUPPORTED",
    "BAD PSID VERSION",
    "BAD DATA OFFSET",
    "NO C64 DATA",
    "BAD SONG COUNT",
    "MUS DATA NOT SUPPORTED",
    "PLAY ADDRESS 0 NOT SUPPORTED",
    "DATA PAST $FFFF",
    "DATA OVERLAPS I/O",
    "DATA OVERLAPS KERNAL STUBS",
    "NO TUNE LOADED",
    "SONG OUT OF RANGE",
    "CIA SPEED NOT SUPPORTED",
    "TUNE NOT INITIALISED",
    "INIT DID NOT RETURN",
    "PLAY DID NOT RETURN",
    "6502 JAM",
    "6502 BRK",
};

_Static_assert(sizeof(g_status_text) / sizeof(g_status_text[0]) == (size_t)PSID_ERR_COUNT,
               "g_status_text must have one entry per psid_status_t");

static psid_info_t g_info;
static int g_loaded;
static int g_inited;
static uint16_t g_song;          /* 1-based song of the last successful psid_init */

/*
 * psid_be -- big-endian field of n bytes (n = 1, 2 or 4) at image[ofs].
 * Returns: the field value.
 */
static uint32_t psid_be(const uint8_t *image, uint32_t ofs, uint32_t n)
{
    uint32_t v = 0u;

    for (uint32_t i = 0u; i < n; i++) {
        v = (v << 8) | image[ofs + i];
    }
    return v;
}

/*
 * psid_copy_string -- copy one 32-byte NUL-padded header string.
 * Steps:
 *   1. Copy up to PSID_STRING_BYTES bytes, stopping at the first NUL.
 *   2. Terminate.
 * Returns: nothing.
 */
static void psid_copy_string(char *dst, const uint8_t *src)
{
    uint32_t i;

    for (i = 0u; i < PSID_STRING_BYTES && src[i] != 0u; i++) {
        dst[i] = (char)src[i];
    }
    dst[i] = '\0';
}

/*
 * psid_unpack -- decode the PSID/RSID header (the one unpack helper of this format).
 * Steps:
 *   1. Require the v1 header; read magic and version; require the v2+ header for v2..v4.
 *   2. Decode the big-endian v1 fields and the three strings.
 *   3. v2+: flags, start page, page length; v3+: second SID; v4: third SID.
 *   4. Locate the C64 data; resolve the embedded load address (load field 0).
 *   5. Default init (0 -> load address), start song (0 -> 1), clock/model for v1.
 * Returns: PSID_OK, PSID_ERR_SHORT, PSID_ERR_MAGIC, PSID_ERR_DATA_OFFSET or
 *   PSID_ERR_NO_DATA (later checks are psid_parse's).
 */
static psid_status_t psid_unpack(const uint8_t *image, uint32_t len, psid_info_t *info)
{
    uint32_t ofs;

    memset(info, 0, sizeof(*info));
    if (len < PSID_V1_HEADER_BYTES) {
        return PSID_ERR_SHORT;
    }
    if (image[1] != (uint8_t)'S' || image[2] != (uint8_t)'I' || image[3] != (uint8_t)'D'
        || (image[0] != (uint8_t)'P' && image[0] != (uint8_t)'R')) {
        return PSID_ERR_MAGIC;
    }
    info->rsid = (image[PSID_OFS_MAGIC] == (uint8_t)'R') ? 1u : 0u;
    info->version = (uint16_t)psid_be(image, PSID_OFS_VERSION, 2u);
    info->data_offset = (uint16_t)psid_be(image, PSID_OFS_DATA, 2u);
    info->load_field = (uint16_t)psid_be(image, PSID_OFS_LOAD, 2u);
    info->init_addr = (uint16_t)psid_be(image, PSID_OFS_INIT, 2u);
    info->play_addr = (uint16_t)psid_be(image, PSID_OFS_PLAY, 2u);
    info->songs = (uint16_t)psid_be(image, PSID_OFS_SONGS, 2u);
    info->start_song = (uint16_t)psid_be(image, PSID_OFS_START, 2u);
    info->speed = psid_be(image, PSID_OFS_SPEED, 4u);
    psid_copy_string(info->name, &image[PSID_OFS_NAME]);
    psid_copy_string(info->author, &image[PSID_OFS_AUTHOR]);
    psid_copy_string(info->released, &image[PSID_OFS_RELEASED]);

    if (info->version >= 2u) {
        if (len < PSID_V2_HEADER_BYTES) {
            return PSID_ERR_SHORT;
        }
        info->flags = (uint16_t)psid_be(image, PSID_OFS_FLAGS, 2u);
        info->start_page = image[PSID_OFS_START_PG];
        info->page_length = image[PSID_OFS_PAGE_LEN];
        if (info->version >= 3u) {
            info->second_sid = image[PSID_OFS_SID2];
        }
        if (info->version >= 4u) {
            info->third_sid = image[PSID_OFS_SID3];
        }
        info->clock = (uint8_t)((info->flags >> PSID_CLOCK_SHIFT) & PSID_FIELD2_MASK);
        info->sid_model = (uint8_t)((info->flags >> PSID_MODEL_SHIFT) & PSID_FIELD2_MASK);
    } else {
        info->clock = PSID_CLOCK_PAL;
        info->sid_model = PSID_MODEL_6581;
    }

    ofs = info->data_offset;
    if (ofs != ((info->version >= 2u) ? PSID_V2_HEADER_BYTES : PSID_V1_HEADER_BYTES)) {
        return PSID_ERR_DATA_OFFSET;
    }
    if (info->load_field == 0u) {
        if (len < ofs + PSID_LOAD_BYTES) {
            return PSID_ERR_NO_DATA;
        }
        info->load_addr = (uint16_t)(image[ofs] | ((uint32_t)image[ofs + 1u] << 8)); /* LE */
        ofs += PSID_LOAD_BYTES;
    } else {
        info->load_addr = info->load_field;
    }
    if (len <= ofs) {
        return PSID_ERR_NO_DATA;
    }
    info->data = &image[ofs];
    info->data_len = len - ofs;
    if (info->init_addr == 0u) {
        info->init_addr = info->load_addr;
    }
    if (info->start_song == 0u) {
        info->start_song = 1u;
    }
    return PSID_OK;
}

/*
 * psid_song_is_vbi -- speed bit of one song.
 * Returns: 1 for vertical-blank timing, 0 for CIA timing (bit 31 for songs above 32;
 *   song 0 reads song 1's bit).
 */
int psid_song_is_vbi(const psid_info_t *info, uint16_t song)
{
    uint32_t bit = 0u;

    if (song > PSID_SPEED_BITS) {
        bit = PSID_SPEED_BITS - 1u;
    } else if (song > 0u) {
        bit = (uint32_t)song - 1u;
    }

    return ((info->speed >> bit) & 1u) == 0u;
}

/*
 * psid_parse -- decode and validate a PSID/RSID image for milestone-1 playback.
 * Steps:
 *   1. Unpack the header (fills *info as far as it gets, so a reject can still show names).
 *   2. Reject RSID, bad versions, bad song counts or start song, MUS data, play = 0.
 *   3. Reject data past $FFFF, over the I/O window or over the c64mem stub areas.
 * Returns: PSID_OK or the first reject reason (psid_status_t).
 */
psid_status_t psid_parse(const uint8_t *image, uint32_t len, psid_info_t *info)
{
    psid_status_t st;

    if (image == NULL || info == NULL) {
        return PSID_ERR_NULL;
    }
    st = psid_unpack(image, len, info);
    if (st != PSID_OK) {
        return st;
    }
    if (info->rsid != 0u) {
        return PSID_ERR_RSID;
    }
    if (info->version < PSID_VERSION_MIN || info->version > PSID_VERSION_MAX) {
        return PSID_ERR_VERSION;
    }
    if (info->songs == 0u || info->songs > PSID_MAX_SONGS) {
        return PSID_ERR_SONGS;
    }
    if (info->start_song > info->songs) {
        return PSID_ERR_SONG_RANGE;
    }
    if ((info->flags & PSID_FLAG_MUS) != 0u) {
        return PSID_ERR_MUS;
    }
    if (info->play_addr == 0u) {
        return PSID_ERR_PLAY_ZERO;
    }
    switch (c64mem_check_range(info->load_addr, info->data_len)) {
    case C64MEM_RANGE_OK:
        return PSID_OK;
    case C64MEM_RANGE_IO:
        return PSID_ERR_IO_OVERLAP;
    case C64MEM_RANGE_STUB:
        return PSID_ERR_STUB_OVERLAP;
    case C64MEM_RANGE_EMPTY:
        return PSID_ERR_NO_DATA;
    case C64MEM_RANGE_PAST_END:
    default:
        return PSID_ERR_PAST_END;
    }
}

/*
 * psid_load -- validate an image and copy its C64 data into c64mem.
 * Steps:
 *   1. psid_parse; on a reject nothing is loaded (the previous tune is dropped).
 *   2. Reset the C64 address space and copy the data to the load address.
 *   3. Keep the decoded header (with its pointer into the caller's image).
 * Returns: PSID_OK or the reject reason; *info holds what the header decode produced.
 */
psid_status_t psid_load(const uint8_t *image, uint32_t len, psid_info_t *info)
{
    psid_status_t st;

    g_loaded = 0;
    g_inited = 0;
    st = psid_parse(image, len, info);
    if (st != PSID_OK) {
        return st;
    }
    c64mem_reset();
    if (c64mem_load(info->load_addr, info->data, info->data_len) != 0) {
        return PSID_ERR_PAST_END;
    }
    g_info = *info;
    g_loaded = 1;
    return PSID_OK;
}

/*
 * psid_map_call -- translate a c64mem call result.
 * Returns: PSID_OK for a return to the sentinel, else cap_status / PSID_ERR_JAM / _BRK.
 */
static psid_status_t psid_map_call(c64mem_call_t res, psid_status_t cap_status)
{
    switch (res) {
    case C64MEM_CALL_RETURNED:
        return PSID_OK;
    case C64MEM_CALL_JAM:
        return PSID_ERR_JAM;
    case C64MEM_CALL_BRK:
        return PSID_ERR_BRK;
    case C64MEM_CALL_CYCLE_CAP:
    default:
        return cap_status;
    }
}

/*
 * psid_init -- start one song of the loaded tune.
 * Steps:
 *   1. Require a loaded tune; song 0 selects the start song; reject songs outside
 *      1..songs.
 *   2. Reset the address space, reload the C64 data, sidbus_reset with the tune's model.
 *   3. Call init with A = song - 1, capped at PSID_INIT_MAX_CYCLES (its SID writes go
 *      to sidbus_write like any call's).
 * Returns: PSID_OK when init returned; otherwise the reject or failure reason (the
 *   tune is then not playable until the next successful psid_init).
 */
psid_status_t psid_init(uint16_t song)
{
    c64mem_call_t res;
    psid_status_t st;

    g_inited = 0;
    if (g_loaded == 0) {
        return PSID_ERR_NOT_LOADED;
    }
    if (song == 0u) {
        song = g_info.start_song;
    }
    if (song > g_info.songs) {
        return PSID_ERR_SONG_RANGE;
    }
    c64mem_reset();
    if (c64mem_load(g_info.load_addr, g_info.data, g_info.data_len) != 0) {
        return PSID_ERR_PAST_END;
    }
    sidbus_reset((g_info.sid_model == PSID_MODEL_8580) ? SIDBUS_MODEL_8580 : SIDBUS_MODEL_6581);
    res = c64mem_call(g_info.init_addr, (uint8_t)(song - 1u), PSID_INIT_MAX_CYCLES);
    st = psid_map_call(res, PSID_ERR_INIT_CAP);
    if (st == PSID_OK) {
        g_song = song;
        g_inited = 1;
    }
    return st;
}

/*
 * psid_play_period_cycles -- PAL-clock cycles between play calls of the current song.
 * Steps:
 *   1. VBI song: PSID_PAL_FRAME_CYCLES, or PSID_NTSC_FRAME_CYCLES for an NTSC-only tune.
 *   2. CIA song: CIA 1 timer A latch + 1 as the tune wrote it (c64mem), else
 *      PSID_CIA_DEFAULT_LATCH + 1. Evaluated on every call, so a timer the tune changes
 *      in init or play takes effect on the next period.
 *   3. NTSC-only tune: scale by PSID_PAL_CLOCK_HZ / PSID_NTSC_CLOCK_HZ (tempo only).
 *   4. Clamp to PSID_PERIOD_MIN_CYCLES..PSID_PERIOD_MAX_CYCLES.
 * Returns: the period; PSID_PAL_FRAME_CYCLES before any successful psid_init.
 */
uint32_t psid_play_period_cycles(void)
{
    uint32_t period;
    uint32_t latch;
    const int ntsc = (g_info.clock == PSID_CLOCK_NTSC);

    if (g_inited == 0) {
        return PSID_PAL_FRAME_CYCLES;
    }
    if (psid_song_is_vbi(&g_info, g_song) != 0) {
        period = ntsc ? PSID_NTSC_FRAME_CYCLES : PSID_PAL_FRAME_CYCLES;
    } else {
        latch = c64mem_cia1_ta_latch();
        if (latch == 0u) {
            latch = PSID_CIA_DEFAULT_LATCH;
        }
        period = latch + 1u;
    }
    if (ntsc) {
        period = (uint32_t)(((uint64_t)period * PSID_PAL_CLOCK_HZ) / PSID_NTSC_CLOCK_HZ);
    }
    if (period < PSID_PERIOD_MIN_CYCLES) {
        period = PSID_PERIOD_MIN_CYCLES;
    } else if (period > PSID_PERIOD_MAX_CYCLES) {
        period = PSID_PERIOD_MAX_CYCLES;
    }
    return period;
}

/*
 * psid_play_frame -- run the play routine once (one PAL frame).
 * Steps:
 *   1. Require a successful psid_init.
 *   2. c64mem_call(play) with the C64MEM_PLAY_MAX_CYCLES cap; its SID writes reach
 *      sidbus_write with cycle offsets from the start of the call.
 * Returns: PSID_OK, PSID_ERR_NOT_INITED, PSID_ERR_PLAY_CAP (the writes made up to the
 *   cap have been delivered), PSID_ERR_JAM or PSID_ERR_BRK.
 */
psid_status_t psid_play_frame(void)
{
    if (g_inited == 0) {
        return PSID_ERR_NOT_INITED;
    }
    return psid_map_call(c64mem_call(g_info.play_addr, 0u, C64MEM_PLAY_MAX_CYCLES),
                         PSID_ERR_PLAY_CAP);
}

/*
 * psid_status_text -- screen text for a status code.
 * Returns: an upper-case message (PETSCII-safe ASCII), "UNKNOWN ERROR" out of range.
 */
const char *psid_status_text(psid_status_t status)
{
    if ((uint32_t)status >= (uint32_t)PSID_ERR_COUNT) {
        return "UNKNOWN ERROR";
    }
    return g_status_text[status];
}
