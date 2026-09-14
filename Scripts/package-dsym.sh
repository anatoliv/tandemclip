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

python3 "$(dirname "$0")/dsym-member.py" "$ARCHIVE" >/dev/null

echo "dSYM archive verified: exactly one DWARF binary and no AppleDouble members"
