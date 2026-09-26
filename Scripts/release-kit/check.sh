#!/usr/bin/env bash
# check.sh: the release kit's one preflight entrypoint. Run it before any release:
#   bash scripts/release-kit/check.sh
# In a project it verifies the vendored copy against its pin, then runs every kit test on
# those exact bytes. In the kit source it runs the tests. Seconds, no network, no Apple.
set -uo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$KIT/MANIFEST.sha256" ]; then
  # shellcheck source=lib/pin.sh
  . "$KIT/lib/pin.sh"
  rk_verify_pin "$KIT" || exit 1
elif [ ! -d "$KIT/dev" ]; then
  echo "release kit: no MANIFEST.sha256 and not the kit source; re-vendor with bin/sync.sh." >&2
  exit 1
fi
fail=0
for t in "$KIT"/tests/test-*.sh; do
  out="$(bash "$t" 2>&1)"; rc=$?
  summary="$(printf '%s\n' "$out" | tail -1)"
  if [ "$rc" = 0 ]; then
    echo "  $summary"
  else
    fail=1
    printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/  /'
    echo "  $summary"
  fi
done
if [ "$fail" != 0 ]; then
  echo "release kit $(head -1 "$KIT/VERSION"): tests FAILED" >&2
  exit 1
fi
echo "release kit $(head -1 "$KIT/VERSION"): ok"
