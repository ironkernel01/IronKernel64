#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# File: dormann_decimal.py
# Role: builds third_party/dormann/6502_decimal_test.bin from the unmodified upstream source
#   third_party/dormann/6502_decimal_test.a65 (Bruce Clark's decimal-mode test as configured
#   by Klaus Dormann, github.com/Klaus2m5/6502_65C02_functional_tests, GPL-3.0).
#
# Upstream ships no binary of the decimal test and assembles it with as65, a
# DOS/Windows executable. This script is a minimal two-pass assembler for the
# as65 subset that file uses (equates, bss/code segments, org, ds, db, if/endif,
# one parameterless macro, zero-page/absolute/indexed/immediate/relative
# operands, `*` and +/- expressions), so no downloaded executable runs.
#
# Configuration applied (each substitution must match exactly once):
#   cputype = 0 (NMOS 6502), vld_bcd = 0 (all 256 x 256 operands, invalid BCD
#   included), chk_a = chk_n = chk_v = chk_z = chk_c = 1 (accumulator and all of
#   N, V, Z, C are checked against the NMOS prediction).
#   end_of_test (upstream: db $db, a 65C02 STP that is DCP abs,Y on NMOS) becomes
#       lda ERROR / bne *+5 / jmp * (success trap) / jmp * (failure trap)
#   as the source's header invites ("modify the code at the DONE label").
#
# How to run (from the repo root):
#   python -I tools/dormann_decimal.py third_party/dormann/6502_decimal_test.a65 third_party/dormann/6502_decimal_test.bin
# It prints the load, start, success-trap and failure-trap addresses and writes a
# listing next to the binary (.lst).

import re
import sys

CONFIG = [
    (r"^cputype\s*=\s*\d+", "cputype = 0"),
    (r"^vld_bcd\s*=\s*\d+", "vld_bcd = 0"),
    (r"^chk_a\s*=\s*\d+", "chk_a   = 1"),
    (r"^chk_n\s*=\s*\d+", "chk_n   = 1"),
    (r"^chk_v\s*=\s*\d+", "chk_v   = 1"),
    (r"^chk_z\s*=\s*\d+", "chk_z   = 1"),
    (r"^chk_c\s*=\s*\d+", "chk_c   = 1"),
]
END_OF_TEST_BODY = [
    "        lda ERROR",
    "        bne *+5",
    "        jmp *",
    "        jmp *",
]

