#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
APPCAST="dist/appcast.xml"
DMG="dist/TandemClip_${VERSION}_aarch64.dmg"

# --- Design-drift lint --------------------------------------------------------
# Views must draw from Tokens (docs/design/DESIGN_SYSTEM.md), not raw numbers.
# Enforced everywhere (picker included, as of §9's exception closing): no raw
# `cornerRadius: <n>` and no raw `.system(size: <n>` outside Theme.swift. The
# only allowance is SF-Rounded faces (keycaps / brand titles), which are a
# deliberate design choice, not a size literal to tokenize.
RADIUS_DRIFT="$(grep -rnE 'cornerRadius: [0-9]' Sources/tandemclip --include='*.swift' \
    | grep -v 'Theme.swift' || true)"
FONT_DRIFT="$(grep -rnE '\.system\(size: [0-9]' Sources/tandemclip --include='*.swift' \
    | grep -vE 'Theme\.swift|design: \.rounded' || true)"
if [[ -n "$RADIUS_DRIFT" || -n "$FONT_DRIFT" ]]; then
    echo "error: design-drift — raw style values in view code (use Tokens; see docs/design/DESIGN_SYSTEM.md §9):" >&2
    [[ -n "$RADIUS_DRIFT" ]] && printf '%s\n' "$RADIUS_DRIFT" >&2
    [[ -n "$FONT_DRIFT" ]] && printf '%s\n' "$FONT_DRIFT" >&2
    exit 1
fi

if [[ ! -f "$DMG" ]]; then
    echo "error: missing release DMG: $DMG" >&2
    exit 1
fi

if [[ ! -f "$APPCAST" ]]; then
    echo "error: missing appcast: $APPCAST" >&2
    exit 1
fi

APPCAST_BUILD="$(perl -0ne 'if (/<sparkle:version>(\d+)<\/sparkle:version>/) { print $1; exit }' "$APPCAST")"
APPCAST_VERSION="$(perl -0ne 'if (/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/) { print $1; exit }' "$APPCAST")"

if [[ -z "$APPCAST_BUILD" || "$APPCAST_BUILD" -lt "$BUILD_NUM" ]]; then
    echo "error: appcast latest build (${APPCAST_BUILD:-missing}) is older than bundle build $BUILD_NUM" >&2
    exit 1
fi

if [[ "$APPCAST_VERSION" != "$VERSION" ]]; then
    echo "error: appcast latest version (${APPCAST_VERSION:-missing}) does not match bundle version $VERSION" >&2
    exit 1
fi

echo "release metadata ok: $VERSION ($BUILD_NUM)"
