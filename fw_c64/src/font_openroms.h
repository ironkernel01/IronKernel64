/*
 * GENERATED FILE -- do not edit. Generator: tools/font2c.py (run with python -I).
 * Source: https://github.com/MEGA65/open-roms, commit ad178dbe4d48cd6a317737a8e0e7e662f7e33d32,
 *   file assets/8x8font.png (copy in third_party/open-roms/8x8font.png).
 *
 * MEGA65 Open ROMs character set.
 *   Copyright Paul Gardner-Stephen, 2019.
 *   Copyright Roman Standzikowski (FeralChild64), 2019-2021.
 * This font is free software: you can redistribute it and/or modify it under the
 * terms of the GNU Lesser General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 * It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU Lesser General Public License (third_party/open-roms/COPYING.LESSER)
 * for more details.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * File: font_openroms.h
 * Role: accessor for the 8x8 C64 character set (generated with font_openroms.c).
 * Glyph order is C64 screen-code order:
 *   0..127 upper-case/graphics set, 128..255 its reverse-video half,
 *   256..383 lower-case/upper-case set, 384..511 its reverse-video half.
 * Each glyph is 8 bytes, top row first; bit 7 is the leftmost pixel.
 */
#ifndef FONT_OPENROMS_H
#define FONT_OPENROMS_H

#include <stdint.h> /* uint8_t, uint32_t */

#define FONT_OPENROMS_GLYPHS        (512u)
#define FONT_OPENROMS_ROWS          (8u)
#define FONT_OPENROMS_SET_GLYPHS    (256u)  /* glyphs per character set */
#define FONT_OPENROMS_REVERSE_EXACT (0u) /* 1: glyph n+128 == NOT glyph n */

const uint8_t *font_openroms_glyph(uint32_t index);

#endif /* FONT_OPENROMS_H */
