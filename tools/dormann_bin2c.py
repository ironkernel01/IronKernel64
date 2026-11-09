#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# File: dormann_bin2c.py
# Role: embeds the Dormann 6502 test images (third_party/dormann/, GPL-3.0) into a generated C
#   file for the core 0 firmware: static const segment arrays plus the accessors
#   cpu_selftest_image_count() / cpu_selftest_image() declared in
#   fw_c64/src/cpu_selftest.h (no extern data, no linker symbols).
#
# Each image is replayed by cpu_selftest.c as "fill RAM with the fill byte, copy
#   the segments". Segments are the runs of non-fill bytes, merged across fill
#   gaps shorter than MERGE_GAP; the script rebuilds the 64 KiB memory image from
#   the segments and checks it equals the input before writing anything.
#   It also checks that the start address holds code and that the success-trap
#   address holds JMP to itself (4C lo hi).
#
# How to run (from the repo root; the build calls it):
#   python -I tools/dormann_bin2c.py third_party/dormann/6502_functional_test.bin \
#       third_party/dormann/6502_decimal_test.bin <build>/gen/cpu_selftest_images.c

import sys

MEM = 0x10000
MERGE_GAP = 64

# name, load, start, success, fill, budget macro; addresses from third_party/dormann/SOURCE.txt.
IMAGES = [
    ("6502_functional_test", 0x0000, 0x0400, 0x3469, 0xFF, "CPU_SELFTEST_FUNC_MAX_CYCLES"),
    ("6502_decimal_test",    0x0200, 0x0200, 0x024F, 0x00, "CPU_SELFTEST_DEC_MAX_CYCLES"),
]


def memory_image(blob, load, fill):
    if load + len(blob) > MEM:
        raise SystemExit("image runs past $FFFF")
    mem = bytearray([fill]) * MEM
    mem[load:load + len(blob)] = blob
    return mem


def segments(mem, fill):
    runs = []
    start = None
    for i, b in enumerate(mem):
        if b != fill and start is None:
            start = i
        elif b == fill and start is not None:
            runs.append([start, i])
            start = None
    if start is not None:
        runs.append([start, MEM])
    merged = []
    for r in runs:
        if merged and r[0] - merged[-1][1] < MERGE_GAP:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return merged


def main(argv):
    if len(argv) != 4:
        raise SystemExit("usage: python -I tools/dormann_bin2c.py <functional.bin> <decimal.bin> <out.c>")
    out = []
    out.append("/*")
    out.append(" * SPDX-License-Identifier: GPL-3.0-or-later")
    out.append(" * Copyright (C) 2026 IronKernel")
    out.append(" *")
    out.append(" * File: cpu_selftest_images.c")
    out.append(" * Role: embedded 6502 test images for cpu_selftest.c.")
    out.append(" *")
    out.append(" * GENERATED FILE -- DO NOT EDIT. Generator: tools/dormann_bin2c.py.")
    out.append(" * Data: Klaus Dormann's 6502_functional_test.bin and Bruce Clark's decimal test")
    out.append(" *   (6502_decimal_test.a65, Dormann's configuration, built by")
    out.append(" *   tools/dormann_decimal.py), github.com/Klaus2m5/6502_65C02_functional_tests,")
    out.append(" *   GPL-3.0; provenance in third_party/dormann/SOURCE.txt.")
    out.append(" */")
    out.append('#include "cpu_selftest.h"')
    out.append("")
    out.append("#include <stddef.h> /* NULL */")
    out.append("")
    descs = []
    total = 0
    for (name, load, start, success, fill, budget), path in zip(IMAGES, argv[1:3]):
        with open(path, "rb") as f:
            blob = f.read()
        mem = memory_image(blob, load, fill)
        if mem[success:success + 3] != bytes([0x4C, success & 0xFF, success >> 8]):
            raise SystemExit("%s: no JMP-to-self at success $%04X" % (name, success))
        if mem[start] == fill:
            raise SystemExit("%s: start $%04X holds the fill byte" % (name, start))
        segs = segments(mem, fill)
        check = bytearray([fill]) * MEM
        for a, b in segs:
            check[a:b] = mem[a:b]
        if check != mem:
            raise SystemExit("%s: segment rebuild mismatch" % name)
        ident = name.replace("6502_", "").replace("_test", "")
        seg_lines = []
        for k, (a, b) in enumerate(segs):
            arr = "g_%s_seg%d" % (ident, k)
            out.append("/* %s $%04X-$%04X (%d bytes) */" % (name, a, b - 1, b - a))
            out.append("static const uint8_t %s[%d] = {" % (arr, b - a))
            data = mem[a:b]
            for i in range(0, len(data), 12):
                out.append("    " + ", ".join("0x%02Xu" % v for v in data[i:i + 12]) + ",")
            out.append("};")
            out.append("")
            seg_lines.append("    { %s, %du, 0x%04Xu }," % (arr, b - a, a))
            total += b - a
        out.append("static const cpu_selftest_seg_t g_%s_segs[%d] = {" % (ident, len(segs)))
        out.extend(seg_lines)
        out.append("};")
        out.append("")
        descs.append("    { \"%s\", g_%s_segs, %du, 0x%02Xu, 0x%04Xu, 0x%04Xu, %s },"
                     % (name, ident, len(segs), fill, start, success, budget))
        print("%s: %s" % (name, ", ".join("$%04X-$%04X" % (a, b - 1) for a, b in segs)))
    out.append("static const cpu_selftest_image_t g_images[] = {")
    out.extend(descs)
    out.append("};")
    out.append("")
    out.append("#define CPU_SELFTEST_IMAGES (sizeof(g_images) / sizeof(g_images[0]))")
    out.append("")
    out.append("/*")
    out.append(" * cpu_selftest_image_count -- number of embedded images.")
    out.append(" * Returns: the count.")
    out.append(" */")
    out.append("uint32_t cpu_selftest_image_count(void)")
    out.append("{")
    out.append("    return (uint32_t)CPU_SELFTEST_IMAGES;")
    out.append("}")
    out.append("")
    out.append("/*")
    out.append(" * cpu_selftest_image -- one embedded image descriptor.")
    out.append(" * Returns: the descriptor, or NULL for an index past the count.")
    out.append(" */")
    out.append("const cpu_selftest_image_t *cpu_selftest_image(uint32_t index)")
    out.append("{")
    out.append("    return (index < CPU_SELFTEST_IMAGES) ? &g_images[index] : NULL;")
    out.append("}")
    with open(argv[3], "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("embedded %d bytes" % total)


if __name__ == "__main__":
    main(sys.argv)
