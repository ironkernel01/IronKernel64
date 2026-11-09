#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# setup_third_party.py -- installs the pinned third-party trees into third_party/
#
# Role: third_party/ is not committed. This tool rebuilds it from tools/third_party.json:
#   for each entry it fetches the pinned commit (git fetch --depth 1), writes the selected
#   files byte-exact from the git blobs (no line-ending conversion, no export attributes),
#   checks the tree digest, writes SOURCE.txt from tools/third_party/<name>.SOURCE.txt and
#   runs the entry's post steps (generated files with fixed SHA-256 values).
#
# Tree digest: SHA-256 over the sorted lines "<installed path>\t<sha256 of file>\n" of the
#   files taken from upstream (SOURCE.txt and post-step outputs are not part of it).
#
# Fetch sources, in order: --mirror NAME=PATH, the sibling checkout ../<sibling> of this
#   repository (entries with "sibling", e.g. C:/IronKernel/RTLNet), then the entry URL.
#   Fetched objects are cached in build/third_party_cache/<name>.
#
# Usage:
#   python -I tools/setup_third_party.py                 install or verify every entry
#   python -I tools/setup_third_party.py --only resid    one entry (repeatable)
#   python -I tools/setup_third_party.py --check         verify installed trees, fetch nothing
#   python -I tools/setup_third_party.py --update-hashes record digests after a version bump
#   python -I tools/setup_third_party.py --dest DIR      install below DIR instead of third_party/
#
# Exit codes: 0 all entries installed and verified, 1 digest or post-step mismatch,
#   2 fetch or git failure, 3 usage or manifest error.
#
# Revision:
#   11-09-2026  first version
#   11-09-2026  --check also verifies the hashes of post-step outputs

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "tools" / "third_party.json"
NOTES_DIR = REPO / "tools" / "third_party"
CACHE_ROOT = REPO / "build" / "third_party_cache"
DEFAULT_DEST = REPO / "third_party"

SOURCE_NAME = "SOURCE.txt"
MODE_SYMLINK = "120000"
MODE_SUBMODULE = "160000"

EXIT_OK = 0
EXIT_MISMATCH = 1
EXIT_FETCH = 2
EXIT_USAGE = 3


class SetupError(Exception):
    """Failure with the exit code that reports it."""

    def __init__(self, code, text):
        super().__init__(text)
        self.code = code


def git(args, cwd, stdin=None):
    """git -- runs git with line-ending conversion off.

    Returns: stdout bytes; raises SetupError(EXIT_FETCH) on a non-zero exit.
    """
    cmd = ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf", *args]
    res = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True)
    if res.returncode != 0:
        raise SetupError(EXIT_FETCH, "git %s failed: %s" % (" ".join(args),
                                                            res.stderr.decode(errors="replace").strip()))
    return res.stdout


def has_commit(cache, commit):
    """has_commit -- tells whether the cache repository already holds the commit.

    Returns: True when the commit object is present.
    """
    res = subprocess.run(["git", "cat-file", "-e", commit + "^{commit}"], cwd=cache,
                         capture_output=True)
    return res.returncode == 0


def fetch(entry, mirrors):
    """fetch -- makes the pinned commit available in build/third_party_cache/<name>.

    Steps: init the cache repository once; skip when the commit is present; otherwise try
    each source (mirror, sibling checkout, URL) with a depth-1 fetch of the commit.
    Returns: the cache path.
    """
    name = entry["name"]
    commit = entry["commit"]
    cache = CACHE_ROOT / name
    if not (cache / ".git").is_dir():
        cache.mkdir(parents=True, exist_ok=True)
        git(["init", "-q"], cache)
    if has_commit(cache, commit):
        return cache
    sources = []
    if name in mirrors:
        sources.append(mirrors[name])
    if entry.get("sibling"):
        sibling = REPO.parent / entry["sibling"]
        if (sibling / ".git").exists():
            sources.append(str(sibling))
    sources.append(entry["url"])
    errors = []
    for src in sources:
        try:
            git(["fetch", "-q", "--depth", "1", "--no-tags", src, commit], cache)
        except SetupError as exc:
            errors.append(str(exc))
            continue
        if has_commit(cache, commit):
            print("  fetched %s from %s" % (commit[:12], src))
            return cache
    raise SetupError(EXIT_FETCH, "%s: commit %s not fetched:\n    %s"
                     % (name, commit, "\n    ".join(errors)))


def list_tree(cache, commit):
    """list_tree -- lists every blob of the commit.

    Returns: dict path -> (mode, object id).
    """
    out = git(["ls-tree", "-r", "-z", "--full-tree", commit], cache)
    tree = {}
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        tree[path.decode("utf-8")] = (mode, kind, oid)
    return tree


