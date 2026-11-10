/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: psid.h
 * Role: PSID/RSID file header parser and the PSID tune driver (load, init,
 *   play one frame) of the core 0 player.
 *
 * Wire format (HVSC SID_file_format, all multi-byte fields big-endian; unpacked
 *   by exactly one helper, psid_unpack, in psid.c):
 *   +$00 magicID "PSID"/"RSID"   +$04 version (1..4)     +$06 dataOffset
 *   +$08 loadAddress             +$0A initAddress        +$0C playAddress
 *   +$0E songs (1..256)          +$10 startSong          +$12 speed (32 bits)
 *   +$16 name[32]  +$36 author[32]  +$56 released[32]   (Latin-1, NUL-padded)
 *   v2+: +$76 flags (16 bits)  +$78 startPage  +$79 pageLength
 *   v3+: +$7A secondSIDAddress   v4: +$7B thirdSIDAddress
 *   dataOffset is $76 for v1 and $7C for v2..v4.
 *   loadAddress 0: the first two data bytes hold it, little-endian.
 *   initAddress 0: init = load address.
 *   speed bit (song - 1), bit 31 for songs above 32: 0 = vertical blank (50 Hz
 *   PAL play call), 1 = CIA timer.
 *   flags: bit 0 MUS data, bit 1 PlaySID-specific (PSID) / BASIC (RSID),
 *   bits 2-3 clock (1 PAL, 2 NTSC, 3 both), bits 4-5 SID model (1 6581, 2 8580,
 *   3 both), bits 6-7 / 8-9 second / third SID model.
 *
 * Milestone-1 acceptance (psid_parse / psid_load / psid_init): PSID v1..v4,
 *   no MUS data, play address != 0, data inside $0000-$FFFF and clear of the
 *   I/O window $D000-$DFFF and the call-return sentinel $FF40 (KERNAL stub areas such as
 *   $EA31/$EA81 may be covered: the tune owns them). RSID files are recognised and
 *   rejected. The second/third SID addresses are reported and ignored. The SID
 *   model is 8580 when the flags say 8580 only, else 6581.
 *
 * Play timing (psid_play_period_cycles): the PAL-clock (985,248 Hz) cycles between play
 *   calls. VBI songs: PAL 312 x 63 = 19656, NTSC 263 x 65 = 17095. CIA songs: the CIA 1
 *   timer A latch + 1 as the tune wrote it, or $4025 + 1 (60 Hz) when it never did.
 *   NTSC-only tunes (header clock NTSC) run on our PAL-clocked SID: the period is
 *   scaled by 985248/1022727 so the tempo is right; the pitch stays about 3.7 % flat
 *   (our SID clock is 3.7 % slower than an NTSC C64's; frequencies are not re-tuned).
 *   The result is clamped to PSID_PERIOD_MIN_CYCLES..PSID_PERIOD_MAX_CYCLES.
 *
 * Lifetime: psid_load keeps a pointer to the caller's image (psid_init reloads
 *   the data from it on every song change); the image must stay valid and
 *   unchanged until the next psid_load.
 * Concurrency: core 0 main loop only.
 * Headers hold signatures, constants, types and contract prose; per-function
 *   commentary lives in psid.c.
 */
#ifndef PSID_H
#define PSID_H

#include <stdint.h> /* uint8_t, uint16_t, uint32_t */

#define PSID_V1_HEADER_BYTES   (0x76u)
#define PSID_V2_HEADER_BYTES   (0x7Cu)
#define PSID_STRING_BYTES      (32u)          /* field width in the file */
#define PSID_MAX_SONGS         (256u)
#define PSID_SPEED_BITS        (32u)

#define PSID_FLAG_MUS          (0x0001u)
#define PSID_FLAG_PSID_SPECIFIC (0x0002u)
#define PSID_CLOCK_SHIFT       (2u)
#define PSID_MODEL_SHIFT       (4u)
#define PSID_FIELD2_MASK       (0x3u)
#define PSID_CLOCK_PAL         (1u)
#define PSID_CLOCK_NTSC        (2u)
#define PSID_MODEL_6581        (1u)
#define PSID_MODEL_8580        (2u)

