/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: oled.c
 * Role: driver of the oled_ctrl block (contract: oled.h).
 *
 * Ownership: the only file that accesses the OLED registers (C64_PLAT_WIN0_BASE +
 *   C64_WIN_OLED_OFS, offsets in c64_regs.h).
 * Bus access: 32-bit words only (Xil_In32/Xil_Out32); a byte column is merged by
 *   read-modify-write of its word, so no byte strobes are relied on.
 * Host build: with OLED_HOST_TEST the bus functions and the log are supplied by the test.
 */
#include "oled.h"

#include <stddef.h>

#include "font_openroms.h"

#ifdef OLED_HOST_TEST
#include <stdio.h>
uint32_t Xil_In32(uintptr_t addr);
void     Xil_Out32(uintptr_t addr, uint32_t val);
#define OLED_LOG(msg)   (void)puts(msg)
#ifndef C64_PLAT_WIN0_BASE
#define C64_PLAT_WIN0_BASE (0x44000000u)
#endif
#else
#include "c64_platform.h"
#include "c64_regs.h"
#include "xil_io.h"     /* Xil_In32, Xil_Out32 */
#include "xil_printf.h" /* xil_printf */
#define OLED_LOG(msg)   xil_printf("%s\r\n", (msg))
#endif

/* Names from c64_regs.h when present; local copies of the register contract otherwise. */
#ifndef C64_WIN_OLED_OFS
#define C64_WIN_OLED_OFS       (0x00050000u)
#endif
#ifndef C64_OLED_ID_OFS
#define C64_OLED_ID_OFS        (0x000u)
#endif
#ifndef C64_OLED_CTRL_OFS
#define C64_OLED_CTRL_OFS      (0x008u)
#endif
#ifndef C64_OLED_STATUS_OFS
#define C64_OLED_STATUS_OFS    (0x00Cu)
#endif
#ifndef C64_OLED_CONTRAST_OFS
#define C64_OLED_CONTRAST_OFS  (0x010u)
#endif
#ifndef C64_OLED_SCROLL0_OFS
#define C64_OLED_SCROLL0_OFS   (0x020u)
#endif
#ifndef C64_OLED_FB_OFS
#define C64_OLED_FB_OFS        (0x800u)
#endif

#define OLED_REG(ofs)       (C64_PLAT_WIN0_BASE + C64_WIN_OLED_OFS + (uint32_t)(ofs))
#define OLED_ID_VALUE       (0x4F4C4544u)   /* "OLED" */
#define OLED_CTRL_POWER     (1u << 0)
#define OLED_SCROLL_MASK    (OLED_VCOLS - 1u)
#define OLED_WORD_BYTES     (4u)
#define OLED_PAGE_WORDS     (OLED_VCOLS / OLED_WORD_BYTES)   /* 128 */
#define OLED_FB_WORDS       (OLED_PAGES * OLED_PAGE_WORDS)   /* 512 */
#define OLED_BYTE_BITS      (8u)
#define OLED_BYTE_MASK      (0xFFu)
#define OLED_GLYPH_ROWS     (8u)
#define OLED_SCREEN_QMARK   (63u)

static int g_present;

/*
 * oled_fb_addr -- bus address of the frame buffer word holding (page, vcol).
 * Returns: the address; the byte lane is vcol & 3.
 */
static uint32_t oled_fb_addr(uint32_t page, uint32_t vcol)
{
    return OLED_REG(C64_OLED_FB_OFS) +
           (((page * OLED_PAGE_WORDS) + (vcol / OLED_WORD_BYTES)) * OLED_WORD_BYTES);
}

/*
 * oled_init -- probe the ID register and start the power-up sequence.
 * Returns: 1 when the block answers with "OLED", else 0 (all other calls become no-ops).
 */
int oled_init(void)
{
    g_present = (Xil_In32(OLED_REG(C64_OLED_ID_OFS)) == OLED_ID_VALUE) ? 1 : 0;
    if (!g_present) {
        OLED_LOG("OLED: block not present");
        return 0;
    }
    Xil_Out32(OLED_REG(C64_OLED_CTRL_OFS), OLED_CTRL_POWER);
    return 1;
}

/*
 * oled_present -- the block answered at oled_init().
 * Returns: 1 or 0.
 */
int oled_present(void)
{
    return g_present;
}

/*
 * oled_clear -- zero the whole frame buffer.
 * Returns: nothing.
 */
void oled_clear(void)
{
    if (!g_present) {
        return;
    }
    for (uint32_t w = 0u; w < OLED_FB_WORDS; w++) {
        Xil_Out32(OLED_REG(C64_OLED_FB_OFS) + (w * OLED_WORD_BYTES), 0u);
    }
}

/*
 * oled_set_contrast -- panel contrast.
 * Returns: nothing.
 */
