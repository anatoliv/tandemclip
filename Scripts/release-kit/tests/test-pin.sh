#!/usr/bin/env bash
# test-pin.sh: rk_verify_pin admits an untouched vendored copy and refuses every way a
# copy can drift: an edited file, a missing file, an extra file, a missing VERSION.
# Builds a throwaway vendored copy from this kit's own lib/ and tests/. RK_PIN_SUBJECT
# points at a mutated copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_PIN_SUBJECT:-$HERE/../lib/pin.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }
# shellcheck source=../lib/pin.sh
. "$SUBJECT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rk-pin.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

fresh() {  # a vendored copy with a correct manifest, in $WORK/kit
  rm -rf "$WORK/kit"; mkdir -p "$WORK/kit/lib" "$WORK/kit/tests"
  cp "$HERE"/../lib/*.sh "$WORK/kit/lib/"; cp "$HERE"/*.sh "$WORK/kit/tests/"
  echo 9.9.9 >"$WORK/kit/VERSION"; echo "# readme" >"$WORK/kit/README.md"
  ( cd "$WORK/kit" && find . -type f | sed 's|^\./||' | LC_ALL=C sort \
      | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"; done ) >"$WORK/manifest"
  mv "$WORK/manifest" "$WORK/kit/MANIFEST.sha256"
}
K="$WORK/kit"

fresh; rk_verify_pin "$K" >/dev/null 2>&1 && ok "an untouched vendored copy passes" || bad "clean copy refused: $(rk_verify_pin "$K" 2>&1)"
fresh; echo "# local tweak" >>"$K/lib/notarize.sh"
rk_verify_pin "$K" >/dev/null 2>"$WORK/err"; [ $? = 1 ] && grep -q "lib/notarize.sh differs" "$WORK/err" && ok "an edited file is refused and named" || bad "edited file: $(cat "$WORK/err")"
fresh; rm "$K/lib/tags.sh"
rk_verify_pin "$K" >/dev/null 2>"$WORK/err"; [ $? = 1 ] && grep -q "lib/tags.sh is in the manifest but missing" "$WORK/err" && ok "a missing file is refused" || bad "missing file: $(cat "$WORK/err")"
fresh; echo 'echo hi' >"$K/lib/extra.sh"
rk_verify_pin "$K" >/dev/null 2>"$WORK/err"; [ $? = 1 ] && grep -q "lib/extra.sh is not part" "$WORK/err" && ok "an extra file in lib/ is refused" || bad "extra file: $(cat "$WORK/err")"
fresh; echo 'x' >"$K/tests/test-local.sh"
rk_verify_pin "$K" >/dev/null 2>&1; [ $? = 1 ] && ok "an extra file in tests/ is refused" || bad "extra test passed"
fresh; rm "$K/VERSION"
rk_verify_pin "$K" >/dev/null 2>&1; [ $? = 1 ] && ok "a missing VERSION is refused" || bad "missing VERSION passed"
fresh; rm "$K/MANIFEST.sha256"
rk_verify_pin "$K" >/dev/null 2>&1; [ $? = 1 ] && ok "a missing manifest is refused" || bad "missing manifest passed"
fresh; echo 1.0.0 >"$K/VERSION"
rk_verify_pin "$K" >/dev/null 2>&1; [ $? = 1 ] && ok "a hand-bumped VERSION is refused" || bad "edited VERSION passed"
fresh; grep -v '  VERSION$' "$K/MANIFEST.sha256" >"$WORK/m"; mv "$WORK/m" "$K/MANIFEST.sha256"
rk_verify_pin "$K" >/dev/null 2>&1; [ $? = 1 ] && ok "a manifest that omits VERSION is refused" || bad "manifest without VERSION passed"

echo "pin: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
