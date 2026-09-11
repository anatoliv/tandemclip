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

# Keep the Mac awake through `notarytool submit --wait`, which uploads to Apple and
# then blocks on a verdict; an idle Mac sleeping through it suspends the upload and the
# step appears to hang with no error.
#
# release.sh already holds a caffeinate assertion for its whole run and calls this
# script, so that path was covered — this is for running make-app.sh on its own.
# Harmless when nested: two assertions simply overlap.
if command -v caffeinate >/dev/null; then
  caffeinate -dimsu -w $$ &
fi

cd "$(dirname "$0")/.."

APP_NAME="TandemClip"                        # display / .app bundle name
EXE_NAME="tandemclip"                        # Swift product + CFBundleExecutable
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${IDENTITY:-}"                 # empty => ad-hoc signature ("-")
NOTARY_PROFILE="${NOTARY_PROFILE:-}"     # empty => skip notarization

# --- Source identity gate -----------------------------------------------------
# The exact source revision gets baked into the bundle further down (Info.plist
# TandemClipSourceCommit, injected the same way the Crashbox DSN is). Whether that
# is even possible is knowable in one `git rev-parse`, so it is checked HERE —
# before the release build — rather than at assembly time. release.sh makes the
# same argument for its preflight gate: a failure that costs a full build plus
# notarization to discover is a failure nobody finds until it is expensive.
#
# Why bake it in at all: a shipped .app records only the version string it chose
# for itself, so nothing about a live artifact says which commit produced it. A
# tag is a claim made beside a release, not a property of its bytes — you cannot
# hand someone a DMG and have them check it. With the commit inside the bundle,
# `plutil -p TandemClip.app/Contents/Info.plist` answers on its own, and the same
# value rides in the event release name (see BuildIdentity.swift).
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
GIT_DIRTY="$(git status --porcelain 2>/dev/null || true)"