# mnemonic -> {mode: opcode}; documented NMOS opcodes for the modes this file uses.
OPS = {
    "adc": {"imm": 0x69, "zp": 0x65, "zpx": 0x75, "abs": 0x6D, "abx": 0x7D, "aby": 0x79},
    "and": {"imm": 0x29, "zp": 0x25, "zpx": 0x35, "abs": 0x2D, "abx": 0x3D, "aby": 0x39},
    "cmp": {"imm": 0xC9, "zp": 0xC5, "zpx": 0xD5, "abs": 0xCD, "abx": 0xDD, "aby": 0xD9},
    "eor": {"imm": 0x49, "zp": 0x45, "zpx": 0x55, "abs": 0x4D, "abx": 0x5D, "aby": 0x59},
    "lda": {"imm": 0xA9, "zp": 0xA5, "zpx": 0xB5, "abs": 0xAD, "abx": 0xBD, "aby": 0xB9},
    "ora": {"imm": 0x09, "zp": 0x05, "zpx": 0x15, "abs": 0x0D, "abx": 0x1D, "aby": 0x19},
    "sbc": {"imm": 0xE9, "zp": 0xE5, "zpx": 0xF5, "abs": 0xED, "abx": 0xFD, "aby": 0xF9},
    "sta": {"zp": 0x85, "zpx": 0x95, "abs": 0x8D, "abx": 0x9D, "aby": 0x99},
    "ldx": {"imm": 0xA2, "zp": 0xA6, "zpy": 0xB6, "abs": 0xAE, "aby": 0xBE},
    "ldy": {"imm": 0xA0, "zp": 0xA4, "zpx": 0xB4, "abs": 0xAC, "abx": 0xBC},
    "stx": {"zp": 0x86, "zpy": 0x96, "abs": 0x8E},
    "sty": {"zp": 0x84, "zpx": 0x94, "abs": 0x8C},
    "cpx": {"imm": 0xE0, "zp": 0xE4, "abs": 0xEC},
    "cpy": {"imm": 0xC0, "zp": 0xC4, "abs": 0xCC},
    "inc": {"zp": 0xE6, "zpx": 0xF6, "abs": 0xEE, "abx": 0xFE},
    "dec": {"zp": 0xC6, "zpx": 0xD6, "abs": 0xCE, "abx": 0xDE},
    "jmp": {"abs": 0x4C},
    "jsr": {"abs": 0x20},
    "bpl": {"rel": 0x10}, "bmi": {"rel": 0x30}, "bvc": {"rel": 0x50}, "bvs": {"rel": 0x70},
    "bcc": {"rel": 0x90}, "bcs": {"rel": 0xB0}, "bne": {"rel": 0xD0}, "beq": {"rel": 0xF0},
    "brk": {"imp": 0x00}, "php": {"imp": 0x08}, "clc": {"imp": 0x18}, "plp": {"imp": 0x28},
    "sec": {"imp": 0x38}, "rti": {"imp": 0x40}, "pha": {"imp": 0x48}, "cli": {"imp": 0x58},
    "rts": {"imp": 0x60}, "pla": {"imp": 0x68}, "sei": {"imp": 0x78}, "dey": {"imp": 0x88},
    "txa": {"imp": 0x8A}, "tya": {"imp": 0x98}, "txs": {"imp": 0x9A}, "tay": {"imp": 0xA8},
    "tax": {"imp": 0xAA}, "clv": {"imp": 0xB8}, "tsx": {"imp": 0xBA}, "iny": {"imp": 0xC8},
    "dex": {"imp": 0xCA}, "cld": {"imp": 0xD8}, "inx": {"imp": 0xE8}, "nop": {"imp": 0xEA},
    "sed": {"imp": 0xF8},
}
SIZES = {"imp": 1, "imm": 2, "zp": 2, "zpx": 2, "zpy": 2, "rel": 2, "abs": 3, "abx": 3, "aby": 3}


class AsmError(Exception):
    pass


def configure(lines):
    out = list(lines)
    for pattern, repl in CONFIG:
        hits = [i for i, l in enumerate(out) if re.match(pattern, l)]
        if len(hits) != 1:
            raise AsmError("config %s matched %d lines" % (pattern, len(hits)))
        comment = out[hits[0]].split(";", 1)
        out[hits[0]] = repl + ("  ;" + comment[1] if len(comment) > 1 else "")
    start = [i for i, l in enumerate(out) if re.match(r"^end_of_test\s+macro", l)]
    if len(start) != 1:
        raise AsmError("end_of_test macro matched %d lines" % len(start))
    end = start[0] + 1
    while not re.match(r"^\s*endm\b", out[end]):
        end += 1
    return out[:start[0] + 1] + END_OF_TEST_BODY + out[end:]


def strip_comment(line):
    return line.split(";", 1)[0].rstrip()


