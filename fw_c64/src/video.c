/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 IronKernel
 *
 * File: video.c
 * Role: driver of the c64_video block: palette, enable, vsync interrupt, page flip, and the
 *   pixel primitives (fill, putpixel, 8x8 glyph blit) on the two framebuffer pages.
 *
 * Ownership: this file is the only one that accesses the c64_video registers
 *   (C64_PLAT_WIN0_BASE + C64_WIN_VID_OFS, offsets in c64_regs.h) and the framebuffer
 *   (C64_PLAT_FB_BASE, common/c64_platform.h). Contract and geometry: video.h.
 * Bus access: every framebuffer access is a 32-bit word (Xil_In32/Xil_Out32); pixels that
 *   do not fill a whole word are merged by read-modify-write, so the framebuffer BRAM needs
 *   no byte write enables. Both regions are uncached (c64_platform.h), so no cache upkeep.
 * Concurrency: video_vsync_isr() writes only the STATUS register (W1C) and g_vsync_count;
 *   the main context owns CTRL (g_ctrl) and the pages.
 */
#include "video.h"

#include "c64_platform.h"

#include "xil_io.h"    /* Xil_In32, Xil_Out32 */

#define VIDEO_REG_BASE        (C64_PLAT_WIN0_BASE + C64_WIN_VID_OFS)
#define VIDEO_REG(ofs)        (VIDEO_REG_BASE + (uint32_t)(ofs))
#define VIDEO_PAGE_BASE(p)    (C64_PLAT_FB_BASE + ((p) & 1u) * C64_FB_PAGE_BYTES)
#define VIDEO_BYTES_PER_WORD  (4u)
#define VIDEO_BYTE_BITS       (8u)
#define VIDEO_BYTE_MASK       (0xFFu)
#define VIDEO_PAL_CHANNEL_MAX (0xFFFFFFu)

#if (C64_FB_PAGE_BYTES * C64_FB_PAGES) > C64_PLAT_FB_RANGE
#error "framebuffer pages exceed the BD framebuffer window"
#endif
#if (C64_FB_WIDTH % VIDEO_BYTES_PER_WORD) != 0u
#error "framebuffer lines must be whole 32-bit words"
#endif

/*
 * C64 palette, "Colodore (PAL)" by Philip "Pepto" Timmermann (colodore.com), as published in
 * VICE 3.9 data/C64/colodore.vpl (checked 11-09-2026 at
 * https://sources.debian.org/src/vice/3.9%2Bdfsg-1/data/C64/colodore.vpl). 0x00RRGGBB.
 */
static const uint32_t g_colodore[VIDEO_C64_COLOURS] = {
    0x000000u, /*  0 black       */
    0xFFFFFFu, /*  1 white       */
    0x96282Eu, /*  2 red         */
    0x5BD6CEu, /*  3 cyan        */
    0x9F2DADu, /*  4 purple      */
    0x41B936u, /*  5 green       */
    0x2724C4u, /*  6 blue        */
    0xEFF347u, /*  7 yellow      */
    0x9F4815u, /*  8 orange      */
    0x5E3500u, /*  9 brown       */
    0xDA5F66u, /* 10 light red   */
    0x474747u, /* 11 dark grey   */
    0x787878u, /* 12 grey        */
    0x91FF84u, /* 13 light green */
    0x6864FFu, /* 14 light blue  */
    0xAEAEAEu  /* 15 light grey  */
};

static uint32_t g_ctrl;                    /* shadow of CTRL; main context only */
static uint32_t g_req_page;                /* page requested in CTRL (0/1) */
static video_vsync_mode_t g_mode;
static volatile uint32_t g_vsync_count;    /* set by ISR or video_poll, read by main */

/*
 * fill_word -- four copies of a colour byte.
 * Returns: the 32-bit word.
 */
static uint32_t fill_word(uint8_t colour)
{
    return (uint32_t)colour * 0x01010101u;
}

/*
 * merge_pixel -- store one pixel by read-modify-write of its 32-bit word.
 * Steps:
 *   1. Read the word holding byte address addr.
 *   2. Replace the byte lane (addr % 4) with colour and write the word back.
 * Returns: nothing.
 */
static void merge_pixel(uint32_t addr, uint8_t colour)
{
    uint32_t word_addr = addr & ~(VIDEO_BYTES_PER_WORD - 1u);
    uint32_t shift = (addr & (VIDEO_BYTES_PER_WORD - 1u)) * VIDEO_BYTE_BITS;
    uint32_t w = Xil_In32(word_addr);

    w &= ~(VIDEO_BYTE_MASK << shift);
    w |= (uint32_t)colour << shift;
    Xil_Out32(word_addr, w);
}

