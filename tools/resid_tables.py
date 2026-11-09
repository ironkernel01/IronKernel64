#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# File: resid_tables.py
# Role: generates fw_c64/src/sid_tables.c from the unmodified reSID files in
#   third_party/resid/ (reSID by Dag Lem, GPL-2.0-or-later, commit recorded in
#   third_party/resid/SOURCE.txt).
#
# What it produces:
#   * The eight combined-waveform tables (wave6581__ST, _P_T, _PS_, _PST and the
#     8580 set) from the wave*.dat files, trimmed to their non-zero span and,
#     where the two 2048-entry halves are identical (or only the first half is
#     indexed, as for _P_T), stored as one half with a 0x7FF index mask.
#   * The 6581 and 8580 FC -> cutoff (Hz) tables: the f0_points_6581 /
#     f0_points_8580 spline points are parsed from filter.cc and interpolated
#     exactly as reSID's spline.h does (forward differencing, res = 1.0,
#     PointPlotter<int> truncation and clamping of negative values).
#   * The resonance table 1024 / (0.707 + res / 15) from reSID's
#     Filter::set_Q(), truncated to int as reSID does.
#
# How to run (from the repo root):
#   python -I tools/resid_tables.py third_party/resid fw_c64/src/sid_tables.c
#
# The output file is generated: do not hand-edit it; change this script and
# re-run it.

import os
import re
import sys

WAVE_NAMES = [
    ("6581", "__ST"), ("6581", "_P_T"), ("6581", "_PS_"), ("6581", "_PST"),
    ("8580", "__ST"), ("8580", "_P_T"), ("8580", "_PS_"), ("8580", "_PST"),
]
WAVE_LEN = 4096
HALF_LEN = 2048
FC_LEN = 2048
RES_LEN = 16
UPSTREAM_COMMIT = "f872782804c751eb94d409a1250cbfeb03940cd0"


def read_wave(resid_dir, model, combo):
    path = os.path.join(resid_dir, "wave%s%s.dat" % (model, combo))
    with open(path, "rb") as f:
        data = f.read()
    if len(data) != WAVE_LEN:
        raise SystemExit("%s: %d bytes, expected %d" % (path, len(data), WAVE_LEN))
    return data


def compact_wave(data, combo):
    # _P_T is indexed by triangle >> 1 (11 bits): only the first half is used.
    if combo == "_P_T" or data[:HALF_LEN] == data[HALF_LEN:]:
        used = data[:HALF_LEN]
        mask = 0x7FF
    else:
        used = data
        mask = 0xFFF
    nz = [i for i, v in enumerate(used) if v != 0]
    if not nz:
        return used[0:0], 0, mask
    first = nz[0]
    last = nz[-1]
    return used[first:last + 1], first, mask


def parse_points(filter_cc, name):
    m = re.search(r"fc_point\s+Filter::%s\[\]\s*=\s*\{(.*?)\};" % name, filter_cc, re.S)
    if m is None:
        raise SystemExit("filter.cc: %s not found" % name)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    pts = [(int(a), int(b)) for a, b in re.findall(r"\{\s*(-?\d+)\s*,\s*(-?\d+)\s*\}", body)]
    if len(pts) < 4:
        raise SystemExit("filter.cc: %s has %d points" % (name, len(pts)))
    return pts


def to_int(v):
    # C++ conversion from double to int: truncation toward zero.
    return int(v)


def plot(table, x, y):
    if y < 0:
        y = 0.0
    table[to_int(x)] = to_int(y)


def cubic_coefficients(x1, y1, x2, y2, k1, k2):
    dx = x2 - x1
    dy = y2 - y1
    a = ((k1 + k2) - 2 * dy / dx) / (dx * dx)
    b = ((k2 - k1) / dx - 3 * (x1 + x2) * a) / 2
    c = k1 - (3 * x1 * a + 2 * b) * x1
    d = y1 - ((x1 * a + b) * x1 + c) * x1
    return a, b, c, d


def interpolate_forward_difference(x1, y1, x2, y2, k1, k2, table, res):
    a, b, c, d = cubic_coefficients(x1, y1, x2, y2, k1, k2)
    y = ((a * x1 + b) * x1 + c) * x1 + d
    dy = (3 * a * (x1 + res) + 2 * b) * x1 * res + ((a * res + b) * res + c) * res
    d2y = (6 * a * (x1 + res) + 2 * b) * res * res
    d3y = 6 * a * res * res * res
    x = x1
    while x <= x2:
        plot(table, x, y)
        y += dy
        dy += d2y
        d2y += d3y
        x += res


