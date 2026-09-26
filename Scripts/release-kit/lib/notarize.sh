#!/usr/bin/env bash
# notarize.sh: submit a file to Apple's notary service with a bounded retry.
# Part of the release kit (~/Projects/_method/release-kit.md). Source it, then:
#   rk_notarize <file> <keychain-profile> || { <print diagnosis>; exit 1; }
#
# Why an outer clock: `notarytool submit --timeout` bounds the wait for Apple's verdict,
# not the upload, and the upload is what hangs. It sits at "initiating connection to the
# Apple notary service" and nothing reaches `notarytool history`. Observed at 69 and 18
# minutes in one afternoon, both killed by hand.
#
# Why no pkill: several apps' releases run on one Mac at once, and
# `pkill -f "notarytool submit"` matches all of them. It is not needed. xcrun execs the
# tool, so notarytool runs as the direct child of GNU timeout and in its process group
# (verified 2026-09-25), and timeout signals that group when the clock fires. The clock
# reaps our attempt and nothing else.
#
# The clock must be real. A `timeout` shell function or stub ahead of coreutils would run
# the attempt unbounded, so the clock is proven first: a 1s limit over a 3s sleep must
# exit 124. Without a working GNU timeout this refuses, having submitted nothing.
#
# RK_NOTARIZE_ATTEMPTS (3), RK_NOTARIZE_ATTEMPT_SECONDS (900) and RK_NOTARIZE_WAIT (12m,
# handed to notarytool as its verdict wait) exist so tests can run the loop in seconds.

# rk_notarize_clock: print the path of a GNU timeout that has been seen to interrupt a
# command, or return 1.
rk_notarize_clock() {
  local t bin rc
  for t in timeout gtimeout; do
    bin="$(type -P "$t" 2>/dev/null)" || continue
    "$bin" --version 2>/dev/null | grep -q coreutils || continue
    "$bin" 1 sleep 3 >/dev/null 2>&1; rc=$?
    if [ "$rc" = 124 ]; then printf '%s\n' "$bin"; return 0; fi
    echo "rk_notarize: $bin did not interrupt a command that outlived it (exit $rc, want 124)." >&2
  done
  return 1
}

rk_notarize() {
  local file="$1" profile="$2" attempt clock
  local attempts="${RK_NOTARIZE_ATTEMPTS:-3}" secs="${RK_NOTARIZE_ATTEMPT_SECONDS:-900}"
  local wait="${RK_NOTARIZE_WAIT:-12m}"
  if [ -z "$file" ] || [ -z "$profile" ]; then
    echo "rk_notarize: usage: rk_notarize <file> <keychain-profile>" >&2; return 2
  fi
  [ -f "$file" ] || { echo "rk_notarize: no such file: $file" >&2; return 2; }
  clock="$(rk_notarize_clock)" || {
    echo "rk_notarize: no working GNU timeout (brew install coreutils), so an attempt could not be bounded." >&2
    echo "             Refusing to run one that can hang for an hour. Nothing was submitted." >&2
    return 1
  }
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$clock" -k 30 "$secs" xcrun notarytool submit "$file" \
         --keychain-profile "$profile" --wait --timeout "$wait"; then
      return 0
    fi
    echo "    WARNING: notarization attempt $attempt/$attempts of $(basename "$file") did not complete within ${secs}s" >&2
  done
  echo "rk_notarize: $attempts attempts failed. Did the upload ever land?" >&2
  echo "             xcrun notarytool history --keychain-profile $profile | head -20" >&2
  echo "             Absent from that list = nothing uploaded; waiting longer cannot help." >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rk_notarize "$@"
fi