/*
 * fill_span -- one horizontal run of a colour on one line (already clipped).
 * Steps:
 *   1. Merge single pixels up to the first word boundary.
 *   2. Write whole words while at least 4 pixels remain.
 *   3. Merge the remaining pixels.
 * Returns: nothing.
 */
static void fill_span(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint8_t colour)
{
    uint32_t addr = VIDEO_PAGE_BASE(page) + y * C64_FB_WIDTH + x;
    uint32_t end = addr + w;
    uint32_t word = fill_word(colour);

    while (addr < end && (addr & (VIDEO_BYTES_PER_WORD - 1u)) != 0u) {
        merge_pixel(addr, colour);
        addr++;
    }
    while (end - addr >= VIDEO_BYTES_PER_WORD) {
        Xil_Out32(addr, word);
        addr += VIDEO_BYTES_PER_WORD;
    }
    while (addr < end) {
        merge_pixel(addr, colour);
        addr++;
    }
}

/*
 * video_init -- palette, blank pages, display on.
 * Steps:
 *   1. Disable the display and its interrupt; clear a stale vsync flag (W1C).
 *   2. Load palette entries 0..15 with Colodore, entries 16..255 with black.
 *   3. Fill both pages with black; request page 0.
 *   4. Enable the display, and the vsync interrupt in VIDEO_VSYNC_IRQ mode (the caller
 *      connects video_vsync_isr to the INTC before enabling interrupts globally).
 * Returns: nothing.
 */
void video_init(video_vsync_mode_t mode)
{
    g_mode = mode;
    g_ctrl = 0u;
    g_req_page = 0u;
    g_vsync_count = 0u;
    Xil_Out32(VIDEO_REG(C64_VID_CTRL_OFS), g_ctrl);
    Xil_Out32(VIDEO_REG(C64_VID_STATUS_OFS), 1u << C64_VID_STATUS_VSYNC_BIT);

    for (uint32_t i = 0u; i < C64_VID_PALETTE_ENTRIES; i++) {
        video_set_palette(i, (i < VIDEO_C64_COLOURS) ? g_colodore[i] : 0u);
    }
    video_fill_page(0u, VIDEO_COL_BLACK);
    video_fill_page(1u, VIDEO_COL_BLACK);

    g_ctrl = 1u << C64_VID_CTRL_ENABLE_BIT;
    if (mode == VIDEO_VSYNC_IRQ) {
        g_ctrl |= 1u << C64_VID_CTRL_IRQ_EN_BIT;
    }
    Xil_Out32(VIDEO_REG(C64_VID_CTRL_OFS), g_ctrl);
}

/*
 * video_vsync_isr -- vsync interrupt handler (connect to the INTC input of c64_video).
 * Steps:
 *   1. If STATUS shows a vsync, clear it (W1C) and count the frame.
 * Returns: nothing. Must not draw or touch CTRL (main context owns them).
 */
void video_vsync_isr(void *ref)
{
    (void)ref;
    if ((Xil_In32(VIDEO_REG(C64_VID_STATUS_OFS)) & (1u << C64_VID_STATUS_VSYNC_BIT)) != 0u) {
        Xil_Out32(VIDEO_REG(C64_VID_STATUS_OFS), 1u << C64_VID_STATUS_VSYNC_BIT);
        g_vsync_count++;
    }
}

/*
 * video_poll -- polled vsync detection (VIDEO_VSYNC_POLL mode only).
 * Steps:
 *   1. In polled mode, run the same check as the ISR.
 * Returns: the vsync count after the check.
 */
uint32_t video_poll(void)
{
    if (g_mode == VIDEO_VSYNC_POLL) {
        video_vsync_isr(0);
    }
    return g_vsync_count;
}

/*
 * video_vsync_count -- frames seen since video_init (wraps at 2^32).
 * Returns: the count.
 */
uint32_t video_vsync_count(void)
{
    return g_vsync_count;
}

/*
 * video_frame_counter -- the hardware frame counter (FRAME register).
 * Returns: the register value.
 */
uint32_t video_frame_counter(void)
{
    return Xil_In32(VIDEO_REG(C64_VID_FRAME_OFS));
}

/*
 * video_front_page -- page the hardware is displaying (STATUS page bit).
 * Returns: 0 or 1.
 */
uint32_t video_front_page(void)
{
    return (Xil_In32(VIDEO_REG(C64_VID_STATUS_OFS)) >> C64_VID_STATUS_PAGE_BIT) & 1u;
}

/*
 * video_flip_pending -- a requested page is not on screen yet.
 * Returns: 1 while the hardware still shows the other page, else 0.
 */
int video_flip_pending(void)
{
    return (video_front_page() != g_req_page) ? 1 : 0;
}

/*
 * video_back_page -- the page the CPU may draw on.
 * Returns: the page not requested for display (valid when video_flip_pending() == 0).
 */
uint32_t video_back_page(void)
{
    return g_req_page ^ 1u;
}

