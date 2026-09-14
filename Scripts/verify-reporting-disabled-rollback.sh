#!/usr/bin/env bash
# Verify one retained DMG without reading or printing any reporting credential.

set -euo pipefail

DMG="${1:?usage: verify-reporting-disabled-rollback.sh DMG COMMIT IDENTITY}"
EXPECTED_COMMIT="${2:?usage: verify-reporting-disabled-rollback.sh DMG COMMIT IDENTITY}"
EXPECTED_IDENTITY="${3:?usage: verify-reporting-disabled-rollback.sh DMG COMMIT IDENTITY}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ "$EXPECTED_IDENTITY" == "Developer ID Application: "*" ("??????????")" ]] \
    || { echo "error: expected signer must be one exact Developer ID Application identity" >&2; exit 1; }
[[ -f "$DMG" && ! -L "$DMG" ]] \
    || { echo "error: rollback DMG is unavailable or is a symlink" >&2; exit 1; }

codesign --verify "$DMG"
hdiutil verify "$DMG" >/dev/null
xcrun stapler validate "$DMG"

MOUNT="$(mktemp -d /tmp/tandemclip-rollback.XXXXXX)"
cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -owners off -mountpoint "$MOUNT" "$DMG" >/dev/null

APPS=()
while IFS= read -r -d '' candidate; do APPS+=("$candidate"); done \
    < <(find "$MOUNT" -mindepth 1 -maxdepth 1 -name '*.app' -print0)
[[ "${#APPS[@]}" -eq 1 && ! -L "${APPS[0]}" ]] \
    || { echo "error: rollback DMG must contain exactly one real top-level app" >&2; exit 1; }
APP="${APPS[0]}"

codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"
xcrun stapler validate "$APP"
ACTUAL_IDENTITY="$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$ACTUAL_IDENTITY" == "$EXPECTED_IDENTITY" ]] \
    || { echo "error: rollback signer does not match the expected identity" >&2; exit 1; }

EXECUTABLE="$(python3 "$ROOT/Scripts/verify-reporting-disabled-metadata.py" \
    "$ROOT" "$APP" "$EXPECTED_COMMIT" | sed -n 's/.*executable=//p')"
[[ "$EXECUTABLE" == "tandemclip" ]] \
    || { echo "error: rollback metadata verifier returned no executable" >&2; exit 1; }
/usr/bin/lipo "$APP/Contents/MacOS/$EXECUTABLE" -verify_arch arm64

echo "reporting-disabled rollback verified: exact source, signer, architecture, metadata, signatures, and staples"
