#!/usr/bin/env bash
#
# Build a distributable TandemClip release: signed + notarized .app, packaged
# into a signed + notarized + stapled DMG, plus (when a Sparkle key is present)
# an ed25519-signed appcast <item> for auto-update.
#
# Usage:
#   IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="your-notary-profile" \
#   Scripts/release.sh
#
# Optional:
#   SPARKLE_BIN=/path/to/sign_update      (else auto-located)
#   APPCAST_BASE=https://tandemclip.com   (enclosure URL base; default below)
#   PREPARE_RELEASE=1 PUBLISH=0           (build once and write a resume manifest)
#   PUBLISH=1 RESUME_PREPARED_RELEASE=/path/to/manifest.json
#   PUBLISH_DEST=user@host:/path          (rsync/scp the DMG + appcast + page)
#   CRASHBOX_ARTIFACT_RECEIPT_FILE=/path/to/receipt.json (required to publish)
#   TANDEMCLIP_CRASHBOX_PROJECT_ID=<uuid> (required to publish)
#   VERIFY_PREPARED_RELEASE_ONLY=1        (validate resume inputs, publish nothing)
#   ALLOW_NO_SYMBOLS=1                    (explicitly omit the Crashbox dSYM archive)

set -euo pipefail

# Keep the Mac awake for the whole run.
#
# The long unattended stretch here is `notarytool submit`, which uploads to Apple and
# then waits for a verdict, and an idle Mac sleeping through that suspends the upload.
# This script has a documented history of that step hanging — once for 69 minutes, once
# for 18, both ended by hand and chased through connectivity, path MTU and a VPN that
# was not even in the route. At least one of those was later traced to a corrupt DMG, so
# this is not a claim that sleep caused them; it is one line that removes sleep from the
# list of suspects for good.
#
# `-w $$` rather than wrapping the script: wrapping puts caffeinate between the terminal
# and this script, so a TERM kills the wrapper and any EXIT trap never runs.
if command -v caffeinate >/dev/null; then
  caffeinate -dimsu -w $$ &
fi
cd "$(dirname "$0")/.."

APP_NAME="TandemClip"
IDENTITY="${IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPCAST_BASE="${APPCAST_BASE:-https://tandemclip.com}"
PUBLISH="${PUBLISH:-0}"
PREPARE_RELEASE="${PREPARE_RELEASE:-0}"
RESUME_MANIFEST="${RESUME_PREPARED_RELEASE:-}"
VERIFY_PREPARED_ONLY="${VERIFY_PREPARED_RELEASE_ONLY:-0}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
DIST="dist"
APP="build/${APP_NAME}.app"
DMG="${DIST}/${APP_NAME}_${VERSION}_aarch64.dmg"
APPCAST="${DIST}/appcast.xml"
CASK="Casks/tandemclip.rb"
SITE_SRC="site/index.html"
SUPPORTERS="site/supporters.json"

case "$PUBLISH:$PREPARE_RELEASE:$VERIFY_PREPARED_ONLY" in
    [01]:[01]:[01]) ;;
    *) echo "error: PUBLISH, PREPARE_RELEASE and VERIFY_PREPARED_RELEASE_ONLY must be 0 or 1." >&2; exit 1 ;;
esac
if [[ -n "$RESUME_MANIFEST" ]]; then
    if [[ "$PUBLISH" != "1" || "$PREPARE_RELEASE" != "0" ]]; then
        echo "error: RESUME_PREPARED_RELEASE requires PUBLISH=1 and PREPARE_RELEASE=0." >&2
        exit 1
    fi
    if [[ -n "${FORCE_REBUILD:-}" ]]; then
        echo "error: FORCE_REBUILD cannot resume an immutable prepared release." >&2
        exit 1
    fi
elif [[ "$PUBLISH" == "1" ]]; then
    echo "error: publication requires RESUME_PREPARED_RELEASE." >&2
    echo "       First run PREPARE_RELEASE=1 PUBLISH=0, upload its dSYM archive," >&2
    echo "       then resume the exact prepared bytes with the recorded manifest." >&2
    exit 1
