#!/usr/bin/env bash
# Produce a retained, signed/notarized/stapled rollback that cannot report crashes.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:?set the exact Developer ID Application identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set the existing notarytool keychain profile}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$TIMEOUT_BIN" ]] \
    || { echo "error: a real wall-clock timeout is required for notarization" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] \
    || { echo "error: rollback builds require a clean source tree" >&2; exit 1; }

COMMIT="$(git rev-parse HEAD)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
APP="build/TandemClip.app"
DMG="dist/rollback/TandemClip_${VERSION}_${BUILD}_${COMMIT}_reporting_disabled_aarch64.dmg"
[[ ! -e "$DMG" ]] || { echo "error: refusing to overwrite retained rollback artifact" >&2; exit 1; }

TANDEMCLIP_REPORTING_DISABLED_ROLLBACK=1 \
    TANDEMCLIP_CRASHBOX_CONFIG_FILE=/dev/null \
    IDENTITY="$IDENTITY" NOTARY_PROFILE= Scripts/make-app.sh

ZIP="$(mktemp /tmp/tandemclip-rollback-app.XXXXXX.zip)"
STAGE="$(mktemp -d /tmp/tandemclip-rollback-stage.XXXXXX)"
COMPLETE=0
cleanup() {
    rm -f "$ZIP"
    rm -rf "$STAGE"
    [[ "$COMPLETE" == "1" ]] || rm -f "$DMG"
}
trap cleanup EXIT
ditto -c -k --keepParent "$APP" "$ZIP"
"$TIMEOUT_BIN" 900 xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait --timeout 12m
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

mkdir -p "$(dirname "$DMG")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname TandemClip -srcfolder "$STAGE" -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" "$DMG"
"$TIMEOUT_BIN" 900 xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" --wait --timeout 12m
xcrun stapler staple "$DMG"
Scripts/verify-reporting-disabled-rollback.sh "$DMG" "$COMMIT" "$IDENTITY"
COMPLETE=1

echo "rollback artifact ready: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
