#!/usr/bin/env python3
"""Fail closed unless an unpacked TandemClip app is an exact-source disabled rollback."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys


COMMIT = re.compile(r"[0-9a-f]{40}\Z")
MAX_PLIST_BYTES = 1024 * 1024


class Refused(Exception):
    pass


def _regular(path: Path, *, maximum: int | None = None) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise Refused("artifact path is unavailable") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise Refused("artifact path is not a regular file")
    if maximum is not None and not 1 <= metadata.st_size <= maximum:
        raise Refused("artifact file size is invalid")
    return metadata


def _contained_app(app: Path) -> tuple[Path, Path]:
    try:
        if app.is_symlink() or not app.is_dir():
            raise Refused("app is not a real directory")
        contents = app / "Contents"
        macos = contents / "MacOS"
        for component in (contents, macos):
            if component.is_symlink() or not component.is_dir():
                raise Refused("bundle contains an invalid directory")
        plist = contents / "Info.plist"
        _regular(plist, maximum=MAX_PLIST_BYTES)
        with plist.open("rb") as handle:
            document = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise Refused("bundle metadata is invalid") from exc
    if not isinstance(document, dict):
        raise Refused("bundle metadata is invalid")
    executable_name = document.get("CFBundleExecutable")
    if executable_name != "tandemclip":
        raise Refused("bundle executable identity is invalid")
    executable = macos / executable_name
    _regular(executable)
    try:
        executable.resolve(strict=True).relative_to(app.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise Refused("bundle executable escapes the app") from exc
    return plist, executable


def _commit_plist(repository: Path, commit: str) -> dict[str, object]:
    result = subprocess.run(
        ["git", "-C", str(repository), "cat-file", "-e", f"{commit}^{{commit}}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise Refused("expected source commit is unavailable")
    result = subprocess.run(
        ["git", "-C", str(repository), "show", f"{commit}:Packaging/Info.plist"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0 or not 1 <= len(result.stdout) <= MAX_PLIST_BYTES:
        raise Refused("source metadata is unavailable")
    try:
        document = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException as exc:
        raise Refused("source metadata is invalid") from exc
    if not isinstance(document, dict):
        raise Refused("source metadata is invalid")
    return document


def verify(repository: Path, app: Path, commit: str) -> Path:
    if COMMIT.fullmatch(commit) is None:
        raise Refused("expected source commit is invalid")
    plist, executable = _contained_app(app)
    with plist.open("rb") as handle:
        document = plistlib.load(handle)
    source = _commit_plist(repository, commit)
    if document.get("CFBundleIdentifier") != "com.tandemclip":
        raise Refused("bundle identifier is invalid")
    if document.get("TandemClipSourceCommit") != commit:
        raise Refused("bundle source identity does not match")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = document.get(key)
        if not isinstance(value, str) or not value or value != source.get(key):
            raise Refused("bundle version does not match the source commit")
    if document.get("CrashboxDSN") not in (None, ""):
        raise Refused("rollback retains Crashbox reporting configuration")
    if document.get("SentryDSN") not in (None, ""):
        raise Refused("rollback retains hosted reporting configuration")
    return executable


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("commit")
    args = parser.parse_args()
    try:
        executable = verify(args.repository, args.app, args.commit)
    except Refused as exc:
        print(f"TandemClip rollback refused: {exc}", file=sys.stderr)
        return 1
    print(f"rollback metadata verified: source={args.commit} executable={executable.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
