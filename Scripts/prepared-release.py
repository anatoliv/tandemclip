#!/usr/bin/env python3
"""Write or verify the immutable files that cross TandemClip's upload pause."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from typing import Any


MAX_MANIFEST_BYTES = 16_384
MAX_TRACKED_FILES = 10_000
MAX_APP_ENTRIES = 20_000
MAX_TOTAL_BYTES = 1_073_741_824
MAX_FILE_BYTES = 1_073_741_824
MAX_METADATA_FILE_BYTES = 16_777_216
SOURCE_COMMIT = re.compile(r"[0-9a-f]{40}\Z")
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*\Z")
BUILD = re.compile(r"[0-9]+\Z")
RELEASE = re.compile(r"com\.tandemclip@[0-9]+(?:\.[0-9]+)*\+[0-9]+\.[0-9a-f]{40}\Z")
EXPECTED_KEYS = {
    "schema",
    "source_commit",
    "version",
    "build",
    "release",
    "tracked_tree",
    "app",
    "files",
}
EXPECTED_FILES = {
    "dsym_archive",
    "dmg",
    "appcast",
    "cask",
    "site",
    "supporters",
}


class Refused(Exception):
    """A stable refusal that never prints file content or a supplied digest."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise ValueError("duplicate key")
        document[key] = value
    return document


