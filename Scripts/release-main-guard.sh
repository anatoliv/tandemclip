#!/usr/bin/env bash
# release-main-guard.sh: refuse to ship a commit that origin/main does not contain.
#
# ESTATE E19 / TBX-7466. Six projects had production running a commit that main did not
# have, so the next routine release from main quietly took the fix back. Every release
# script checked for a clean tree; none checked that the commit it shipped was merged.
#
# The same file is copied into every repo that ships (the repos are independent, so there
# is no shared import). Keep the copies identical. Two ways to use it:
#   . scripts/release-main-guard.sh; release_main_guard || exit 1     from a bash script
#   scripts/release-main-guard.sh [repo-dir]                            from anything else
#
# It fetches main from origin, then admits HEAD only when HEAD is an ancestor of
# origin/main. A refusal names the commits origin/main is missing. A failed fetch refuses
# too: a stale origin/main proves nothing.
#
# Emergency hotfix override (explicit, logged, never silent):
#   ALLOW_UNMERGED_RELEASE="<why this cannot wait for a merge>" <release command>
# admits the release, appends a line to <git common dir>/unmerged-releases.log and prints a
# merge-back note to file as a card straight away. Every later run warns about logged
# hotfixes origin/main still lacks, because a release from main would take them back.
#
# RELEASE_MAIN_GUARD_REMOTE (default origin) and RELEASE_MAIN_GUARD_BRANCH (default main)
# exist for tests and for a checkout whose trunk lives under another name.

release_main_guard() {
  local dir="${1:-.}"
  local remote="${RELEASE_MAIN_GUARD_REMOTE:-origin}"
  local branch="${RELEASE_MAIN_GUARD_BRANCH:-main}"
  local ref="refs/remotes/$remote/$branch" trunk="$remote/$branch"
  local head short fetched=1 missing="" log common now who reason entry c when why

  head="$(git -C "$dir" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || {
    echo "RELEASE REFUSED: $dir is not a git checkout with a commit, so nothing shows it is on $trunk." >&2
    return 1
  }
  short="$(git -C "$dir" rev-parse --short=12 "$head")"
  common="$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd)" || return 1
  log="$common/unmerged-releases.log"

  if ! git -C "$dir" fetch --quiet --no-tags "$remote" "+refs/heads/$branch:$ref"; then
    fetched=0
  fi

  if [ "$fetched" = 1 ] && git -C "$dir" merge-base --is-ancestor "$head" "$ref"; then
    echo "  release main guard ok: $short is contained in $trunk (fetched just now)"
    # A hotfix shipped under the override that main still lacks is taken back by this release.
    if [ -s "$log" ]; then
      while IFS="$(printf '\t')" read -r when c who why; do
        [ -n "$c" ] || continue
        git -C "$dir" cat-file -e "$c^{commit}" 2>/dev/null || continue
        git -C "$dir" merge-base --is-ancestor "$c" "$ref" && continue
        git -C "$dir" merge-base --is-ancestor "$c" "$head" && continue
        {
          echo "  WARNING: hotfix $(git -C "$dir" rev-parse --short=12 "$c") shipped unmerged on $when ($why)"
          echo "    is still not on $trunk, and this release does not contain it: shipping takes it back."
          echo "    Merge it first. If it was merged by squash or cherry-pick, delete its line from $log."
        } >&2
      done <"$log"
    fi
    return 0
  fi

  if [ "$fetched" = 1 ]; then
    missing="$(git -C "$dir" log --format='    %h %s' "$ref..$head" | head -20)" || true
  fi

  if [ -z "${ALLOW_UNMERGED_RELEASE:-}" ]; then
    {
      echo
      echo "=============================================================================="
      if [ "$fetched" = 1 ]; then
        echo "RELEASE REFUSED: HEAD $short is not contained in $trunk"
        echo "=============================================================================="
        echo "  $trunk (fetched just now) is missing these commits:"
        printf '%s\n' "$missing"
        echo "  Shipping them from a branch is how production ends up running code that the"
        echo "  next release from main quietly takes back (ESTATE E19). Merge to main, then"
        echo "  release from a checkout of main."
      else
        echo "RELEASE REFUSED: could not fetch $trunk, so HEAD $short cannot be shown to be merged"
        echo "=============================================================================="
        echo "  Fix the fetch (network, credentials, remote name) and re-run."
      fi
      echo "  Emergency hotfix only: ALLOW_UNMERGED_RELEASE=\"<reason>\" re-runs it, logs the"
      echo "  override and prints a merge-back note to file as a card. Nothing has shipped."
      echo
    } >&2
    return 1
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  who="$(id -un 2>/dev/null || echo unknown)"
  reason="$(printf '%s' "$ALLOW_UNMERGED_RELEASE" | tr '\t\n' '  ')"
  entry="$(printf '%s\t%s\t%s\t%s' "$now" "$head" "$who" "$reason")"
  printf '%s\n' "$entry" >>"$log" || {
    echo "RELEASE REFUSED: the override could not be logged to $log, and an unlogged override is not allowed." >&2
    return 1
  }
  {
    echo
    echo "=============================================================================="
    echo "UNMERGED RELEASE (ALLOW_UNMERGED_RELEASE): HEAD $short is not on $trunk"
    echo "=============================================================================="
    echo "  Reason: $reason"
    [ "$fetched" = 1 ] || echo "  (the fetch of $trunk failed, so containment was not checked at all)"
    [ -z "$missing" ] || { echo "  Commits $trunk does not have:"; printf '%s\n' "$missing"; }
    echo "  Logged: $log"
    echo "  MERGE-BACK REQUIRED. File this card now:"
    echo "    Merge hotfix $short into main: released unmerged at $now by $who. Reason: $reason"
    echo "  Until $trunk contains it, every release from main takes this fix back."
    echo
  } >&2
  return 0
}

# Executed rather than sourced: run the guard on the given checkout (default: here).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  release_main_guard "$@"
  exit $?
fi
