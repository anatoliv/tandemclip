#!/usr/bin/env python3
"""Verify that Crashbox accepted this exact release's dSYM archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any
from uuid import UUID


MAX_RECEIPT_BYTES = 8_192
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
RELEASE = re.compile(r"com\.tandemclip@[0-9]+(?:\.[0-9]+)*\+[0-9]+\.[0-9a-f]{40}\Z")
EXPECTED_KEYS = {
    "artifact_id",
    "project_id",
    "release",
    "sha256",
    "state",
    "type",
}


class Refused(Exception):
    """One stable refusal that never prints receipt or artifact content."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise ValueError("duplicate key")
        document[key] = value
    return document


def _held_regular_file(path: Path, maximum: int) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise Refused("file_unavailable") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise Refused("file_not_regular")
        if not 1 <= metadata.st_size <= maximum:
            raise Refused("file_size_invalid")
        return descriptor, metadata
    except Exception:
        os.close(descriptor)
        raise


def _read_receipt(path: Path) -> dict[str, str]:
    descriptor, before = _held_regular_file(path, MAX_RECEIPT_BYTES)
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
            raise Refused("receipt_changed_during_read")
    finally:
        os.close(descriptor)
    try:
        document = json.loads(payload, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise Refused("receipt_invalid") from exc
    if (
        not isinstance(document, dict)
        or set(document) != EXPECTED_KEYS
        or not all(isinstance(value, str) for value in document.values())
    ):
        raise Refused("receipt_invalid")
    return document


def _digest(path: Path) -> str:
    descriptor, before = _held_regular_file(path, MAX_ARCHIVE_BYTES)
    digest = hashlib.sha256()
    try:
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise Refused("archive_changed_during_read")
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def verify(receipt_path: Path, archive_path: Path, release: str, project_id: str) -> None:
    if RELEASE.fullmatch(release) is None:
        raise Refused("release_invalid")
    try:
        normalized_project = str(UUID(project_id))
    except (TypeError, ValueError) as exc:
        raise Refused("project_invalid") from exc
    if normalized_project != project_id:
        raise Refused("project_invalid")

    document = _read_receipt(receipt_path)
    try:
        normalized_artifact = str(UUID(document["artifact_id"]))
    except (TypeError, ValueError) as exc:
        raise Refused("receipt_invalid") from exc
    if normalized_artifact != document["artifact_id"]:
        raise Refused("receipt_invalid")
    if (
        document["project_id"] != project_id
        or document["release"] != release
        or document["sha256"] != _digest(archive_path)
        or document["state"] != "ready"
        or document["type"] != "apple_dsym"
    ):
        raise Refused("receipt_mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    try:
        verify(args.receipt, args.archive, args.release, args.project)
    except Refused as exc:
        print(f"Crashbox artifact receipt refused: {exc}", file=os.sys.stderr)
        return 1
    print("Crashbox artifact receipt ok: exact project, release, archive, and ready state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
