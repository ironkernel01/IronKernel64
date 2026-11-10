"""
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 IronKernel

File: public_bank_test.py
Purpose: build the public bank (tools/mkpublicbank.py), build tools/sid_host_test.c with gcc (MSYS2 UCRT64) and
  run it on every generated tune: the real core 0 PSID loader, 6502 and memory map play each tune for two
  loops, the notes are compared with the score, and every tune is rendered to build/bank/wav/<tune>.wav with
  the firmware's software SID (fw_c64/src/sid.c, 48 kHz mono 16 bit, 6581). Then the negative control
  (+INJECT_FAILURE) must fail, and the packed bank must parse and serve every tune byte for byte
  (build/bank_host_test.exe --image, the C parser and cbmdos of core 1; skipped with a note when that
  executable is not built).
Usage: python -I tools/public_bank_test.py [+INJECT_FAILURE]
  With +INJECT_FAILURE the positive run is replaced by the negative control alone (must print TEST FAIL).
Prints "TEST PASS: public_bank" or "TEST FAIL" (exit 1). Run from the repository root.
Revision: 11-10-2026
  * 11-10-2026: initial version.
"""
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
GCC_DIRS = [r"C:\msys64\ucrt64\bin"]
SRC = ["tools/sid_host_test.c", "fw_c64/src/psid.c", "fw_c64/src/c64mem.c", "fw_c64/src/cpu6502.c",
       "fw_c64/src/sid.c", "fw_c64/src/sid_tables.c"]
EXE = os.path.join(ROOT, "build", "sid_host_test.exe")
BANK_EXE = os.path.join(ROOT, "build", "bank_host_test.exe")


def find_gcc():
    env = dict(os.environ)
    for d in GCC_DIRS:
        if os.path.isdir(d):
            env["PATH"] = d + os.pathsep + env.get("PATH", "")
    exe = shutil.which("gcc", path=env["PATH"])
    return exe, env


def run(cmd, env=None):
    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main(argv):
    inject = "+INJECT_FAILURE" in argv
    gcc, env = find_gcc()
    if gcc is None:
        print("TEST FAIL: gcc not found (MSYS2 UCRT64 expected at C:\\msys64\\ucrt64\\bin)")
        return 1
    rc, out = run([sys.executable, "-I", "tools/mkpublicbank.py"])
    print(out, end="")
    if rc != 0:
        print("TEST FAIL: bank build")
        return 1
    os.makedirs(os.path.join(ROOT, "build", "bank", "wav"), exist_ok=True)
    rc, out = run([gcc, "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-Ifw_c64/src"] + SRC
                  + ["-o", EXE], env)
    if rc != 0:
        print(out)
        print("TEST FAIL: host test build")
        return 1
    sids = sorted(glob.glob(os.path.join(ROOT, "build", "bank", "public", "*.sid")))
    ok = True
    if not inject:
        rc, out = run([EXE, "--wav-dir", "build/bank/wav"] + sids, env)
        print(out, end="")
        ok = ok and rc == 0 and "TEST PASS: sid_host" in out
    rc, out = run([EXE, "+INJECT_FAILURE"] + sids[:1], env)
    negative_failed = rc != 0 and "TEST FAIL" in out
    print("negative control:", "failed as required" if negative_failed else "DID NOT FAIL")
    if inject:
        print("TEST FAIL: injected failure detected" if negative_failed else "TEST PASS: injection missed")
        return 1 if negative_failed else 0
    ok = ok and negative_failed
    if os.path.exists(BANK_EXE):
        args = [BANK_EXE, "--image", os.path.join("build", "bank", "public.bin")]
        for s in sids:
            args += ["--file", s]
        rc, out = run(args, env)
        print(out.strip().splitlines()[-1] if out.strip() else out)
        ok = ok and rc == 0
    else:
        print("note: build/bank_host_test.exe missing, bank image round trip skipped (build line in tools/bank_host_test.c)")
    print("TEST PASS: public_bank" if ok else "TEST FAIL: public_bank")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
