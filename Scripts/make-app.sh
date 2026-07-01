#!/usr/bin/env bash
#
# Build clipboardd.app — a menu-bar-only (.app) bundle ready for launch-at-login.
#
# Usage:
#   Scripts/make-app.sh                     # build + ad-hoc sign (local use)
#   IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/make-app.sh
#                                           # build + Developer ID sign (distributable)
#   IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=tonebox-notarize \
#     Scripts/make-app.sh                   # ...and notarize + staple
#
# NOTARY_PROFILE is a notarytool keychain profile created once with:
#   xcrun notarytool store-credentials "<name>" --apple-id ... --team-id ...

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="clipboardd"
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${IDENTITY:-}"                 # empty => ad-hoc signature ("-")
NOTARY_PROFILE="${NOTARY_PROFILE:-}"     # empty => skip notarization

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
