#!/usr/bin/env bash
# pin.sh: a vendored copy of the kit is exactly the version it claims to be.
# Part of the release kit (~/Projects/_method/release-kit.md).
#
#   rk_verify_pin <kit-dir>
#       <kit-dir>/MANIFEST.sha256 lists "<sha256>  <relative path>" for every vendored file,
#       written by bin/sync.sh. This refuses when a listed file is missing or differs, when
#       a file not in the manifest sits in lib/ or tests/, or when VERSION is absent.
#
# Why: the guards were copied between repos by hand, and within a day the same guard
# existed in two versions (194 and 121 lines) across ten checkouts. A fix made in one copy
# never reached the others. With a pin, the only way to change a vendored file is to
# re-sync from the kit; a local edit fails that project's next preflight.

rk_verify_pin() {
  local dir="${1:?rk_verify_pin: kit dir required}" manifest sum path bad=0 f rel version
  manifest="$dir/MANIFEST.sha256"
  [ -f "$manifest" ] || { echo "PIN FAILED: $manifest is missing; re-vendor with the kit's bin/sync.sh." >&2; return 1; }
  [ -s "$dir/VERSION" ] || { echo "PIN FAILED: $dir/VERSION is missing or empty." >&2; return 1; }
  version="$(head -1 "$dir/VERSION")"
  while read -r sum path; do
    [ -n "$path" ] || continue
    if [ ! -f "$dir/$path" ]; then
      echo "PIN FAILED: $path is in the manifest but missing." >&2; bad=1; continue
    fi
    if [ "$(shasum -a 256 "$dir/$path" | awk '{print $1}')" != "$sum" ]; then
      echo "PIN FAILED: $path differs from release kit $version (edited in place?)." >&2; bad=1
    fi
  done <"$manifest"
  grep -qE '  VERSION$' "$manifest" || { echo "PIN FAILED: VERSION is not in the manifest." >&2; bad=1; }
  for f in "$dir"/lib/* "$dir"/tests/* "$dir"/*; do
    [ -f "$f" ] || continue
    rel="${f#"$dir"/}"
    [ "$rel" = MANIFEST.sha256 ] && continue
    grep -qF "  $rel" "$manifest" || { echo "PIN FAILED: $rel is not part of release kit $version." >&2; bad=1; }
  done
  if [ "$bad" != 0 ]; then
    echo "  Do not edit vendored kit files. Change ~/Projects/_release, then re-run bin/sync.sh." >&2
    return 1
  fi
  echo "release kit $version: pin ok ($(grep -c . "$manifest") files)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rk_verify_pin "${1:-$(cd "$(dirname "$0")/.." && pwd)}"
fi