def select(entry, tree):
    """select -- maps installed paths to upstream paths for one entry.

    Steps: "files" maps names explicitly; "include" takes every blob under each prefix
    (an empty prefix is the whole tree) at the same relative path.
    Returns: dict installed path -> upstream path.
    """
    picked = {}
    if "files" in entry:
        for dst, src in entry["files"].items():
            if src not in tree:
                raise SetupError(EXIT_USAGE, "%s: %s not in commit" % (entry["name"], src))
            picked[dst] = src
    else:
        for prefix in entry["include"]:
            hits = [p for p in tree if p.startswith(prefix)] if prefix else list(tree)
            if not hits:
                raise SetupError(EXIT_USAGE, "%s: nothing under %s" % (entry["name"], prefix))
            for p in hits:
                if tree[p][0] == MODE_SUBMODULE:
                    print("  skipped submodule %s (not fetched, as a plain clone)" % p)
                    continue
                picked[p] = p
    for dst, src in picked.items():
        mode = tree[src][0]
        if mode == MODE_SUBMODULE:
            raise SetupError(EXIT_USAGE, "%s: %s is a submodule" % (entry["name"], src))
        if dst == SOURCE_NAME:
            raise SetupError(EXIT_USAGE, "%s: upstream file collides with %s"
                             % (entry["name"], SOURCE_NAME))
    return picked


def read_blobs(cache, oids):
    """read_blobs -- reads blob contents through one git cat-file --batch call.

    Returns: dict object id -> bytes.
    """
    unique = sorted(set(oids))
    out = git(["cat-file", "--batch"], cache, stdin=("\n".join(unique) + "\n").encode())
    blobs = {}
    pos = 0
    for oid in unique:
        nl = out.index(b"\n", pos)
        head = out[pos:nl].decode().split()
        if len(head) != 3 or head[0] != oid or head[1] != "blob":
            raise SetupError(EXIT_FETCH, "cat-file: unexpected header %r" % head)
        size = int(head[2])
        blobs[oid] = out[nl + 1:nl + 1 + size]
        pos = nl + 1 + size + 1
    return blobs


def digest(files):
    """digest -- tree digest of installed path -> sha256 hex pairs.

    Returns: hex SHA-256 string.
    """
    h = hashlib.sha256()
    for path in sorted(files):
        h.update(("%s\t%s\n" % (path, files[path])).encode("utf-8"))
    return h.hexdigest()


def sha256_file(path):
    """sha256_file -- SHA-256 of one file.

    Returns: hex string.
    """
    return hashlib.sha256(path.read_bytes()).hexdigest()


def installed_digest(entry, dest):
    """installed_digest -- recomputes the tree digest of an installed entry.

    Steps: every file below dest except SOURCE.txt and declared post-step outputs.
    Returns: hex digest, or None when dest does not exist.
    """
    if not dest.is_dir():
        return None
    skip = {SOURCE_NAME}
    for step in entry.get("post", []):
        skip.update(step.get("outputs", {}))
    files = {}
    for p in dest.rglob("*"):
        if p.is_file():
            rel = p.relative_to(dest).as_posix()
            if rel not in skip:
                files[rel] = sha256_file(p)
    return digest(files)


def run_post(entry, dest):
    """run_post -- runs the entry's post steps and checks their declared outputs.

    Returns: nothing; raises SetupError(EXIT_MISMATCH) on a failed step or hash.
    """
    for step in entry.get("post", []):
        subst = {"python": sys.executable, "repo": REPO.as_posix(), "dest": dest.as_posix()}
        cmd = [arg.format(**subst) for arg in step["run"]]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise SetupError(EXIT_MISMATCH, "%s: post step %s failed:\n%s%s"
                             % (entry["name"], cmd[2:3], res.stdout, res.stderr))
        for out, want in step.get("outputs", {}).items():
            path = dest / out
            if not path.is_file():
                raise SetupError(EXIT_MISMATCH, "%s: post step made no %s" % (entry["name"], out))
            got = sha256_file(path)
            if want and got != want:
                raise SetupError(EXIT_MISMATCH, "%s: %s sha256 %s, expected %s"
                                 % (entry["name"], out, got, want))


def post_current(entry, dest):
    """post_current -- tells whether every declared post-step output exists with its hash.

    Returns: True when all outputs are present and match (an empty hash only needs presence).
    """
    for step in entry.get("post", []):
        for out, want in step.get("outputs", {}).items():
            path = dest / out
            if not (path.is_file() and (not want or sha256_file(path) == want)):
                print("  post output %s missing or changed" % out)
                return False
    return True


def source_bytes(entry):
    """source_bytes -- SOURCE.txt content: the manifest pin plus the committed provenance note.

    Returns: bytes.
    """
    note = NOTES_DIR / ("%s.SOURCE.txt" % entry["name"])
    if not note.is_file():
        raise SetupError(EXIT_USAGE, "%s: missing provenance note %s" % (entry["name"], note))
    head = ("Installed by tools/setup_third_party.py from tools/third_party.json; do not edit.\n"
            "url: %s\ncommit: %s\nlicense: %s\ntree_sha256: %s\n\n"
            % (entry["url"], entry["commit"], entry["license"], entry["tree_sha256"]))
    return (head + note.read_text(encoding="utf-8")).encode("utf-8")