void oled_set_contrast(uint8_t contrast)
{
    if (g_present) {
        Xil_Out32(OLED_REG(C64_OLED_CONTRAST_OFS), (uint32_t)contrast);
    }
}

/*
 * oled_set_scroll -- virtual column shown at display column 0 of a page.
 * Returns: nothing.
 */
void oled_set_scroll(uint32_t page, uint32_t off)
{
    if (g_present && page < OLED_PAGES) {
        Xil_Out32(OLED_REG(C64_OLED_SCROLL0_OFS) + (page * OLED_WORD_BYTES), off & OLED_SCROLL_MASK);
    }
}

/*
 * oled_put_column -- write one byte column (bit 0 = top row of the page).
 * Returns: nothing; out-of-range page or column is ignored.
 */
void oled_put_column(uint32_t page, uint32_t vcol, uint8_t bits)
{
    uint32_t addr;
    uint32_t shift;
    uint32_t w;

    if (!g_present || page >= OLED_PAGES || vcol >= OLED_VCOLS) {
        return;
    }
    addr = oled_fb_addr(page, vcol);
    shift = (vcol % OLED_WORD_BYTES) * OLED_BYTE_BITS;
    w = Xil_In32(addr);
    w = (w & ~(OLED_BYTE_MASK << shift)) | ((uint32_t)bits << shift);
    Xil_Out32(addr, w);
}

/*
 * oled_get_column -- read one byte column back.
 * Returns: the byte, 0 when absent or out of range.
 */
uint8_t oled_get_column(uint32_t page, uint32_t vcol)
{
    if (!g_present || page >= OLED_PAGES || vcol >= OLED_VCOLS) {
        return 0u;
    }
    return (uint8_t)((Xil_In32(oled_fb_addr(page, vcol)) >>
                      ((vcol % OLED_WORD_BYTES) * OLED_BYTE_BITS)) & OLED_BYTE_MASK);
}

/*
 * oled_ascii_to_screen -- ASCII to C64 screen code of character set 0 (upper case/graphics).
 * Letters of either case map to the capitals; characters without a glyph give '?'.
 * Returns: screen code 0..63.
 */
uint32_t oled_ascii_to_screen(char c)
{
    const uint32_t u = (uint32_t)(uint8_t)c;

    if (u >= (uint32_t)'a' && u <= (uint32_t)'z') {
        return u - (uint32_t)'a' + 1u;
    }
    if (u >= (uint32_t)'A' && u <= (uint32_t)'Z') {
        return u - (uint32_t)'A' + 1u;
    }
    if (u >= 0x20u && u <= 0x3Fu) {
        return u;
    }
    switch (c) {
    case '@': return 0u;
    case '[': return 27u;
    case ']': return 29u;
    case '^': return 30u;
    case '_': return 31u;
    default:  return OLED_SCREEN_QMARK;
    }
}

/*
 * oled_glyph_column -- one page-format column of a glyph.
 * Steps: column x (0 = leftmost) takes bit (7 - x) of each glyph row; row r goes to bit r.
 * Returns: the column byte, complemented when invert.
 */
uint8_t oled_glyph_column(const uint8_t *glyph, uint32_t x, int invert)
{
    uint32_t col = 0u;

    for (uint32_t r = 0u; r < OLED_GLYPH_ROWS; r++) {
        col |= (((uint32_t)glyph[r] >> ((OLED_GLYPH_COLS - 1u) - x)) & 1u) << r;
    }
    if (invert) {
        col ^= OLED_BYTE_MASK;
    }
    return (uint8_t)col;
}

/*
 * oled_put_text -- draw ASCII text as 8x8 glyphs starting at a virtual column of a page.
 * Returns: the number of columns written (clipped at virtual column 511).
 */
uint32_t oled_put_text(uint32_t page, uint32_t vcol, const char *ascii, int invert)
{
    uint32_t written = 0u;

    if (!g_present || page >= OLED_PAGES || ascii == NULL) {
        return 0u;
    }
    for (; *ascii != '\0'; ascii++) {
        const uint8_t *glyph = font_openroms_glyph(oled_ascii_to_screen(*ascii));

        for (uint32_t x = 0u; x < OLED_GLYPH_COLS; x++) {
            if ((vcol + written) >= OLED_VCOLS) {
                return written;
            }
            oled_put_column(page, vcol + written, oled_glyph_column(glyph, x, invert));
            written++;
        }
    }
    return written;
}

/*
 * oled_status -- STATUS register ([1:0] state, [31:16] frame count).
 * Returns: the register, 0 when absent.
 */
uint32_t oled_status(void)
{
    return g_present ? Xil_In32(OLED_REG(C64_OLED_STATUS_OFS)) : 0u;
}