def interpolate(points, table, res):
    # Port of reSID spline.h interpolate(p0, pn, plot, res) with pn = last point.
    n = len(points)
    for i in range(0, n - 3):
        p0, p1, p2, p3 = points[i], points[i + 1], points[i + 2], points[i + 3]
        x0, y0 = float(p0[0]), float(p0[1])
        x1, y1 = float(p1[0]), float(p1[1])
        x2, y2 = float(p2[0]), float(p2[1])
        x3, y3 = float(p3[0]), float(p3[1])
        if x1 == x2:
            continue
        if x0 == x1 and x2 == x3:
            k1 = k2 = (y2 - y1) / (x2 - x1)
        elif x0 == x1:
            k2 = (y3 - y1) / (x3 - x1)
            k1 = (3 * (y2 - y1) / (x2 - x1) - k2) / 2
        elif x2 == x3:
            k1 = (y2 - y0) / (x2 - x0)
            k2 = (3 * (y2 - y1) / (x2 - x1) - k1) / 2
        else:
            k1 = (y2 - y0) / (x2 - x0)
            k2 = (y3 - y1) / (x3 - x1)
        interpolate_forward_difference(x1, y1, x2, y2, k1, k2, table, res)


def cutoff_table(points):
    table = [None] * FC_LEN
    interpolate(points, table, 1.0)
    missing = [i for i, v in enumerate(table) if v is None]
    if missing:
        raise SystemExit("cutoff table: %d FC values not plotted (first %d)"
                         % (len(missing), missing[0]))
    for v in table:
        if v < 0 or v > 0xFFFF:
            raise SystemExit("cutoff table: value %d does not fit uint16_t" % v)
    return table


def res_table():
    return [to_int(1024.0 / (0.707 + 1.0 * r / 0x0F)) for r in range(RES_LEN)]


