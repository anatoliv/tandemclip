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
#   PUBLISH=1 PUBLISH_DEST=user@host:/path (rsync/scp the DMG + appcast + page)
#   SENTRY_ORG / SENTRY_PROJECT           (dSYM upload; skipped if org unset)

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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
DIST="dist"
APP="build/${APP_NAME}.app"
DMG="${DIST}/${APP_NAME}_${VERSION}_aarch64.dmg"

# One Sentry *organization* token covers every project in the org, so it is
# stored once under a shared Keychain item rather than copied per project —
# otherwise rotating it means updating N items and silently missing one. The
# older per-project item is still honored so existing setups keep working.
SENTRY_KEYCHAIN_ITEMS=(sentry-release-token tandemclip-sentry)
sentry_token_from_keychain() {
    local item
    for item in "${SENTRY_KEYCHAIN_ITEMS[@]}"; do
        if security find-generic-password -s "$item" -w 2>/dev/null; then return 0; fi
    done
    return 1
}

# 0. Preflight: catch a missing symbolication token BEFORE the long build and
#    notarization, not as a warning partway down a log nobody re-reads. 0.23.0
#    shipped unsymbolicated exactly that way. Set ALLOW_NO_SYMBOLS=1 to ship
#    anyway (a deliberate choice, rather than one made by not noticing).
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]] \
   && ! sentry_token_from_keychain >/dev/null 2>&1; then
    if [[ "${ALLOW_NO_SYMBOLS:-}" != "1" ]]; then
        cat >&2 <<'MSG'
error: no Sentry auth token — this release would ship without symbolicated
       crash reports (stack traces with no function names or line numbers).

  Store one once (needs the project:releases scope):
      security add-generic-password -U -s sentry-release-token -a sentry -w
      (bare -w prompts hidden, so the token stays out of shell history)

  Or ship without symbols deliberately:
      ALLOW_NO_SYMBOLS=1 Scripts/release.sh ...
MSG
        exit 1
    fi
    echo "WARNING: ALLOW_NO_SYMBOLS=1 — shipping without symbolicated crash reports" >&2
fi

# 0a1. A published release must be reproducible from a commit. Refuse a dirty
#      tree when actually publishing, so the tag describes what shipped rather
#      than what happened to be on disk.
#
#      Only when PUBLISH=1: local test builds from a working tree are the normal
#      way to develop. Note the tree WILL be dirty when this script finishes, by
#      design — step 4b rewrites Casks/tandemclip.rb and step 5 rewrites
#      web/site/index.html once the DMG exists, so they land one commit behind
#      the tag. That is expected; commit them after a successful run.
if [[ "${PUBLISH:-}" == "1" && -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "error: working tree is dirty — commit or stash before publishing." >&2
    echo "       A release must be reproducible from a commit; otherwise the tag" >&2
    echo "       does not describe what actually shipped." >&2
    git status --short >&2
    exit 1
fi

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
IDENTITY="$IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/make-app.sh

mkdir -p "$DIST"
rm -f "$DMG"

# 1b. Upload dSYMs to Sentry for symbolicated crash reports. Token comes from
#     the environment or, failing that, the shared Keychain item (see above)
#     (create once with:
#       security add-generic-password -U -s sentry-release-token -a sentry -w
#       — bare -w prompts hidden, keeping the token out of shell history —
#     token needs project:releases scope). Missing token WARNS — a release
#     without dSYMs means unsymbolicated crash reports, which you want to know.
if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    SENTRY_AUTH_TOKEN="$(sentry_token_from_keychain || true)"
    export SENTRY_AUTH_TOKEN
fi
if [[ -n "${SENTRY_AUTH_TOKEN:-}" && -n "${SENTRY_ORG:-}" ]] && command -v sentry-cli >/dev/null 2>&1; then
    echo "==> Uploading dSYMs to Sentry"
    # Upload the shipped bundle (app + Sparkle, i.e. everything a user can crash
    # in) and the matching release dSYM — NOT all of .build, which also holds the
    # SwiftPM artifacts cache: Sentry-cocoa's iOS/visionOS/simulator slices and
    # debug-build copies, none of which this macOS app can ever crash in. They
    # just burn upload time and Sentry storage.
    SENTRY_UPLOAD_PATHS=("$APP")
    RELEASE_DSYM="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/tandemclip.dSYM"
    [[ -d "$RELEASE_DSYM" ]] && SENTRY_UPLOAD_PATHS+=("$RELEASE_DSYM")
    sentry-cli debug-files upload --org "${SENTRY_ORG}" \
        --project "${SENTRY_PROJECT:-tandemclip}" "${SENTRY_UPLOAD_PATHS[@]}" 2>&1 | tail -3 || \
        echo "    dSYM upload failed (non-fatal)"
else
    echo "WARNING: no SENTRY_AUTH_TOKEN + SENTRY_ORG — shipping without symbolicated crash reports" >&2
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

# 5. Publish DMG + appcast + landing page to the web host (PUBLISH=1). Serves
#    the exact SUFeedURL. The landing page's download links are version-pinned,
#    so render the current VERSION into a copy of web/site/index.html before
#    publishing — otherwise the "Download" button rots to a DMG that 404s.
#    Set PUBLISH_DEST to your own scp/rsync target, e.g. user@host:/srv/site/.
if [[ "${PUBLISH:-}" == "1" ]]; then
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
    # Opt-in supporter list shown in the app + site footer (Support links). Not versioned.
    [[ -f "web/site/supporters.json" ]] && publish_atomic "web/site/supporters.json"

    SITE_SRC="web/site/index.html"
    if [[ -f "$SITE_SRC" ]]; then
        RENDERED="$DIST/index.html"
        # Repoint every versioned DMG link and the "Version x.y.z" line at VERSION.
        sed -E "s/TandemClip_[0-9]+\.[0-9]+\.[0-9]+_aarch64\.dmg/TandemClip_${VERSION}_aarch64.dmg/g; \
                s/Version [0-9]+\.[0-9]+\.[0-9]+/Version ${VERSION}/g" \
            "$SITE_SRC" > "$RENDERED"
        publish_atomic "$RENDERED"
        # Also write the version back into the SOURCE. Rendering only into $RENDERED
        # left web/site/index.html pinned at whatever release last touched it by hand
        # (it sat at 0.22.7 while 0.24.1 was live), so anyone deploying the source
        # directly would silently DOWNGRADE the page and link a DMG that may be gone.
        cp "$RENDERED" "$SITE_SRC"
        echo "    site source synced to v$VERSION (commit web/site/index.html)"
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
