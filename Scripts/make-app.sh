#!/usr/bin/env bash
#
# Build clipboardd.app — a menu-bar-only (.app) bundle ready for launch-at-login.
#
# Usage:
#   Scripts/make-app.sh                     # build + ad-hoc sign (local use)
#   IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/make-app.sh
#                                           # build + Developer ID sign (distributable)
#
# After a Developer ID build, notarize with the steps printed at the end.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="clipboardd"
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${IDENTITY:-}"          # empty => ad-hoc signature ("-")

echo "==> Building release binary"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Packaging/Info.plist" "${BUNDLE}/Contents/Info.plist"

echo "==> Code signing"
if [[ -n "${IDENTITY}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "${IDENTITY}" "${BUNDLE}"
    echo "    signed with Developer ID: ${IDENTITY}"
else
    # Ad-hoc signature: fine for running on THIS machine; will not pass
    # Gatekeeper on other machines and cannot be notarized.
    codesign --force --deep --sign - "${BUNDLE}"
    echo "    ad-hoc signed (local machine only)"
fi

codesign --verify --verbose "${BUNDLE}" >/dev/null && echo "    signature verified"

echo
echo "Built: ${BUNDLE}"
echo "Run:   open ${BUNDLE}    (look for 📋 in the menu bar)"

if [[ -n "${IDENTITY}" ]]; then
cat <<'EOF'

==> Notarize (required for launch-at-login on managed / other Macs):
    ditto -c -k --keepParent build/clipboardd.app build/clipboardd.zip
    xcrun notarytool submit build/clipboardd.zip \
        --apple-id "you@example.com" --team-id "TEAMID" \
        --password "app-specific-password" --wait
    xcrun stapler staple build/clipboardd.app
EOF
fi
