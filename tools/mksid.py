"""
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 IronKernel

File: mksid.py
Purpose: build one PSID v2 tune from a score file (bank/public/<tune>.txt): parse the score,
  generate the song data section, assemble it behind the ik64 player (tools/ik64sid/player.asm,
  assembler tools/ik64sid/asm6502.py) and write the PSID (load $1000, init $1000, play $1003, PAL,
  6581, vertical-blank speed, one song).
Usage: python -I tools/mksid.py <score.txt> -o <out.sid> [--info <out.info>]
  --info writes the facts the host test checks (loop length, the base frequency of every note-on).
Exit codes: 0 written, 1 score error (message names the line), 2 usage.

Score format (';' starts a comment; keywords end with ':' or are inst / pat):
  title: The Entertainer             PSID name (<= 31 characters)
  author: Scott Joplin, arr. IronKernel   PSID author (<= 31 characters)
  released: 2026 IronKernel 64       PSID released field (<= 31 characters)
  tempo: 100                         quarter notes per minute
  tpq: 12                            ticks per quarter note (the time grid; ticks per frame must
                                     stay below 1: tempo * tpq / 3000 < 1)
  meter: 2/4                         bar length for the '|' checks
  inst NAME key=value ...            instrument; keys (all optional):
        wave=pulse|saw|tri|noise (join with '+')   a= d= s= r= (0..15 each)
        pw=0.5 (duty 0.0..1.0)  pwspeed=N (signed sweep, 0 = static)
        vibcents=N (peak vibrato depth in cents, 0 = off)  vibdelay=FRAMES  vibrate=HZ
        gate=FRAMES (gate-on length, 0 = whole note)  hr=0|1 (hard restart)
  pat NAME:                          a pattern; the following lines hold its events
  voice 1: NAME NAME+12@lead NAME-5*2   order list of voice 1..3: pattern, transpose in semitones,
                                     optional @instrument (switched at the pattern start), optional repeat count
Events inside a pattern (whitespace separated):
  c4/8  c#4/8.  bb3/16  d5/8t        note: letter a-g, optional # or b, octave 0-7, then / and the
                                     note value: 1 2 4 8 16 32 64, '.' dotted (several allowed),
                                     't' triplet, or /=N for N ticks. A missing /value repeats the
                                     last value of the pattern (default quarter).
  &e4/8                              slur: pitch change without retrigger
  r/4                                rest
  ~/8                                tie: lengthen the previous event by this value
  @lead                              select instrument
  |                                  bar line: the ticks since the pattern start must fill whole bars
All three voices must have the same length in ticks, so the tune loops cleanly.
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import argparse
import math
import os
import re
import struct
import sys

sys.dont_write_bytecode = True    # no __pycache__ next to the sources
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ik64sid"))
import asm6502  # noqa: E402

PLAYER_ASM = os.path.join(HERE, "ik64sid", "player.asm")
LOAD_ADDR = 0x1000
PLAY_ADDR = 0x1003
PAL_CLOCK = 985248
FRAME_HZ = 50.0
NOTE_COUNT = 96
FIELD_MAX = 31
MAX_PATTERNS = 128
MAX_INSTRUMENTS = 16
MIN_NOTE_FRAMES = 3.0

WAVES = {"tri": 0x10, "saw": 0x20, "pulse": 0x40, "noise": 0x80}
LETTERS = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}
KEYWORDS = ("title", "author", "released", "tempo", "tpq", "meter")


class ScoreError(Exception):
    pass


def freq_table():
    """SID frequency register values for note index 0 (C0) .. 95 (B7), equal temperament, A4 = 440."""
    out = []
    for idx in range(NOTE_COUNT):
        hz = 440.0 * 2.0 ** ((idx - 57) / 12.0)
        out.append(int(round(hz * 16777216.0 / PAL_CLOCK)))
    return out


def vib_shift(cents):
    """vibshift whose peak deviation (8 * f >> shift) is nearest to the wanted cents."""
    best, err = 0, 1e9
    for s in range(4, 13):
        peak = 1200.0 * math.log2(1.0 + 8.0 / (1 << s))
        if abs(peak - cents) < err:
            best, err = s, abs(peak - cents)
    return best


class Score:
    def __init__(self):
        self.meta = {}
        self.tempo = 0
        self.tpq = 0
        self.meter = (4, 4)
        self.insts = {}        # name -> (index, record bytes)
        self.inst_order = []
        self.patterns = {}     # name -> list of events
        self.pat_order = []
        self.voices = {}       # 1..3 -> list of (pattern name, transpose)


def duration(spec, tpq, no):
    """Ticks of a note value like 8, 8., 8t, =3. spec excludes the '/'."""
    if spec.startswith("="):
        n = int(spec[1:])
    else:
        m = re.fullmatch(r"(\d+)(\.*)(t?)", spec)
        if not m or int(m.group(1)) not in (1, 2, 4, 8, 16, 32, 64):
            raise ScoreError(f"line {no}: bad note value '/{spec}'")
        base = 4.0 * tpq / int(m.group(1))
        dots = len(m.group(2))
        val = base * (2.0 - 0.5 ** dots)
        if m.group(3):
            val = val * 2.0 / 3.0
        n = int(round(val))
        if abs(val - n) > 1e-6:
            raise ScoreError(f"line {no}: /{spec} is {val} ticks at tpq {tpq}, not a whole number")
    if not 1 <= n <= 255 * 64:
        raise ScoreError(f"line {no}: duration {n} ticks out of range")
    return n


def parse_inst(line, no):
    parts = line.split()
    if len(parts) < 2:
        raise ScoreError(f"line {no}: inst needs a name")
    name = parts[1]
    kv = {"wave": "pulse", "a": "0", "d": "9", "s": "0", "r": "0", "pw": "0.5", "pwspeed": "0",
          "vibcents": "0", "vibdelay": "0", "vibrate": "5.5", "gate": "0", "hr": "1"}
    for item in parts[2:]:
        if "=" not in item:
            raise ScoreError(f"line {no}: bad instrument item '{item}'")
        k, v = item.split("=", 1)
        if k not in kv:
            raise ScoreError(f"line {no}: unknown instrument key '{k}'")
        kv[k] = v
    try:
        wave = 0
        for w in kv["wave"].split("+"):
            wave |= WAVES[w]
        a, d, s, r = (int(kv[k]) for k in "adsr")
        if not all(0 <= x <= 15 for x in (a, d, s, r)):
            raise ScoreError(f"line {no}: a/d/s/r are 0..15")
        pwspeed = int(kv["pwspeed"])
        pw = int(round(float(kv["pw"]) * 4096)) >> 4
        pw = max(0, min(255, pw))
        if pwspeed:
            pw = max(0x20, min(0xBF, pw))
        if not -127 <= pwspeed <= 127:
            raise ScoreError(f"line {no}: pwspeed -127..127")
        cents = float(kv["vibcents"])
        vsh = vib_shift(cents) if cents > 0 else 0
        vdel = int(kv["vibdelay"])
        vspd = int(round(float(kv["vibrate"]) * 256.0 / FRAME_HZ))
        gate = int(kv["gate"])
        hr = int(kv["hr"])
    except KeyError as e:
        raise ScoreError(f"line {no}: unknown waveform {e}")
    except ValueError as e:
        raise ScoreError(f"line {no}: bad number ({e})")
    for what, v in (("vibdelay", vdel), ("vibrate", vspd), ("gate", gate)):
        if not 0 <= v <= 255:
            raise ScoreError(f"line {no}: {what} out of range")
    rec = bytes([wave, a << 4 | d, s << 4 | r, pw, pwspeed & 0xFF, vsh, vdel, vspd, gate, hr & 1]) + bytes(6)
    return name, rec


def parse_pattern(lines, sc, name):
    """lines = [(no, text)]. Returns the event list [(kind, value, ticks)] with kind note/slur/rest/tie/inst."""
    events = []
    last_dur = sc.tpq
    bar = sc.meter[0] * 4 * sc.tpq // sc.meter[1]
    pos = 0
    for no, text in lines:
        for tok in text.split():
            if tok == "|":
                if pos % bar:
                    raise ScoreError(f"line {no}: pattern {name}: bar line after {pos} ticks, bars are {bar}")
                continue
            if tok.startswith("@"):
                if tok[1:] not in sc.insts:
                    raise ScoreError(f"line {no}: unknown instrument {tok}")
                events.append(("inst", sc.insts[tok[1:]][0], 0))
                continue
            dur = last_dur
            body = tok
            if "/" in tok:
                body, spec = tok.split("/", 1)
                dur = duration(spec, sc.tpq, no)
            last_dur = dur
            if body == "~":
                if not events or events[-1][0] == "inst":
                    raise ScoreError(f"line {no}: tie without a previous event")
                k, v, t = events[-1]
                events[-1] = (k, v, t + dur)
            elif body == "r":
                events.append(("rest", 0, dur))
            else:
                slur = body.startswith("&")
                m = re.fullmatch(r"([a-g])([#b]?)(\d)", body.lstrip("&"))
                if not m:
                    raise ScoreError(f"line {no}: cannot read event '{tok}'")
                idx = 12 * int(m.group(3)) + LETTERS[m.group(1)] + {"": 0, "#": 1, "b": -1}[m.group(2)]
                if not 0 <= idx < NOTE_COUNT:
                    raise ScoreError(f"line {no}: note {tok} outside C0..B7")
                events.append(("slur" if slur else "note", idx, dur))
            pos += dur
    return events, pos


def parse_score(text):
    sc = Score()
    cur = None           # (name, lines)
    raw_pats = []
    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        first = line.split()[0]
        try:
            if first == "voice:" or re.match(r"voice\s+[123]\s*:", line):
                cur = None
                m = re.fullmatch(r"voice\s+([123])\s*:\s*(.*)", line)
                if not m:
                    raise ScoreError(f"line {no}: expected 'voice 1..3: ...'")
                entries = []
                for tok in m.group(2).split():
                    mm = re.fullmatch(r"([A-Za-z0-9_]+?)([+-]\d+)?(?:@([A-Za-z0-9_]+))?(?:\*(\d+))?", tok)
                    if not mm:
                        raise ScoreError(f"line {no}: bad order entry '{tok}'")
                    entries += [(mm.group(1), int(mm.group(2) or 0), mm.group(3))] * int(mm.group(4) or 1)
                sc.voices[int(m.group(1))] = (no, entries)
            elif first.endswith(":") and first[:-1] in KEYWORDS:
                key = first[:-1]
                val = line[len(first):].strip()
                cur = None
                if key in ("title", "author", "released"):
                    if len(val) > FIELD_MAX or not val:
                        raise ScoreError(f"line {no}: {key} must be 1..{FIELD_MAX} characters")
                    sc.meta[key] = val
                elif key == "tempo":
                    sc.tempo = float(val)
                elif key == "tpq":
                    sc.tpq = int(val)
                elif key == "meter":
                    n, d = val.split("/")
                    sc.meter = (int(n), int(d))
            elif first == "inst":
                cur = None
                name, rec = parse_inst(line, no)
                if name in sc.insts:
                    raise ScoreError(f"line {no}: duplicate instrument {name}")
                if len(sc.insts) >= MAX_INSTRUMENTS:
                    raise ScoreError(f"line {no}: more than {MAX_INSTRUMENTS} instruments")
                sc.insts[name] = (len(sc.insts), rec)
            elif first == "pat":
                m = re.fullmatch(r"pat\s+([A-Za-z0-9_]+)\s*:", line)
                if not m:
                    raise ScoreError(f"line {no}: expected 'pat NAME:'")
                name = m.group(1)
                if name in sc.patterns or any(n == name for n, _, _ in raw_pats):
                    raise ScoreError(f"line {no}: duplicate pattern {name}")
                cur = (name, no, [])
                raw_pats.append(cur)
            else:
                if cur is None:
                    raise ScoreError(f"line {no}: event outside a pattern: '{line}'")
                cur[2].append((no, line))
        except ValueError as e:
            raise ScoreError(f"line {no}: bad value ({e})")
    for key in ("title", "author", "released"):
        if key not in sc.meta:
            raise ScoreError(f"missing {key}:")
    if sc.tempo <= 0 or sc.tpq <= 0:
        raise ScoreError("tempo: and tpq: are required")
    if not sc.insts:
        raise ScoreError("no instrument defined")
    if len(raw_pats) > MAX_PATTERNS:
        raise ScoreError(f"more than {MAX_PATTERNS} patterns")
    for name, no, lines in raw_pats:
        ev, ticks = parse_pattern(lines, sc, name)
        sc.patterns[name] = (ev, ticks)
        sc.pat_order.append(name)
    if sorted(sc.voices) != [1, 2, 3]:
        raise ScoreError("voice 1, 2 and 3 are all required")
    # NAME@inst entries become a copy of the pattern that starts with that instrument.
    for v, (no, entries) in list(sc.voices.items()):
        resolved = []
        for name, trn, inst in entries:
            if inst is not None:
                if inst not in sc.insts:
                    raise ScoreError(f"line {no}: voice {v}: unknown instrument {inst}")
                if name not in sc.patterns:
                    raise ScoreError(f"line {no}: voice {v}: unknown pattern {name}")
                derived = f"{name}__{inst}"
                if derived not in sc.patterns:
                    ev, ticks = sc.patterns[name]
                    sc.patterns[derived] = ([("inst", sc.insts[inst][0], 0)] + ev, ticks)
                    sc.pat_order.append(derived)
                name = derived
            resolved.append((name, trn))
        sc.voices[v] = (no, resolved)
    used = {n for _, (no, es) in sc.voices.items() for n, _ in es}
    sc.pat_order = [n for n in sc.pat_order if n in used]    # unused patterns are not emitted
    return sc


def pattern_bytes(events):
    out = bytearray()
    for kind, val, ticks in events:
        if kind == "inst":
            out += bytes([0xF1, val])
            continue
        code = {"rest": 0x00, "tie": 0x7F}.get(kind)
        if code is None:
            code = val + 1 + (0x80 if kind == "slur" else 0)
        first = min(ticks, 255)
        out += bytes([code, first])
        ticks -= first
        while ticks > 0:
            chunk = min(ticks, 255)
            out += bytes([0x00 if kind == "rest" else 0x7F, chunk])
            ticks -= chunk
    out.append(0xFF)
    return bytes(out)


def check_score(sc, ftab):
    """Whole-score checks; returns (loop_ticks, note-on frequency lists per voice)."""
    rate = sc.tempo * sc.tpq / 60.0 / FRAME_HZ
    if rate >= 1.0:
        raise ScoreError(f"tempo {sc.tempo} with tpq {sc.tpq} needs {rate:.2f} ticks per frame, lower tpq")
    lengths, notes = {}, {}
    for v, (no, entries) in sorted(sc.voices.items()):
        total, lst = 0, []
        if not entries:
            raise ScoreError(f"line {no}: voice {v} is empty")
        for name, trn in entries:
            if name not in sc.patterns:
                raise ScoreError(f"line {no}: voice {v}: unknown pattern {name}")
            ev, ticks = sc.patterns[name]
            total += ticks
            inst_set = False
            for kind, val, t in ev:
                if kind == "inst":
                    inst_set = True
                if kind in ("note", "slur"):
                    idx = val + trn
                    if not 0 <= idx < NOTE_COUNT or ftab[idx] > 65535:
                        raise ScoreError(f"line {no}: voice {v}: pattern {name}{trn:+d} leaves the SID range")
                    if kind == "note":
                        lst.append(ftab[idx])
                        if t / rate < MIN_NOTE_FRAMES and t / rate < 2.0:
                            raise ScoreError(f"line {no}: pattern {name}: a note of {t} ticks is shorter than "
                                             f"{MIN_NOTE_FRAMES:.0f} frames")
        lengths[v], notes[v] = total, lst
    if len(set(lengths.values())) != 1:
        raise ScoreError("voices differ in length (ticks): "
                         + ", ".join(f"voice {v} = {n}" for v, n in sorted(lengths.items())))
    return lengths[1], notes


def song_asm(sc, ftab):
    """The generated data section (see the contract at the top of player.asm)."""
    rate = int(round(sc.tempo * sc.tpq / 60.0 / FRAME_HZ * 65536.0))
    pats = sc.pat_order
    pidx = {n: i for i, n in enumerate(pats)}
    used = set(n for _, (no, es) in sc.voices.items() for n, _ in es)
    lines = ["; generated by tools/mksid.py", f"song_rate_lo: .byte {rate & 255}", f"song_rate_hi: .byte {rate >> 8}",
             "ord_lo: .byte <ord1, <ord2, <ord3", "ord_hi: .byte >ord1, >ord2, >ord3"]
    lines.append("pat_lo: .byte " + ", ".join(f"<pat_{n}" for n in pats))
    lines.append("pat_hi: .byte " + ", ".join(f">pat_{n}" for n in pats))
    lines.append("freq_lo: .byte " + ", ".join(str(min(f, 65535) & 255) for f in ftab))
    lines.append("freq_hi: .byte " + ", ".join(str(min(f, 65535) >> 8) for f in ftab))
    recs = [None] * len(sc.insts)
    for name, (i, rec) in sc.insts.items():
        recs[i] = rec
    lines.append("inst:")
    for rec in recs:
        lines.append("  .byte " + ", ".join(str(b) for b in rec))
    for v in (1, 2, 3):
        _, entries = sc.voices[v]
        lines.append(f"ord{v}:")
        body = []
        for n, trn in entries:
            body += [pidx[n], trn & 0xFF]
        for i in range(0, len(body), 16):
            lines.append("  .byte " + ", ".join(str(b) for b in body[i:i + 16]))
        lines.append("  .byte 255")
    for n in pats:
        lines.append(f"pat_{n}:")
        data = pattern_bytes(sc.patterns[n][0])
        for i in range(0, len(data), 16):
            lines.append("  .byte " + ", ".join(str(b) for b in data[i:i + 16]))
    return "\n".join(lines) + "\n", rate, used


def build_image(sc, ftab):
    """Assemble player + data; variables follow the image on a page boundary."""
    with open(PLAYER_ASM, encoding="utf-8") as f:
        player = f.read()
    data, rate, _ = song_asm(sc, ftab)
    text = player + data
    image, org, _ = asm6502.assemble(text, {"VARS": 0x2000})
    vars_addr = (org + len(image) + 0xFF) & ~0xFF
    image, org, syms = asm6502.assemble(text, {"VARS": vars_addr})
    if vars_addr + 80 >= 0xD000:
        raise ScoreError("tune too large (variables would reach $D000)")
    return image, org, vars_addr, rate, syms


def tick_frames(rate, ticks):
    """Frame index (0-based play call) of tick number k for k = 1..ticks + 1 under the 16-bit accumulator."""
    acc, frame, k, out = 0xFFFF, 0, 0, []
    while k < ticks + 1:
        acc += rate
        if acc > 0xFFFF:
            k += 1
            out.append(frame)
        acc &= 0xFFFF
        frame += 1
    return out


def psid(sc, image, vars_addr):
    def field(s):
        b = s.encode("latin-1")
        return b + bytes(32 - len(b))
    pages = ((vars_addr + 0x100) - LOAD_ADDR + 0xFF) >> 8
    head = b"PSID" + struct.pack(">HHHHHHHI", 2, 0x7C, 0, LOAD_ADDR, PLAY_ADDR, 1, 1, 0)
    head += field(sc.meta["title"]) + field(sc.meta["author"]) + field(sc.meta["released"])
    head += struct.pack(">HBBBB", 0x0014, LOAD_ADDR >> 8, pages, 0, 0)
    assert len(head) == 0x7C, len(head)
    return head + struct.pack("<H", LOAD_ADDR) + image


def main(argv):
    ap = argparse.ArgumentParser(description="score file -> PSID")
    ap.add_argument("score")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--info")
    args = ap.parse_args(argv)
    try:
        with open(args.score, encoding="utf-8") as f:
            sc = parse_score(f.read())
        ftab = freq_table()
        loop_ticks, notes = check_score(sc, ftab)
        image, org, vars_addr, rate, syms = build_image(sc, ftab)
    except (ScoreError, asm6502.AsmError) as e:
        print(f"mksid: FAIL {os.path.basename(args.score)}: {e}")
        return 1
    except OSError as e:
        print(f"mksid: FAIL {e}")
        return 2
    sid = psid(sc, image, vars_addr)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(sid)
    tf = tick_frames(rate, loop_ticks)
    loop_frames = tf[loop_ticks] - tf[0]
    secs = loop_frames / FRAME_HZ
    if args.info:
        with open(args.info, "w", encoding="utf-8") as f:
            f.write(f"title={sc.meta['title']}\nloop_ticks={loop_ticks}\nloop_frames={loop_frames}\n")
            f.write(f"seconds={secs:.1f}\nplayer_bytes={len(image)}\nvars={vars_addr:04X}\n")
            for v in (1, 2, 3):
                f.write(f"notes{v}=" + " ".join(f"{x:04X}" for x in notes[v]) + "\n")
    print(f"mksid: {os.path.basename(args.out)}: {len(sid)} bytes, {secs:.1f} s, "
          f"{len(notes[1])}/{len(notes[2])}/{len(notes[3])} notes, variables at ${vars_addr:04X}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
