#!/usr/bin/env bash
#
# Build a distributable TandemClip release: signed + notarized .app, packaged
# into a signed + notarized + stapled DMG, plus (when a Sparkle key is present)
# an ed25519-signed appcast <item> for auto-update. Mirrors tonebox's flow.
#
# Usage:
#   IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="tonebox-notarize" \
#   Scripts/release.sh
#
# Optional:
#   SPARKLE_BIN=/path/to/sign_update   (else auto-located)
#   APPCAST_BASE=https://tandemclip.com   (enclosure URL base; default below)

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="TandemClip"
IDENTITY="${IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPCAST_BASE="${APPCAST_BASE:-https://tandemclip.com}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
DIST="dist"
APP="build/${APP_NAME}.app"
DMG="${DIST}/${APP_NAME}_${VERSION}_aarch64.dmg"

# 1. Build + sign + notarize + staple the .app (reuses make-app.sh).
IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/make-app.sh

mkdir -p "$DIST"
rm -f "$DMG"

# 2. Stage the DMG (app + /Applications drop target) and build it.
echo "==> Building DMG $DMG"
STAGE="build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 3. Sign → notarize → staple the DMG (order matters).
if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing DMG"
    codesign --force --sign "$IDENTITY" "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG" && echo "    DMG staple validated"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "==> DMG ready: $DMG"
echo "    sha256: $SHA"

# 4. Best-effort Sparkle appcast <item> (skipped if sign_update/key absent).
SPARKLE_BIN="${SPARKLE_BIN:-$(find "$HOME/Library/Developer" ~/Library/Caches/org.swift.swiftpm 2>/dev/null -type f -name sign_update -path '*Sparkle*' | head -1 || true)}"
if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN" ]]; then
    SIG_ATTRS="$("$SPARKLE_BIN" "$DMG" 2>/dev/null || true)"
    if [[ -n "$SIG_ATTRS" ]]; then
        DMG_NAME="$(basename "$DMG")"
        cat > "$DIST/appcast-item.xml" <<XML
<item>
    <title>${APP_NAME} ${VERSION}</title>
    <sparkle:version>${BUILD_NUM}</sparkle:version>
    <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <enclosure url="${APPCAST_BASE}/${DMG_NAME}"
               type="application/octet-stream"
               $SIG_ATTRS />
</item>
XML
        echo "==> Wrote $DIST/appcast-item.xml"
    else
        echo "==> Sparkle key not in keychain — skipped appcast item (DMG is ready)."
    fi
else
    echo "==> sign_update not found — skipped appcast item (add Sparkle + run generate_keys once)."
fi
