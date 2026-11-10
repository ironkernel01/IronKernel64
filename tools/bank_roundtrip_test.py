"""
File: bank_roundtrip_test.py
Purpose: round trip of the device 9 bank: tools/mkbank.py packs a temporary folder of small
  synthetic PSID files made here, then build/bank_host_test.exe (the C parser, backend_ram and
  cbmdos of the firmware) parses the image and serves every file back byte for byte.
Usage: python -I tools/bank_roundtrip_test.py [+INJECT_FAILURE]
  Build the C test first (command in tools/bank_host_test.c). +INJECT_FAILURE flips one image byte
  before the C parse, so the run must fail (negative control).
Also checks: an RSID file is rejected with a message, a non-PSID .sid is rejected, an image over
  the limit fails and writes nothing, names sort case-insensitively, a name over 31 bytes fails.
Prints "TEST PASS: bank_roundtrip" or "TEST FAIL" (exit 1).
No tune data is involved: the files are generated here and deleted with the temp folder.
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MKBANK = os.path.join(HERE, "mkbank.py")
EXE = os.path.join(HERE, "..", "build", "bank_host_test.exe")
PSID_HEADER = 0x7C

errors = 0
checks = 0


def check(ok, what):
    global errors, checks
    checks += 1
    if not ok:
        errors += 1
        print(f"  CHECK FAILED: {what}")


def psid(seed, payload_len, magic=b"PSID"):
    """A syntactically plausible PSID: 124-byte v2 header, then payload bytes from the seed."""
    head = magic + struct.pack(">HHHHHHI", 2, PSID_HEADER, 0, 0x1000, 0, 1, 1) + b"\0" * (PSID_HEADER - 18)
    head = head[:PSID_HEADER]
    return head + bytes((seed * 13 + i * 5) & 0xFF for i in range(payload_len))


def run_mkbank(folder, out, extra=()):
    return subprocess.run([sys.executable, "-I", MKBANK, folder, "-o", out, *extra],
                          capture_output=True, text=True)


def main():
    inject = "+INJECT_FAILURE" in sys.argv
    with tempfile.TemporaryDirectory() as tmp:
        folder = os.path.join(tmp, "tunes")
        os.mkdir(folder)
        spec = [("zeta.sid", 3, 100), ("Alpha.sid", 1, 1), ("beta.SID", 2, 1000), ("Gamma_Long_Name.sid", 4, 4001),
                ("notes.txt", 9, 10)]
        for name, seed, n in spec:
            with open(os.path.join(folder, name), "wb") as f:
                f.write(psid(seed, n) if name.lower().endswith(".sid") else b"text")
        out = os.path.join(tmp, "bank.bin")
        r = run_mkbank(folder, out)
        check(r.returncode == 0, "mkbank packs the folder")
        check("4 tunes" in r.stdout, "mkbank skips the .txt file and reports 4 tunes")
        order = ["Alpha.sid", "beta.SID", "Gamma_Long_Name.sid", "zeta.sid"]
        names = [line.split()[0] for line in r.stdout.splitlines()[1:5]]
        check(names == order, f"case-insensitive name order {names}")

        files = [os.path.join(folder, n) for n in order]
        cmd = [EXE, "--image", out]
        for f in files:
            cmd += ["--file", f]
        if inject:
            cmd.append("+INJECT_FAILURE")
        c = subprocess.run(cmd, capture_output=True, text=True)
        print(c.stdout.strip())
        check(c.returncode == 0 and "TEST PASS: bank_roundtrip" in c.stdout, "C parser and backend serve the image")

        # Rejections and limits.
        bad = os.path.join(tmp, "rsid")
        os.mkdir(bad)
        with open(os.path.join(bad, "r.sid"), "wb") as f:
            f.write(psid(1, 50, b"RSID"))
        r = run_mkbank(bad, os.path.join(tmp, "r.bin"))
        check(r.returncode == 1 and "RSID" in r.stdout and not os.path.exists(os.path.join(tmp, "r.bin")),
              "RSID rejected with a message, no output")
        junk = os.path.join(tmp, "junk")
        os.mkdir(junk)
        with open(os.path.join(junk, "j.sid"), "wb") as f:
            f.write(b"hello world" * 20)
        r = run_mkbank(junk, os.path.join(tmp, "j.bin"))
        check(r.returncode == 1 and "not a PSID" in r.stdout, "non-PSID rejected")
        r = run_mkbank(folder, os.path.join(tmp, "small.bin"), ["--max-bytes", "2000"])
        check(r.returncode == 1 and "FAIL" in r.stdout and not os.path.exists(os.path.join(tmp, "small.bin")),
              "over the size limit fails and writes nothing")
        longn = os.path.join(tmp, "longname")
        os.mkdir(longn)
        with open(os.path.join(longn, "x" * 30 + ".sid"), "wb") as f:
            f.write(psid(1, 10))
        r = run_mkbank(longn, os.path.join(tmp, "l.bin"))
        check(r.returncode == 1 and "at most 31" in r.stdout, "name over 31 bytes fails")
        empty = os.path.join(tmp, "empty")
        os.mkdir(empty)
        r = run_mkbank(empty, os.path.join(tmp, "e.bin"))
        check(r.returncode == 0 and os.path.getsize(os.path.join(tmp, "e.bin")) == 32, "empty folder packs a 32-byte bank")

    if errors:
        print(f"TEST FAIL: bank_roundtrip_py ({errors} of {checks} checks failed)")
        return 1
    print(f"TEST PASS: bank_roundtrip_py ({checks} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