def emit_array(out, ctype, name, values, per_line, fmt):
    out.append("static const %s %s[%d] = {" % (ctype, name, len(values)))
    for i in range(0, len(values), per_line):
        chunk = ", ".join(fmt % v for v in values[i:i + per_line])
        out.append("    " + chunk + ",")
    out.append("};")
    out.append("")


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: python -I tools/resid_tables.py <third_party/resid> <out.c>")
    resid_dir, out_path = argv[1], argv[2]
    with open(os.path.join(resid_dir, "filter.cc"), "r", encoding="latin-1") as f:
        filter_cc = f.read()

    waves = []
    for model, combo in WAVE_NAMES:
        data, first, mask = compact_wave(read_wave(resid_dir, model, combo), combo)
        waves.append((model, combo, data, first, mask))

    fc6581 = cutoff_table(parse_points(filter_cc, "f0_points_6581"))
    fc8580 = cutoff_table(parse_points(filter_cc, "f0_points_8580"))
    resq = res_table()

    wave_bytes = sum(len(w[2]) for w in waves)
    out = []
    out.append("/*")
    out.append(" * SPDX-License-Identifier: GPL-3.0-or-later")
    out.append(" * Copyright (C) 2026 IronKernel")
    out.append(" *")
    out.append(" * File: sid_tables.c")
    out.append(" * Role: constant tables of the SID synthesizer (sid.c): reSID combined")
    out.append(" *   waveforms, 6581/8580 FC -> cutoff curves and the resonance -> 1/Q map.")
    out.append(" *")
    out.append(" * GENERATED FILE -- DO NOT EDIT. Generator: tools/resid_tables.py, run as")
    out.append(" *   python -I tools/resid_tables.py third_party/resid fw_c64/src/sid_tables.c")
    out.append(" *")
    out.append(" * Derived from reSID by Dag Lem <resid@nimrod.no>, GPL-2.0-or-later,")
    out.append(" *   https://github.com/libsidplayfp/resid commit %s" % UPSTREAM_COMMIT)
    out.append(" *   (the reSID 0.16 code base). Source files, kept unmodified in")
    out.append(" *   third_party/resid/ with COPYING and SOURCE.txt:")
    out.append(" *   - wave6581__ST.dat wave6581_P_T.dat wave6581_PS_.dat wave6581_PST.dat")
    out.append(" *     wave8580__ST.dat wave8580_P_T.dat wave8580_PS_.dat wave8580_PST.dat")
    out.append(" *     (8-bit OSC3 samples of the combined waveforms);")
    out.append(" *   - filter.cc (f0_points_6581, f0_points_8580, Filter::set_Q) and")
    out.append(" *     spline.h (the interpolation the generator reproduces).")
    out.append(" *   GPL-2.0-or-later is compatible with this project's GPL-3.0-or-later.")
    out.append(" *")
    out.append(" * Wave table layout: entry k of a table is the reSID sample at index")
    out.append(" *   first + k; indices below first or past first + count read 0. A mask of")
    out.append(" *   0x7FF means the table holds one 2048-entry half (both halves equal, or")
    out.append(" *   only the first half indexed, as for _P_T). Total wave bytes: %d." % wave_bytes)
    out.append(" * Cutoff tables: Hz per 11-bit FC value, 2048 x uint16_t per model.")
    out.append(" * Resonance table: 1024 / Q per 4-bit RES value (Q10).")
    out.append(" * Accessors are declared in sid.h (no extern data).")
    out.append(" */")
    out.append('#include "sid.h"')
    out.append("")
    out.append("#include <stddef.h> /* NULL */")
    out.append("")
    for model, combo, data, first, mask in waves:
        name = "g_wave%s%s" % (model, combo)
        if len(data) == 0:
            out.append("static const uint8_t %s[1] = { 0u };" % name)
            out.append("")
        else:
            emit_array(out, "uint8_t", name, list(data), 12, "0x%02Xu")
    out.append("static const sid_wave_tab_t g_wave_tabs[SID_TAB_MODELS][SID_TAB_COMBOS] = {")
    for mi, model in enumerate(("6581", "8580")):
        out.append("    {")
        for model2, combo, data, first, mask in waves:
            if model2 != model:
                continue
            out.append("        { g_wave%s%s, %du, %du, 0x%03Xu },"
                       % (model, combo, first, len(data), mask))
        out.append("    },")
    out.append("};")
    out.append("")
    emit_array(out, "uint16_t", "g_cutoff_6581", fc6581, 12, "%5du")
    emit_array(out, "uint16_t", "g_cutoff_8580", fc8580, 12, "%5du")
    emit_array(out, "uint16_t", "g_res_q10", resq, 8, "%4du")
    out.append("/*")
    out.append(" * sid_tables_wave -- one combined-waveform table.")
    out.append(" * Steps:")
    out.append(" *   1. Select the model row and the combination column (SID_TAB_ST, _PT, _PS, _PST).")
    out.append(" * Returns: the table descriptor, or NULL for an out-of-range model or combination.")
    out.append(" */")
    out.append("const sid_wave_tab_t *sid_tables_wave(sid_model_t model, uint32_t combo)")
    out.append("{")
    out.append("    if ((uint32_t)model >= SID_TAB_MODELS || combo >= SID_TAB_COMBOS) {")
    out.append("        return NULL;")
    out.append("    }")
    out.append("    return &g_wave_tabs[(uint32_t)model][combo];")
    out.append("}")
    out.append("")
    out.append("/*")
    out.append(" * sid_tables_cutoff_hz -- the FC -> cutoff curve of one model.")
    out.append(" * Returns: a pointer to SID_TAB_FC_ENTRIES cutoff values in Hz.")
    out.append(" */")
    out.append("const uint16_t *sid_tables_cutoff_hz(sid_model_t model)")
    out.append("{")
    out.append("    return (model == SID_MODEL_8580) ? g_cutoff_8580 : g_cutoff_6581;")
    out.append("}")
    out.append("")
    out.append("/*")
    out.append(" * sid_tables_res_q10 -- 1024 / Q for one RES value.")
    out.append(" * Returns: the Q10 reciprocal of Q (RES is masked to 4 bits).")
    out.append(" */")
    out.append("uint32_t sid_tables_res_q10(uint32_t res)")
    out.append("{")
    out.append("    return g_res_q10[res & (SID_TAB_RES_ENTRIES - 1u)];")
    out.append("}")
    with open(out_path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    for model, combo, data, first, mask in waves:
        print("wave%s%s first=%d count=%d mask=0x%03X" % (model, combo, first, len(data), mask))
    print("wave bytes %d; cutoff 6581 [0]=%d [1023]=%d [1024]=%d [2047]=%d; 8580 [0]=%d [2047]=%d"
          % (wave_bytes, fc6581[0], fc6581[1023], fc6581[1024], fc6581[2047], fc8580[0], fc8580[2047]))
    print("res_q10", resq)


if __name__ == "__main__":
    main(sys.argv)
