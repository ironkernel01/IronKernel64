#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
"""
uart_capture.py -- log the bytes a serial port delivers for a fixed time.

Usage: python -I tools/uart_capture.py --port COMn [--baud 115200] --seconds N
           --out FILE [--send TEXT] [--expect REGEX]

Received bytes are decoded latin-1 and written line by line, each line prefixed with
the elapsed time, to FILE and stdout. --send TEXT is written once after the port opens
(\\n, \\r and \\xNN escapes are expanded). The capture ends after N seconds, or early
once REGEX matches the received text.
Exit codes: 0 expect matched (or no --expect), 1 not matched in time, 2 port cannot be opened.
Backend: pyserial (pip package "pyserial").
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    serial = None


def unescape(text):
    def sub(m):
        g = m.group(1)
        return {"n": "\n", "r": "\r"}.get(g) or chr(int(g[1:], 16))
    return re.sub(r"\\(n|r|x[0-9a-fA-F]{2})", sub, text)


def main(argv):
    ap = argparse.ArgumentParser(description="Capture serial output to a file.")
    ap.add_argument("--port", required=True, help="serial port, e.g. COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, required=True, help="capture time limit")
    ap.add_argument("--out", required=True, help="log file")
    ap.add_argument("--send", help="text sent once after the port opens")
    ap.add_argument("--expect", help="regex; capture ends early when it matches")
    a = ap.parse_args(argv)
    try:
        rx = re.compile(a.expect) if a.expect else None
    except re.error as e:
        ap.error("bad --expect regex: %s" % e)

    if serial is None:
        print("uart_capture: pyserial is not installed (pip install pyserial)", file=sys.stderr)
        return 2
    try:
        port = serial.Serial(a.port, a.baud, timeout=0.05)
    except (serial.SerialException, OSError, ValueError) as e:
        print("uart_capture: cannot open port %s: %s" % (a.port, e), file=sys.stderr)
        return 2

    t0 = time.monotonic()
    text = ""
    pending = ""
    matched = rx is None
    with open(a.out, "w", encoding="latin-1", newline="\n") as f:
        def emit(line):
            s = "[%8.3f] %s\n" % (time.monotonic() - t0, line.rstrip("\r"))
            f.write(s)
            f.flush()
            sys.stdout.write(s)
            sys.stdout.flush()
        try:
            if a.send:
                port.write(unescape(a.send).encode("latin-1", "replace"))
                port.flush()
            while time.monotonic() - t0 < a.seconds:
                data = port.read(4096)
                if not data:
                    continue
                chunk = data.decode("latin-1")
                text += chunk
                pending += chunk
                while "\n" in pending:
                    line, pending = pending.split("\n", 1)
                    emit(line)
                if rx and rx.search(text):
                    matched = True
                    break
            if pending:
                emit(pending)
        finally:
            port.close()
    if not matched:
        print("uart_capture: --expect %r not matched in %.1f s" % (a.expect, a.seconds),
              file=sys.stderr)
    return 0 if matched else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
