#!/usr/bin/env bash
# notarize-retry.sh: sourced by release.sh. notarize_with_retry <dmg> <keychain profile>
# submits the DMG to Apple, each attempt under an outer wall clock, three attempts, and
# returns 1 if none completes.
#
# Why the outer clock: `notarytool submit --timeout` covers the *wait for Apple's
# verdict*, not the upload, and the upload is what hangs. It sits at "initiating
# connection to the Apple notary service" with nothing ever reaching `notarytool
# history`, so the flag never fires and the release appears to be working. Observed
# twice in one afternoon at 69 and 18 minutes, both killed by hand.
#
# Why no pkill (TBX-6235): this Mac runs several apps' releases at once. A timed-out
# attempt used to be followed by `pkill -f "notarytool submit"`, which matches every
# lane's notarization, not just ours. GNU timeout already owns the attempt: it runs the
# command in its own process group and signals that whole group on expiry, which reaches
# the notarytool that xcrun started and nothing outside it. So the clock is the reaper.
#
# The clock is required, not best effort. If neither `timeout` nor `gtimeout` (Homebrew
# coreutils) is installed, this refuses rather than running an unbounded attempt.
#
# NOTARIZE_ATTEMPT_SECONDS (default 900) and NOTARIZE_WAIT (default 12m, the verdict
# wait handed to notarytool) exist so the regression can run the loop in seconds.

notarize_timeout_bin() {
  local t
  for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q coreutils; then
      command -v "$t"; return 0
    fi
  done
  return 1
}

notarize_with_retry() {
  local dmg="$1" profile="$2" attempt tbin
  local secs="${NOTARIZE_ATTEMPT_SECONDS:-900}" wait="${NOTARIZE_WAIT:-12m}"
  tbin="$(notarize_timeout_bin)" || {
    echo "error: no GNU timeout (brew install coreutils), so a notarization attempt could not be bounded." >&2
    echo "       Refusing to run one that can hang for an hour. Nothing was submitted." >&2
    return 1
  }
  for attempt in 1 2 3; do
    if "$tbin" -k 30 "$secs" xcrun notarytool submit "$dmg" \
         --keychain-profile "$profile" --wait --timeout "$wait"; then
      return 0
    fi
    echo "    WARNING: notarization attempt $attempt did not complete within ${secs}s, retrying" >&2
  done
  return 1
}
