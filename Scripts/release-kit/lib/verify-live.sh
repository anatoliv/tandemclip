#!/usr/bin/env bash
# verify-live.sh: check what the server actually serves, not the local file.
# Part of the release kit (~/Projects/_method/release-kit.md). Source it, then:
#
#   rk_verify_served_sha <url> <sha256>
#       Downloads <url> and compares its sha256 with the built artifact's. A local hash can
#       never fail this; a truncated upload, a stale same-size copy behind a cache, or a
#       half-swapped mirror all do.
#
#   rk_require_single_header <url> <header> [must-contain]
#       The response to <url> carries <header> exactly once, containing [must-contain] when
#       given. Two Strict-Transport-Security headers (origin nginx plus the proxy's toggle)
#       leave the effective policy to header order, which nobody wrote down.
#
# Both fetch first and match second, never `curl | grep -q`: under pipefail that pipeline
# can report SIGPIPE (141) when it succeeded, depending on body size. RK_CURL_OPTS adds
# curl options (tests use it for a local server).

rk_verify_served_sha() {
  local url="$1" want="$2" tmp have bytes
  if [ -z "$url" ] || [ -z "$want" ]; then
    echo "rk_verify_served_sha: usage: rk_verify_served_sha <url> <sha256>" >&2; return 2
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/rk-served.XXXXXX")" || return 1
  # shellcheck disable=SC2086
  if ! curl -fsSL --max-time "${RK_VERIFY_TIMEOUT:-300}" ${RK_CURL_OPTS:-} -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "LIVE CHECK FAILED: could not fetch $url. The feed may now advertise an undownloadable build." >&2
    return 1
  fi
  have="$(shasum -a 256 "$tmp" | awk '{print $1}')"; bytes="$(wc -c <"$tmp" | tr -d ' ')"
  rm -f "$tmp"
  if [ "$have" != "$want" ]; then
    echo "LIVE CHECK FAILED: $url is not the artifact that was built." >&2
    echo "  served: $have ($bytes bytes)" >&2
    echo "  built : $want" >&2
    echo "  Do not announce or tag this release; re-upload and verify again." >&2
    return 1
  fi
  echo "served bytes match: $url ($bytes bytes, sha256 ${have:0:16}...)"
}

rk_require_single_header() {
  local url="$1" header="$2" must="${3:-}" raw lines n
  if [ -z "$url" ] || [ -z "$header" ]; then
    echo "rk_require_single_header: usage: rk_require_single_header <url> <header> [must-contain]" >&2
    return 2
  fi
  # shellcheck disable=SC2086
  if ! raw="$(curl -sS -o /dev/null -D - --max-time "${RK_VERIFY_TIMEOUT:-30}" ${RK_CURL_OPTS:-} "$url")"; then
    echo "LIVE CHECK FAILED: could not fetch $url" >&2; return 1
  fi
  # Only the final response's headers count when curl followed nothing; strip CRs.
  lines="$(printf '%s\n' "$raw" | tr -d '\r' | grep -i "^$header:" || true)"
  n="$(printf '%s' "$lines" | grep -c . || true)"
  if [ "$n" != 1 ]; then
    echo "LIVE CHECK FAILED: $url sends $header $n times, want exactly 1:" >&2
    [ -z "$lines" ] || printf '  %s\n' "$lines" >&2
    return 1
  fi
  if [ -n "$must" ] && ! printf '%s' "$lines" | grep -qiF -- "$must"; then
    echo "LIVE CHECK FAILED: $url sends '$lines', which lacks '$must'." >&2
    return 1
  fi
  echo "one $header on $url: ${lines#*: }"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "verify-live.sh is a library: source it and call rk_verify_served_sha or rk_require_single_header." >&2
  exit 2
fi