def source_current(entry, dest):
    """source_current -- tells whether the installed SOURCE.txt matches the manifest and note.

    Returns: True when it matches.
    """
    path = dest / SOURCE_NAME
    return path.is_file() and path.read_bytes() == source_bytes(entry)


def install(entry, dest_root, mirrors, update_hashes):
    """install -- installs one entry, or confirms an existing install is current.

    Steps: skip when the installed digest matches the manifest and the post outputs are current;
    otherwise fetch, build the file set in a staging directory, check the digest
    (or record it with --update-hashes), swap the staging directory in, then run post steps.
    Returns: True when the manifest digest changed (only with update_hashes).
    """
    name = entry["name"]
    dest = dest_root / name
    want = entry.get("tree_sha256", "")
    if (want and not update_hashes and installed_digest(entry, dest) == want
            and post_current(entry, dest)):
        if not source_current(entry, dest):
            (dest / SOURCE_NAME).write_bytes(source_bytes(entry))
            print("%-10s SOURCE.txt refreshed" % name)
        print("%-10s up to date (%s)" % (name, entry["commit"][:12]))
        return False
    print("%-10s installing %s" % (name, entry["commit"][:12]))
    cache = fetch(entry, mirrors)
    tree = list_tree(cache, entry["commit"])
    picked = select(entry, tree)
    blobs = read_blobs(cache, [tree[src][2] for src in picked.values()])
    files = {dst: hashlib.sha256(blobs[tree[src][2]]).hexdigest() for dst, src in picked.items()}
    got = digest(files)
    changed = False
    if update_hashes:
        changed = got != want
        entry["tree_sha256"] = got
    elif got != want:
        raise SetupError(EXIT_MISMATCH, "%s: tree digest %s, manifest has %s"
                         % (name, got, want or "(empty; run --update-hashes)"))
    staging = dest_root / (".%s.staging" % name)
    if staging.exists():
        shutil.rmtree(staging)
    for dst, src in picked.items():
        out = staging / dst
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(blobs[tree[src][2]])
    if dest.exists():
        shutil.rmtree(dest)
    staging.rename(dest)
    (dest / SOURCE_NAME).write_bytes(source_bytes(entry))
    run_post(entry, dest)
    print("%-10s installed %d files, tree %s" % (name, len(picked), got[:16]))
    return changed


def check(entry, dest_root):
    """check -- verifies an installed entry against the manifest without fetching.

    Returns: True when the installed digest matches.
    """
    dest = dest_root / entry["name"]
    got = installed_digest(entry, dest)
    ok = got is not None and got == entry.get("tree_sha256") and source_current(entry, dest)
    ok = ok and post_current(entry, dest)
    print("%-10s %s" % (entry["name"], "OK" if ok else ("MISSING" if got is None else "MISMATCH")))
    return ok


def main(argv):
    """main -- parses options and processes the selected entries.

    Returns: process exit code.
    """
    ap = argparse.ArgumentParser(description="Install pinned third-party trees.")
    ap.add_argument("--only", action="append", default=[], help="entry name (repeatable)")
    ap.add_argument("--check", action="store_true", help="verify installed trees only")
    ap.add_argument("--update-hashes", action="store_true", help="record tree digests")
    ap.add_argument("--mirror", action="append", default=[], help="NAME=PATH fetch source")
    ap.add_argument("--dest", default=str(DEFAULT_DEST), help="install root")
    args = ap.parse_args(argv[1:])
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entries = manifest["entries"]
        names = [e["name"] for e in entries]
        for n in args.only:
            if n not in names:
                raise SetupError(EXIT_USAGE, "unknown entry %s (have %s)" % (n, ", ".join(names)))
        mirrors = {}
        for m in args.mirror:
            if "=" not in m:
                raise SetupError(EXIT_USAGE, "--mirror wants NAME=PATH")
            k, v = m.split("=", 1)
            mirrors[k] = v
        dest_root = Path(args.dest).resolve()
        dest_root.mkdir(parents=True, exist_ok=True)
        todo = [e for e in entries if not args.only or e["name"] in args.only]
        if args.check:
            bad = [e["name"] for e in todo if not check(e, dest_root)]
            if bad:
                print("THIRD_PARTY: FAIL (%s)" % ", ".join(bad))
                return EXIT_MISMATCH
            print("THIRD_PARTY: PASS (%d entries)" % len(todo))
            return EXIT_OK
        changed = False
        for e in todo:
            changed |= install(e, dest_root, mirrors, args.update_hashes)
        if args.update_hashes and changed:
            MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            print("tree digests written to %s" % MANIFEST.relative_to(REPO).as_posix())
        print("THIRD_PARTY: PASS (%d entries)" % len(todo))
        return EXIT_OK
    except SetupError as exc:
        print("THIRD_PARTY: FAIL: %s" % exc, file=sys.stderr)
        return exc.code
    except (OSError, ValueError, KeyError) as exc:
        print("THIRD_PARTY: FAIL: %s" % exc, file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv))
