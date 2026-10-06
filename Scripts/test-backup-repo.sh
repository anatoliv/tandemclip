#!/usr/bin/env bash
#
# Scripts/backup-repo.sh against a local bare remote.
#
# WHY THIS EXISTS. The backup was a bare `git push --all` under `set -e`. A local branch
# that is only BEHIND the remote is already backed up (the remote holds every commit it
# has), but `--all` rejects it as non-fast-forward, so one stale local branch failed the
# whole nightly backup and skipped the tags with nothing actually missing. These cases pin
# the three answers a branch can get: pushed, already covered, or refused because it
# diverged. No network, no build, about a second.
#
# Scripts/backup-repo.sh is local ops tooling and is not tracked, so a checkout without it
# skips. BACKUP_REPO_SCRIPT points the test at another copy (to prove it fails on the old one).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SOURCE="${BACKUP_REPO_SCRIPT:-$PWD/Scripts/backup-repo.sh}"
if [ ! -f "$SOURCE" ]; then echo "skipped: Scripts/backup-repo.sh is not in this checkout"; exit 0; fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/backup-repo-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global tag.gpgsign false
unset TANDEMCLIP_BACKUP_REMOTE DRY_RUN

q() { git "$@" >/dev/null 2>&1; }

# A fresh bare remote, a local clone carrying the script under test, and a second clone
# that plays "another worktree pushed to main".
setup() {
  rm -rf "$WORK/remote.git" "$WORK/local" "$WORK/other"
  q init --bare "$WORK/remote.git"
  q init -b main "$WORK/local"
  q -C "$WORK/local" remote add origin "$WORK/remote.git"
  echo initial > "$WORK/local/data.txt"
  q -C "$WORK/local" add data.txt
  q -C "$WORK/local" commit -m initial
  q -C "$WORK/local" push -u origin main
  mkdir -p "$WORK/local/Scripts"
  cp "$SOURCE" "$WORK/local/Scripts/backup-repo.sh"
  q clone -b main "$WORK/remote.git" "$WORK/other"
}

commit_in() {   # $1 = clone, $2 = content; prints the new tip
  echo "$2" > "$WORK/$1/data.txt"
  q -C "$WORK/$1" commit -am "$2"
  git -C "$WORK/$1" rev-parse HEAD
}

backup() {
  TANDEMCLIP_BACKUP_REMOTE=origin bash "$WORK/local/Scripts/backup-repo.sh" \
    >"$WORK/out" 2>"$WORK/err"
}

remote_tip() { git -C "$WORK/local" ls-remote origin "$1" | awk '{print $1}'; }

# 1. The failure: local main behind the remote, plus a tag only local has.
#    Must succeed, leave the remote alone, and still push the tag.
setup
ahead="$(commit_in other "remote ahead")"
q -C "$WORK/other" push origin main
q -C "$WORK/local" tag behind-proof
if backup; then ok "local branch behind the remote: exit 0"
else bad "local branch behind the remote: exit $? ($(tail -2 "$WORK/err" | tr '\n' ' '))"; fi
grep -q 'already covered: main' "$WORK/out" && ok "reports main as already covered" || bad "no 'already covered: main' line"
[ "$(remote_tip refs/heads/main)" = "$ahead" ] && ok "remote main untouched" || bad "remote main was moved"
[ -n "$(remote_tip refs/tags/behind-proof)" ] && ok "tags still pushed when a branch is behind" || bad "tag not pushed"

# 2. Local ahead, and a branch the remote has never seen: both pushed.
setup
tip="$(commit_in local "local ahead")"
q -C "$WORK/local" branch side
if backup; then ok "local ahead: exit 0"; else bad "local ahead: exit $?"; fi
[ "$(remote_tip refs/heads/main)" = "$tip" ] && ok "local-ahead main pushed" || bad "main not pushed"
[ "$(remote_tip refs/heads/side)" = "$tip" ] && ok "new branch pushed" || bad "new branch not pushed"

# 3. Diverged: refuse, exit non-zero, never rewrite the backup.
setup
ahead="$(commit_in other "remote side")"
q -C "$WORK/other" push origin main
commit_in local "local side" >/dev/null
if backup; then bad "diverged branch: exit 0, should fail"; else ok "diverged branch: exits non-zero"; fi
grep -q 'diverged' "$WORK/err" && ok "says the branch diverged" || bad "no 'diverged' message"
[ "$(remote_tip refs/heads/main)" = "$ahead" ] && ok "remote main preserved" || bad "remote main rewritten"

# 4. DRY_RUN=1 reports what it would do and writes nothing to the remote.
setup
before="$(remote_tip refs/heads/main)"
commit_in local "dry run" >/dev/null
q -C "$WORK/local" branch dry-side
q -C "$WORK/local" tag dry-tag
if DRY_RUN=1 backup; then ok "dry run: exit 0"; else bad "dry run: exit $?"; fi
[ "$(remote_tip refs/heads/main)" = "$before" ] && ok "dry run leaves remote main alone" || bad "dry run moved remote main"
[ -z "$(remote_tip refs/heads/dry-side)$(remote_tip refs/tags/dry-tag)" ] \
  && ok "dry run pushes no branch or tag" || bad "dry run created a remote ref"

# 5. A missing remote is a stated failure, never an invented one.
setup
if TANDEMCLIP_BACKUP_REMOTE=nope bash "$WORK/local/Scripts/backup-repo.sh" >"$WORK/out" 2>"$WORK/err"; then
  bad "missing remote: exit 0, should fail"
else
  grep -q "no 'nope' remote" "$WORK/err" && ok "missing remote: refuses and says so" || bad "missing remote: wrong message"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
