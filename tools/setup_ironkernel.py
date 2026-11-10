#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# setup_ironkernel.py -- installs the IronKernel network sources: the private ik64 netcore repository
#   into ironkernel/ and the RTLNet trees into ironkernel/src/
#
# Role: ironkernel/ is a separate private git repository (never part of this repository): the
#   ik64_net_core wrapper, the netlist and firmware library build scripts and the network firmware
#   glue. ironkernel/src/ is not committed anywhere. The public repository carries the prebuilt
#   netlist (fpga/netlist/ik64_net_core.dcp) and firmware library (fw_1541/lib/libik64_netcore.a);
#   this tool pulls what they are built from (ironkernel/build_netcore.ps1 and
#   ironkernel/build_fwlib.ps1 read it).
#
# Steps:
#   1. When ironkernel/.git is missing, clone the repository named by "netcore_repo" in
#      tools/ironkernel.json. A URL still reading "OWNER TO SET", or a refused clone (private
#      repository, no credentials), ends the run with one clear line.
#   2. Install the RTLNet trees of tools/ironkernel.json through tools/setup_third_party.py (manifest
#      tools/ironkernel.json, notes tools/ironkernel/<name>.SOURCE.txt, root ironkernel/src/).
#      Fetch order: the sibling checkout C:/IronKernel/RTLNet when present, else the private GitHub
#      repository with the user's own git credentials. When it refuses them, one line says the
#      repository is private and the prebuilt files suffice.
#
# Usage (same options as setup_third_party.py):
#   python -I tools/setup_ironkernel.py                 install or verify everything
#   python -I tools/setup_ironkernel.py --check         verify installed trees, fetch nothing
#   python -I tools/setup_ironkernel.py --update-hashes record digests after a version bump
#   python -I tools/setup_ironkernel.py --only rtlnet   one RTLNet entry
#
# Exit codes: as setup_third_party.py (0 ok, 1 digest mismatch, 2 fetch or clone failure, 3 usage).
#
# Revision:
#   11-09-2026  first version
#   11-09-2026  clones the private ironkernel/ repository when missing

import json
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import setup_third_party as stp  # noqa: E402  (after the sys.path insert)

REPO = stp.REPO
MANIFEST = REPO / "tools" / "ironkernel.json"
PLACEHOLDER = "OWNER TO SET"


def ensure_netcore_repo(check_only):
    """ensure_netcore_repo -- makes sure ironkernel/ is a git repository, cloning it when missing.

    Returns: 0 when present or cloned, else an exit code (message printed).
    """
    spec = json.loads(MANIFEST.read_text(encoding="utf-8")).get("netcore_repo")
    if spec is None:
        return 0
    dest = REPO / spec.get("dest", "ironkernel")
    if (dest / ".git").exists():
        return 0
    if check_only:
        print("IRONKERNEL: FAIL: %s is not a git repository (run without --check to clone)" % dest.name)
        return stp.EXIT_MISMATCH
    url = spec.get("url", "")
    if not url or url.startswith(PLACEHOLDER):
        print("IRONKERNEL: FAIL: %s/ is missing and tools/ironkernel.json has no URL for it yet (%s)"
              % (dest.name, PLACEHOLDER))
        return stp.EXIT_USAGE
    if dest.exists() and any(dest.iterdir()):
        print("IRONKERNEL: FAIL: %s/ exists without .git; move it away and rerun" % dest.name)
        return stp.EXIT_USAGE
    res = subprocess.run(["git", "clone", "-q", url, str(dest)], capture_output=True, text=True)
    if res.returncode != 0:
        print("IRONKERNEL: FAIL: %s is a private repository and git refused your credentials; the netlist "
              "and library committed in this repository are prebuilt, so nothing here needs it." % url)
        return stp.EXIT_FETCH
    print("ironkernel  cloned %s" % url)
    return 0


def main(argv):
    """main -- clones the private repository if needed, then runs setup_third_party on the RTLNet manifest.

    Returns: process exit code.
    """
    rc = ensure_netcore_repo("--check" in argv)
    if rc != 0:
        return rc
    stp.MANIFEST = MANIFEST
    stp.NOTES_DIR = REPO / "tools" / "ironkernel"
    stp.TOOL_NAME = "tools/setup_ironkernel.py"
    stp.LABEL = "IRONKERNEL"
    return stp.main(argv, dest_default=REPO / "ironkernel" / "src")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
