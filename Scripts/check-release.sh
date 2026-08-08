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

# --- The build number must actually increase ----------------------------------
# Sparkle decides whether an update exists by comparing sparkle:version — the
# BUILD number — and ignores shortVersionString entirely. So two releases that
# share a build number are invisible to each other: no update is offered, no
# error is shown, and the appcast looks perfectly correct. Every other check in
# this file compares the release against *itself* and cannot see it. This one
# compares it against the last release that actually shipped.
PREV_TAG="$(git tag --list 'v*' --sort=-v:refname 2>/dev/null | grep -v "^v${VERSION}\$" | head -1 || true)"
if [[ -n "$PREV_TAG" ]]; then
    PREV_PLIST="$(mktemp -t tandemclip-prevplist)"
    if git show "$PREV_TAG:Packaging/Info.plist" > "$PREV_PLIST" 2>/dev/null; then
        PREV_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PREV_PLIST" 2>/dev/null || true)"
    fi
    rm -f "$PREV_PLIST"
    case "${PREV_BUILD:-x}" in
        (*[!0-9]*|'') : ;;   # unreadable or pre-dates the field — nothing to compare
        (*)
            if [[ "$BUILD_NUM" -le "$PREV_BUILD" ]]; then
                echo "error: build $BUILD_NUM is not greater than $PREV_BUILD (shipped in $PREV_TAG)." >&2
                echo "       Sparkle compares sparkle:version, so this release would never be" >&2
                echo "       offered to anyone running $PREV_TAG. Bump CFBundleVersion in" >&2
                echo "       Packaging/Info.plist." >&2
                exit 1
            fi
            ;;
    esac
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

# --- Version-pinned surfaces --------------------------------------------------
# Every one of these has gone stale in practice, silently, because nothing
# compared them to the release being built:
#   * the cask pinned an old version/sha256  -> `brew install` 404s
#   * the cask pinned "X" not "X,BUILD"      -> `brew audit` fails, autobump breaks
#   * the site source sat 2 releases behind  -> deploying it DOWNGRADES the page
# They are all mechanically checkable, so check them rather than remembering.

CASK="Casks/tandemclip.rb"
if [[ -f "$CASK" ]]; then
    CASK_VERSION="$(sed -nE 's/^  version "([^"]+)".*/\1/p' "$CASK" | head -1)"
    CASK_SHA="$(sed -nE 's/^  sha256 "([0-9a-f]{64})".*/\1/p' "$CASK" | head -1)"
    WANT_VERSION="${VERSION},${BUILD_NUM}"
    if [[ "$CASK_VERSION" != "$WANT_VERSION" ]]; then
        echo "error: cask version '$CASK_VERSION' != '$WANT_VERSION'." >&2
        echo "       The appcast carries both shortVersionString and version, so Homebrew's" >&2
        echo "       Sparkle livecheck reports them joined; pin '<short>,<build>'." >&2
        exit 1
    fi
    DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    if [[ "$CASK_SHA" != "$DMG_SHA" ]]; then
        echo "error: cask sha256 does not match $DMG" >&2
        echo "       cask: ${CASK_SHA:-missing}" >&2
        echo "       dmg : $DMG_SHA" >&2
        exit 1
    fi
    if ! grep -q 'brew trust' README.md 2>/dev/null; then
        echo "error: README install steps omit 'brew trust' — Homebrew 6+ refuses" >&2
        echo "       third-party taps without it, so the instructions do not work." >&2
        exit 1
    fi
fi

SITE_SRC="web/site/index.html"
if [[ -f "$SITE_SRC" ]]; then
    SITE_STALE="$(grep -oE 'TandemClip_[0-9]+\.[0-9]+\.[0-9]+_aarch64\.dmg|Version [0-9]+\.[0-9]+\.[0-9]+' "$SITE_SRC" \
        | grep -v "$VERSION" | sort -u || true)"
    if [[ -n "$SITE_STALE" ]]; then
        echo "error: $SITE_SRC still references versions other than $VERSION:" >&2
        printf '       %s\n' $SITE_STALE >&2
        echo "       release.sh syncs this; deploying a stale source downgrades the live page." >&2
        exit 1
    fi
fi

echo "release metadata ok: $VERSION ($BUILD_NUM)"
echo "  cask + site + README install steps all match this release"