#define PSID_PAL_FRAME_CYCLES  (19656u)       /* 312 lines x 63 */
#define PSID_NTSC_FRAME_CYCLES (17095u)       /* 263 lines x 65 */
#define PSID_CIA_DEFAULT_LATCH (0x4025u)      /* 60 Hz when the tune sets no timer */
#define PSID_PAL_CLOCK_HZ      (985248u)
#define PSID_NTSC_CLOCK_HZ     (1022727u)
#define PSID_PERIOD_MIN_CYCLES (1000u)
#define PSID_PERIOD_MAX_CYCLES (100000u)

/* Cycle cap of the init call (direct SID writes): 100 PAL frames, about 2 s of C64 time. */
#define PSID_INIT_MAX_CYCLES   (100u * 19656u)

typedef enum
{
    PSID_OK = 0,
    PSID_ERR_NULL,            /* NULL image or info pointer */
    PSID_ERR_SHORT,           /* shorter than the header its version needs */
    PSID_ERR_MAGIC,           /* neither "PSID" nor "RSID" */
    PSID_ERR_RSID,            /* RSID: real C64 environment needed (not in milestone 1) */
    PSID_ERR_VERSION,         /* version not 1..4 */
    PSID_ERR_DATA_OFFSET,     /* dataOffset not $76 (v1) / $7C (v2+) */
    PSID_ERR_NO_DATA,         /* no C64 data after the header (and load address) */
    PSID_ERR_SONGS,           /* songs not 1..256 */
    PSID_ERR_MUS,             /* MUS data (needs a Compute! Sidplayer) */
    PSID_ERR_PLAY_ZERO,       /* play address 0 (init installs its own IRQ) */
    PSID_ERR_PAST_END,        /* data runs past $FFFF */
    PSID_ERR_IO_OVERLAP,      /* data overlaps $D000-$DFFF */
    PSID_ERR_STUB_OVERLAP,    /* data covers the call-return sentinel $FF40 */
    PSID_ERR_NOT_LOADED,      /* psid_init / psid_play_frame before a good psid_load */
    PSID_ERR_SONG_RANGE,      /* song not 1..songs */
    PSID_ERR_NOT_INITED,      /* psid_play_frame before a good psid_init */
    PSID_ERR_INIT_CAP,        /* init did not return within PSID_INIT_MAX_CYCLES */
    PSID_ERR_PLAY_CAP,        /* play did not return within C64MEM_PLAY_MAX_CYCLES */
    PSID_ERR_JAM,             /* the 6502 hit a JAM opcode */
    PSID_ERR_BRK,             /* the 6502 executed BRK */
    PSID_ERR_COUNT
} psid_status_t;

typedef struct
{
    uint8_t  rsid;                         /* 1 for "RSID" */
    uint16_t version;
    uint16_t data_offset;
    uint16_t load_field;                   /* loadAddress as stored (0 = in data) */
    uint16_t load_addr;                    /* effective load address */
    uint16_t init_addr;                    /* effective init address */
    uint16_t play_addr;
    uint16_t songs;
    uint16_t start_song;                   /* 1-based; a stored 0 reads as 1 */
    uint32_t speed;
    char     name[PSID_STRING_BYTES + 1u];     /* NUL-terminated copy */
    char     author[PSID_STRING_BYTES + 1u];
    char     released[PSID_STRING_BYTES + 1u];
    uint16_t flags;                        /* 0 for v1 */
    uint8_t  clock;                        /* PSID_CLOCK_*; v1: PAL */
    uint8_t  sid_model;                    /* PSID_MODEL_*; v1: 6581 */
    uint8_t  start_page;
    uint8_t  page_length;
    uint8_t  second_sid;                   /* v3+: $Dxx0 middle byte, 0 = none (ignored) */
    uint8_t  third_sid;                    /* v4: likewise (ignored) */
    const uint8_t *data;                   /* C64 data inside the image (after the load bytes) */
    uint32_t data_len;
} psid_info_t;

psid_status_t psid_parse(const uint8_t *image, uint32_t len, psid_info_t *info);
psid_status_t psid_load(const uint8_t *image, uint32_t len, psid_info_t *info);
psid_status_t psid_init(uint16_t song);
psid_status_t psid_play_frame(void);
uint32_t psid_play_period_cycles(void);
int psid_song_is_vbi(const psid_info_t *info, uint16_t song);
const char *psid_status_text(psid_status_t status);

#endif /* PSID_H */
