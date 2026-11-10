"""
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 IronKernel

File: mkqspi.py
Purpose: build the data blob of the single QSPI flash image: the image header (fw_1541/boot/qspi_format.h),
  the core 1 DDR3 image (flat binary of the fw_1541.elf PT_LOAD segments) and the device 9 tune bank.
  scripts/make_qspi.ps1 places the blob at flash offset 0x1000000 next to the bitstream (write_cfgmem).
Usage: python -I tools/mkqspi.py --elf build/fw_1541/fw_1541.elf [--bank build/bank/public.bin]
         --out build/qspi/qspi_data.bin [--build-id 0123abcd]
  The blob starts with the 64-byte header padded to 4 KiB, then the firmware image (4 KiB aligned), then the bank.
  Offsets in the header are flash offsets (blob offset + 0x1000000).
  --selftest checks the packer against a synthetic ELF and exits 0 (also with --inject-failure: expected exit 1).
Exit codes: 0 written, 1 input rejected (bad ELF, segment outside the core 1 partition, bank too big or
  not a bank image), 2 usage.
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import argparse
import os
import struct
import sys
import zlib

sys.dont_write_bytecode = True

FLASH_OFS = 0x01000000
ALIGN = 0x1000
HDR_BYTES = 64
VERSION = 1
DDR_CORE1_BASE = 0x80000000
BANK_BASE = 0x83F00000
BANK_SIZE = 0x00100000
FW_MAX = BANK_BASE - DDR_CORE1_BASE


def flatten_elf(data):
    """Return (load_addr, image bytes, entry) of the PT_LOAD segments with file data."""
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise ValueError("not a little-endian ELF32 file")
    entry, phoff = struct.unpack_from("<II", data, 24)
    phentsize, phnum = struct.unpack_from("<HH", data, 42)
    segs = []
    for i in range(phnum):
        ptype, off, vaddr, _paddr, filesz, _memsz, _flags, _align = struct.unpack_from("<IIIIIIII", data, phoff + i * phentsize)
        if ptype == 1 and filesz > 0:
            if off + filesz > len(data):
                raise ValueError("segment runs past the end of the ELF")
            segs.append((vaddr, data[off:off + filesz]))
    if not segs:
        raise ValueError("ELF has no loadable segment")
    base = min(v for v, _ in segs)
    end = max(v + len(b) for v, b in segs)
    if base < DDR_CORE1_BASE or end > BANK_BASE:
        raise ValueError("segments 0x%08X..0x%08X are outside the core 1 partition 0x%08X..0x%08X"
                         % (base, end, DDR_CORE1_BASE, BANK_BASE))
    img = bytearray(end - base)
    for v, b in segs:
        img[v - base:v - base + len(b)] = b
    if not base <= entry < end:
        raise ValueError("entry 0x%08X is outside the image" % entry)
    return base, bytes(img), entry


def check_bank(bank):
    if len(bank) > BANK_SIZE:
        raise ValueError("bank is %d bytes, more than the %d byte bank region" % (len(bank), BANK_SIZE))
    if bank[:8] != b"IK64BANK":
        raise ValueError("bank image does not start with IK64BANK (tools/mkbank.py output expected)")


def pad(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def build_blob(elf_data, bank, build_id):
    load, fw, entry = flatten_elf(elf_data)
    fw_ofs = FLASH_OFS + ALIGN
    bank_ofs = fw_ofs + pad(len(fw))
    if bank:
        check_bank(bank)
    hdr = bytearray(HDR_BYTES)
    hdr[0:8] = b"IK64QSPI"
    struct.pack_into("<IIIIIII", hdr, 8, VERSION, HDR_BYTES, load, len(fw), fw_ofs, zlib.crc32(fw), entry)
    struct.pack_into("<IIII", hdr, 36, BANK_BASE if bank else 0, len(bank), bank_ofs if bank else 0, zlib.crc32(bank) if bank else 0)
    struct.pack_into("<II", hdr, 52, 0, build_id)
    struct.pack_into("<I", hdr, 60, zlib.crc32(bytes(hdr[:60])))
    blob = bytes(hdr).ljust(ALIGN, b"\xff") + fw.ljust(pad(len(fw)), b"\xff")
    if bank:
        blob += bank.ljust(pad(len(bank)), b"\xff")
    return blob, load, len(fw), entry


def selftest(inject):
    # a synthetic ELF: one PT_LOAD at 0x80000000 with 8 bytes, entry 0x80000000
    ph = struct.pack("<IIIIIIII", 1, 0x54, 0x80000000, 0x80000000, 8, 16, 7, 4)
    eh = bytearray(52)
    eh[0:6] = b"\x7fELF\x01\x01"
    struct.pack_into("<II", eh, 24, 0x80000000 + (0x100 if inject else 0), 52)
    struct.pack_into("<HH", eh, 42, 32, 1)
    elf = bytes(eh) + ph + bytes(range(8))
    bank = b"IK64BANK" + bytes(24)
    try:
        blob, load, size, entry = build_blob(elf, bank, 0x12345678)
    except ValueError as e:
        print("mkqspi selftest: FAIL %s" % e)
        return 1
    assert blob[:8] == b"IK64QSPI" and load == 0x80000000 and size == 8
    assert struct.unpack_from("<I", blob, 60)[0] == zlib.crc32(blob[:60])
    assert blob[0x1000:0x1008] == bytes(range(8))
    assert blob[0x2000:0x2008] == b"IK64BANK"
    assert len(blob) == 0x3000
    try:
        build_blob(elf, b"BADBANK!", 0)
        return 1
    except ValueError:
        pass
    print("mkqspi selftest: PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="build the QSPI data blob (header + core 1 image + tune bank)")
    ap.add_argument("--elf")
    ap.add_argument("--bank")
    ap.add_argument("--out")
    ap.add_argument("--build-id", default="0")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--inject-failure", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest(a.inject_failure)
    if not a.elf or not a.out:
        ap.error("--elf and --out are required")
    try:
        with open(a.elf, "rb") as f:
            elf = f.read()
        bank = b""
        if a.bank:
            with open(a.bank, "rb") as f:
                bank = f.read()
        blob, load, size, entry = build_blob(elf, bank, int(a.build_id, 16))
    except (OSError, ValueError) as e:
        print("mkqspi: FAIL %s" % e)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(blob)
    print("mkqspi: PASS %s: firmware 0x%08X + %d bytes (entry 0x%08X), bank %d bytes, blob %d bytes, flash 0x%08X..0x%08X"
          % (a.out, load, size, entry, len(bank), len(blob), FLASH_OFS, FLASH_OFS + len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
