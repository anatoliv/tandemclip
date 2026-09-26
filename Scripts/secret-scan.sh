#!/usr/bin/env bash
#
# Secret scanner. The maintainer works in a private repository (remote `origin`),
# and the public repository is a filtered mirror that only a separate publish step
# writes to, after running its own, stricter guards over the snapshot it builds.
# This is the earlier and cheaper check, run on every push and available to anyone
# with a clone. A push to the private repository only reports findings; a push
# anywhere else is refused (see TARGET_PUBLIC below). Wired as a pre-push hook via:
#
#   git config core.hooksPath .githooks
#
# The release gate refuses to run while that is not set (Scripts/check-hooks-path.sh),
# because an unset hook fails silently: the push just goes out unscanned.
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
# Run manually to scan just the tree: Scripts/secret-scan.sh  (exit 1 on any finding)
# As a pre-push hook it also reads stdin and scans the pushed commit range.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Tokens, Crashbox DSNs, private keys — never legitimate in the tree.
SECRET_RE='ghp_[0-9A-Za-z]{20,}|gho_[0-9A-Za-z]{20,}|glpat-[0-9A-Za-z_-]{18,}|xox[abprs]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}|sntry[a-z]_[0-9a-f]{32}|https?://[0-9a-f]{16,}@o[0-9]+\.ingest\.|-----BEGIN [A-Z ]*PRIVATE KEY'
# Private LAN IPs — deployment hosts, never something the public repo needs.
LAN_RE='192\.168\.[0-9]+\.[0-9]+|(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+'

# Internal hostnames and infra names. These have no shape: a machine name is not a
# credential and not an IP, so SECRET_RE and LAN_RE both wave one through. That is how
# two of this estate's names reached this repo's history and had to be rewritten out of
# it on 2026-08-16. An explicit list is the only thing that catches a name.
#
# NOTE, and it is the reason this comment names nothing: is_exempt() skips THIS file,
# because HOST_RE below contains a literal domain that would match itself. That
# exemption covers the whole file, prose included — so this is the one place in the
# repo where writing a real hostname in a comment is guaranteed NOT to be caught. The
# first draft of this block did exactly that and published it. Keep the prose generic.
# Keep in sync with the internal-name guard of the private publish script: same
# author, same homelab, same failure mode.
HOST_RE='\b(web|ai|db|nas|dev|tm)-[0-9]{2}\b|\bagent-macbook\b|getvirtualview|[a-z]+-notarize\b|/Users/anatoli'

# Paths that must never appear in public history. Anchored prefixes, matched
# against the full path. Set SECRET_SCAN_ALLOW_PRIVATE_PATHS=1 to publish one
# deliberately (e.g. if an internal doc is ever cleared for release).
PRIVATE_PATHS=(
    "docs/COMPETITIVE.md"           # competitive/pricing strategy
    "docs/launch/"                  # launch + credit playbook, marketing drafts
    "web/"                          # deploy infra: compose, nginx, marketing site
    "SECURITY_AUDIT.md"             # internal audit; names exact weak spots
    "Packaging/crashbox-dsn.local"  # the real Crashbox DSN
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

# Exempt from the INFRA check only. The mirror publish script carries its own copy of
# the internal-name guard, so it spells those names by necessity, and it is never
# published. Every other check still applies to it: a real credential pasted into it
# is caught like anywhere else. Without this, every push to the private repository
# printed the same known finding, and a warning that always fires is one people stop
# reading.
is_infra_exempt() {
    case "$1" in
        Scripts/publish-repo.sh) return 0 ;;
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

# Is this push going somewhere PUBLIC? git hands a pre-push hook the remote name in $1
# and its URL in $2. A push to the private repository is where work lands, and nothing
# in it is public until the publish step snapshots it and runs its own guards, which
# refuse these same shapes. So a private push only REPORTS findings, as a warning to
# fix them in the source before the next publish; vetoing it would stop work from
# landing without making anything safer. Any other destination is treated as public
# and refused: the public mirror's push URL is disabled in the maintainer's checkout,
# so a push that gets this far with another URL is a clone pushing somewhere new.
#
# Fails CLOSED: an unrecognised or absent URL is treated as public. With no remote at
# all (run by hand, not as a hook) it is a plain scan and says so.
TARGET_PUBLIC=1
case "${2:-}" in
    *tandemclip-private*) TARGET_PUBLIC=0 ;;
esac
MANUAL=0
[[ -z "${1:-}" && -z "${2:-}" ]] && MANUAL=1

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
    is_infra_exempt "$f" && continue
    if out=$(grep -InE "$HOST_RE" "$f" 2>/dev/null); then
        echo "INFRA   $f"; echo "$out"; hit=1
    fi
done < <(git ls-files)

# --- 2 + 3. Commits being pushed ---------------------------------------------
# Only when invoked as a pre-push hook (git feeds refs on stdin). Scanning the
# range catches a secret that was added and later deleted: still in history.
scan_range() {
    local range="$1" commit path blob
    # Commit messages travel with the history too.
    if out=$(git log --format='%H %s%n%b' "$range" 2>/dev/null | grep -InE "$SECRET_RE|$LAN_RE|$HOST_RE"); then
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
            is_infra_exempt "$path" && continue
            if out=$(git cat-file blob "$blob" 2>/dev/null | grep -InIE "$HOST_RE"); then
                echo "INFRA   $path (in $commit)"; echo "$out"; hit=1
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
            # New branch/tag: scan what it adds beyond everything origin already has.
            scan_range "$local_sha --not --remotes=origin"
        else
            scan_range "$remote_sha..$local_sha"
        fi
    done
fi

if [[ $hit -ne 0 ]]; then
    echo "" >&2
    if [[ $MANUAL -eq 1 ]]; then
        echo "✗ secret-scan: findings above. Remove them from the tracked tree." >&2
        exit 1
    fi
    if [[ $TARGET_PUBLIC -eq 0 ]]; then
        echo "! secret-scan: allowing this push, because ${1:-this remote} is the PRIVATE repository." >&2
        echo "  Nothing above is public yet. The mirror publish refuses these shapes, so fix" >&2
        echo "  them in the source before the next publish. A real credential is exposed to" >&2
        echo "  everyone with access to the private repository once pushed: rotate it." >&2
        exit 0
    fi
    # The URL is not echoed: a remote URL can carry a token in its userinfo.
    echo "✗ secret-scan: refusing to push to ${1:-this remote}, which is not the private" >&2
    echo "  repository and is treated as public. Remove the above first." >&2
    echo "  A secret already in a pushed commit needs history rewritten, not just a new commit." >&2
    exit 1
fi
echo "✓ secret-scan clean"