/*
 * video_flip -- request the back page for display from the next vsync on.
 * Steps:
 *   1. Toggle the requested page and write CTRL with the new page bit.
 * Returns: nothing. The caller checks video_flip_pending() before drawing again.
 */
void video_flip(void)
{
    g_req_page ^= 1u;
    g_ctrl &= ~(1u << C64_VID_CTRL_PAGE_BIT);
    g_ctrl |= g_req_page << C64_VID_CTRL_PAGE_BIT;
    Xil_Out32(VIDEO_REG(C64_VID_CTRL_OFS), g_ctrl);
}

/*
 * video_set_palette -- write one palette entry.
 * Steps:
 *   1. Ignore indices past the palette; write 0x00RRGGBB to entry index.
 * Returns: nothing.
 */
void video_set_palette(uint32_t index, uint32_t rgb)
{
    if (index < C64_VID_PALETTE_ENTRIES) {
        Xil_Out32(VIDEO_REG(C64_VID_PALETTE_OFS + index * 4u), rgb & VIDEO_PAL_CHANNEL_MAX);
    }
}

/*
 * video_fill_page -- fill a whole page with one colour (word writes only).
 * Returns: nothing.
 */
void video_fill_page(uint32_t page, uint8_t colour)
{
    uint32_t base = VIDEO_PAGE_BASE(page);
    uint32_t word = fill_word(colour);

    for (uint32_t i = 0u; i < C64_FB_PAGE_BYTES; i += VIDEO_BYTES_PER_WORD) {
        Xil_Out32(base + i, word);
    }
}

/*
 * video_fill_rect -- fill a rectangle, clipped to the page.
 * Steps:
 *   1. Clip the rectangle; return if nothing is left.
 *   2. Fill each line with fill_span (word writes in the aligned middle).
 * Returns: nothing.
 */
void video_fill_rect(uint32_t page, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                     uint8_t colour)
{
    if (x >= C64_FB_WIDTH || y >= C64_FB_HEIGHT) {
        return;
    }
    if (w > C64_FB_WIDTH - x) {
        w = C64_FB_WIDTH - x;
    }
    if (h > C64_FB_HEIGHT - y) {
        h = C64_FB_HEIGHT - y;
    }
    for (uint32_t row = 0u; row < h; row++) {
        fill_span(page, x, y + row, w, colour);
    }
}

/*
 * video_putpixel -- one pixel, clipped.
 * Returns: nothing.
 */
void video_putpixel(uint32_t page, uint32_t x, uint32_t y, uint8_t colour)
{
    if (x < C64_FB_WIDTH && y < C64_FB_HEIGHT) {
        merge_pixel(VIDEO_PAGE_BASE(page) + y * C64_FB_WIDTH + x, colour);
    }
}

/*
 * video_glyph -- draw an 8x8 glyph with foreground and background colours.
 * Steps:
 *   1. For each of the 8 rows (clipped at the bottom), invert the row bits when reverse
 *      is set; bit 7 is the leftmost pixel.
 *   2. When x is word aligned and the glyph fits horizontally, write the row as two words.
 *   3. Otherwise store each visible pixel with a read-modify-write.
 * Returns: nothing.
 */
void video_glyph(uint32_t page, uint32_t x, uint32_t y, const uint8_t *rows, uint8_t fg,
                 uint8_t bg, int reverse)
{
    uint32_t base = VIDEO_PAGE_BASE(page);

    for (uint32_t r = 0u; r < VIDEO_GLYPH_PIXELS && (y + r) < C64_FB_HEIGHT; r++) {
        uint8_t bits = reverse ? (uint8_t)~rows[r] : rows[r];
        uint32_t line = base + (y + r) * C64_FB_WIDTH;

        if ((x & (VIDEO_BYTES_PER_WORD - 1u)) == 0u && x + VIDEO_GLYPH_PIXELS <= C64_FB_WIDTH) {
            uint32_t w0 = 0u;
            uint32_t w1 = 0u;
            for (uint32_t i = 0u; i < VIDEO_BYTES_PER_WORD; i++) {
                uint32_t c0 = ((bits >> (7u - i)) & 1u) ? fg : bg;
                uint32_t c1 = ((bits >> (3u - i)) & 1u) ? fg : bg;
                w0 |= c0 << (i * VIDEO_BYTE_BITS);
                w1 |= c1 << (i * VIDEO_BYTE_BITS);
            }
            Xil_Out32(line + x, w0);
            Xil_Out32(line + x + VIDEO_BYTES_PER_WORD, w1);
        } else {
            for (uint32_t i = 0u; i < VIDEO_GLYPH_PIXELS && (x + i) < C64_FB_WIDTH; i++) {
                merge_pixel(line + x + i, ((bits >> (7u - i)) & 1u) ? fg : bg);
            }
        }
    }
}
