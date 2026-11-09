#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
"""font2c.py -- convert the MEGA65 Open ROMs character set to fw_c64/src/font_openroms.[ch].

Source: third_party/open-roms/8x8font.png, the unmodified upstream assets/8x8font.png of
github.com/MEGA65/open-roms (LGPL-3.0-or-later; commit in third_party/open-roms/SOURCE.txt).
Upstream builds its chargen ROM from that PNG with tools/pngprepare.c, mode "charrom":
  * the image is 8 pixels wide and 4096 rows high: 512 glyphs x 8 rows, top to bottom;
  * a pixel is set when any of its R, G, B components (after palette expansion) is > 0x7F;
  * bit 7 of each row byte is the leftmost pixel;
  * the rows are written out in image order, so glyph n is image rows 8n..8n+7.
This script applies the same rules, so its output equals upstream bin/chargen_openroms.rom byte
for byte (checked with --check-rom).

Glyph order (no remapping needed): the chargen layout is C64 screen-code order.
  glyphs   0..127  upper-case/graphics set, screen codes $00..$7F
  glyphs 128..255  the same set in reverse video (screen codes $80..$FF)
  glyphs 256..383  lower-case/upper-case set, screen codes $00..$7F
  glyphs 384..511  the same set in reverse video
The script checks the reverse halves (glyph n+128 == NOT glyph n) and reports any difference.

Usage (run isolated, no site packages needed):
  python -I tools/font2c.py --png third_party/open-roms/8x8font.png \
      --check-rom third_party/open-roms/chargen_openroms.rom \
      --source third_party/open-roms/SOURCE.txt --out-dir fw_c64/src
Exit status: 0 written, 1 input error or check failure.
"""
import argparse
import os
import struct
import sys
import zlib

GLYPHS = 512
ROWS = 8
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
THRESHOLD = 0x7F
REVERSE_SPAN = 128


class FontError(Exception):
    """Input file is not what the converter expects."""


def paeth(a, b, c):
    """paeth -- PNG Paeth predictor (PNG spec 9.4)."""
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path):
    """read_png -- decode an 8-bit PNG into rows of (r, g, b) tuples.

    Steps:
      1. Parse IHDR, PLTE and the IDAT chunks; reject interlaced or non-8-bit images.
      2. Inflate the IDAT stream and undo the per-row filters.
      3. Expand each pixel to RGB (palette, grey or truecolour).
    Returns: (width, height, rows) where rows[y][x] is an (r, g, b) tuple.
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != PNG_MAGIC:
        raise FontError(f"{path}: not a PNG file")
    pos = 8
    ihdr = None
    palette = []
    idat = bytearray()
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"PLTE":
            palette = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
    if ihdr is None:
        raise FontError(f"{path}: no IHDR chunk")
    width, height, depth, colour, _comp, _filt, interlace = ihdr
    if depth != 8 or interlace != 0:
        raise FontError(f"{path}: need 8-bit non-interlaced PNG (depth {depth}, interlace {interlace})")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise FontError(f"{path}: unsupported colour type {colour}")
    if colour == 3 and not palette:
        raise FontError(f"{path}: indexed PNG without PLTE")
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows = []
    prev = bytearray(stride)
    p = 0
    for _y in range(height):
        ftype = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = prev[i]
            upleft = prev[i - channels] if i >= channels else 0
            if ftype == 1:
                line[i] = (line[i] + left) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + up) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + ((left + up) >> 1)) & 0xFF
            elif ftype == 4:
                line[i] = (line[i] + paeth(left, up, upleft)) & 0xFF
            elif ftype != 0:
                raise FontError(f"{path}: bad filter type {ftype}")
        prev = line
        pix = []
        for x in range(width):
            px = line[x * channels:(x + 1) * channels]
            if colour == 3:
                pix.append(palette[px[0]])
            elif colour in (0, 4):
                pix.append((px[0], px[0], px[0]))
            else:
                pix.append((px[0], px[1], px[2]))
        rows.append(pix)
    return width, height, rows


def png_to_glyphs(path):
    """png_to_glyphs -- apply the pngprepare "charrom" rules to the font image.

    Returns: bytes of GLYPHS * ROWS, glyph n at offset 8n, bit 7 = leftmost pixel.
    """
    width, height, rows = read_png(path)
    if width != 8:
        raise FontError(f"{path}: font image must be 8 pixels wide, is {width}")
    if height != GLYPHS * ROWS:
        raise FontError(f"{path}: font image must be {GLYPHS * ROWS} rows high, is {height}")
    out = bytearray()
    for y in range(height):
        byte = 0
        for x in range(8):
            r, g, b = rows[y][x]
            if r > THRESHOLD or g > THRESHOLD or b > THRESHOLD:
                byte |= 0x80 >> x
        out.append(byte)
    return bytes(out)


def reverse_mismatches(glyphs):
    """reverse_mismatches -- glyph numbers n+128 that are not the inverse of glyph n.

    Returns: list of glyph indices (empty when both sets have exact reverse halves).
    """
    bad = []
    for base in (0, 256):
        for n in range(REVERSE_SPAN):
            a = glyphs[(base + n) * ROWS:(base + n + 1) * ROWS]
            b = glyphs[(base + n + REVERSE_SPAN) * ROWS:(base + n + REVERSE_SPAN + 1) * ROWS]
            if any((x ^ 0xFF) != y for x, y in zip(a, b)):
                bad.append(base + n + REVERSE_SPAN)
    return bad


def read_source(path):
    """read_source -- key: value lines of SOURCE.txt (URL, commit, date).

    Returns: dict of the keys found.
    """
    info = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if ":" in line and not line.startswith("#"):
                key, val = line.split(":", 1)
                info[key.strip().lower()] = val.strip()
    for key in ("url", "commit"):
        if key not in info:
            raise FontError(f"{path}: missing '{key}:' line")
    return info


NOTICE = """/*
 * GENERATED FILE -- do not edit. Generator: tools/font2c.py (run with python -I).
 * Source: {url}, commit {commit},
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
 */"""

HEADER = """{notice}
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

