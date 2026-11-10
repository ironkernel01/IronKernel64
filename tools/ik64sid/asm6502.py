# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
"""
File: asm6502.py
Role: a small two-pass 6502 assembler (documented NMOS opcodes only) for the ik64 SID player
  (tools/ik64sid/player.asm). Used by tools/mksid.py.
Syntax:
  * one statement per line, ';' starts a comment, labels end with ':'.
  * directives: .org ADDR, .byte e,e,..., .word e,e,..., NAME = expr (constant).
  * expressions: numbers ($hex, %binary, decimal), symbols, '<' (low byte) and '>' (high byte)
    prefixes, '+' and '-', and '*' for the current address.
  * operands: none / A, #imm, zp or abs, zp or abs with ,X or ,Y, (zp,X), (zp),Y, (abs) for JMP,
    and a target label for the branches.
  * zero page is chosen when the value is known and below 256 in pass 1 and the mnemonic has a zero
    page form; a symbol defined later always takes the absolute form (size stable across passes;
    the assembler checks that pass 2 lays out exactly like pass 1).
API: assemble(text, predefined=None) -> (bytes, origin, symbols)
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import re

# mnemonic -> {mode: opcode}; modes: imp acc imm zp zpx zpy abs abx aby inx iny ind rel
OPS = {
    "ADC": dict(imm=0x69, zp=0x65, zpx=0x75, abs=0x6D, abx=0x7D, aby=0x79, inx=0x61, iny=0x71),
    "AND": dict(imm=0x29, zp=0x25, zpx=0x35, abs=0x2D, abx=0x3D, aby=0x39, inx=0x21, iny=0x31),
    "ASL": dict(acc=0x0A, zp=0x06, zpx=0x16, abs=0x0E, abx=0x1E),
    "BCC": dict(rel=0x90), "BCS": dict(rel=0xB0), "BEQ": dict(rel=0xF0),
    "BIT": dict(zp=0x24, abs=0x2C),
    "BMI": dict(rel=0x30), "BNE": dict(rel=0xD0), "BPL": dict(rel=0x10),
    "BRK": dict(imp=0x00), "BVC": dict(rel=0x50), "BVS": dict(rel=0x70),
    "CLC": dict(imp=0x18), "CLD": dict(imp=0xD8), "CLI": dict(imp=0x58), "CLV": dict(imp=0xB8),
    "CMP": dict(imm=0xC9, zp=0xC5, zpx=0xD5, abs=0xCD, abx=0xDD, aby=0xD9, inx=0xC1, iny=0xD1),
    "CPX": dict(imm=0xE0, zp=0xE4, abs=0xEC),
    "CPY": dict(imm=0xC0, zp=0xC4, abs=0xCC),
    "DEC": dict(zp=0xC6, zpx=0xD6, abs=0xCE, abx=0xDE),
    "DEX": dict(imp=0xCA), "DEY": dict(imp=0x88),
    "EOR": dict(imm=0x49, zp=0x45, zpx=0x55, abs=0x4D, abx=0x5D, aby=0x59, inx=0x41, iny=0x51),
    "INC": dict(zp=0xE6, zpx=0xF6, abs=0xEE, abx=0xFE),
    "INX": dict(imp=0xE8), "INY": dict(imp=0xC8),
    "JMP": dict(abs=0x4C, ind=0x6C), "JSR": dict(abs=0x20),
    "LDA": dict(imm=0xA9, zp=0xA5, zpx=0xB5, abs=0xAD, abx=0xBD, aby=0xB9, inx=0xA1, iny=0xB1),
    "LDX": dict(imm=0xA2, zp=0xA6, zpy=0xB6, abs=0xAE, aby=0xBE),
    "LDY": dict(imm=0xA0, zp=0xA4, zpx=0xB4, abs=0xAC, abx=0xBC),
    "LSR": dict(acc=0x4A, zp=0x46, zpx=0x56, abs=0x4E, abx=0x5E),
    "NOP": dict(imp=0xEA),
    "ORA": dict(imm=0x09, zp=0x05, zpx=0x15, abs=0x0D, abx=0x1D, aby=0x19, inx=0x01, iny=0x11),
    "PHA": dict(imp=0x48), "PHP": dict(imp=0x08), "PLA": dict(imp=0x68), "PLP": dict(imp=0x28),
    "ROL": dict(acc=0x2A, zp=0x26, zpx=0x36, abs=0x2E, abx=0x3E),
    "ROR": dict(acc=0x6A, zp=0x66, zpx=0x76, abs=0x6E, abx=0x7E),
    "RTI": dict(imp=0x40), "RTS": dict(imp=0x60),
    "SBC": dict(imm=0xE9, zp=0xE5, zpx=0xF5, abs=0xED, abx=0xFD, aby=0xF9, inx=0xE1, iny=0xF1),
    "SEC": dict(imp=0x38), "SED": dict(imp=0xF8), "SEI": dict(imp=0x78),
    "STA": dict(zp=0x85, zpx=0x95, abs=0x8D, abx=0x9D, aby=0x99, inx=0x81, iny=0x91),
    "STX": dict(zp=0x86, zpy=0x96, abs=0x8E),
    "STY": dict(zp=0x84, zpx=0x94, abs=0x8C),
    "TAX": dict(imp=0xAA), "TAY": dict(imp=0xA8), "TSX": dict(imp=0xBA),
    "TXA": dict(imp=0x8A), "TXS": dict(imp=0x9A), "TYA": dict(imp=0x98),
}
SIZE = dict(imp=1, acc=1, imm=2, zp=2, zpx=2, zpy=2, abs=3, abx=3, aby=3, inx=2, iny=2, ind=3, rel=2)
ZP_OF = dict(abs="zp", abx="zpx", aby="zpy")


class AsmError(Exception):
    pass


def _term(tok, symbols, pc, known_only):
    """Value of one term; None for an unknown symbol while known_only (pass 1)."""
    if tok == "*":
        return pc
    if tok.startswith("$"):
        return int(tok[1:], 16)
    if tok.startswith("%"):
        return int(tok[1:], 2)
    if tok.isdigit():
        return int(tok)
    if tok in symbols:
        return symbols[tok]
    if known_only:
        return None
    raise AsmError(f"undefined symbol {tok}")


def evaluate(expr, symbols, pc, known_only=False):
    """expr = [<|>] term {(+|-) term}. Returns an int, or None for a forward reference (pass 1)."""
    expr = expr.strip()
    sel = None
    if expr and expr[0] in "<>":
        sel, expr = expr[0], expr[1:].strip()
    toks = re.findall(r"[+-]|[^+\-\s]+", expr)
    if not toks:
        raise AsmError("empty expression")
    total, sign = 0, 1
    for t in toks:
        if t in ("+", "-"):
            sign = 1 if t == "+" else -1
            continue
        v = _term(t, symbols, pc, known_only)
        if v is None:
            return None
        total += sign * v
        sign = 1
    if sel == "<":
        total &= 0xFF
    elif sel == ">":
        total = (total >> 8) & 0xFF
    return total


def _split_operand(op):
    """Return (mode, expr): mode is imp, acc, imm, ind, inx, iny, x, y or plain."""
    op = op.strip()
    if op == "":
        return "imp", ""
    if op.upper() == "A":
        return "acc", ""
    if op.startswith("#"):
        return "imm", op[1:]
    m = re.fullmatch(r"\((.*),\s*[xX]\)", op)
    if m:
        return "inx", m.group(1)
    m = re.fullmatch(r"\((.*)\)\s*,\s*[yY]", op)
    if m:
        return "iny", m.group(1)
    m = re.fullmatch(r"\((.*)\)", op)
    if m:
        return "ind", m.group(1)
    m = re.fullmatch(r"(.*),\s*([xXyY])", op)
    if m:
        return m.group(2).lower(), m.group(1)
    return "plain", op


def _parse(text):
    """Return [(lineno, label, mnemonic-or-directive-or-'=', operand)]."""
    out = []
    for no, raw in enumerate(text.splitlines(), 1):
        s = raw.split(";", 1)[0].strip()
        if not s:
            continue
        label = None
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*):\s*(.*)", s)
        if m:
            label, s = m.group(1), m.group(2).strip()
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", s)
        if m:
            out.append((no, label, "=", (m.group(1), m.group(2))))
        elif s:
            parts = s.split(None, 1)
            out.append((no, label, parts[0], parts[1] if len(parts) > 1 else ""))
        else:
            out.append((no, label, None, ""))
    return out


def _instruction(u, arg, symbols, pc, final, sizes, idx):
    """Encode one instruction; returns (bytes or None in pass 1, size)."""
    mode, expr = _split_operand(arg)
    table = OPS[u]
    if mode == "plain":
        mode = "rel" if "rel" in table else "abs"
    elif mode in ("x", "y"):
        mode = "abx" if mode == "x" else "aby"
    elif mode == "imp" and "imp" not in table and "acc" in table:
        mode = "acc"
    val = evaluate(expr, symbols, pc, known_only=not final) if expr else None
    if mode in ZP_OF and ZP_OF[mode] in table:
        if not final:
            sizes[idx] = 2 if (val is not None and 0 <= val < 256) else 3
        if sizes[idx] == 2:
            mode = ZP_OF[mode]
    if mode not in table:
        raise AsmError(f"{u}: addressing mode {mode} not available")
    n = SIZE[mode]
    if not final:
        return None, n
    op = table[mode]
    if mode == "rel":
        off = val - (pc + 2)
        if not -128 <= off <= 127:
            raise AsmError(f"branch to {expr.strip()} out of range ({off})")
        return bytes([op, off & 0xFF]), n
    if n == 1:
        return bytes([op]), n
    if n == 2:
        if not -128 <= val <= 255:
            raise AsmError(f"operand out of range: {val}")
        return bytes([op, val & 0xFF]), n
    return bytes([op, val & 0xFF, (val >> 8) & 0xFF]), n


def _pass(stmts, symbols, final, sizes):
    pc, org, out = None, None, bytearray()
    for idx, (no, label, mn, arg) in enumerate(stmts):
        try:
            if label:
                if pc is None:
                    raise AsmError("label before .org")
                if not final:
                    if label in symbols:
                        raise AsmError(f"duplicate label {label}")
                    symbols[label] = pc
            if mn is None:
                continue
            if mn == "=":
                name, expr = arg
                v = evaluate(expr, symbols, pc or 0, known_only=not final)
                if v is None:
                    raise AsmError(f"constant {name} uses a forward reference")
                symbols[name] = v
                continue
            u = mn.upper()
            if u == ".ORG":
                pc = org = evaluate(arg, symbols, 0)
                continue
            if pc is None:
                raise AsmError("code before .org")
            if u in (".BYTE", ".WORD"):
                step = 1 if u == ".BYTE" else 2
                for e in [x for x in arg.split(",") if x.strip()]:
                    v = evaluate(e, symbols, pc, known_only=not final)
                    if final:
                        if step == 1 and not -128 <= v <= 255:
                            raise AsmError(f"byte out of range: {e.strip()} = {v}")
                        v &= 0xFF if step == 1 else 0xFFFF
                        out += bytes([v]) if step == 1 else bytes([v & 255, v >> 8])
                    pc += step
                continue
            if u not in OPS:
                raise AsmError(f"unknown mnemonic {mn}")
            code, n = _instruction(u, arg, symbols, pc, final, sizes, idx)
            if final:
                out += code
            pc += n
        except AsmError as e:
            raise AsmError(f"line {no}: {e}")
        except ValueError as e:
            raise AsmError(f"line {no}: bad number ({e})")
    return org, bytes(out), pc


def assemble(text, predefined=None):
    """Assemble text; returns (image bytes, origin address, symbol table)."""
    stmts = _parse(text)
    symbols = dict(predefined or {})
    sizes = {}
    org, _, end1 = _pass(stmts, symbols, False, sizes)
    final_symbols = dict(symbols)
    org2, image, end2 = _pass(stmts, final_symbols, True, sizes)
    if org != org2 or end1 != end2:
        raise AsmError("internal: pass 2 layout differs from pass 1")
    return image, org, final_symbols
