#!/usr/bin/env bash
# main-guard.sh: refuse to ship a commit that origin/main does not contain.
#
# Six projects had production running a commit that main did not
# have, so the next routine release from main quietly took the fix back. Every release
# script checked for a clean tree; none checked that the commit it shipped was merged.
#
# Part of the release kit (~/Projects/_release, design in ~/Projects/_method/release-kit.md).
# Projects vendor it under scripts/release-kit/ and a pin check refuses local edits; change
# it in the kit and re-sync. Two ways to use it:
#   . scripts/release-kit/lib/main-guard.sh; release_main_guard || exit 1   from a bash script
#   scripts/release-kit/lib/main-guard.sh [repo-dir]                          from anything else
#
# It fetches main from origin, then admits HEAD only when HEAD is an ancestor of
# origin/main. A refusal names the commits origin/main is missing. A failed fetch refuses
# too: a stale origin/main proves nothing.
#
# Emergency hotfix override (explicit, logged, never silent):
#   ALLOW_UNMERGED_RELEASE="<why this cannot wait for a merge>" <release command>
# admits the release, appends a line to <git common dir>/unmerged-releases.log and files a
# merge-back card. Every later run warns about logged hotfixes origin/main still lacks,
# because a release from main would take them back.
#
# Filing the card: on the owner's Mac the card goes to the house task tracker, an MCP
# server whose entry name is house configuration rather than part of this file:
# RELEASE_MAIN_GUARD_TRACKER, or else the first line of ~/.config/release-kit/tracker. Its
# URL and headers are read from mcpServers.<name> in ~/.claude.json (the same entry agents
# use), and the card is a high-priority quick task in the project named like the origin
# repo (app-private -> App), or unfiled when no project matches. With no tracker named,
# or where it is not reachable (a deploy host, no python3, the tracker not running), the
# card text is printed to file by hand instead, and the release is admitted either way.
# A checkout whose origin is a local path (a test's throwaway repo) never files, unless
# RELEASE_MAIN_GUARD_TRACKER_CONFIG names a config explicitly; pointing that at a file
# that does not exist turns filing off.
#
# RELEASE_MAIN_GUARD_REMOTE (default origin) and RELEASE_MAIN_GUARD_BRANCH (default main)
# exist for tests and for a checkout whose trunk lives under another name.

release_main_guard() {
  local dir="${1:-.}"
  local remote="${RELEASE_MAIN_GUARD_REMOTE:-origin}"
  local branch="${RELEASE_MAIN_GUARD_BRANCH:-main}"
  local ref="refs/remotes/$remote/$branch" trunk="$remote/$branch"
  local head short fetched=1 missing="" log common now who reason entry c when why card filed url name

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
        echo "  next release from main quietly takes back. Merge to main, then"
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
  # The repo's name from its origin URL (app-private.git -> app), which a
  # worktree's directory name is not.
  url="$(git -C "$dir" config --get "remote.$remote.url" 2>/dev/null)" || url=""
  name="${url%/}"; name="${name##*/}"; name="${name##*:}"; name="${name%.git}"; name="${name%-private}"
  [ -n "$name" ] || name="$(basename "$(cd "$dir" && pwd)")"
  card="Merge hotfix $short into main of $name: released unmerged at $now by $who. Reason: $reason"
  filed="$(release_main_guard_file_card "$url" "$name" "$card")" || filed=""
  {
    echo
    echo "=============================================================================="
    echo "UNMERGED RELEASE (ALLOW_UNMERGED_RELEASE): HEAD $short is not on $trunk"
    echo "=============================================================================="
    echo "  Reason: $reason"
    [ "$fetched" = 1 ] || echo "  (the fetch of $trunk failed, so containment was not checked at all)"
    [ -z "$missing" ] || { echo "  Commits $trunk does not have:"; printf '%s\n' "$missing"; }
    echo "  Logged: $log"
    if [ -n "$filed" ]; then
      echo "  MERGE-BACK REQUIRED. Filed in the task tracker as $filed:"
    else
      echo "  MERGE-BACK REQUIRED. The task tracker was not reachable from here, so file this card now:"
    fi
    echo "    $card"
    echo "  Until $trunk contains it, every release from main takes this fix back."
    echo
  } >&2
  return 0
}

# release_main_guard_file_card <origin url> <repo name> <card text>: file the merge-back
# card in the house task tracker. Prints where it landed and returns 0, or returns 1 having
# filed nothing. Never prints the server's credentials.
release_main_guard_file_card() {
  local url="$1" repo="$2" text="$3" cfg="${RELEASE_MAIN_GUARD_TRACKER_CONFIG:-}"
  local server="${RELEASE_MAIN_GUARD_TRACKER:-}" named
  if [ -z "$server" ]; then
    named="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/release-kit/tracker"
    [ -r "$named" ] && server="$(head -1 "$named" | tr -d '[:space:]')"
  fi
  [ -n "$server" ] || return 1
  if [ -z "$cfg" ]; then
    case "$url" in ""|/*|./*|../*|file:*) return 1 ;; esac
    cfg="${HOME:-/nonexistent}/.claude.json"
  fi
  [ -r "$cfg" ] && command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$cfg" "$repo" "$text" "$server" 2>/dev/null <<'PY'
import json, re, sys, urllib.request
cfg_path, repo, text, server = sys.argv[1:5]
cfg = json.load(open(cfg_path))["mcpServers"][server]
headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
headers.update(cfg.get("headers") or {})
session = [None]
def rpc(i, method, params):
    h = dict(headers)
    if session[0]:
        h["Mcp-Session-Id"] = session[0]
    body = json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}).encode()
    with urllib.request.urlopen(urllib.request.Request(cfg["url"], data=body, headers=h), timeout=5) as r:
        raw = r.read().decode()
        session[0] = r.headers.get("Mcp-Session-Id") or session[0]
    if not raw.lstrip().startswith("{"):
        raw = "\n".join(l[5:].strip() for l in raw.splitlines() if l.startswith("data:"))
    res = json.loads(raw)
    if "error" in res or res["result"].get("isError"):
        raise RuntimeError(method)
    return res["result"]
def call(i, name, args):
    out = rpc(i, "tools/call", {"name": name, "arguments": args})
    return "".join(p.get("text", "") for p in out.get("content", []) if p.get("type") == "text")
rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                      "clientInfo": {"name": "release-main-guard", "version": "1"}})
key = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
project = None
try:
    for p in json.loads(call(2, "list_projects", {})).get("projects", []):
        if repo and key(p.get("name", "")) == key(repo) and not p.get("archived"):
            project = p["name"]
except Exception:
    pass
args = {"text": text, "priority": "high", "labels": ["release", "merge-back"]}
if project:
    args["project"] = project
out = call(3, "quick_task", args)
m = re.search(r'"human_id"\s*:\s*"([^"]+)"', out)
print((m.group(1) if m else "a quick task") + (" in project " + project if project else " (unfiled: no project matches " + repr(repo) + ")"))
PY
}

# Executed rather than sourced: run the guard on the given checkout (default: here).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  release_main_guard "$@"
  exit $?
fi