#define FONT_OPENROMS_GLYPHS        ({glyphs}u)
#define FONT_OPENROMS_ROWS          ({rows}u)
#define FONT_OPENROMS_SET_GLYPHS    (256u)  /* glyphs per character set */
#define FONT_OPENROMS_REVERSE_EXACT ({reverse_exact}u) /* 1: glyph n+128 == NOT glyph n */

const uint8_t *font_openroms_glyph(uint32_t index);

#endif /* FONT_OPENROMS_H */
"""

SOURCE_C = """{notice}
/*
 * File: font_openroms.c
 * Role: the Open ROMs 8x8 character set as a read-only table, in C64 screen-code order
 *   (layout in font_openroms.h).
 */
#include "font_openroms.h"

static const uint8_t g_glyphs[FONT_OPENROMS_GLYPHS][FONT_OPENROMS_ROWS] = {{
{body}
}};

/*
 * font_openroms_glyph -- the 8 row bytes of one glyph.
 * Steps:
 *   1. Wrap the index into the table (index % FONT_OPENROMS_GLYPHS).
 * Returns: pointer to 8 bytes, top row first, bit 7 = leftmost pixel.
 */
const uint8_t *font_openroms_glyph(uint32_t index)
{{
    return g_glyphs[index % FONT_OPENROMS_GLYPHS];
}}
"""


def render_body(glyphs):
    """render_body -- C initialiser lines, one glyph per line with its screen code.

    Returns: the table body text.
    """
    lines = []
    for n in range(GLYPHS):
        row = glyphs[n * ROWS:(n + 1) * ROWS]
        vals = ", ".join(f"0x{b:02X}u" for b in row)
        lines.append(f"    {{ {vals} }}, /* {n:3d}: set {n // 256}, screen code ${n % 256:02X} */")
    return "\n".join(lines)


def main(argv):
    """main -- parse arguments, convert, check and write the outputs.

    Returns: process exit status.
    """
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--png", required=True, help="upstream assets/8x8font.png")
    ap.add_argument("--source", required=True, help="SOURCE.txt with url: and commit: lines")
    ap.add_argument("--check-rom", help="upstream bin/chargen_openroms.rom to compare against")
    ap.add_argument("--out-dir", required=True, help="directory for font_openroms.c/.h")
    args = ap.parse_args(argv)
    try:
        glyphs = png_to_glyphs(args.png)
        info = read_source(args.source)
    except (OSError, FontError, zlib.error) as exc:
        print(f"font2c: {exc}", file=sys.stderr)
        return 1
    if args.check_rom:
        with open(args.check_rom, "rb") as f:
            rom = f.read()
        if rom != glyphs:
            diff = next(i for i in range(min(len(rom), len(glyphs))) if rom[i] != glyphs[i]) \
                if len(rom) == len(glyphs) else -1
            print(f"font2c: PNG conversion differs from {args.check_rom} (first byte {diff})",
                  file=sys.stderr)
            return 1
        print(f"font2c: conversion matches {args.check_rom} ({len(rom)} bytes)")
    bad = reverse_mismatches(glyphs)
    if bad:
        print(f"font2c: {len(bad)} reverse-half glyphs are not exact inverses: {bad[:16]}")
    notice = NOTICE.format(url=info["url"], commit=info["commit"])
    with open(os.path.join(args.out_dir, "font_openroms.h"), "w", encoding="utf-8", newline="\n") as f:
        f.write(HEADER.format(notice=notice, glyphs=GLYPHS, rows=ROWS,
                              reverse_exact=0 if bad else 1))
    with open(os.path.join(args.out_dir, "font_openroms.c"), "w", encoding="utf-8", newline="\n") as f:
        f.write(SOURCE_C.format(notice=notice, body=render_body(glyphs)))
    print(f"font2c: wrote {GLYPHS} glyphs to {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
