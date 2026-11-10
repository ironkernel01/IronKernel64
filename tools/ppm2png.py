#!/usr/bin/env python
"""ppm2png.py -- convert a binary P6 PPM to PNG (stdlib only). Usage: python -I ppm2png.py in.ppm out.png"""
import struct
import sys
import zlib


def main():
    data = open(sys.argv[1], 'rb').read()
    parts = data.split(b'\n', 3)
    w, h = (int(t) for t in parts[1].split())
    pix = parts[3]
    raw = b''.join(b'\x00' + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        c = struct.pack('>I', len(body)) + tag + body
        return c + struct.pack('>I', zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(sys.argv[2], 'wb').write(png)


main()
