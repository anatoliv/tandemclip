#!/usr/bin/env bash
# test-release-entry-main-guard.sh: drive the real Scripts/release.sh against a planted
# unmerged commit and prove it refuses before any side effect.
#
# Hermetic: a throwaway repo holding this checkout's Scripts/ and Packaging/Info.plist, a
# bare local "origin", a temp HOME, and every side-effecting tool stubbed on PATH to log
# its name and fail. No network, no build, nothing reaches Apple or a web host.
#
# Admitted runs are stopped just past the guard by a later, real check: the prepare path
# by the "a TandemClip built from this repo is running" guard (fed by stubbed pgrep/ps),
# the resume path by prepared-release.py refusing a manifest that does not exist.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
unset ALLOW_UNMERGED_RELEASE RELEASE_MAIN_GUARD_REMOTE RELEASE_MAIN_GUARD_BRANCH
unset IDENTITY NOTARY_PROFILE PUBLISH PREPARE_RELEASE RESUME_PREPARED_RELEASE \
      VERIFY_PREPARED_RELEASE_ONLY PUBLISH_DEST FORCE_REBUILD ALLOW_NO_SYMBOLS

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-entry-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"; mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# Side-effecting tools: log the name, fail closed. pgrep/ps are read-only and only used to
# stop an admitted prepare run at the repo-runner check; they log to a separate file.
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
SIDE="$WORK/side-effects.log"; REACHED="$WORK/reached.log"; : >"$SIDE"; : >"$REACHED"
for tool in ssh scp rsync curl xcrun notarytool codesign spctl hdiutil swift gh docker \
            ditto dwarfdump unzip stapler; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$tool" "$SIDE" >"$STUBS/$tool"
done
printf '#!/bin/sh\nexit 0\n' >"$STUBS/caffeinate"
printf '#!/bin/sh\necho "pgrep $*" >>"%s"\necho 4242\n' "$REACHED" >"$STUBS/pgrep"
printf '#!/bin/sh\necho "ps $*" >>"%s"\necho ./build/tandemclip\n' "$REACHED" >"$STUBS/ps"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export GK_BIN=/nonexistent GA_BIN=/nonexistent

# The fixture carries this checkout's release.sh and guard, as they are on disk now.
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/rel" 2>/dev/null
mkdir -p "$WORK/rel/Packaging"
cp -R "$ROOT/Scripts" "$WORK/rel/Scripts"
cp -R "$ROOT/.githooks" "$WORK/rel/.githooks"
cp "$ROOT/Packaging/Info.plist" "$WORK/rel/Packaging/Info.plist"
git -C "$WORK/rel" add -A
git -C "$WORK/rel" commit -qm "fixture on main"
git -C "$WORK/rel" push -q origin HEAD:main
# The secret-scan hook, active as release.sh requires. Set after the fixture's push, so
# the hook does not scan the fixture on its way to a bare repo it would treat as public.
git -C "$WORK/rel" config core.hooksPath .githooks

prepare() {
  (cd "$WORK/rel" && IDENTITY="Developer ID Application: Test (TEAMID0000)" \
     NOTARY_PROFILE=test-profile PREPARE_RELEASE=1 PUBLISH=0 Scripts/release.sh) 2>&1
}
resume() {  # [VERIFY_PREPARED_RELEASE_ONLY]
  (cd "$WORK/rel" && PUBLISH=1 RESUME_PREPARED_RELEASE="$WORK/none.prepared.json" \
     CRASHBOX_ARTIFACT_RECEIPT_FILE="$WORK/none.receipt.json" \
     TANDEMCLIP_CRASHBOX_PROJECT_ID=00000000-0000-4000-8000-000000000000 \
     PUBLISH_DEST="$WORK/dest/" VERIFY_PREPARED_RELEASE_ONLY="${1:-0}" \
     Scripts/release.sh) 2>&1
}
local_build() {
  (cd "$WORK/rel" && PUBLISH=0 PREPARE_RELEASE=0 Scripts/release.sh) 2>&1
}

