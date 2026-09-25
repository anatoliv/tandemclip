#!/usr/bin/env bash
# test-release-main-guard.sh: plant unmerged commits and watch scripts/release-main-guard.sh
# refuse them (TBX-7466, ESTATE E19).
#
# Throwaway repos only: a bare "origin", a clone that releases, and a second clone that
# pushes behind its back. No network. Point RELEASE_MAIN_GUARD_SUBJECT at a mutated copy
# to prove a check can fail. The same file is copied into every repo that carries the guard.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${RELEASE_MAIN_GUARD_SUBJECT:-$HERE/release-main-guard.sh}"
[ -f "$GUARD" ] || { echo "FAIL  no guard at $GUARD"; exit 1; }
unset ALLOW_UNMERGED_RELEASE RELEASE_MAIN_GUARD_REMOTE RELEASE_MAIN_GUARD_BRANCH

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
expect_refused() {   # <name> <rc> <output> <text the refusal must contain>
  if [ "$2" = 0 ]; then bad "$1 (it was admitted)"
  elif ! grep -qF -- "$4" <<<"$3"; then bad "$1 (refused without saying '$4'). Got: $(head -c 600 <<<"$3")"
  else ok "$1"; fi
}
expect_admitted() {  # <name> <rc> <output> [text the output must contain]
  if [ "$2" != 0 ]; then bad "$1 (refused). Got: $(head -c 600 <<<"$3")"
  elif [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$3"; then bad "$1 (admitted without saying '$4'). Got: $(head -c 600 <<<"$3")"
  else ok "$1"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-main-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"; mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/rel" 2>/dev/null
git -C "$WORK/rel" commit -q --allow-empty -m "initial"
git -C "$WORK/rel" push -q origin HEAD:main
git clone -q "$WORK/origin.git" "$WORK/other"

run_guard() {   # run the guard as a release script would: sourced, in the checkout
  (cd "$WORK/rel" && . "$GUARD" && release_main_guard) 2>&1
}

# 1. HEAD is origin/main: admitted.
out="$(run_guard)"; rc=$?
expect_admitted "HEAD equal to origin/main is admitted" "$rc" "$out" "is contained in origin/main"

# 2. The E19 shape: a commit that exists only on the releasing checkout.
git -C "$WORK/rel" commit -q --allow-empty -m "planted hotfix never merged"
out="$(run_guard)"; rc=$?
expect_refused "a planted unmerged commit is refused" "$rc" "$out" "is not contained in origin/main"
expect_refused "the refusal names the missing commit" "$rc" "$out" "planted hotfix never merged"
expect_refused "the refusal names the override" "$rc" "$out" "ALLOW_UNMERGED_RELEASE"

# 3. A stale local origin/main that claims HEAD is merged proves nothing: the guard fetches.
git -C "$WORK/rel" update-ref refs/remotes/origin/main HEAD
out="$(run_guard)"; rc=$?
expect_refused "a faked local origin/main is overwritten by the fetch" "$rc" "$out" "planted hotfix never merged"

# 4. Executed rather than sourced, from another directory: same refusal, exit status 1.
out="$(cd "$WORK" && bash "$GUARD" "$WORK/rel" 2>&1)"; rc=$?
expect_refused "executed with a repo argument, it refuses too" "$rc" "$out" "planted hotfix never merged"

# 5. Once the commit is on main (pushed from anywhere), the same HEAD is admitted, even
#    though this checkout's origin/main has not been updated yet.
git -C "$WORK/rel" push -q "$WORK/origin.git" HEAD:refs/heads/main
git -C "$WORK/rel" update-ref refs/remotes/origin/main "$(git -C "$WORK/rel" rev-parse HEAD~1)"
out="$(run_guard)"; rc=$?
expect_admitted "a commit merged since the last fetch is admitted" "$rc" "$out" "is contained in origin/main"

# 6. An older commit of main is still contained: releasing it is allowed (a rollback).
out="$(cd "$WORK/rel" && git checkout -q HEAD~1 && . "$GUARD" && release_main_guard 2>&1)"; rc=$?
git -C "$WORK/rel" checkout -q main
expect_admitted "an ancestor of origin/main (rollback) is admitted" "$rc" "$out"

# 7. main moved on without this checkout's new commit: refused, and names only that one.
git -C "$WORK/other" pull -q origin main 2>/dev/null
git -C "$WORK/other" commit -q --allow-empty -m "someone else's merged work"
git -C "$WORK/other" push -q origin HEAD:main
git -C "$WORK/rel" commit -q --allow-empty -m "second planted fix"
out="$(run_guard)"; rc=$?
expect_refused "a branch off an older main with its own commit is refused" "$rc" "$out" "second planted fix"
if grep -qF "someone else's merged work" <<<"$out"; then bad "the refusal lists commits main has, not only the missing one"; else ok "the refusal lists only the missing commit"; fi

# 8. A failed fetch refuses: an unreachable origin cannot vouch for anything.
git -C "$WORK/rel" remote set-url origin "$WORK/no-such-origin.git"
out="$(run_guard)"; rc=$?
expect_refused "an unreachable origin is refused" "$rc" "$out" "could not fetch origin/main"
git -C "$WORK/rel" remote set-url origin "$WORK/origin.git"

# 9. The override admits the release, logs it, and prints the merge-back card text.
HOTFIX="$(git -C "$WORK/rel" rev-parse HEAD)"
out="$(cd "$WORK/rel" && ALLOW_UNMERGED_RELEASE="prod is down, TBX-0000" bash -c '. "$1" && release_main_guard' _ "$GUARD" 2>&1)"; rc=$?
expect_admitted "ALLOW_UNMERGED_RELEASE admits an unmerged HEAD" "$rc" "$out" "MERGE-BACK REQUIRED"
expect_admitted "the override prints the card text with the reason" "$rc" "$out" "Reason: prod is down, TBX-0000"
LOG="$WORK/rel/.git/unmerged-releases.log"
if grep -qF "$HOTFIX" "$LOG" 2>/dev/null && grep -qF "prod is down, TBX-0000" "$LOG"; then
  ok "the override is logged with the commit and the reason"
else
  bad "the override left no log line in $LOG"
fi

# 10. An empty override is no override.
out="$(cd "$WORK/rel" && ALLOW_UNMERGED_RELEASE="" bash -c '. "$1" && release_main_guard' _ "$GUARD" 2>&1)"; rc=$?
expect_refused "an empty ALLOW_UNMERGED_RELEASE does not override" "$rc" "$out" "is not contained in origin/main"

# 11. The next release from main, which lacks the logged hotfix, is admitted but warned.
git -C "$WORK/rel" checkout -q -b from-main origin/main 2>/dev/null
out="$(run_guard)"; rc=$?
expect_admitted "a release from main after an override is admitted" "$rc" "$out" "is contained in origin/main"
expect_admitted "and it warns that the logged hotfix would be taken back" "$rc" "$out" "$(git -C "$WORK/rel" rev-parse --short=12 "$HOTFIX")"

# 12. Once the hotfix is merged, the warning stops.
git -C "$WORK/rel" merge -q --no-edit "$HOTFIX" 2>/dev/null
git -C "$WORK/rel" push -q origin HEAD:main
out="$(run_guard)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qF "WARNING" <<<"$out"; then ok "a merged hotfix is no longer warned about"; else bad "a merged hotfix still warns or refuses. Got: $(head -c 600 <<<"$out")"; fi

# 13. A linked worktree logs to the shared git dir, where every checkout of the repo sees it.
git -C "$WORK/rel" worktree add -q "$WORK/wt" -b wt-branch origin/main 2>/dev/null
git -C "$WORK/wt" commit -q --allow-empty -m "worktree hotfix"
out="$(cd "$WORK/wt" && ALLOW_UNMERGED_RELEASE="worktree case" bash -c '. "$1" && release_main_guard' _ "$GUARD" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qF "worktree case" "$LOG"; then ok "a worktree override lands in the shared log"; else bad "a worktree override did not reach $LOG. Got: $(head -c 400 <<<"$out")"; fi

echo "release-main-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