class Assembler:
    def __init__(self, lines):
        self.lines = lines
        self.symbols = {}
        self.macros = {}

    def value(self, expr, pc, final):
        expr = expr.strip()
        total = 0
        sign = 1
        pos = 0
        tokens = re.findall(r"\$[0-9A-Fa-f]+|%[01]+|\d+|[A-Za-z_][A-Za-z0-9_]*|\*|[+-]", expr)
        if "".join(tokens) != expr.replace(" ", ""):
            raise AsmError("unsupported expression '%s'" % expr)
        expect_term = True
        for t in tokens:
            if t in "+-" and not expect_term:
                sign = 1 if t == "+" else -1
                expect_term = True
                continue
            if not expect_term:
                raise AsmError("bad expression '%s'" % expr)
            if t.startswith("$"):
                v = int(t[1:], 16)
            elif t.startswith("%"):
                v = int(t[1:], 2)
            elif t.isdigit():
                v = int(t)
            elif t == "*":
                v = pc
            elif t in self.symbols:
                v = self.symbols[t]
            elif final:
                raise AsmError("undefined symbol '%s'" % t)
            else:
                v = 0
            total += sign * v
            sign = 1
            expect_term = False
            pos += 1
        if expect_term:
            raise AsmError("bad expression '%s'" % expr)
        return total

    def known(self, expr):
        names = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", expr)
        return all(n in self.symbols for n in names)

    def condition(self, text, pc):
        m = re.match(r"(.+?)(!=|=)(.+)", text)
        if m is None:
            return self.value(text, pc, True) != 0
        a = self.value(m.group(1), pc, True)
        b = self.value(m.group(3), pc, True)
        return (a == b) if m.group(2) == "=" else (a != b)

    def expand(self):
        out = []
        i = 0
        while i < len(self.lines):
            line = self.lines[i]
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s+macro\b", line)
            if m:
                body = []
                i += 1
                while not re.match(r"^\s*endm\b", self.lines[i]):
                    body.append(self.lines[i])
                    i += 1
                self.macros[m.group(1)] = body
                i += 1
                continue
            out.append(line)
            i += 1
        return out

    def run_pass(self, lines, final):
        seg = "code"
        pcs = {"code": 0, "bss": 0}
        image = {}
        listing = []
        cond = []
        work = list(lines)
        i = 0
        while i < len(work):
            raw = work[i]
            i += 1
            text = strip_comment(raw)
            if not text.strip():
                listing.append("                  %s" % raw)
                continue
            active = all(cond)
            stripped = text.strip()
            word = stripped.split()[0].lower()
            if word == "if":
                cond.append(active and self.condition(stripped[2:], pcs[seg]))
                listing.append("                  %s" % raw)
                continue
            if word == "endif":
                if not cond:
                    raise AsmError("endif without if")
                cond.pop()
                listing.append("                  %s" % raw)
                continue
            if not active:
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", stripped)
            if m and not text[0].isspace():
                self.symbols[m.group(1)] = self.value(m.group(2), pcs[seg], final)
                listing.append("%04X =            %s" % (self.symbols[m.group(1)], raw))
                continue
            label = None
            rest = stripped
            if not text[0].isspace():
                parts = stripped.split(None, 1)
                label = parts[0]
                rest = parts[1] if len(parts) > 1 else ""
            pc = pcs[seg]
            if label is not None:
                if final and self.symbols.get(label) != pc:
                    raise AsmError("label %s moved between passes" % label)
                self.symbols[label] = pc
            if not rest:
                listing.append("%04X :            %s" % (pc, raw))
                continue
            parts = rest.split(None, 1)
            op = parts[0].lower()
            arg = parts[1].strip() if len(parts) > 1 else ""
            if op in ("bss", "code"):
                seg = op
                listing.append("                  %s" % raw)
                continue
            if op == "org":
                pcs[seg] = self.value(arg, pc, True)
                listing.append("%04X :            %s" % (pcs[seg], raw))
                continue
            if op == "ds":
                pcs[seg] = pc + self.value(arg, pc, True)
                listing.append("%04X :            %s" % (pc, raw))
                continue
            if op == "end":
                listing.append("                  %s" % raw)
                break
            if op in self.macros:
                work[i:i] = self.macros[op]
                listing.append("%04X :            %s" % (pc, raw))
                continue
            if op == "db":
                vals = [self.value(v, pc, final) & 0xFF for v in arg.split(",")]
                code = vals
            elif op in OPS:
                code = self.encode(op, arg, pc, final)
            else:
                raise AsmError("unsupported directive or mnemonic '%s'" % op)
            if seg != "code":
                raise AsmError("code emitted in bss: %s" % raw)
            for k, b in enumerate(code):
                if (pc + k) in image:
                    raise AsmError("overlapping code at $%04X" % (pc + k))
                image[pc + k] = b
            listing.append("%04X : %-10s %s" % (pc, " ".join("%02X" % b for b in code), raw))
            pcs[seg] = pc + len(code)
        if cond:
            raise AsmError("unterminated if")
        return image, listing

    def encode(self, op, arg, pc, final):
        modes = OPS[op]
        if not arg:
            mode, val = "imp", 0
        elif arg.startswith("#"):
            mode, val = "imm", self.value(arg[1:], pc, final)
        elif "rel" in modes:
            mode, val = "rel", self.value(arg, pc, final)
        else:
            idx = None
            m = re.match(r"^(.*),\s*([xXyY])$", arg)
            expr = arg
            if m:
                expr, idx = m.group(1), m.group(2).lower()
            val = self.value(expr, pc, final)
            zp = self.known(expr) and 0 <= val < 0x100
            if idx is None:
                mode = "zp" if zp and "zp" in modes else "abs"
            elif idx == "x":
                mode = "zpx" if zp and "zpx" in modes else "abx"
            else:
                mode = "zpy" if zp and "zpy" in modes else "aby"
        if mode not in modes:
            raise AsmError("%s: addressing mode %s not supported" % (op, mode))
        opc = modes[mode]
        size = SIZES[mode]
        if mode == "imp":
            return [opc]
        if mode == "rel":
            off = val - (pc + 2)
            if final and not -128 <= off <= 127:
                raise AsmError("%s: branch out of range" % op)
            return [opc, off & 0xFF]
        if size == 2:
            if final and not 0 <= val < 0x100:
                raise AsmError("%s: operand $%X does not fit a byte" % (op, val))
            return [opc, val & 0xFF]
        return [opc, val & 0xFF, (val >> 8) & 0xFF]


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: python -I tools/dormann_decimal.py <6502_decimal_test.a65> <out.bin>")
    with open(argv[1], "r", encoding="latin-1") as f:
        src = f.read().splitlines()
    asm = Assembler(configure(src))
    lines = asm.expand()
    asm.run_pass(lines, False)
    image, listing = asm.run_pass(lines, True)
    lo = min(image)
    hi = max(image)
    blob = bytes(image.get(a, 0) for a in range(lo, hi + 1))
    with open(argv[2], "wb") as f:
        f.write(blob)
    done = asm.symbols["DONE"]
    success = done + 4
    failure = done + 7
    # The trap layout above must match the END_OF_TEST_BODY encodings.
    expect = [0xA5, asm.symbols["ERROR"], 0xD0, 0x03, 0x4C, success & 0xFF, success >> 8,
              0x4C, failure & 0xFF, failure >> 8]
    got = [image.get(done + k) for k in range(len(expect))]
    if got != expect:
        raise SystemExit("trap layout mismatch at DONE: %s" % got)
    lst = argv[2].rsplit(".", 1)[0] + ".lst"
    with open(lst, "w", encoding="ascii", newline="\n") as f:
        f.write("; generated by tools/dormann_decimal.py from 6502_decimal_test.a65\n")
        f.write("\n".join(listing) + "\n")
        f.write("\n; symbols\n")
        for name in sorted(asm.symbols, key=lambda n: (asm.symbols[n], n)):
            f.write("; %-8s = $%04X\n" % (name, asm.symbols[name]))
    print("load $%04X  length %d  start $%04X  success $%04X  failure $%04X  ERROR $%04X"
          % (lo, len(blob), asm.symbols["TEST"], success, failure, asm.symbols["ERROR"]))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except AsmError as e:
        raise SystemExit("error: %s" % e)
