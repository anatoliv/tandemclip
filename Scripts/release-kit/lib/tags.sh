#!/usr/bin/env bash
# tags.sh: every shipped version has a pushed tag, and tagging is the last scripted step.
# Part of the release kit (~/Projects/_method/release-kit.md). Source it, then:
#
#   rk_require_live_tag <live-version> <building-version> [repo-dir]
#       Preflight. Refuses when the version users have now (read by the caller from its
#       cask, appcast or site) has no v<version> tag, unless it is the one being built.
#       Release tooling reads "the last release" from tags (build-number checks, changelog
#       ranges), so a missing tag makes those checks compare against an older release
#       and pass things they should refuse. tandemclip shipped 0.25.1 and 0.25.3 untagged
#       and ran a week that way (TBX-7509).
#
#   rk_tag_release <version> <commit> <message> [remote] [repo-dir]
#       Final step of a publish. Creates annotated tag v<version> on <commit>, pushes it,
#       and confirms the remote serves it on that commit. Idempotent when the tag already
#       names that commit. A tag on another commit is refused unless RK_RETAG=1, the
#       deliberate re-publish, which moves the tag and force-pushes that one tag only.
#
# RK_TAG_PREFIX (default "v") is for a repo that tags differently.

rk_require_live_tag() {
  local live="$1" building="$2" dir="${3:-.}" tag
  local prefix="${RK_TAG_PREFIX-v}"
  if [ -z "$live" ]; then
    echo "rk_require_live_tag: no live version given, so the check cannot run." >&2
    echo "                     Pass the version users have now (from the cask, appcast or site)." >&2
    return 2
  fi
  [ "$live" = "$building" ] && return 0
  tag="$prefix$live"
  git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null && return 0
  echo "RELEASE REFUSED: $live is live but has no $tag tag." >&2
  echo "  Tag the commit that published it, then release again:" >&2
  echo "    git fetch --tags   # it may already exist on the remote" >&2
  echo "    git tag -a $tag <publish commit> -m '$live' && git push origin $tag" >&2
  return 1
}

rk_tag_release() {
  local version="$1" commit="$2" message="$3" remote="${4:-origin}" dir="${5:-.}"
  local prefix="${RK_TAG_PREFIX-v}" tag want have remote_commit
  if [ -z "$version" ] || [ -z "$commit" ] || [ -z "$message" ]; then
    echo "rk_tag_release: usage: rk_tag_release <version> <commit> <message> [remote] [repo-dir]" >&2
    return 2
  fi
  tag="$prefix$version"
  want="$(git -C "$dir" rev-parse -q --verify "$commit^{commit}")" || {
    echo "rk_tag_release: $commit is not a commit in $dir." >&2; return 2; }
  if have="$(git -C "$dir" rev-parse -q --verify "refs/tags/$tag^{commit}")"; then
    if [ "$have" != "$want" ]; then
      if [ "${RK_RETAG:-}" != 1 ]; then
        echo "rk_tag_release: $tag already names ${have:0:12}, not ${want:0:12}." >&2
        echo "                A re-publish moves it only with RK_RETAG=1." >&2
        return 1
      fi
      git -C "$dir" tag -a -f "$tag" "$want" -m "$message" >/dev/null || return 1
      git -C "$dir" push -q -f "$remote" "refs/tags/$tag" || {
        echo "rk_tag_release: moved $tag locally but could not push it to $remote." >&2; return 1; }
    fi
  else
    git -C "$dir" tag -a "$tag" "$want" -m "$message" || return 1
  fi
  # A rejected push is not fatal on its own: the remote may already hold this tag. What
  # decides success is what the remote serves, checked next.
  git -C "$dir" push -q "$remote" "refs/tags/$tag" 2>/dev/null || true
  remote_commit="$(git -C "$dir" ls-remote "$remote" "refs/tags/$tag^{}" | cut -f1)"
  [ -n "$remote_commit" ] || remote_commit="$(git -C "$dir" ls-remote "$remote" "refs/tags/$tag" | cut -f1)"
  if [ "$remote_commit" != "$want" ]; then
    echo "rk_tag_release: $remote does not serve $tag on ${want:0:12} (it has '${remote_commit:0:12}')." >&2
    echo "                The release is live but untagged; the next preflight will refuse until it is." >&2
    return 1
  fi
  echo "tagged $tag on ${want:0:12} and confirmed on $remote"
}

# rk_record_release <version> <message> <path>... : the last step of a publish. Commits
# the listed paths (the cask, the landing page: whatever the publish rewrote) if they
# changed, pushes that commit to the trunk as a fast-forward, then rk_tag_release on it.
# When nothing changed it tags HEAD. It never commits anything outside the listed paths,
# and it refuses a push that would not fast-forward: someone else moved the trunk, and a
# human has to merge. Either failure leaves the release live and untagged, which the next
# rk_require_live_tag preflight refuses, so it cannot be forgotten.
# RK_RECORD_REMOTE (origin) and RK_RECORD_BRANCH (main) name the trunk.
rk_record_release() {
  local version="$1" message="$2"; shift 2 || true
  local remote="${RK_RECORD_REMOTE:-origin}" branch="${RK_RECORD_BRANCH:-main}" dir="."
  if [ -z "$version" ] || [ -z "$message" ] || [ "$#" = 0 ]; then
    echo "rk_record_release: usage: rk_record_release <version> <message> <path>..." >&2; return 2
  fi
  if [ -n "$(git -C "$dir" status --porcelain -- "$@")" ]; then
    git -C "$dir" add -- "$@" || return 1
    git -C "$dir" commit -q -m "$message" -- "$@" || {
      echo "rk_record_release: could not commit $*; $version is live but unrecorded." >&2; return 1; }
  fi
  if ! git -C "$dir" push -q "$remote" "HEAD:refs/heads/$branch"; then
    echo "rk_record_release: $remote/$branch did not accept $(git -C "$dir" rev-parse --short HEAD) as a fast-forward." >&2
    echo "  $version is live but its publish commit is not on $branch and it is untagged." >&2
    echo "  Merge it into $branch, push, then: git tag -a ${RK_TAG_PREFIX-v}$version <that commit> && git push $remote ${RK_TAG_PREFIX-v}$version" >&2
    return 1
  fi
  rk_tag_release "$version" "$(git -C "$dir" rev-parse HEAD)" "$message" "$remote" "$dir"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "tags.sh is a library: source it and call rk_require_live_tag, rk_tag_release or rk_record_release." >&2
  exit 2
fi
