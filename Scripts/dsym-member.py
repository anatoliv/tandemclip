#!/usr/bin/env python3
"""Print the sole safe DWARF binary member in a bounded dSYM zip."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_MEMBERS = 4096
MAX_UNCOMPRESSED_BYTES = 512 * 1024 * 1024


def select(path: Path) -> str:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError("archive unavailable") from exc
    if not stat.S_ISREG(metadata.st_mode) or not 1 <= metadata.st_size <= MAX_ARCHIVE_BYTES:
        raise ValueError("archive is not a bounded regular file")
    try:
        with zipfile.ZipFile(path) as bundle:
            members = bundle.infolist()
    except (OSError, zipfile.BadZipFile) as exc:
        raise ValueError("archive is not a readable zip") from exc
    if not members or len(members) > MAX_MEMBERS:
        raise ValueError("archive member count is invalid")
    total = 0
    dwarf: list[str] = []
    for member in members:
        total += member.file_size
        if total > MAX_UNCOMPRESSED_BYTES:
            raise ValueError("archive expansion is too large")
        candidate = PurePosixPath(member.filename)
        if (
            candidate.is_absolute()
            or ".." in candidate.parts
            or "__MACOSX" in candidate.parts
            or stat.S_ISLNK((member.external_attr >> 16) & 0o170000)
        ):
            raise ValueError("archive contains an unsafe member")
        parts = candidate.parts
        if (
            len(parts) == 5
            and parts[0].endswith(".dSYM")
            and parts[1:4] == ("Contents", "Resources", "DWARF")
            and not member.is_dir()
        ):
            dwarf.append(member.filename)
    if len(dwarf) != 1:
        raise ValueError("archive must contain exactly one DWARF binary")
    return dwarf[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        member = select(args.archive)
    except ValueError as exc:
        print(f"dSYM archive refused: {exc}", file=sys.stderr)
        return 1
    print(member)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
