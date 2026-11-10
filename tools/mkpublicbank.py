"""
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 IronKernel

File: mkpublicbank.py
Purpose: build the public device 9 tune bank in one command: every score bank/public/<tune>.txt becomes
  build/bank/public/<tune>.sid (plus <tune>.info, the facts tools/sid_host_test.c checks) through
  tools/mksid.py, then tools/mkbank.py packs the folder into build/bank/public.bin.
Usage: python -I tools/mkpublicbank.py [--src bank/public] [--out build/bank]
  Run from the repository root (or give --src / --out). Stale .sid/.info files of removed scores are
  deleted from the output folder first. A score name is the file name of the tune on device 9, so it
  should be at most 16 characters (LOAD"NAME",9 typed whole; an underscore is a space in cbmdos);
  longer names are built but reported.
Next: python -I tools/public_bank_test.py (host test with the real core 0 code, WAV rendering);
  board: scripts/jtag_load.ps1 -Core 1 -Bank build/bank/public.bin or scripts/load_bank.ps1 -Bank build/bank/public.bin.
Exit codes: 0 bank written, 1 a score or the packer failed, 2 usage / environment.
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import argparse
import glob
import os
import sys

sys.dont_write_bytecode = True    # no __pycache__ next to the sources
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mkbank  # noqa: E402
import mksid   # noqa: E402

NAME_LIMIT = 16


def main(argv):
    ap = argparse.ArgumentParser(description="build the public tune bank")
    ap.add_argument("--src", default="bank/public")
    ap.add_argument("--out", default="build/bank")
    args = ap.parse_args(argv)
    scores = sorted(glob.glob(os.path.join(args.src, "*.txt")))
    if not scores:
        print(f"mkpublicbank: FAIL no scores in {args.src}")
        return 2
    folder = os.path.join(args.out, "public")
    os.makedirs(folder, exist_ok=True)
    keep = {os.path.splitext(os.path.basename(s))[0] for s in scores}
    for old in glob.glob(os.path.join(folder, "*.sid")) + glob.glob(os.path.join(folder, "*.info")):
        if os.path.splitext(os.path.basename(old))[0] not in keep:
            os.remove(old)
    for s in scores:
        stem = os.path.splitext(os.path.basename(s))[0]
        if len(stem) > NAME_LIMIT:
            print(f"mkpublicbank: note: {stem} is {len(stem)} characters, LOAD\"{stem.upper()}\",9 needs a wildcard")
        rc = mksid.main([s, "-o", os.path.join(folder, stem + ".sid"), "--info", os.path.join(folder, stem + ".info")])
        if rc != 0:
            return 1
    rc = mkbank.main([folder, "-o", os.path.join(args.out, "public.bin")])
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
