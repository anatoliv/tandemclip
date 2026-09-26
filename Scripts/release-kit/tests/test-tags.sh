#!/usr/bin/env bash
# test-tags.sh: rk_require_live_tag refuses an untagged live version, and rk_tag_release
# tags, pushes, confirms, is idempotent, and moves a tag only on RK_RETAG=1.
#
# Throwaway repos only: a bare "origin" and a clone. No network. RK_TAGS_SUBJECT points at
# a mutated copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_TAGS_SUBJECT:-$HERE/../lib/tags.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }
# shellcheck source=../lib/tags.sh
. "$SUBJECT"
unset RK_RETAG RK_TAG_PREFIX

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rk-tags.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"; mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global tag.gpgsign false

git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
R="$WORK/repo"
git -C "$R" commit -q --allow-empty -m one; C1="$(git -C "$R" rev-parse HEAD)"
git -C "$R" commit -q --allow-empty -m two; C2="$(git -C "$R" rev-parse HEAD)"
git -C "$R" push -q origin main
remote_tag() { git -C "$R" ls-remote origin "refs/tags/$1^{}" | cut -f1; }

# rk_require_live_tag
rk_require_live_tag 1.0.0 1.0.1 "$R" 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && ok "an untagged live version is refused" || bad "untagged live: rc=$rc"
grep -q "git tag -a v1.0.0" "$WORK/err" && ok "the refusal prints the command that fixes it" || bad "no fix command in: $(cat "$WORK/err")"
rk_require_live_tag 1.0.1 1.0.1 "$R" 2>/dev/null && ok "the version being built needs no tag yet" || bad "building == live was refused"
rk_require_live_tag "" 1.0.1 "$R" 2>/dev/null; [ $? = 2 ] && ok "an empty live version is an error, not a pass" || bad "empty live version passed"
git -C "$R" tag -a v1.0.0 "$C1" -m x
rk_require_live_tag 1.0.0 1.0.1 "$R" 2>/dev/null && ok "a tagged live version is admitted" || bad "tagged live version refused"
RK_TAG_PREFIX="" rk_require_live_tag 1.0.0 1.0.1 "$R" 2>/dev/null; [ $? = 1 ] && ok "RK_TAG_PREFIX changes the tag looked for" || bad "empty prefix still found v1.0.0"
git -C "$R" tag -d v1.0.0 >/dev/null

# rk_tag_release
out="$(rk_tag_release 2.0.0 "$C1" "App 2.0.0" origin "$R" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(remote_tag v2.0.0)" = "$C1" ] && ok "a new tag is created, pushed and confirmed on the remote" || bad "tag release: rc=$rc remote=$(remote_tag v2.0.0) out=$out"
[ "$(git -C "$R" cat-file -t v2.0.0)" = tag ] && ok "the tag is annotated" || bad "tag type $(git -C "$R" cat-file -t v2.0.0)"
rk_tag_release 2.0.0 "$C1" "App 2.0.0" origin "$R" >/dev/null 2>&1 && ok "re-running on the same commit is a no-op success" || bad "idempotent re-run failed"
rk_tag_release 2.0.0 "$C2" "App 2.0.0" origin "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(remote_tag v2.0.0)" = "$C1" ] && ok "a tag on another commit is refused and left alone" || bad "retarget without RK_RETAG: rc=$rc remote=$(remote_tag v2.0.0)"
RK_RETAG=1 rk_tag_release 2.0.0 "$C2" "App 2.0.0 again" origin "$R" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(remote_tag v2.0.0)" = "$C2" ] && ok "RK_RETAG=1 moves the tag locally and on the remote" || bad "RK_RETAG: rc=$rc remote=$(remote_tag v2.0.0)"
rk_tag_release 3.0.0 nosuchcommit "x" origin "$R" >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown commit is refused" || bad "unknown commit accepted"
rk_tag_release 3.0.0 "$C1" "" origin "$R" >/dev/null 2>&1; [ $? = 2 ] && ok "an empty message is refused" || bad "empty message accepted"

