#!/usr/bin/env python3
"""Refuse a release dSYM that cannot source-map its native crash probe."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


SYMBOL = "tandemclipCrashboxTestCrash"
SOURCE_BASENAME = "CrashReporting.swift"
SOURCE_PATH = "source/Sources/tandemclip/CrashReporting.swift"
MAX_TOOL_OUTPUT = 1_048_576
TOOL_TIMEOUT_SECONDS = 15
MAX_PROBE_BYTES = 4096


class ProofError(RuntimeError):
    """The dSYM cannot prove source-level symbolication for the probe."""


def _run(argv: list[str]) -> str:
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=TOOL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProofError(f"{Path(argv[0]).name} could not inspect the dSYM") from exc
    output = completed.stdout + completed.stderr
    if len(output.encode("utf-8")) > MAX_TOOL_OUTPUT:
        raise ProofError(f"{Path(argv[0]).name} returned too much output")
    if completed.returncode != 0:
        raise ProofError(
            f"{Path(argv[0]).name} refused the dSYM (status {completed.returncode})"
        )
    return output


def _dwarf_binary(dsym: Path) -> Path:
    if dsym.is_symlink() or not dsym.is_dir():
        raise ProofError("dSYM is missing, not a directory, or is a symlink")
    root = dsym / "Contents" / "Resources" / "DWARF"
    if root.is_symlink() or not root.is_dir():
        raise ProofError("dSYM has no safe DWARF directory")
    members = [
        path
        for path in root.iterdir()
        if path.is_file() and not path.is_symlink()
    ]
    if len(members) != 1:
        raise ProofError("dSYM must contain exactly one regular DWARF binary")
    return members[0]


def _fault_line(source: Path) -> int:
    if (
        source.name != SOURCE_BASENAME
        or source.is_symlink()
        or not source.is_file()
    ):
        raise ProofError("native crash-probe source is missing or is a symlink")
    if source.stat().st_size > MAX_TOOL_OUTPUT:
        raise ProofError("native crash-probe source is too large")
    lines = source.read_text(encoding="utf-8").splitlines()
    matches = [
        number
        for number, line in enumerate(lines, start=1)
        if line.strip() == "address.pointee = 0"
    ]
    if len(matches) != 1:
        raise ProofError("native crash probe must contain exactly one faulting write")
    return matches[0]


def verify(dsym: Path, source: Path, *, dwarfdump: str) -> tuple[str, int]:
    _dwarf_binary(dsym)
    expected_line = _fault_line(source)
    listing = _run([dwarfdump, "--name", SYMBOL, str(dsym)])
    stable_linkages = re.findall(
        rf'DW_AT_linkage_name\s+\("{SYMBOL}"\)', listing
    )
    if len(stable_linkages) != 1:
        raise ProofError(
            "dSYM must contain exactly one stable TandemClip crash-probe linkage"
        )
    candidates: list[tuple[int, int]] = []
    for block in re.split(r"(?m)(?=^0x[0-9a-fA-F]+: DW_TAG_subprogram$)", listing):
        if not re.search(rf'DW_AT_name\s+\("{SYMBOL}"\)', block):
            continue
        source = re.search(r'DW_AT_decl_file\s+\("([^"]+)"\)', block)
        line = re.search(r"DW_AT_decl_line\s+\(([0-9]+)\)", block)
        address = re.search(r"DW_AT_low_pc\s+\(0x([0-9a-fA-F]+)\)", block)
        high = re.search(r"DW_AT_high_pc\s+\(0x([0-9a-fA-F]+)\)", block)
        if source is None or line is None or address is None or high is None:
            continue
        if source.group(1) != SOURCE_PATH:
            continue
        if int(line.group(1)) <= 0:
            continue
        candidates.append((int(address.group(1), 16), int(high.group(1), 16)))
    if len(candidates) != 1:
        raise ProofError(
            "dSYM must contain exactly one source-backed TandemClip crash-probe function"
        )

    low, high = candidates[0]
    if high <= low or high - low > MAX_PROBE_BYTES or low % 4 or high % 4:
        raise ProofError("native crash-probe machine-code range is unsafe or unbounded")
    valid = False
    for address in range(low, high, 4):
        lookup = _run([dwarfdump, "--lookup", f"0x{address:x}", str(dsym)])
        line_matches = re.findall(r"Line info: file '([^']+)', line ([0-9]+)", lookup)
        if any(
            path == SOURCE_BASENAME
            and int(line) == expected_line
            for path, line in line_matches
        ):
            valid = True
            break
    if not valid:
        raise ProofError(
            "faulting write has no real CrashReporting.swift dSYM source line"
        )
    return SOURCE_PATH, expected_line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dsym", type=Path)
    parser.add_argument(
        "--source", type=Path, default=Path("Sources/tandemclip/CrashReporting.swift")
    )
    parser.add_argument("--dwarfdump", default="dwarfdump")
    args = parser.parse_args(argv)
    try:
        source, line = verify(args.dsym, args.source, dwarfdump=args.dwarfdump)
    except ProofError as exc:
        print(f"dSYM source proof refused: {exc}", file=sys.stderr)
        return 1
    print(f"dSYM source proof verified: {SYMBOL} ({source}:{line})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
