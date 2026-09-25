#!/usr/bin/env python3
"""Guard against silently destroying the Chinese text in the documents.

The documents in this repository are UTF-8 and mostly written in Chinese.
Windows PowerShell 5.1's `Set-Content` / `Add-Content` / `Out-File` default to
the ANSI code page, so an edit that reads a document as text and writes it back
replaces every Chinese character with a literal `?` - no error, no warning, and
the commit looks perfectly ordinary. That already happened once: commit
`cc88c13` turned 16083 non-ASCII bytes of `docs/capture_and_quantify.md` into
5184 question marks, and it was only noticed days later.

This walks every text file through the whole history and flags any revision
where the file's non-ASCII byte count collapsed relative to the revision that
came before it. A wipe-out that a later revision already repaired is reported as
history and does not fail the run; one that is still missing text exits 1, so the
script can gate a push. Run it after any bulk text edit.

    python tools/doc_health.py                  # scan the whole history
    python tools/doc_health.py --rev HEAD~5..HEAD
    python tools/doc_health.py --paths docs/
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

TEXT_SUFFIXES = (
    ".md", ".txt", ".py", ".ps1", ".v", ".sv", ".svh", ".tcl", ".bat",
    ".mem", ".json", ".csv", ".yml", ".yaml",
)

# A file may legitimately shrink, so only flag a real wipe-out: it had plenty of
# non-ASCII text before and now has none at all.
MIN_BEFORE = 200


def git(repo: Path, args: list[str], check: bool = True) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, check=False
    )
    if check and result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise SystemExit(f"git {' '.join(args)} failed: {message}")
    return result.stdout


def non_ascii(blob: bytes) -> int:
    return sum(1 for byte in blob if byte > 127)


def list_files(repo: Path, rev: str, prefixes: list[str]) -> list[str]:
    names = git(repo, ["ls-tree", "-r", "--name-only", rev]).decode("utf-8").split()
    # "." and "" mean the whole tree; keeping them as literal prefixes would
    # match nothing, because git prints paths without a leading "./".
    prefixes = [p for p in prefixes if p not in (".", "")]
    return [
        name
        for name in names
        if name.endswith(TEXT_SUFFIXES)
        and (not prefixes or any(name.startswith(p) for p in prefixes))
    ]


def revisions(repo: Path, revspec: str | None, path: str) -> list[str]:
    args = ["log", "--format=%h"]
    args.append(revspec if revspec else "--all")
    args += ["--", path]
    return git(repo, args).decode().split()


def blob_series(repo: Path, path: str, revs: list[str]) -> list[bytes]:
    """Fetch many blobs of one path in a single `git cat-file --batch` call.

    One subprocess per blob made a full-history scan take minutes on Windows;
    this brings it down to one call per file.
    """
    request = "".join(f"{rev}:{path}\n" for rev in revs).encode()
    out = subprocess.run(
        ["git", "-C", str(repo), "cat-file", "--batch"],
        input=request,
        capture_output=True,
        check=True,
    ).stdout
    blobs: list[bytes] = []
    pos = 0
    while pos < len(out):
        end = out.index(b"\n", pos)
        parts = out[pos:end].split()
        if len(parts) >= 3 and parts[1] == b"blob":
            size = int(parts[2])
            blobs.append(out[end + 1 : end + 1 + size])
            pos = end + 1 + size + 1
        else:  # "<name> missing" - the path did not exist in that revision
            blobs.append(b"")
            pos = end + 1
    return blobs


def scan(repo: Path, paths: list[str], revspec: str | None):
    """Return (path, revision, non_ascii_before, non_ascii_after) for wipe-outs."""
    findings = []
    files = list_files(repo, "HEAD", paths)
    print(f"scanning {len(files)} text files under {paths} ...")
    for path in files:
        revs = revisions(repo, revspec, path)
        blobs = blob_series(repo, path, revs)
        previous = None
        # `git log` is newest first; walk oldest first so `previous` really is the
        # revision that came before `rev`.
        for rev, blob in zip(reversed(revs), reversed(blobs)):
            if not blob:
                continue
            if previous is not None:
                before, after = non_ascii(previous), non_ascii(blob)
                if before >= MIN_BEFORE and after == 0:
                    findings.append((path, rev, before, after))
            previous = blob
    return findings


def last_healthy(repo: Path, path: str, bad_rev: str) -> str:
    """The newest revision older than `bad_rev` whose blob still had non-ASCII."""
    revs = revisions(repo, None, path)
    if bad_rev in revs:
        revs = revs[revs.index(bad_rev) + 1 :]
    for rev in revs:
        blob = git(repo, ["cat-file", "blob", f"{rev}:{path}"], check=False)
        if blob and non_ascii(blob) > 0:
            return rev
    return bad_rev + "~1"


def restoring_revision(repo: Path, path: str, bad_rev: str):
    """A revision newer than `bad_rev` that put non-ASCII text back, if any.

    A wipe-out that a later commit already repaired is history, not a live bug,
    so the scan reports it but does not fail on it. Without this the tool would
    stay red forever, the day after it caught the first real case.
    """
    revs = revisions(repo, None, path)
    if bad_rev not in revs:
        return None
    for rev in revs[: revs.index(bad_rev)]:
        blob = git(repo, ["cat-file", "blob", f"{rev}:{path}"], check=False)
        if blob and non_ascii(blob) > 0:
            return rev
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None, help="repository root (default: parent of tools/)")
    parser.add_argument("--paths", default=".", help="comma list of directory prefixes to scan")
    parser.add_argument("--rev", default=None, help="git revspec, e.g. HEAD~5..HEAD (default: all)")
    args = parser.parse_args()

    repo = Path(args.repo) if args.repo else Path(__file__).resolve().parent.parent
    if not (repo / ".git").exists():
        raise SystemExit(f"not a git repository: {repo}")
    paths = [p for p in args.paths.split(",") if p]

    findings = scan(repo, paths, args.rev)
    if not findings:
        print("no non-ASCII wipe-out found in the scanned history")
        return 0

    live = []
    print()
    for path, rev, before, after in findings:
        fixed = restoring_revision(repo, path, rev)
        if fixed:
            print(
                f"already repaired  {rev}  {path}: {before} -> {after} non-ASCII "
                f"bytes, text is back as of {fixed}"
            )
        else:
            live.append((path, rev, before, after))

    if not live:
        print()
        print("no unrepaired wipe-out: every finding above has been restored already")
        return 0

    print()
    print("NON-ASCII TEXT IS STILL MISSING - the file has '?' where Chinese used to be:")
    for path, rev, before, after in live:
        print(f"  {rev}  {path}: {before} -> {after} non-ASCII bytes")
    print()
    print("Recover the last healthy revision of each file with:")
    for path, rev, _, _ in live:
        previous = last_healthy(repo, path, rev)
        print(f'  git cat-file blob {previous}:{path} > "{path}"')
    return 1


if __name__ == "__main__":
    sys.exit(main())