# The remote refuses the push (a pre-receive hook): the tag must not be reported as done.
printf '#!/bin/sh\necho "no tags today" >&2\nexit 1\n' >"$WORK/origin.git/hooks/pre-receive"
chmod +x "$WORK/origin.git/hooks/pre-receive"
rk_tag_release 4.0.0 "$C1" "App 4.0.0" origin "$R" >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && [ -z "$(remote_tag v4.0.0)" ] && ok "a rejected push is reported as a failure" || bad "rejected push: rc=$rc remote=$(remote_tag v4.0.0)"
grep -q "live but untagged" "$WORK/err" && ok "and it says the release is live but untagged" || bad "no explanation: $(cat "$WORK/err")"

# rk_record_release: a fresh origin and clone, with a cask the publish "rewrote".
rm -f "$WORK/origin.git/hooks/pre-receive"
rm -rf "$WORK/o2.git" "$WORK/r2" "$WORK/other"
git init -q --bare "$WORK/o2.git"
git clone -q "$WORK/o2.git" "$WORK/r2" 2>/dev/null
R2="$WORK/r2"
echo 'version "1.0"' >"$R2/cask.rb"; echo keep >"$R2/notes.txt"
git -C "$R2" add . && git -C "$R2" commit -q -m base && git -C "$R2" push -q origin main
o2_tag()  { git -C "$R2" ls-remote origin "refs/tags/$1^{}" | cut -f1; }
o2_main() { git -C "$R2" ls-remote origin refs/heads/main | cut -f1; }

echo 'version "1.1"' >"$R2/cask.rb"; echo "local scratch" >>"$R2/notes.txt"
( cd "$R2" && rk_record_release 1.1 "publish 1.1" cask.rb >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(o2_main)" = "$(git -C "$R2" rev-parse HEAD)" ] && [ "$(o2_tag v1.1)" = "$(o2_main)" ] \
  && ok "a changed cask is committed, pushed to main, and the tag names that commit" || bad "record: rc=$rc main=$(o2_main) tag=$(o2_tag v1.1)"
git -C "$R2" show --stat --format= HEAD | grep -q notes.txt && bad "an unlisted file was committed" || ok "only the listed paths are committed"
[ -n "$(git -C "$R2" status --porcelain notes.txt)" ] && ok "an unlisted change stays uncommitted in the tree" || bad "notes.txt lost its local change"
git -C "$R2" checkout -q -- notes.txt

( cd "$R2" && rk_record_release 1.1 "publish 1.1" cask.rb >/dev/null 2>&1 ) && ok "re-recording an already recorded release is a no-op success" || bad "second record failed"

git clone -q "$WORK/o2.git" "$WORK/other" 2>/dev/null
git -C "$WORK/other" commit -q --allow-empty -m "someone else" && git -C "$WORK/other" push -q origin main
echo 'version "1.2"' >"$R2/cask.rb"
( cd "$R2" && rk_record_release 1.2 "publish 1.2" cask.rb >/dev/null 2>"$WORK/err" ); rc=$?
[ "$rc" = 1 ] && [ -z "$(o2_tag v1.2)" ] && ok "a trunk that moved is refused, and nothing is tagged" || bad "moved trunk: rc=$rc tag=$(o2_tag v1.2)"
grep -q "live but its publish commit is not on main" "$WORK/err" && ok "and it says what is live and what to do" || bad "no explanation: $(cat "$WORK/err")"
( cd "$R2" && rk_record_release 1.2 "" cask.rb >/dev/null 2>&1 ); [ $? = 2 ] && ok "a missing message is a usage error" || bad "empty message accepted"
( cd "$R2" && rk_record_release 1.2 "publish" >/dev/null 2>&1 ); [ $? = 2 ] && ok "no paths is a usage error" || bad "no paths accepted"

echo "tags: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
