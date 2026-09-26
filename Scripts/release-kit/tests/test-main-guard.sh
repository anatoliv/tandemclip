#!/usr/bin/env bash
# test-main-guard.sh: plant unmerged commits and watch lib/main-guard.sh refuse them
# (TBX-7466, ESTATE E19).
#
# Throwaway repos only: a bare "origin", a clone that releases, and a second clone that
# pushes behind its back. No network: the merge-back card goes to a stub Tonebox on
# 127.0.0.1. Point RELEASE_MAIN_GUARD_SUBJECT at a mutated copy to prove a check can fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${RELEASE_MAIN_GUARD_SUBJECT:-$HERE/../lib/main-guard.sh}"
[ -f "$GUARD" ] || { echo "FAIL  no guard at $GUARD"; exit 1; }
unset ALLOW_UNMERGED_RELEASE RELEASE_MAIN_GUARD_REMOTE RELEASE_MAIN_GUARD_BRANCH RELEASE_MAIN_GUARD_TONEBOX_CONFIG

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

# 14-17. The override files its merge-back card in Tonebox when it can, and prints it when
#        it cannot. A stub MCP server on 127.0.0.1 stands in for Tonebox and records calls.
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip  merge-back card filing (no python3 here, so the guard only prints the card)"
else
  STUB_LOG="$WORK/stub-calls.jsonl"; : >"$STUB_LOG"
  python3 - "$WORK/stub-port" "$STUB_LOG" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_file, log = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(log, "a") as f:
            f.write(json.dumps({"auth": self.headers.get("Authorization"), "session": self.headers.get("Mcp-Session-Id"),
                                "method": req["method"], "params": req.get("params")}) + "\n")
        if req["method"] == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {}}
        elif req["params"]["name"] == "list_projects":
            text = {"projects": [{"name": "Other", "archived": False}, {"name": "Origin", "archived": False}]}
            result = {"content": [{"type": "text", "text": json.dumps(text)}]}
        else:
            text = {"created": True, "task": {"human_id": "TBX-9999", "text": req["params"]["arguments"]["text"]}}
            result = {"content": [{"type": "text", "text": json.dumps(text)}]}
        body = "event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}) + "\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Mcp-Session-Id", "stub-session")
        self.end_headers()
        self.wfile.write(body.encode())
srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  STUB_PID=$!
  trap 'kill "$STUB_PID" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
  for _ in $(seq 50); do [ -s "$WORK/stub-port" ] && break; sleep 0.1; done
  PORT="$(cat "$WORK/stub-port" 2>/dev/null)"
  printf '{"mcpServers":{"tonebox":{"type":"http","url":"http://127.0.0.1:%s","headers":{"Authorization":"Bearer stub-secret-token"}}}}\n' "$PORT" >"$WORK/tonebox.json"
  # A port nothing listens on: bind one, note it, close it.
  DEAD_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  printf '{"mcpServers":{"tonebox":{"type":"http","url":"http://127.0.0.1:%s"}}}\n' "$DEAD_PORT" >"$WORK/dead.json"
  git -C "$WORK/rel" checkout -q -b card-cases origin/main 2>/dev/null
  git -C "$WORK/rel" commit -q --allow-empty -m "card hotfix"
  CARD_SHORT="$(git -C "$WORK/rel" rev-parse --short=12 HEAD)"
  override() {   # <reason> [env assignments...]
    local why="$1"; shift
    (cd "$WORK/rel" && env ALLOW_UNMERGED_RELEASE="$why" "$@" bash -c '. "$1" && release_main_guard' _ "$GUARD" 2>&1)
  }

  # 14. Reachable: filed as a quick task in the project named like the repo, with the token.
  : >"$STUB_LOG"
  out="$(override "card case reachable" RELEASE_MAIN_GUARD_TONEBOX_CONFIG="$WORK/tonebox.json")"; rc=$?
  expect_admitted "a reachable Tonebox gets the merge-back card filed" "$rc" "$out" "Filed in Tonebox as TBX-9999 in project Origin"
  filed="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    c = json.loads(l)
    if c["method"] == "tools/call" and c["params"]["name"] == "quick_task":
        a = c["params"]["arguments"]; print(c["auth"], c["session"], a.get("project"), a.get("priority"), "|", a["text"])' "$STUB_LOG")"
  if grep -qF "Bearer stub-secret-token stub-session Origin high | Merge hotfix $CARD_SHORT into main of origin" <<<"$filed" \
     && grep -qF "Reason: card case reachable" <<<"$filed"; then
    ok "the card names the hotfix, the repo and the reason, and goes to the matching project with the configured token"
  else bad "the stub did not receive the expected quick_task. Got: $filed"; fi
  if grep -qF "stub-secret-token" <<<"$out"; then bad "the guard printed the Tonebox token"; else ok "the Tonebox token is never printed"; fi

  # 15. Not reachable: the release is still admitted and the card text is printed to file.
  out="$(override "card case dead" RELEASE_MAIN_GUARD_TONEBOX_CONFIG="$WORK/dead.json")"; rc=$?
  expect_admitted "an unreachable Tonebox falls back to printing the card" "$rc" "$out" "Tonebox was not reachable from here, so file this card now:"
  expect_admitted "and the printed card names the hotfix and the reason" "$rc" "$out" "Merge hotfix $CARD_SHORT into main of origin"

  # 16. A checkout whose origin is a local path (every test repo) never files by default,
  #     even with a live Tonebox in ~/.claude.json.
  cp "$WORK/tonebox.json" "$HOME/.claude.json"; : >"$STUB_LOG"
  out="$(override "card case local origin")"; rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$STUB_LOG" ] && grep -qF "file this card now:" <<<"$out"; then
    ok "a local-path origin does not file a card from ~/.claude.json, it prints it"
  else bad "a local-path origin reached Tonebox or did not print the card. Calls: $(wc -l <"$STUB_LOG")"; fi

  # 17. A real-looking origin URL (rewritten to the local bare repo for the fetch) files from
  #     ~/.claude.json, and <name>-private matches the project <Name>.
  git -C "$WORK/rel" config url."$WORK/origin.git".insteadOf "https://git.example.invalid/acme/origin-private.git"
  git -C "$WORK/rel" remote set-url origin "https://git.example.invalid/acme/origin-private.git"
  : >"$STUB_LOG"
  out="$(override "card case default config")"; rc=$?
  expect_admitted "with a hosted origin, the card is filed through ~/.claude.json" "$rc" "$out" "Filed in Tonebox as TBX-9999 in project Origin"
  git -C "$WORK/rel" remote set-url origin "$WORK/origin.git"
  rm -f "$HOME/.claude.json"
fi

echo "release-main-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
