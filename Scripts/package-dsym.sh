#!/usr/bin/env bash
# Package exactly one dSYM without AppleDouble/resource-fork pseudo-members.

set -euo pipefail
SOURCE="${1:?usage: package-dsym.sh DSYM ARCHIVE}"
ARCHIVE="${2:?usage: package-dsym.sh DSYM ARCHIVE}"

[[ -d "$SOURCE" && ! -L "$SOURCE" ]] \
    || { echo "error: dSYM source is unavailable or is a symlink" >&2; exit 1; }
[[ ! -L "$ARCHIVE" ]] \
    || { echo "error: dSYM archive destination is a symlink" >&2; exit 1; }

rm -f "$ARCHIVE"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$SOURCE" "$ARCHIVE"

python3 - "$ARCHIVE" <<'PY'
from pathlib import PurePosixPath
import stat
import sys
import zipfile

archive = sys.argv[1]
with zipfile.ZipFile(archive) as bundle:
    members = bundle.infolist()
    if not members or len(members) > 4096:
        raise SystemExit("error: dSYM archive member count is invalid")
    dwarf = []
    for member in members:
        path = PurePosixPath(member.filename)
        if path.is_absolute() or ".." in path.parts or "__MACOSX" in path.parts:
            raise SystemExit("error: dSYM archive contains an unsafe or AppleDouble path")
        if stat.S_ISLNK((member.external_attr >> 16) & 0o170000):
            raise SystemExit("error: dSYM archive contains a symlink")
        parts = path.parts
        if len(parts) == 5 and parts[0].endswith(".dSYM") \
                and parts[1:4] == ("Contents", "Resources", "DWARF") \
                and not member.is_dir():
            dwarf.append(member.filename)
    if len(dwarf) != 1:
        raise SystemExit("error: dSYM archive must contain exactly one DWARF binary")
PY

echo "dSYM archive verified: exactly one DWARF binary and no AppleDouble members"