def _field(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _held_regular_file(path: Path, maximum: int) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise Refused("prepared_file_unavailable") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise Refused("prepared_file_not_regular")
        if not 1 <= metadata.st_size <= maximum:
            raise Refused("prepared_file_size_invalid")
        return descriptor, metadata
    except Exception:
        os.close(descriptor)
        raise


def _regular_file(path: Path, maximum: int) -> dict[str, Any]:
    descriptor, before = _held_regular_file(path, maximum)
    digest = hashlib.sha256()
    total = 0
    try:
        while chunk := os.read(descriptor, 1024 * 1024):
            total += len(chunk)
            if total > maximum:
                raise Refused("prepared_file_size_invalid")
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            total != before.st_size
            or after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise Refused("prepared_file_changed_during_read")
    finally:
        os.close(descriptor)
    return {"bytes": total, "sha256": digest.hexdigest()}


def _optional_regular_file(path: Path, maximum: int) -> dict[str, Any] | None:
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Refused("prepared_file_unavailable") from exc
    return _regular_file(path, maximum)


def _tree_once(root: Path, *, maximum_entries: int, maximum_bytes: int) -> dict[str, Any]:
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        raise Refused("prepared_tree_unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise Refused("prepared_tree_not_directory")

    entries: list[Path] = []
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda entry: os.fsencode(entry.name))
        except OSError as exc:
            raise Refused("prepared_tree_unavailable") from exc
        for child in children:
            path = Path(child.path)
            entries.append(path)
            if len(entries) > maximum_entries:
                raise Refused("prepared_tree_entries_invalid")
            if child.is_dir(follow_symlinks=False):
                stack.append(path)

    digest = hashlib.sha256()
    total = 0
    for path in sorted(entries, key=lambda item: os.fsencode(str(item.relative_to(root)))):
        relative = os.fsencode(str(path.relative_to(root)))
        if not relative or len(relative) > 4096:
            raise Refused("prepared_tree_path_invalid")
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise Refused("prepared_tree_unavailable") from exc
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            kind = b"directory"
            body = b""
        elif stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            try:
                body = os.fsencode(os.readlink(path))
            except OSError as exc:
                raise Refused("prepared_tree_unavailable") from exc
            if not body or len(body) > 4096:
                raise Refused("prepared_tree_link_invalid")
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"file"
            file_snapshot = _regular_file(path, maximum_bytes)
            total += file_snapshot["bytes"]
            if total > maximum_bytes:
                raise Refused("prepared_tree_size_invalid")
            body = bytes.fromhex(file_snapshot["sha256"])
        else:
            raise Refused("prepared_tree_entry_invalid")
        _field(digest, kind)
        _field(digest, relative)
        _field(digest, str(mode).encode("ascii"))
        _field(digest, body)
    return {"bytes": total, "entries": len(entries), "sha256": digest.hexdigest()}


def _stable_tree(root: Path, *, maximum_entries: int, maximum_bytes: int) -> dict[str, Any]:
    first = _tree_once(root, maximum_entries=maximum_entries, maximum_bytes=maximum_bytes)
    second = _tree_once(root, maximum_entries=maximum_entries, maximum_bytes=maximum_bytes)
    if first != second:
        raise Refused("prepared_tree_changed_during_read")
    return first


def _tracked_paths(repository: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "ls-files", "-z"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise Refused("repository_unavailable") from exc
    if len(result.stdout) > 4 * 1024 * 1024:
        raise Refused("tracked_tree_entries_invalid")
    raw_paths = result.stdout.split(b"\0")
    if raw_paths and raw_paths[-1] == b"":
        raw_paths.pop()
    if not 1 <= len(raw_paths) <= MAX_TRACKED_FILES or len(set(raw_paths)) != len(raw_paths):
        raise Refused("tracked_tree_entries_invalid")
    paths: list[Path] = []
    for raw in raw_paths:
        path = Path(os.fsdecode(raw))
        if path.is_absolute() or not path.parts or ".." in path.parts:
            raise Refused("tracked_tree_path_invalid")
        paths.append(path)
    return sorted(paths, key=lambda item: os.fsencode(str(item)))


def _tracked_tree_once(repository: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    total = 0
    paths = _tracked_paths(repository)
    for relative in paths:
        path = repository / relative
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise Refused("tracked_tree_unavailable") from exc
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            try:
                body = os.fsencode(os.readlink(path))
            except OSError as exc:
                raise Refused("tracked_tree_unavailable") from exc
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"file"
            file_snapshot = _regular_file(path, MAX_TOTAL_BYTES)
            total += file_snapshot["bytes"]
            if total > MAX_TOTAL_BYTES:
                raise Refused("tracked_tree_size_invalid")
            body = bytes.fromhex(file_snapshot["sha256"])
        else:
            raise Refused("tracked_tree_entry_invalid")
        _field(digest, kind)
        _field(digest, os.fsencode(str(relative)))
        _field(digest, str(mode).encode("ascii"))
        _field(digest, body)
    return {"bytes": total, "entries": len(paths), "sha256": digest.hexdigest()}


def _tracked_tree(repository: Path) -> dict[str, Any]:
    first = _tracked_tree_once(repository)
    second = _tracked_tree_once(repository)
    if first != second:
        raise Refused("tracked_tree_changed_during_read")
    return first


def _head(repository: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            text=True,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise Refused("repository_unavailable") from exc
    return result.stdout.strip()


def snapshot(args: argparse.Namespace) -> dict[str, Any]:
    if (
        SOURCE_COMMIT.fullmatch(args.source_commit) is None
        or VERSION.fullmatch(args.version) is None
        or BUILD.fullmatch(args.build) is None
        or RELEASE.fullmatch(args.release) is None
        or args.release != f"com.tandemclip@{args.version}+{args.build}.{args.source_commit}"
        or _head(args.repository) != args.source_commit
    ):
        raise Refused("prepared_identity_invalid")
    files = {
        "dsym_archive": _regular_file(args.dsym_archive, MAX_FILE_BYTES),
        "dmg": _regular_file(args.dmg, MAX_FILE_BYTES),
        "appcast": _regular_file(args.appcast, MAX_METADATA_FILE_BYTES),
        "cask": _regular_file(args.cask, MAX_METADATA_FILE_BYTES),
        "site": _regular_file(args.site, MAX_METADATA_FILE_BYTES),
        "supporters": _optional_regular_file(args.supporters, MAX_METADATA_FILE_BYTES),
    }
    return {
        "schema": 1,
        "source_commit": args.source_commit,
        "version": args.version,
        "build": args.build,
        "release": args.release,
        "tracked_tree": _tracked_tree(args.repository),
        "app": _stable_tree(
            args.app,
            maximum_entries=MAX_APP_ENTRIES,
            maximum_bytes=MAX_TOTAL_BYTES,
        ),
        "files": files,
    }


def _read_manifest(path: Path) -> dict[str, Any]:
    descriptor, before = _held_regular_file(path, MAX_MANIFEST_BYTES)
    try:
        payload = os.read(descriptor, before.st_size + 1)
        after = os.fstat(descriptor)
        if (
            len(payload) != before.st_size
            or after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise Refused("prepared_manifest_changed_during_read")
    finally:
        os.close(descriptor)
    try:
        document = json.loads(payload, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise Refused("prepared_manifest_invalid") from exc
    if (
        not isinstance(document, dict)
        or set(document) != EXPECTED_KEYS
        or not isinstance(document.get("files"), dict)
        or set(document["files"]) != EXPECTED_FILES
    ):
        raise Refused("prepared_manifest_invalid")
    return document


def write_manifest(path: Path, document: dict[str, Any]) -> None:
    payload = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(payload) > MAX_MANIFEST_BYTES:
        raise Refused("prepared_manifest_size_invalid")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as exc:
        raise Refused("prepared_manifest_unavailable") from exc
    try:
        written = os.write(descriptor, payload)
        if written != len(payload):
            raise Refused("prepared_manifest_write_failed")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verify_manifest(path: Path, current: dict[str, Any]) -> None:
    if _read_manifest(path) != current:
        raise Refused("prepared_release_mismatch")


def _arguments() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "verify"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--dsym-archive", type=Path, required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--cask", type=Path, required=True)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--supporters", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--release", required=True)
    return parser


def main() -> int:
    args = _arguments().parse_args()
    try:
        current = snapshot(args)
        if args.action == "write":
            write_manifest(args.manifest, current)
            message = "prepared release recorded"
        else:
            verify_manifest(args.manifest, current)
            message = "prepared release verified"
    except Refused as exc:
        print(f"TandemClip prepared release refused: {exc}", file=os.sys.stderr)
        return 1
    print(message + ": exact tree, app, dSYM archive, DMG, appcast, cask, and site")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
