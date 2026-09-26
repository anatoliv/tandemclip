#!/usr/bin/env bash
# test-verify-live.sh: rk_verify_served_sha and rk_require_single_header against a local
# HTTP server on 127.0.0.1 that serves chosen bytes and chosen headers. No network beyond
# loopback. RK_VERIFY_SUBJECT points at a mutated copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_VERIFY_SUBJECT:-$HERE/../lib/verify-live.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP  python3 is needed for the local server"; exit 0; }
# shellcheck source=../lib/verify-live.sh
. "$SUBJECT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rk-verify.XXXXXX")"
SERVER=""
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

head -c 200000 /dev/urandom >"$WORK/app.dmg"
cp "$WORK/app.dmg" "$WORK/stale.dmg"; printf 'x' | dd of="$WORK/stale.dmg" bs=1 seek=100 conv=notrunc 2>/dev/null
WANT="$(shasum -a 256 "$WORK/app.dmg" | awk '{print $1}')"

cat >"$WORK/server.py" <<'PY'
import http.server, os, sys
root = sys.argv[1]
HSTS_A = "max-age=63072000; includeSubDomains; preload"
HSTS_B = "max-age=63072000; preload"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        p = self.path
        if p in ("/app.dmg", "/stale.dmg"):
            return self.send(200, open(os.path.join(root, p[1:]), "rb").read())
        if p == "/one":   return self.send(200, b"ok", [("Strict-Transport-Security", HSTS_A)])
        if p == "/two":   return self.send(200, b"ok", [("Strict-Transport-Security", HSTS_A), ("Strict-Transport-Security", HSTS_B)])
        if p == "/weak":  return self.send(200, b"ok", [("Strict-Transport-Security", HSTS_B)])
        if p == "/none":  return self.send(200, b"ok")
        if p == "/big":   return self.send(200, b"y" * 2_000_000, [("Strict-Transport-Security", HSTS_A)])
        return self.send(404, b"no")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$WORK/server.py" "$WORK" >"$WORK/port" 2>/dev/null &
SERVER=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT="$(head -1 "$WORK/port")"; [ -n "$PORT" ] || { echo "FAIL  local server did not start"; exit 1; }
U="http://127.0.0.1:$PORT"
H=Strict-Transport-Security

rk_verify_served_sha "$U/app.dmg" "$WANT" >/dev/null 2>&1 && ok "matching served bytes pass" || bad "matching bytes failed"
rk_verify_served_sha "$U/stale.dmg" "$WANT" >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q "served:" "$WORK/err" && ok "a same-size copy differing by one byte fails, naming both hashes" || bad "stale copy: rc=$rc $(cat "$WORK/err")"
rk_verify_served_sha "$U/missing.dmg" "$WANT" >/dev/null 2>&1; [ $? = 1 ] && ok "a 404 fails" || bad "404 passed"
rk_verify_served_sha "$U/app.dmg" "" >/dev/null 2>&1; [ $? = 2 ] && ok "an empty expected hash is an error, not a pass" || bad "empty hash passed"

rk_require_single_header "$U/one" "$H" includeSubDomains >/dev/null 2>&1 && ok "one HSTS header with the wanted value passes" || bad "single header failed"
rk_require_single_header "$U/two" "$H" >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q "2 times" "$WORK/err" && ok "two HSTS headers fail and are counted" || bad "duplicate: rc=$rc $(cat "$WORK/err")"
rk_require_single_header "$U/none" "$H" >/dev/null 2>&1; [ $? = 1 ] && ok "a missing header fails" || bad "missing header passed"
rk_require_single_header "$U/weak" "$H" includeSubDomains >/dev/null 2>&1; [ $? = 1 ] && ok "one header lacking the wanted value fails" || bad "weak header passed"
rk_require_single_header "$U/one" "strict-transport-security" >/dev/null 2>&1 && ok "the header name matches case-insensitively" || bad "lowercase name failed"
( set -o pipefail; rk_require_single_header "$U/big" "$H" >/dev/null 2>&1 ) && ok "a large body under pipefail passes (no SIGPIPE false failure)" || bad "large body failed under pipefail"
rk_require_single_header "http://127.0.0.1:1/x" "$H" >/dev/null 2>&1; [ $? = 1 ] && ok "an unreachable host fails" || bad "unreachable host passed"

echo "verify-live: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