reset_logs() { : >"$SIDE"; : >"$REACHED"; }
check_refused() {  # <name> <rc> <out>
  if [ "$2" = 0 ]; then bad "$1: exited 0"; return; fi
  if ! grep -qF "RELEASE REFUSED" <<<"$3"; then bad "$1: no RELEASE REFUSED. Got: $(head -c 600 <<<"$3")"; return; fi
  if ! grep -qF "planted fix never merged" <<<"$3"; then bad "$1: refusal does not name the commit"; return; fi
  if [ -s "$SIDE" ]; then bad "$1: side effect before refusal: $(cat "$SIDE")"; return; fi
  if [ -s "$REACHED" ]; then bad "$1: ran past the guard: $(cat "$REACHED")"; return; fi
  ok "$1"
}
check_admitted() {  # <name> <rc> <out> <text of the later check that stopped it>
  if ! grep -qF "release main guard ok" <<<"$3"; then bad "$1: guard did not admit. Got: $(head -c 600 <<<"$3")"; return; fi
  if grep -qF "RELEASE REFUSED" <<<"$3"; then bad "$1: refused"; return; fi
  if ! grep -qF "$4" <<<"$3"; then bad "$1: did not reach the later check '$4'. Got: $(head -c 600 <<<"$3")"; return; fi
  if [ -s "$SIDE" ]; then bad "$1: side effect reached: $(cat "$SIDE")"; return; fi
  ok "$1"
}

# 1. HEAD is origin/main: both halves of a publication get past the guard.
reset_logs; out="$(prepare)"; rc=$?
check_admitted "prepare from origin/main passes the guard" "$rc" "$out" "built from this repo is running"
reset_logs; out="$(resume)"; rc=$?
check_admitted "resume from origin/main passes the guard" "$rc" "$out" "prepared_"

# 1b. The secret-scan hook is off: both halves of a publication refuse before any side
#     effect, and say how to turn it on.
git -C "$WORK/rel" config --unset core.hooksPath
for half in prepare resume; do
  reset_logs; out="$($half)"; rc=$?
  if [ "$rc" = 0 ]; then bad "$half with the hook off: exited 0"
  elif ! grep -qF "pre-push hook is not active" <<<"$out" || ! grep -qF "config core.hooksPath .githooks" <<<"$out"; then
    bad "$half with the hook off: no hook refusal. Got: $(head -c 600 <<<"$out")"
  elif [ -s "$SIDE" ] || [ -s "$REACHED" ]; then bad "$half with the hook off: ran past the check"
  else ok "$half with the hook off is refused before any side effect"; fi
done
git -C "$WORK/rel" config core.hooksPath .githooks

# 2. The E19 shape: a fix committed on the releasing checkout and never merged.
echo "hotfix" >"$WORK/rel/HOTFIX"
git -C "$WORK/rel" add HOTFIX
git -C "$WORK/rel" commit -qm "planted fix never merged"

reset_logs; out="$(prepare)"; rc=$?
check_refused "prepare of an unmerged commit is refused before the build" "$rc" "$out"
reset_logs; out="$(resume)"; rc=$?
check_refused "resume (publish) of an unmerged commit is refused before any upload" "$rc" "$out"
reset_logs; out="$(resume 1)"; rc=$?
check_refused "the VERIFY_PREPARED_RELEASE_ONLY rehearsal refuses it too" "$rc" "$out"

# 3. A local build publishes nothing and is not gated on main.
reset_logs; out="$(local_build)"; rc=$?
if grep -qF "release main guard" <<<"$out" || grep -qF "RELEASE REFUSED" <<<"$out"; then
  bad "a local build (PUBLISH=0, PREPARE_RELEASE=0) ran the guard"
elif ! grep -qF "built from this repo is running" <<<"$out" || [ -s "$SIDE" ]; then
  bad "a local build did not reach the repo-runner check cleanly. Got: $(head -c 600 <<<"$out")"
else
  ok "a local build (PUBLISH=0, PREPARE_RELEASE=0) is not gated"
fi

echo "release.sh main guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