fi
if [[ "$PREPARE_RELEASE" == "1" ]]; then
    if [[ "$PUBLISH" != "0" || -z "$IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
        echo "error: PREPARE_RELEASE=1 requires PUBLISH=0, IDENTITY and NOTARY_PROFILE." >&2
        exit 1
    fi
    if [[ "${ALLOW_NO_SYMBOLS:-}" == "1" ]]; then
        echo "error: PREPARE_RELEASE=1 cannot omit the dSYM archive." >&2
        exit 1
    fi
fi
if [[ "$VERIFY_PREPARED_ONLY" == "1" && -z "$RESUME_MANIFEST" ]]; then
    echo "error: VERIFY_PREPARED_RELEASE_ONLY requires RESUME_PREPARED_RELEASE." >&2
    exit 1
fi

# 0a1. A published release must be reproducible from a commit. Refuse a dirty
#      tree when actually publishing, so the tag describes what shipped rather
#      than what happened to be on disk.
#
#      Only when PUBLISH=1: local test builds from a working tree are the normal
#      way to develop. Note the tree WILL be dirty when this script finishes, by
#      design — step 4b rewrites Casks/tandemclip.rb and step 4c rewrites
#      site/index.html once the DMG exists, so they land one commit behind
#      the tag. That is expected; commit them after a successful run.
if [[ "$PUBLISH" == "1" && -z "$RESUME_MANIFEST" && -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "error: working tree is dirty — commit or stash before publishing." >&2
    echo "       A release must be reproducible from a commit; otherwise the tag" >&2
    echo "       does not describe what actually shipped." >&2
    git status --short >&2
    exit 1
fi

prepared_release() {
    python3 Scripts/prepared-release.py "$1" \
        --manifest "$2" \
        --repository . \
        --app "$APP" \
        --dsym-archive "$DEBUG_ARCHIVE" \
        --dmg "$DMG" \
        --appcast "$APPCAST" \
        --cask "$CASK" \
        --site "$SITE_SRC" \
        --supporters "$SUPPORTERS" \
        --source-commit "$SOURCE_COMMIT" \
        --version "$VERSION" \
        --build "$BUILD_NUM" \
        --release "$EVENT_RELEASE"
}

verify_prepared_release() {
    prepared_release verify "$RESUME_MANIFEST"
    python3 Scripts/verify-crashbox-artifact-receipt.py \
        --receipt "$CRASHBOX_ARTIFACT_RECEIPT_FILE" \
        --archive "$DEBUG_ARCHIVE" \
        --release "$EVENT_RELEASE" \
        --project "$TANDEMCLIP_CRASHBOX_PROJECT_ID"
}

if [[ -n "$RESUME_MANIFEST" ]]; then
    SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
    DEBUG_ARCHIVE="${DIST}/${APP_NAME}_${VERSION}_${BUILD_NUM}_${SOURCE_COMMIT}.dSYM.zip"
    EVENT_RELEASE="com.tandemclip@${VERSION}+${BUILD_NUM}.${SOURCE_COMMIT}"
    if [[ -z "${CRASHBOX_ARTIFACT_RECEIPT_FILE:-}" || -z "${TANDEMCLIP_CRASHBOX_PROJECT_ID:-}" ]]; then
        echo "error: resume requires CRASHBOX_ARTIFACT_RECEIPT_FILE and TANDEMCLIP_CRASHBOX_PROJECT_ID." >&2
        exit 1
    fi
    verify_prepared_release

    APP_UUIDS="$(dwarfdump --uuid "$APP/Contents/MacOS/tandemclip" | awk '{print $2}' | LC_ALL=C sort)"
    DSYM_BINARY_MEMBER="$(unzip -Z1 "$DEBUG_ARCHIVE" | awk '
        /\.dSYM\/Contents\/Resources\/DWARF\/[^/]+$/ { member=$0; count++ }
        END { if (count == 1) print member }
    ')"
    if [[ -z "$DSYM_BINARY_MEMBER" ]]; then
        echo "error: prepared dSYM archive must contain exactly one DWARF binary." >&2
        exit 1
    fi
    DSYM_CHECK_BINARY="$(mktemp -t tandemclip-resume-dsym)"
    trap 'rm -f "$DSYM_CHECK_BINARY"' EXIT
    unzip -p "$DEBUG_ARCHIVE" "$DSYM_BINARY_MEMBER" > "$DSYM_CHECK_BINARY"
    DSYM_UUIDS="$(dwarfdump --uuid "$DSYM_CHECK_BINARY" | awk '{print $2}' | LC_ALL=C sort)"
    rm -f "$DSYM_CHECK_BINARY"
    trap - EXIT
    if [[ -z "$APP_UUIDS" || "$APP_UUIDS" != "$DSYM_UUIDS" ]]; then
        echo "error: prepared app and dSYM UUIDs do not match." >&2
        exit 1
    fi
    codesign --verify --deep --strict "$APP"
    spctl -a -vv "$APP"
    xcrun stapler validate "$APP"
    codesign --verify "$DMG"
    hdiutil verify "$DMG" >/dev/null
    xcrun stapler validate "$DMG"
    SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    echo "==> Prepared release identity, signatures, ticket and UUIDs verified"
    echo "==> Pre-publish gate (Scripts/check-release.sh)"
    Scripts/check-release.sh
    if [[ "$VERIFY_PREPARED_ONLY" == "1" ]]; then
        echo "==> Prepared release is safe to resume; publication was not attempted"
        exit 0
    fi
else

# 0a2. Refuse to package while a copy of the app is running out of this repo.
#      A running copy holds files open in the tree `hdiutil create` reads, which
#      produces a CORRUPT DMG — and a corrupt DMG makes `notarytool submit` hang
#      exactly like a dead connection: nothing reaches Apple, no error is
#      printed, and every network check comes back clean. Baton lost two
#      debugging sessions to precisely this, chasing connectivity and even a VPN
#      that was not in the route, when the image was simply bad.
#
#      Deliberately narrower than Baton's guard, which refuses ANY running copy.
#      TandemClip is an always-resident menu-bar agent, so a copy running from
#      /Applications is the normal state of every Mac it is installed on and
#      blocking on it would mean quitting clipboard sync for every release. That
#      copy also cannot hold open anything under build/, which is what gets
#      staged. A copy running from THIS repo can, so that one is fatal.
#      ALLOWLIST the installed copy and refuse everything else, rather than
#      trying to pattern-match repo paths. Neither `ps -o args=` nor `ps -o comm=`
#      reliably yields an absolute path — a process launched as
#      ./build/…/tandemclip reports exactly that relative string — so any
#      $PWD-anchored pattern silently misses the very case this guard exists for
#      and leaves a check that looks present and never fires. Matching what is
#      known-safe needs no path arithmetic and fails closed: a tandemclip running
#      from anywhere other than /Applications during a release is worth stopping
#      for, wherever it came from.
REPO_RUNNERS=""
INSTALLED_RUNNING=""
for _pid in $(pgrep -x tandemclip 2>/dev/null || true); do
    _exe="$(ps -p "$_pid" -o comm= 2>/dev/null || true)"
    [[ -z "$_exe" ]] && continue          # exited between pgrep and ps
    case "$_exe" in
        /Applications/TandemClip.app/*) INSTALLED_RUNNING="$_pid  $_exe" ;;
        *)                              REPO_RUNNERS+="$_pid  $_exe"$'\n' ;;
    esac
done
if [[ -n "$REPO_RUNNERS" ]]; then
    echo "error: a TandemClip built from this repo is running — quit it before packaging." >&2
    printf '       %s' "$REPO_RUNNERS" >&2
    echo "       It holds files open under build/, which corrupts the DMG that" >&2
    echo "       hdiutil creates, which then hangs notarization with no error." >&2
    exit 1
fi
if [[ -n "$INSTALLED_RUNNING" ]]; then
    echo "note: the installed /Applications copy is running (normal for a menu-bar app)."
    echo "      It holds nothing open under build/, so packaging continues."
fi

# 0b. Never clobber an already-built DMG for this version. `rm -f "$DMG"` below
#     would otherwise destroy a *released*, notarized artifact — and since step 4
#     regenerates the appcast from every DMG in dist/, the replacement gets
#     EdDSA-signed as that version, breaking auto-update for everyone already on
#     it. This also catches the plain mistake of forgetting to bump the version.
if [[ -f "$DMG" && "${FORCE_REBUILD:-}" != "1" ]]; then
    cat >&2 <<MSG
error: ${DMG} already exists — refusing to overwrite it.

  Version ${VERSION} (build ${BUILD_NUM}) looks already built/released. If this
  is a new release, bump CFBundleShortVersionString/CFBundleVersion in
  Packaging/Info.plist first.

  To rebuild this exact version on purpose:
      FORCE_REBUILD=1 Scripts/release.sh ...
MSG
    exit 1
fi

# 0c. The Sparkle signing key must match the SUPublicEDKey baked into shipped
#     builds. If it doesn't, generate_appcast still produces a perfectly
#     well-formed, EdDSA-signed appcast — and every installed copy REJECTS the
#     signature and silently stops updating. No error is shown to the user, and
#     nothing downstream can see it: the feed looks correct, the DMG downloads,
#     the release appears to succeed.
#
#     This is not hypothetical here. Keychain items on this machine have gone
#     missing before (the notarize profile has vanished more than once), and a
#     regenerated Sparkle key is indistinguishable from a working one until
#     users stop receiving updates. Check it BEFORE the build, not after.
#     Override with ALLOW_KEY_MISMATCH=1 only if you are deliberately rotating
#     the key AND shipping a build whose Info.plist carries the new public key.
GK_BIN="${GK_BIN:-$(find "$HOME/Library/Developer" "$HOME/Library/Caches/org.swift.swiftpm" ./.build 2>/dev/null -type f -name generate_keys -path '*Sparkle*' | head -1 || true)}"
PLIST_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Packaging/Info.plist 2>/dev/null || true)"
if [[ -n "${GK_BIN:-}" && -x "$GK_BIN" && -n "$PLIST_ED_KEY" ]]; then
    KEYCHAIN_ED_KEY="$("$GK_BIN" -p 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "$KEYCHAIN_ED_KEY" ]]; then
        echo "error: no Sparkle signing key found in the keychain." >&2
        echo "       generate_appcast would be unable to sign this release." >&2
        echo "       Restore the key, or regenerate with: $GK_BIN" >&2
        exit 1
    fi
    if [[ "$KEYCHAIN_ED_KEY" != "$PLIST_ED_KEY" ]]; then
        if [[ "${ALLOW_KEY_MISMATCH:-}" != "1" ]]; then
            cat >&2 <<MSG
error: Sparkle signing key does not match SUPublicEDKey in Packaging/Info.plist.

  keychain : $KEYCHAIN_ED_KEY
  Info.plist: $PLIST_ED_KEY

  Shipping this would produce a valid-looking appcast that EVERY installed copy
  rejects — auto-update stops working silently, with no error shown to users.

  Either restore the original signing key, or (if rotating on purpose) update
  SUPublicEDKey to the new public key and re-run with ALLOW_KEY_MISMATCH=1.
  Note a rotation only reaches users who update via a build signed with the OLD
  key, so ship the key change before relying on it.
MSG
            exit 1
        fi
        echo "WARNING: ALLOW_KEY_MISMATCH=1 — Sparkle key differs from SUPublicEDKey" >&2
    fi
    echo "==> Sparkle key matches SUPublicEDKey"
fi

# 0d. Run the artifact-independent half of the release gate NOW, before the build.
#     A missing changelog entry or a non-increasing build number is knowable in
#     one second; discovering it at step 4d costs a full build plus notarization
#     first. Same script, same rules — just the checks that need no DMG.
echo "==> Preflight gate (Scripts/check-release.sh, artifact-independent checks)"
PREFLIGHT_ONLY=1 Scripts/check-release.sh || {
    echo "error: preflight gate failed — nothing built. Fix the above and re-run." >&2
    exit 1
}

# 1. Build + sign + notarize + staple the .app (reuses make-app.sh).
BUILD_REQUIRES_CRASHBOX="$PUBLISH"
if [[ "$PREPARE_RELEASE" == "1" ]]; then
    BUILD_REQUIRES_CRASHBOX=1
fi
REQUIRE_CRASHBOX="$BUILD_REQUIRES_CRASHBOX" IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/make-app.sh

mkdir -p "$DIST"
rm -f "$DMG"

# 1b. Produce a private Crashbox upload artifact and prove that it matches the
#     application binary by UUID. This script deliberately does not contact a
#     provider or read an upload credential: an operator uploads the archive to
#     Crashbox through the protected artifact path and records the returned
#     artifact id before publishing. There is no hosted-provider fallback.
RELEASE_DSYM="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/tandemclip.dSYM"
if [[ -d "$RELEASE_DSYM" ]]; then
    APP_UUIDS="$(dwarfdump --uuid "$APP/Contents/MacOS/tandemclip" | awk '{print $2}' | LC_ALL=C sort)"
    DSYM_UUIDS="$(dwarfdump --uuid "$RELEASE_DSYM" | awk '{print $2}' | LC_ALL=C sort)"
    if [[ -z "$APP_UUIDS" || "$APP_UUIDS" != "$DSYM_UUIDS" ]]; then
        echo "error: release dSYM UUIDs do not match the application binary." >&2
        echo "       Refusing to package symbols that could never resolve this release." >&2
        exit 1
    fi
    SOURCE_COMMIT="$(git rev-parse HEAD)"
    DEBUG_ARCHIVE="${DIST}/${APP_NAME}_${VERSION}_${BUILD_NUM}_${SOURCE_COMMIT}.dSYM.zip"
    rm -f "$DEBUG_ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DSYM" "$DEBUG_ARCHIVE"
    EVENT_RELEASE="com.tandemclip@${VERSION}+${BUILD_NUM}.${SOURCE_COMMIT}"
    echo "==> Crashbox dSYM artifact ready (not uploaded)"
    echo "    archive: $DEBUG_ARCHIVE"
    echo "    sha256: $(shasum -a 256 "$DEBUG_ARCHIVE" | awk '{print $1}')"
    while IFS= read -r uuid; do echo "    uuid: $uuid"; done <<< "$DSYM_UUIDS"
elif [[ "${ALLOW_NO_SYMBOLS:-}" == "1" ]]; then
    echo "WARNING: ALLOW_NO_SYMBOLS=1 — shipping without a Crashbox dSYM artifact" >&2
else
    cat >&2 <<'MSG'
error: release dSYM is missing. Refusing to build a release whose crashes cannot
       be symbolicated in Crashbox.

  Fix dSYM generation, or ship without symbols deliberately:
      ALLOW_NO_SYMBOLS=1 Scripts/release.sh ...
MSG
    exit 1
fi

# 2. Stage the DMG (app + /Applications drop target) and build it.
echo "==> Building DMG $DMG"
STAGE="build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 2b. Verify the DMG is structurally sound BEFORE spending 5+ minutes on
#     notarization. A corrupt DMG makes `notarytool submit` hang rather than
#     fail cleanly, which then gets chased as a network/notary problem when it
#     is nothing of the sort. One second of `hdiutil verify` says it outright.
if ! hdiutil verify "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG failed hdiutil verify — refusing to notarize a corrupt image." >&2
    echo "       Rebuild it (delete dist/ and re-run); do not retry notarization." >&2
    exit 1
fi

# 3. Sign → notarize → staple the DMG (order matters).
if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing DMG"
    codesign --force --sign "$IDENTITY" "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarizing DMG"
    # `--timeout` covers the *wait for Apple's verdict*, not the upload — and the
    # upload is what hangs. `notarytool submit` sits at "initiating connection to
    # the Apple notary service" with nothing ever reaching `notarytool history`,
    # so the flag never fires and the release appears to be working. Observed
    # twice in one afternoon at 69 and 18 minutes, both killed by hand. An outer
    # wall clock plus retries turns an hour of silence into a hiccup, and fails
    # loudly instead of appearing to work.
    #
    # Diagnosis if all attempts fail: `xcrun notarytool history --keychain-profile
    # "$NOTARY_PROFILE" | head -20`. If this DMG is absent from that list, nothing
    # ever uploaded and waiting longer cannot help.
    command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }  # coreutils absent: run bare
    notarize_with_retry() {
        local attempt
        for attempt in 1 2 3; do
            if timeout 900 xcrun notarytool submit "$DMG" \
                 --keychain-profile "$NOTARY_PROFILE" --wait --timeout 12m; then
                return 0
            fi
            echo "    WARNING: notarization attempt $attempt did not complete within 15 minutes — retrying" >&2
            pkill -f "notarytool submit" 2>/dev/null || true
        done
        return 1
    }
    if ! notarize_with_retry; then
        echo "error: notarization failed after 3 attempts (15 min wall clock each)." >&2
        echo "       Check whether the upload ever landed:" >&2
        echo "         xcrun notarytool history --keychain-profile $NOTARY_PROFILE | head -20" >&2
        echo "       Absent from that list = nothing uploaded. Nothing was published or tagged." >&2
        exit 1
    fi
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

# 4b. Sync the Homebrew cask to this release. The cask pins version + sha256, so
#     without this it rots to an old DMG (same failure mode the landing page had).
#     Rewrites the committed Casks/tandemclip.rb in place; commit it with the bump.
#     The pinned value is "<short>,<build>" because the appcast carries both and
#     Homebrew's Sparkle livecheck reports them joined — pinning only the short
#     version fails `brew audit --online`. The URL uses version.csv.first.
CASK="Casks/tandemclip.rb"
if [[ -f "$CASK" ]]; then
    /usr/bin/sed -i '' -E \
        -e "s/^  version \"[0-9.]+(,[0-9]+)?\"/  version \"${VERSION},${BUILD_NUM}\"/" \
        -e "s/^  sha256 \"[0-9a-f]{64}\"/  sha256 \"${SHA}\"/" \
        "$CASK"
    echo "==> Cask synced: $CASK -> v$VERSION"
    echo "    (commit Casks/tandemclip.rb alongside the version bump)"
fi

# 4c. Sync the landing page to this release, for the same reason as the cask and
#     in the same place: BEFORE the gate, so the gate validates what will actually
#     be published rather than a source the publish step is about to rewrite.
#
#     This used to live in step 5, after the gate, reading a gitignored
#     `web/site/index.html` that did not exist. Both halves failed silently: the
#     links were never repointed, and the staleness check never ran. The live page
#     offered 0.24.1 for the whole of 0.24.2 as a result. Ordering it here also
#     removes the contradiction that made a naive path fix impossible, where the
#     gate demanded a synced source that only the later step could produce.
SITE_SRC="site/index.html"
if [[ -f "$SITE_SRC" ]]; then
    /usr/bin/sed -i '' -E \
        -e "s/TandemClip_[0-9]+\.[0-9]+\.[0-9]+_aarch64\.dmg/TandemClip_${VERSION}_aarch64.dmg/g" \
        -e "s/Version [0-9]+\.[0-9]+\.[0-9]+/Version ${VERSION}/g" \
        "$SITE_SRC"
    echo "==> Site synced: $SITE_SRC -> v$VERSION"
    echo "    (commit site/index.html alongside the version bump)"
fi

# 4d. Gate: every version-pinned surface must agree with this release before any
#     of it goes out. check-release.sh verifies the appcast, the cask (version
#     pin + sha256 against the real DMG), the README install steps, and the site
#     source. It used to be a script you had to remember to run, which is the same
#     as not having it — a stale cask and a two-releases-behind landing page both
#     shipped that way.
echo "==> Pre-publish gate (Scripts/check-release.sh)"
Scripts/check-release.sh || {
    echo "error: release gate failed — nothing published. Fix the above and re-run." >&2
    exit 1
}

if [[ "$PREPARE_RELEASE" == "1" ]]; then
    PREPARED_MANIFEST="${PREPARED_RELEASE_MANIFEST:-${DIST}/${APP_NAME}_${VERSION}_${BUILD_NUM}_${SOURCE_COMMIT}.prepared.json}"
    prepared_release write "$PREPARED_MANIFEST"
    echo "==> Prepared release paused before publication"
    echo "    manifest: $PREPARED_MANIFEST"
    echo "    Upload the dSYM archive privately, retain its Crashbox receipt, then"
    echo "    resume these exact bytes with PUBLISH=1 RESUME_PREPARED_RELEASE=$PREPARED_MANIFEST."
fi
fi

# The resume path deliberately bypasses the existing-DMG build guard: that DMG
# is required input, not stale output. Recheck all bytes and the receipt at the
# last possible moment before the first external write.
if [[ -n "$RESUME_MANIFEST" ]]; then
    verify_prepared_release
fi

# 5. Publish DMG + appcast + landing page to the web host (PUBLISH=1). Serves
#    the exact SUFeedURL. The landing page's download links are version-pinned,
#    The page's download links are version-pinned; step 4c already synced them
#    to VERSION and the gate verified it, so this just ships that file.
#    Set PUBLISH_DEST to your own scp/rsync target, e.g. user@host:/srv/site/.
if [[ "$PUBLISH" == "1" ]]; then
    DEST="${PUBLISH_DEST:-}"
    if [[ -z "$DEST" ]]; then
        echo "error: PUBLISH=1 but PUBLISH_DEST is unset (e.g. user@host:/srv/tandemclip/)" >&2
        exit 1
    fi
    echo "==> Publishing to $DEST"
    # Upload the DMG BEFORE the appcast, and land each file atomically (temp name
    # + mv). Two failure modes this closes: a half-written DMG being served while
    # scp is still streaming, and — if the run dies between the two copies — an
    # appcast advertising a build whose download 404s, which breaks auto-update
    # for everyone rather than merely delaying it. DMG-then-appcast means the
    # worst interruption leaves the feed pointing at the PREVIOUS good release.
    publish_atomic() {
        local src="$1" base; base="$(basename "$src")"
        if [[ "$DEST" == *:* ]]; then
            local host="${DEST%%:*}" dir="${DEST#*:}"
            dir="${dir%/}"
            scp -q "$src" "$host:$dir/.$base.tmp"
            ssh "$host" "mv -f '$dir/.$base.tmp' '$dir/$base'"
        else
            local dir="${DEST%/}"
            cp "$src" "$dir/.$base.tmp"
            mv -f "$dir/.$base.tmp" "$dir/$base"
        fi
    }
    publish_atomic "$DMG"
    [[ -f "$DIST/appcast.xml" ]] && publish_atomic "$DIST/appcast.xml"
    # Opt-in supporter list shown in the app + site footer (Support links).
    [[ -f "site/supporters.json" ]] && publish_atomic "site/supporters.json"

    # The page was already synced to VERSION in step 4c and the gate verified it,
    # so publish the source as-is rather than rendering a second copy that could
    # differ from the one that was checked.
    if [[ -f "$SITE_SRC" ]]; then
        publish_atomic "$SITE_SRC"
        echo "    published: $(basename "$DMG") + appcast.xml + index.html (v$VERSION)"
    else
        echo "    published: $(basename "$DMG") + appcast.xml"
    fi
    # 5b. Origin verify — check the artifact AS THE SERVER ACTUALLY SERVES IT,
    #     not the local file. Hashing the local DMG proves nothing: it can never
    #     fail, and it cannot see a truncated upload, a stale cached copy, or a
    #     proxy serving an error page with a 200. This is the only check that
    #     catches those, so it FAILS the release rather than printing a command
    #     for someone to remember to run. Compares sha256, not just byte length —
    #     length misses a same-size stale file.
    DL_URL="${APPCAST_BASE}/$(basename "$DMG")"
    echo "==> Origin verify: $DL_URL"
    TMP_DL="$(mktemp -t tandemclip-originverify)"
    trap 'rm -f "$TMP_DL"' EXIT
    if ! curl -fsSL --max-time 300 -o "$TMP_DL" "$DL_URL"; then
        echo "error: origin verify FAILED — $DL_URL is not fetchable." >&2
        echo "       The appcast may now advertise a build users cannot download." >&2
        exit 1
    fi
    REMOTE_SHA="$(shasum -a 256 "$TMP_DL" | awk '{print $1}')"
    REMOTE_LEN="$(wc -c < "$TMP_DL" | tr -d ' ')"
    LOCAL_LEN="$(wc -c < "$DMG" | tr -d ' ')"
    if [[ "$REMOTE_SHA" != "$SHA" ]]; then
        echo "error: origin verify FAILED — served bytes do not match the built DMG." >&2
        echo "       url   : $DL_URL" >&2
        echo "       served: $REMOTE_SHA ($REMOTE_LEN bytes)" >&2
        echo "       built : $SHA ($LOCAL_LEN bytes)" >&2
        echo "       Do NOT announce this release; re-publish and re-verify first." >&2
        exit 1
    fi
    echo "    origin verified: $REMOTE_LEN bytes, sha256 ${REMOTE_SHA:0:16}…"

    # The appcast must also be the one just written, or clients keep seeing the
    # previous feed from a cache while the DMG is already swapped.
    if [[ -f "$DIST/appcast.xml" ]]; then
        REMOTE_APPCAST_BUILD="$(curl -fsSL --max-time 60 "${APPCAST_BASE}/appcast.xml" 2>/dev/null \
            | perl -0ne 'if (/<sparkle:version>(\d+)<\/sparkle:version>/) { print $1; exit }' || true)"
        if [[ "$REMOTE_APPCAST_BUILD" != "$BUILD_NUM" ]]; then
            echo "error: origin verify FAILED — ${APPCAST_BASE}/appcast.xml advertises build" >&2
            echo "       ${REMOTE_APPCAST_BUILD:-missing}, expected $BUILD_NUM. Auto-update will not offer this release." >&2
            exit 1
        fi
        echo "    appcast verified: build $REMOTE_APPCAST_BUILD live"
    fi
fi