identity_is_well_formed() {                 # 40 chars, lowercase hex, nothing else
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# A distributable build (IDENTITY set = Developer ID signed = a thing that can
# reach a user) refuses to exist without a well-formed identity. An unsigned
# local build is allowed to carry none: dev builds go nowhere, and blocking them
# on git state would only teach people to work around this.
if [[ -n "${IDENTITY}" ]]; then
    if ! identity_is_well_formed "${SOURCE_COMMIT}"; then
        cat >&2 <<MSG
error: refusing to build a distributable app with no usable source identity.

  git rev-parse HEAD gave: '${SOURCE_COMMIT:-<nothing>}'
  Required: exactly 40 lowercase hex characters.

  A signed build can reach a user, and a build that reaches a user must be
  mappable back to the revision it came from. An abbreviated, uppercase or
  placeholder value is not identity — it is a value that looks like one.
MSG
        exit 1
    fi
    if [[ -n "${GIT_DIRTY}" && "${ALLOW_DIRTY_IDENTITY:-}" != "1" ]]; then
        cat >&2 <<MSG
error: working tree is dirty — a distributable build would claim a revision
       that does not describe its own bytes.

  Commit or stash first, or (knowing the identity will be a lie) re-run with:
      ALLOW_DIRTY_IDENTITY=1 ${0}
MSG
        git status --short >&2
        exit 1
    fi
    if [[ -n "${GIT_DIRTY}" ]]; then
        echo "WARNING: ALLOW_DIRTY_IDENTITY=1 — ${SOURCE_COMMIT} does not describe this build" >&2
    else
        echo "==> Source identity: ${SOURCE_COMMIT} (clean tree)"
    fi
fi

# Select and validate the sole remote reporting endpoint before the expensive
# build. A contributor's unsigned local build may stay reporting-disabled. A
# signed build, or a build that release.sh intends to publish, must carry a
# valid Crashbox DSN; otherwise a successful release silently removes crash
# reporting from the public artifact.
crashbox_dsn_is_valid() {
    local value="$1" host
    [[ "$value" =~ ^https://([A-Za-z0-9._~-]+)@([A-Za-z0-9.-]+)/([A-Za-z0-9-]+)$ ]] \
        || return 1
    host="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
    case "$host" in
        sentry.io|*.sentry.io) return 1 ;;
    esac
}

CRASHBOX_DSN_FILE="${TANDEMCLIP_CRASHBOX_CONFIG_FILE:-Packaging/crashbox-dsn.local}"
CRASHBOX_DSN_VALUE="${TANDEMCLIP_CRASHBOX_DSN:-}"
if [[ -z "${CRASHBOX_DSN_VALUE}" && -f "$CRASHBOX_DSN_FILE" ]]; then
    CRASHBOX_DSN_VALUE="$(tr -d ' \t\r\n' < "$CRASHBOX_DSN_FILE")"
fi
if [[ -n "${CRASHBOX_DSN_VALUE}" ]] && ! crashbox_dsn_is_valid "${CRASHBOX_DSN_VALUE}"; then
    echo "error: Crashbox DSN has an unsafe or malformed shape." >&2
    exit 1
fi
if [[ ( -n "${IDENTITY}" || "${REQUIRE_CRASHBOX:-}" == "1" ) && -z "${CRASHBOX_DSN_VALUE}" ]]; then
    echo "error: a distributable release requires a protected Crashbox DSN." >&2
    echo "       Install ${CRASHBOX_DSN_FILE} with mode 0600; local unsigned builds may stay disabled." >&2
    exit 1
fi
if [[ "${VERIFY_CRASHBOX_INPUT_ONLY:-}" == "1" ]]; then
    [[ -n "${CRASHBOX_DSN_VALUE}" ]] && echo crashbox || echo disabled
    exit 0
fi

echo "==> Building release binary"
# -Xswiftc -g emits DWARF so dsymutil can produce a real dSYM. Without it the
# binary carries only symtab+unwind, and Crashbox can resolve function names but
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

# Inject the sole Crashbox DSN from a gitignored source (never committed). The
# tracked Info.plist keeps CrashboxDSN empty; no source means reporting-disabled.
# Deliberately read no legacy variable or local file: a stale hosted-provider
# secret must not become an accidental fallback.
if [[ -n "${CRASHBOX_DSN_VALUE}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CrashboxDSN ${CRASHBOX_DSN_VALUE}" "${BUNDLE}/Contents/Info.plist"
    echo "==> Injected Crashbox DSN into bundle Info.plist"
fi

# Bake in the revision checked at the top of this script. Injected here, at the
# same point and for the same reason as the DSN: it is a property of the *build*,
# not of the tracked tree, so the committed Packaging/Info.plist keeps it empty.
if identity_is_well_formed "${SOURCE_COMMIT}"; then
    /usr/libexec/PlistBuddy -c "Set :TandemClipSourceCommit ${SOURCE_COMMIT}" \
        "${BUNDLE}/Contents/Info.plist"
    # Read it back out of the bundle rather than trusting the write. PlistBuddy
    # reports success on a Set against a key type it cannot honor, and the whole
    # point of this value is that it can be trusted without re-deriving it.
    BAKED="$(/usr/libexec/PlistBuddy -c 'Print :TandemClipSourceCommit' \
        "${BUNDLE}/Contents/Info.plist" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${BAKED}" != "${SOURCE_COMMIT}" ]]; then
        echo "error: source identity did not survive injection (bundle holds '${BAKED:-<empty>}')." >&2
        exit 1
    fi
    echo "==> Source identity baked in: ${SOURCE_COMMIT}"
else
    echo "note: no source identity (not a git checkout, or detached/unborn HEAD)."
    echo "      Fine for a local build; a signed build refuses this."
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

# --strict, and verify the nested code too. The default verification is lenient
# enough to pass a bundle whose embedded Sparkle XPC services or framework are
# mis-signed — which then fails at notarization, or worse, at update time on a
# user's machine. --deep walks the nested code signed in the loop above.
codesign --verify --strict --deep --verbose=2 "${BUNDLE}" 2>/dev/null && echo "    signature verified (strict, nested)"

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
