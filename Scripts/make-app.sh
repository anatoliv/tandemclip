#!/usr/bin/env bash
#
# Build clipboardd.app — a menu-bar-only (.app) bundle ready for launch-at-login.
#
# Usage:
#   Scripts/make-app.sh                     # build + ad-hoc sign (local use)
#   IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/make-app.sh
#                                           # build + Developer ID sign (distributable)
#   IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=your-notary-profile \
#     Scripts/make-app.sh                   # ...and notarize + staple
#
# NOTARY_PROFILE is a notarytool keychain profile created once with:
#   xcrun notarytool store-credentials "<name>" --apple-id ... --team-id ...

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="TandemClip"                        # display / .app bundle name
EXE_NAME="tandemclip"                        # Swift product + CFBundleExecutable
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${IDENTITY:-}"                 # empty => ad-hoc signature ("-")
NOTARY_PROFILE="${NOTARY_PROFILE:-}"     # empty => skip notarization

echo "==> Building release binary"
# -Xswiftc -g emits DWARF so dsymutil can produce a real dSYM. Without it the
# binary carries only symtab+unwind, and Sentry can resolve function names but
# never file/line — which is most of the value of a crash report.
swift build -c release --build-system native -Xswiftc -g
BIN_PATH="$(swift build -c release --build-system native --show-bin-path)/${EXE_NAME}"

# Build the dSYM next to the binary inside .build, which is exactly where
# release.sh points `sentry-cli debug-files upload`. The dSYM is deliberately
# NOT copied into the .app: it would double the download for no user benefit.
if command -v dsymutil >/dev/null 2>&1; then
    echo "==> Generating dSYM for crash symbolication"
    dsymutil "${BIN_PATH}" -o "${BIN_PATH}.dSYM" 2>/dev/null \
        || echo "    dsymutil failed (non-fatal; crash reports lose file/line)"
fi

# Regenerate the app icon if the source is present but the .icns is stale/missing.
if [[ ! -f Packaging/AppIcon.icns && -x Scripts/make-icon.sh ]]; then
    echo "==> Generating app icon"
    Scripts/make-icon.sh
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${EXE_NAME}"
cp "Packaging/Info.plist" "${BUNDLE}/Contents/Info.plist"
[[ -f Packaging/AppIcon.icns ]] && cp "Packaging/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Inject the Sentry DSN from a gitignored source (never committed). The tracked
# Packaging/Info.plist keeps SentryDSN empty; the real DSN comes from the env
# var TANDEMCLIP_SENTRY_DSN, or the gitignored file Packaging/sentry-dsn.local.
# No source means an empty DSN, so crash reporting stays off in the shipped build.
SENTRY_DSN_VALUE="${TANDEMCLIP_SENTRY_DSN:-}"
if [[ -z "${SENTRY_DSN_VALUE}" && -f Packaging/sentry-dsn.local ]]; then
    SENTRY_DSN_VALUE="$(tr -d ' \t\r\n' < Packaging/sentry-dsn.local)"
fi
if [[ -n "${SENTRY_DSN_VALUE}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SentryDSN ${SENTRY_DSN_VALUE}" "${BUNDLE}/Contents/Info.plist"
    echo "==> Injected Sentry DSN into bundle Info.plist"
fi

# Bundle Sparkle.framework (auto-update) if the app links it.
SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [[ -n "${SPARKLE_FW}" ]]; then
    echo "==> Bundling Sparkle.framework"
    mkdir -p "${BUNDLE}/Contents/Frameworks"
    cp -R "${SPARKLE_FW}" "${BUNDLE}/Contents/Frameworks/"
fi

echo "==> Code signing"
SIGN="${IDENTITY:--}"                       # '-' = ad-hoc
SOPTS=(--force --options runtime --timestamp)
[[ -z "${IDENTITY}" ]] && SOPTS=(--force)   # ad-hoc can't use runtime/timestamp

# Sign Sparkle's nested code deepest-first (no --deep; it mis-signs XPC).
FW="${BUNDLE}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${FW}" ]]; then
    V="${FW}/Versions/B"
    for x in "${V}/XPCServices/Downloader.xpc" "${V}/XPCServices/Installer.xpc" \
             "${V}/Autoupdate" "${V}/Updater.app" "${FW}"; do
        codesign "${SOPTS[@]}" --sign "${SIGN}" "$x"
    done
fi
codesign "${SOPTS[@]}" --sign "${SIGN}" "${BUNDLE}"
[[ -n "${IDENTITY}" ]] && echo "    signed with Developer ID: ${IDENTITY}" || echo "    ad-hoc signed (local only)"

codesign --verify --verbose "${BUNDLE}" >/dev/null && echo "    signature verified"

if [[ -n "${NOTARY_PROFILE}" ]]; then
    if [[ -z "${IDENTITY}" ]]; then
        echo "error: NOTARY_PROFILE set but no IDENTITY — an ad-hoc build cannot be notarized." >&2
        exit 1
    fi
    echo "==> Notarizing (profile: ${NOTARY_PROFILE})"
    ZIP="build/${APP_NAME}.zip"
    ditto -c -k --keepParent "${BUNDLE}" "${ZIP}"
    xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
    echo "==> Stapling"
    xcrun stapler staple "${BUNDLE}"
    xcrun stapler validate "${BUNDLE}" && echo "    staple validated"
    spctl --assess --type execute --verbose "${BUNDLE}" 2>&1 | sed 's/^/    gatekeeper: /' || true
    rm -f "${ZIP}"
fi

echo
echo "Built: ${BUNDLE}"
echo "Run:   open ${BUNDLE}    (look for 📋 in the menu bar)"
