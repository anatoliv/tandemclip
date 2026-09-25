#!/usr/bin/env bash
# test-notarize-retry.sh: prove the notarization retry loop bounds each attempt, keeps
# three attempts and fails closed, and never signals a notarization it did not start
# (TBX-6235).
#
# Hermetic: xcrun and pkill are stubs on PATH, attempts are shortened to 1 second, and a
# decoy process whose command line reads "notarytool submit" stands in for another app's
# release. Nothing reaches Apple.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${NOTARIZE_RETRY_SUBJECT:-$HERE/notarize-retry.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no helper at $SUBJECT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize-retry.XXXXXX")"
DECOY=""
cleanup() { [ -z "$DECOY" ] || kill "$DECOY" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

REAL_TIMEOUT=""
for t in timeout gtimeout; do
  if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q coreutils; then
    REAL_TIMEOUT="$(command -v "$t")"; break
  fi
done
[ -n "$REAL_TIMEOUT" ] || { echo "SKIP  GNU timeout is not installed (brew install coreutils)"; exit 0; }

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
CALLS="$WORK/xcrun.log"; PKILL="$WORK/pkill.log"; CHILD="$WORK/child.pid"
ln -s "$REAL_TIMEOUT" "$STUBS/timeout"
printf '#!/bin/sh\necho "pkill $*" >>"%s"\nexit 0\n' "$PKILL" >"$STUBS/pkill"
cp "$STUBS/pkill" "$STUBS/killall"
# xcrun stub. XCRUN_MODE: hang (starts a child "notarytool" and waits on it, as xcrun
# does, so the test can see whether the clock reaps the child), fail, or ok-on-N.
cat >"$STUBS/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >>"$CALLS"
n=\$(wc -l <"$CALLS" | tr -d ' ')
case "\${XCRUN_MODE:-fail}" in
  hang) sleep 300 & echo \$! >>"$CHILD"; wait ;;
  ok-on-*) [ "\$n" -ge "\${XCRUN_MODE#ok-on-}" ] && exit 0; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUBS"/*

run() {  # run <mode> [extra env...]: source the helper and call it in a clean shell
  local mode="$1"; shift
  : >"$CALLS"; : >"$PKILL"; : >"$CHILD"
  env "$@" PATH="$STUBS:/usr/bin:/bin" XCRUN_MODE="$mode" NOTARIZE_ATTEMPT_SECONDS=1 \
    bash -c '. "$1"; notarize_with_retry /tmp/x.dmg prof' _ "$SUBJECT" >"$WORK/out" 2>&1
}

# A decoy: another lane's notarization, as `pkill -f "notarytool submit"` would match it.
bash -c 'exec -a "xcrun notarytool submit Other.dmg --wait" sleep 300' &
DECOY=$!
sleep 0.2

# 1. Every attempt hangs: three attempts, fail closed, each bounded.
start=$SECONDS
run hang; rc=$?; took=$((SECONDS-start))
[ "$rc" = 1 ] && ok "three hung attempts fail closed" || bad "hung attempts returned $rc, want 1"
[ "$(wc -l <"$CALLS" | tr -d ' ')" = 3 ] && ok "exactly three attempts are made" || bad "attempts: $(wc -l <"$CALLS")"
[ "$took" -lt 20 ] && ok "each attempt is bounded by the outer clock (${took}s for three)" || bad "three 1s attempts took ${took}s"

# 2. The clock reaps the child it started.
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done <"$CHILD"
[ "$alive" = 0 ] && ok "the hung attempt's own notarytool child is reaped" || bad "$alive attempt children still running"

# 3. It never reaches for a machine-wide kill, and another lane's notarization survives.
[ ! -s "$PKILL" ] && ok "no pkill or killall is invoked" || bad "invoked: $(cat "$PKILL")"
kill -0 "$DECOY" 2>/dev/null && ok "another lane's notarytool process is left running" || bad "the decoy notarization was killed"
if grep -vE '^[[:space:]]*#' "$SUBJECT" "$HERE/release.sh" | grep -qE '\b(pkill|killall)\b'; then
  bad "pkill or killall is still executable code in the helper or release.sh"
else
  ok "neither the helper nor release.sh runs pkill or killall"
fi

# 4. Plain failures retry too, and a later success stops the loop.
run fail; rc=$?
[ "$rc" = 1 ] && [ "$(wc -l <"$CALLS" | tr -d ' ')" = 3 ] && ok "three failed attempts fail closed" || bad "failed attempts: rc=$rc calls=$(wc -l <"$CALLS")"
run ok-on-2; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$CALLS" | tr -d ' ')" = 2 ] && ok "success on attempt 2 returns 0 without a third" || bad "ok-on-2: rc=$rc calls=$(wc -l <"$CALLS")"
grep -q -- "--keychain-profile prof --wait --timeout 12m" "$CALLS" && ok "the DMG, profile and verdict wait reach notarytool" || bad "xcrun got: $(head -1 "$CALLS")"

# 5. No GNU timeout on PATH: refuse, submit nothing.
rm "$STUBS/timeout"
: >"$CALLS"
env PATH="$STUBS:/usr/bin:/bin" NOTARIZE_ATTEMPT_SECONDS=1 \
  bash -c '. "$1"; notarize_with_retry /tmp/x.dmg prof' _ "$SUBJECT" >"$WORK/out" 2>&1; rc=$?
if [ -x /usr/bin/timeout ] && /usr/bin/timeout --version 2>/dev/null | grep -q coreutils; then
  ok "(a system GNU timeout exists, so the missing-clock case cannot be staged here)"
else
  [ "$rc" = 1 ] && [ ! -s "$CALLS" ] && grep -q "could not be bounded" "$WORK/out" \
    && ok "without a GNU timeout it refuses and submits nothing" \
    || bad "no-timeout: rc=$rc calls=$(wc -l <"$CALLS") out=$(head -c 200 "$WORK/out")"
fi

echo "notarize-retry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
