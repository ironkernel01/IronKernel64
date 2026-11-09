#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
"""
regs_check.py -- verify that fw_c64/src/c64_regs.h mirrors fpga/hdl/c64_pkg.sv.

Every `localparam ... NAME = value;` in the package must appear in the header as
`#define C64_NAME (value)` with the same numeric value, and the header must not
define a C64_ name the package does not have. Both sides are evaluated
numerically (SystemVerilog sized literals and arithmetic over earlier names are
supported), so `16'h0400` and `0x0400u` compare equal.

Usage: python -I tools/regs_check.py [repo_root]
Prints `REGS_CHECK: PASS (<n> constants)` and exits 0, or lists every mismatch
with `REGS_CHECK: FAIL` and exits 1.
"""
import re
import sys
from pathlib import Path

SV_LIT = re.compile(r"(\d+)?'([hHdDbBoO])([0-9a-fA-F_xXzZ]+)")


def sv_expr_to_py(expr):
    """Convert one SystemVerilog constant expression to a Python expression."""
    def lit(m):
        base = {"h": 16, "d": 10, "b": 2, "o": 8}[m.group(2).lower()]
        return str(int(m.group(3).replace("_", ""), base))
    expr = SV_LIT.sub(lit, expr)
    expr = re.sub(r"(?<=\d)_(?=\d)", "", expr)
    return expr.replace("/", "//")


def parse_pkg(path):
    text = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
    vals = {}
    for m in re.finditer(r"localparam\s+(?:[\w\s\[\]:]+?\s+)?(\w+)\s*=\s*([^;]+);", text):
        name, expr = m.group(1), m.group(2).strip()
        vals[name] = eval(sv_expr_to_py(expr), {"__builtins__": {}}, dict(vals))  # noqa: S307
    return vals


def parse_hdr(path):
    text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    vals = {}
    for m in re.finditer(r"#define\s+C64_(\w+)\s+\(?\s*(0x[0-9a-fA-F]+|\d+)u?\s*\)?", text):
        vals[m.group(1)] = int(m.group(2), 0)
    return vals


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    pkg = parse_pkg(root / "fpga/hdl/c64_pkg.sv")
    hdr = parse_hdr(root / "fw_c64/src/c64_regs.h")
    errors = []
    for name, value in pkg.items():
        if name not in hdr:
            errors.append(f"missing in c64_regs.h: C64_{name} (= {value})")
        elif hdr[name] != value:
            errors.append(f"value differs: {name} package={value} header={hdr[name]}")
    for name in hdr:
        if name not in pkg:
            errors.append(f"extra in c64_regs.h (not in c64_pkg.sv): C64_{name}")
    if errors:
        for e in errors:
            print("  " + e)
        print("REGS_CHECK: FAIL")
        return 1
    print(f"REGS_CHECK: PASS ({len(pkg)} constants)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
