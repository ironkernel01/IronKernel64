"""
File: mkbank.py
Purpose: pack a folder of PSID tunes into the device 9 bank image (format in
  fw_1541/src/bank_format.h, the only packer of that format).
Usage: python -I tools/mkbank.py <folder> -o <bank.bin> [--max-bytes N]
  e.g. python -I tools/mkbank.py build/bank/public -o build/bank/public.bin
Behavior:
  * Takes every *.sid file of the folder (not recursive), sorted by file name, case-insensitive.
    The entry name is the file name as on the share ("Airwolf.sid"); cbmdos hides the extension.
  * Each file must be a PSID (magic "PSID"); an RSID file is rejected with a message, as is a file
    that is too short for a PSID header, a name over 31 bytes, a duplicate name (ignoring case),
    or a folder with more than 256 tunes.
  * The image must fit C64_PLAT_BANK_SIZE (read from common/c64_platform.h); over that size the
    tool fails and writes nothing. --max-bytes overrides the limit (tests).
  * Prints the table (name, offset, size, CRC-32) and the total.
  * The tunes are never copied anywhere but into the output file; the .sid files and the bank are
    git-ignored (*.sid, build/). The public bank (device 9) is built by tools/mkpublicbank.py, which runs
    tools/mksid.py on bank/public/*.txt and then this packer on build/bank/public.
Exit codes: 0 written, 1 a tune or the folder is rejected, 2 usage / environment.
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import argparse
import os
import re
import struct
import sys
import zlib

MAGIC = b"IK64BANK"
VERSION = 1
HDR_BYTES = 32
ENTRY_BYTES = 48
NAME_BYTES = 32
MAX_ENTRIES = 256
ALIGN = 4
PSID_MIN_BYTES = 0x7C
CRC_SPAN = 20

HERE = os.path.dirname(os.path.abspath(__file__))
PLATFORM_H = os.path.join(HERE, "..", "common", "c64_platform.h")


def bank_limit():
    """C64_PLAT_BANK_SIZE from common/c64_platform.h (the only place it is defined)."""
    with open(PLATFORM_H, encoding="utf-8") as f:
        m = re.search(r"C64_PLAT_BANK_SIZE\s+\(0x([0-9A-Fa-f]+)u\)", f.read())
    if not m:
        raise SystemExit("mkbank: C64_PLAT_BANK_SIZE not found in common/c64_platform.h")
    return int(m.group(1), 16)


def collect(folder):
    """Return [(name, data)] sorted case-insensitively; raise ValueError on a rejected file."""
    names = [n for n in os.listdir(folder)
             if n.lower().endswith(".sid") and os.path.isfile(os.path.join(folder, n))]
    names.sort(key=lambda n: (n.lower(), n))
    if len(names) > MAX_ENTRIES:
        raise ValueError(f"{len(names)} tunes, the format holds {MAX_ENTRIES}")
    tunes = []
    seen = set()
    for n in names:
        raw = n.encode("utf-8")
        if len(raw) >= NAME_BYTES:
            raise ValueError(f"{n}: name is {len(raw)} bytes, at most {NAME_BYTES - 1}")
        if n.lower() in seen:
            raise ValueError(f"{n}: duplicate name ignoring case")
        seen.add(n.lower())
        with open(os.path.join(folder, n), "rb") as f:
            data = f.read()
        if data[:4] == b"RSID":
            raise ValueError(f"{n}: RSID file (real C64 environment required), only PSID is supported")
        if data[:4] != b"PSID":
            raise ValueError(f"{n}: not a PSID file (magic {data[:4]!r})")
        if len(data) < PSID_MIN_BYTES:
            raise ValueError(f"{n}: {len(data)} bytes, too short for a PSID header")
        tunes.append((n, data))
    return tunes


def pack(tunes):
    """Build the image bytes and the table rows [(name, offset, size, crc)]."""
    table_end = HDR_BYTES + len(tunes) * ENTRY_BYTES
    offset = table_end
    rows = []
    body = bytearray()
    for name, data in tunes:
        pad = (-offset) % ALIGN
        body += b"\0" * pad
        offset += pad
        rows.append((name, offset, len(data), zlib.crc32(data) & 0xFFFFFFFF))
        body += data
        offset += len(data)
    total = offset
    table = b"".join(struct.pack("<32sIIII", n.encode("utf-8"), o, s, c, 0) for n, o, s, c in rows)
    head = MAGIC + struct.pack("<III", VERSION, len(tunes), total)
    crc = zlib.crc32(table, zlib.crc32(head)) & 0xFFFFFFFF
    header = head + struct.pack("<I", crc) + b"\0" * (HDR_BYTES - CRC_SPAN - 4)
    return header + table + bytes(body), rows


def main(argv):
    ap = argparse.ArgumentParser(description="pack a folder of PSID tunes into the device 9 bank")
    ap.add_argument("folder")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--max-bytes", type=int, default=0)
    args = ap.parse_args(argv)
    if not os.path.isdir(args.folder):
        print(f"mkbank: FAIL not a folder: {args.folder}")
        return 2
    limit = args.max_bytes if args.max_bytes > 0 else bank_limit()
    try:
        tunes = collect(args.folder)
    except ValueError as e:
        print(f"mkbank: FAIL {e}")
        return 1
    image, rows = pack(tunes)
    print(f"{'name':<32} {'offset':>8} {'size':>8}  crc32")
    for name, off, size, crc in rows:
        print(f"{name:<32} {off:>8} {size:>8}  {crc:08x}")
    print(f"{len(rows)} tunes, {len(image)} bytes of {limit} ({100.0 * len(image) / limit:.1f} %)")
    if len(image) > limit:
        print(f"mkbank: FAIL image is {len(image)} bytes, the bank holds {limit}")
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(image)
    print(f"mkbank: PASS {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
