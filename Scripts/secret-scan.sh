#!/usr/bin/env bash
#
# Secret scanner for the public repo. TandemClip's `origin` IS the public
# GitHub repo (no sanitizing mirror), so this is the backstop between a bad
# commit and public history. Wired as a pre-push hook via:
#
#   git config core.hooksPath .githooks
#
# Three checks, because they catch genuinely different mistakes:
#
#   1. Secrets/LAN infra in the tracked tree — the current state.
#   2. The same patterns in the commits being pushed. A secret that was
#      committed and then "removed" in a later commit is still readable
#      forever via `git show`; scanning only the tree would wave it through.
#   3. Private paths being published at all. Internal notes and deploy infra
#      contain no secret-shaped strings, so patterns alone never flag them —
#      the only reliable signal is the path itself. This is how SECURITY_AUDIT.md
#      and web/ reached public history.
#
# Run manually to scan just the tree: Scripts/secret-scan.sh
# As a pre-push hook it also reads stdin and scans the pushed commit range.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Tokens, Sentry DSNs, private keys — never legitimate in the tree.
SECRET_RE='ghp_[0-9A-Za-z]{20,}|gho_[0-9A-Za-z]{20,}|glpat-[0-9A-Za-z_-]{18,}|xox[abprs]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}|sntry[a-z]_[0-9a-f]{32}|https?://[0-9a-f]{16,}@o[0-9]+\.ingest\.|-----BEGIN [A-Z ]*PRIVATE KEY'
# Private LAN IPs — deployment hosts, never something the public repo needs.
LAN_RE='192\.168\.[0-9]+\.[0-9]+|(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+'

# Paths that must never appear in public history. Anchored prefixes, matched
# against the full path. Set SECRET_SCAN_ALLOW_PRIVATE_PATHS=1 to publish one
# deliberately (e.g. if an internal doc is ever cleared for release).
PRIVATE_PATHS=(
    "docs/COMPETITIVE.md"           # competitive/pricing strategy
    "docs/launch/"                  # launch + credit playbook, marketing drafts
    "web/"                          # deploy infra: compose, nginx, marketing site
    "SECURITY_AUDIT.md"             # internal audit; names exact weak spots
    "Packaging/sentry-dsn.local"    # the real Sentry DSN
    "Scripts/backup-repo.sh"        # private backup remote wiring
)

# Files that legitimately contain secret-shaped or IP-shaped sample strings.
# Deliberately specific: a blanket Tests/* skip would wave through a real
# credential pasted into any other test.
is_exempt() {
    case "$1" in
        Scripts/secret-scan.sh) return 0 ;;                     # these patterns
        Sources/tandemclip/SecretGuard.swift) return 0 ;;       # the feature itself
        Tests/tandemclipTests/SecretGuardTests.swift) return 0 ;;
        Tests/tandemclipTests/LooseEndsTests.swift) return 0 ;; # sample LAN IPs
        *) return 1 ;;
    esac
}

is_private_path() {
    [[ "${SECRET_SCAN_ALLOW_PRIVATE_PATHS:-}" == "1" ]] && return 1
    local p="$1"
    for priv in "${PRIVATE_PATHS[@]}"; do
        case "$priv" in
            */) [[ "$p" == "$priv"* ]] && return 0 ;;
            *)  [[ "$p" == "$priv"  ]] && return 0 ;;
        esac
    done
    return 1
}

hit=0

# --- 1 + 3. Tracked tree ------------------------------------------------------
while IFS= read -r f; do
    if is_private_path "$f"; then
        echo "PRIVATE $f  (internal — must not be published)"; hit=1; continue
    fi
    is_exempt "$f" && continue
    [[ -f "$f" ]] || continue
    if out=$(grep -InE "$SECRET_RE" "$f" 2>/dev/null); then
        echo "SECRET  $f"; echo "$out"; hit=1
    fi
    if out=$(grep -InE "$LAN_RE" "$f" 2>/dev/null); then
        echo "LAN IP  $f"; echo "$out"; hit=1
    fi
done < <(git ls-files)

# --- 2 + 3. Commits being pushed ---------------------------------------------
# Only when invoked as a pre-push hook (git feeds refs on stdin). Scanning the
# range catches a secret that was added and later deleted: still in history.
scan_range() {
    local range="$1" commit path blob
    # Commit messages travel with the history too.
    if out=$(git log --format='%H %s%n%b' "$range" 2>/dev/null | grep -InE "$SECRET_RE|$LAN_RE"); then
        echo "SECRET  in a commit message being pushed"; echo "$out"; hit=1
    fi
    # Every blob added or modified anywhere in the range.
    while read -r commit; do
        [[ -n "$commit" ]] || continue
        while IFS=$'\t' read -r _ path; do
            [[ -n "$path" ]] || continue
            if is_private_path "$path"; then
                echo "PRIVATE $path  (in $commit — internal, must not be published)"; hit=1; continue
            fi
            is_exempt "$path" && continue
            blob=$(git rev-parse "$commit:$path" 2>/dev/null) || continue
            if out=$(git cat-file blob "$blob" 2>/dev/null | grep -InIE "$SECRET_RE"); then
                echo "SECRET  $path (in $commit)"; echo "$out"; hit=1
            fi
            if out=$(git cat-file blob "$blob" 2>/dev/null | grep -InIE "$LAN_RE"); then
                echo "LAN IP  $path (in $commit)"; echo "$out"; hit=1
            fi
        done < <(git diff-tree --no-commit-id --name-status -r --diff-filter=AM "$commit" 2>/dev/null)
    done < <(git rev-list "$range" 2>/dev/null)
}

ZERO='0000000000000000000000000000000000000000'
if [[ ! -t 0 ]]; then
    while read -r _local_ref local_sha _remote_ref remote_sha; do
        [[ -z "${local_sha:-}" ]] && continue
        [[ "$local_sha" == "$ZERO" ]] && continue          # branch deletion
        if [[ "${remote_sha:-$ZERO}" == "$ZERO" ]]; then
            # New branch/tag: scan what it adds beyond everything already published.
            scan_range "$local_sha --not --remotes=origin"
        else
            scan_range "$remote_sha..$local_sha"
        fi
    done
fi

if [[ $hit -ne 0 ]]; then
    echo "" >&2
    echo "✗ secret-scan: refusing to push — remove the above before publishing." >&2
    echo "  A secret already in a pushed commit needs history rewritten, not just a new commit." >&2
    exit 1
fi
echo "✓ secret-scan clean"
