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

# 1b. Upload dSYMs to Sentry for symbolicated crash reports. Token comes from
#     the environment or, failing that, the Keychain item "tandemclip-sentry"
#     (create once with:
#       security add-generic-password -s tandemclip-sentry -a sentry -w <token>
#     token needs project:releases scope). Missing token WARNS — a release
#     without dSYMs means unsymbolicated crash reports, which you want to know.
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    SENTRY_AUTH_TOKEN="$(security find-generic-password -s tandemclip-sentry -w 2>/dev/null || true)"
    export SENTRY_AUTH_TOKEN
fi
if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] && command -v sentry-cli >/dev/null 2>&1; then
    echo "==> Uploading dSYMs to Sentry"
    sentry-cli debug-files upload --org "${SENTRY_ORG:-your-sentry-org}" \
        --project "${SENTRY_PROJECT:-tandemclip}" .build 2>&1 | tail -3 || \
        echo "    dSYM upload failed (non-fatal)"
else
    echo "WARNING: no SENTRY_AUTH_TOKEN (env or Keychain 'tandemclip-sentry') — shipping without symbolicated crash reports" >&2
fi

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

# 4. Full Sparkle appcast feed via generate_appcast (EdDSA-signs every DMG in
#    dist/ from the keychain key; writes dist/appcast.xml).
GA_BIN="${GA_BIN:-$(find "$HOME/Library/Developer" "$HOME/Library/Caches/org.swift.swiftpm" ./.build 2>/dev/null -type f -name generate_appcast -path '*Sparkle*' | head -1 || true)}"
if [[ -n "${GA_BIN:-}" && -x "$GA_BIN" ]]; then
    echo "==> Generating appcast ($DIST/appcast.xml)"
    "$GA_BIN" "$DIST" --download-url-prefix "${APPCAST_BASE}/" -o "$DIST/appcast.xml"
    echo "    appcast.xml written"
    APPCAST_BUILD="$(perl -0ne 'if (/<sparkle:version>(\d+)<\/sparkle:version>/) { print $1; exit }' "$DIST/appcast.xml")"
    if [[ -z "$APPCAST_BUILD" || "$APPCAST_BUILD" -lt "$BUILD_NUM" ]]; then
        echo "error: appcast latest build (${APPCAST_BUILD:-missing}) is older than bundle build $BUILD_NUM" >&2
        exit 1
    fi
else
    echo "error: generate_appcast not found — refusing to publish a release without appcast verification." >&2
    exit 1
fi

# 5. Publish DMG + appcast + landing page to web-01 (PUBLISH=1). Serves the
#    exact SUFeedURL. The landing page's download links are version-pinned, so
#    render the current VERSION into a copy of web/site/index.html before
#    publishing — otherwise the "Download" button rots to a DMG that 404s.
if [[ "${PUBLISH:-}" == "1" ]]; then
    DEST="user@host:/srv/tandemclip/"
    echo "==> Publishing to web-01 ($DEST)"
    scp -q "$DMG" "$DEST"
    [[ -f "$DIST/appcast.xml" ]] && scp -q "$DIST/appcast.xml" "$DEST"

    SITE_SRC="web/site/index.html"
    if [[ -f "$SITE_SRC" ]]; then
        RENDERED="$DIST/index.html"
        # Repoint every versioned DMG link and the "Version x.y.z" line at VERSION.
        sed -E "s/TandemClip_[0-9]+\.[0-9]+\.[0-9]+_aarch64\.dmg/TandemClip_${VERSION}_aarch64.dmg/g; \
                s/Version [0-9]+\.[0-9]+\.[0-9]+/Version ${VERSION}/g" \
            "$SITE_SRC" > "$RENDERED"
        scp -q "$RENDERED" "$DEST"
        echo "    published: $(basename "$DMG") + appcast.xml + index.html (v$VERSION)"
    else
        echo "    published: $(basename "$DMG") + appcast.xml"
    fi
    echo "    verify: curl -fsSI https://tandemclip.com/appcast.xml"
    echo "    verify: curl -fsSI https://tandemclip.com/TandemClip_${VERSION}_aarch64.dmg"
fi
