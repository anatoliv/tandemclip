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
# Two modes, chosen by the arguments and never by what stdin looks like:
#
#   Scripts/secret-scan.sh                             manual: the tracked tree only
#   Scripts/secret-scan.sh --pre-push <remote> <url>   hook: tree + pushed range
#
# Manual mode never reads stdin (exit 1 on any finding). Only .githooks/pre-push passes
# --pre-push, and only then is stdin read, as git's ref list. Guessing from stdin was
# wrong both ways: a hook's stdin is never a terminal, and neither is an agent's shell
# or a CI step, so a manual run there sat waiting on a pipe that never closed.
# Any other arguments are a usage error (exit 2), so a caller that forgets the flag
# fails loudly instead of silently skipping the range scan.
#
# Output: one line per finding, naming WHERE and WHICH RULE, never WHAT matched:
#
#   SECRET  config.txt:3  rule=aws-access-key-id
#   SECRET  config.txt:3  rule=aws-access-key-id  (in <commit>)
#   LAN IP  commit message <commit>:2  rule=lan-ip
#   PRIVATE docs/launch/plan.md  (internal — must not be published)
#
# The matched text is deliberately absent. This runs in agent sessions and CI, and
# whatever it prints is copied into their transcripts and logs, so printing a caught
# secret leaks it a second time, to more places than the commit did. A live upload
# token reached a transcript exactly that way on 2026-09-14. Open the file at the
# line to see what it is.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Each rule is `name=extended-regex`, split at the first `=`. The name is what a
# finding reports in place of the text it matched.
#
# Tokens, Crashbox DSNs, private keys — never legitimate in the tree.
SECRET_RULES=(
    'github-token=ghp_[0-9A-Za-z]{20,}|gho_[0-9A-Za-z]{20,}'
    'gitlab-token=glpat-[0-9A-Za-z_-]{18,}'
    'slack-token=xox[abprs]-[0-9A-Za-z-]{10,}'
    'aws-access-key-id=AKIA[0-9A-Z]{16}'
    'sentry-token=sntry[a-z]_[0-9a-f]{32}'
    'dsn-with-key=https?://[0-9a-f]{16,}@o[0-9]+\.ingest\.'
    'private-key=-----BEGIN [A-Z ]*PRIVATE KEY'
)
# Private LAN IPs — deployment hosts, never something the public repo needs.
LAN_RULES=(
    'lan-ip=192\.168\.[0-9]+\.[0-9]+|(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+'
)

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
INFRA_RULES=(
    'internal-host=\b(web|ai|db|nas|dev|tm)-[0-9]{2}\b|\bagent-macbook\b|getvirtualview|[a-z]+-notarize\b'
    'personal-path=/Users/anatoli'
)

# One alternation per class, for the cheap does-anything-match test that runs on every
# file before the per-rule pass that names the rule.
join_rules() {
    local entry out=""
    for entry in "$@"; do out="${out:+$out|}${entry#*=}"; done
    printf '%s' "$out"
}
SECRET_RE="$(join_rules "${SECRET_RULES[@]}")"
LAN_RE="$(join_rules "${LAN_RULES[@]}")"
HOST_RE="$(join_rules "${INFRA_RULES[@]}")"

rules_for() {
    case "$1" in
        SECRET)   printf '%s\n' "${SECRET_RULES[@]}" ;;
        "LAN IP") printf '%s\n' "${LAN_RULES[@]}" ;;
        INFRA)    printf '%s\n' "${INFRA_RULES[@]}" ;;
    esac
}

# report CLASS WHERE SUFFIX COMMAND...
#
# Runs COMMAND once per rule of CLASS, and prints one line per matching line:
#   CLASS  WHERE:LINE  rule=NAME SUFFIX
# Only grep's line number leaves the pipe (`cut -d: -f1` on single-input `grep -n`
# output); the matched text is never held in a variable or printed. See the header.
# Returns 0 when anything matched.
report() {
    local class="$1" where="$2" suffix="$3" entry name re n found=1
    shift 3
    while IFS= read -r entry; do
        name="${entry%%=*}"; re="${entry#*=}"
        while IFS= read -r n; do
            [[ -n "$n" ]] || continue
            printf '%-8s%s:%s  rule=%s%s\n' "$class" "$where" "$n" "$name" "$suffix"
            found=0
        done < <("$@" 2>/dev/null | grep -nIE -- "$re" | cut -d: -f1)
    done < <(rules_for "$class")
    return $found
}

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
# Fails CLOSED: an unrecognised or absent URL is treated as public. Run by hand (no
# --pre-push) it is a plain scan of the tree and says so.
MANUAL=1
REMOTE=""
URL=""
if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--pre-push" || $# -gt 3 ]]; then
        echo "usage: Scripts/secret-scan.sh                           scan the tracked tree" >&2
        echo "       Scripts/secret-scan.sh --pre-push <remote> <url>   as the pre-push hook" >&2
        exit 2
    fi
    MANUAL=0
    REMOTE="${2:-}"
    URL="${3:-}"
fi
TARGET_PUBLIC=1
case "$URL" in
    *tandemclip-private*) TARGET_PUBLIC=0 ;;
esac

hit=0

# --- 1 + 3. Tracked tree ------------------------------------------------------
while IFS= read -r f; do
    if is_private_path "$f"; then
        echo "PRIVATE $f  (internal — must not be published)"; hit=1; continue
    fi
    is_exempt "$f" && continue
    [[ -f "$f" ]] || continue
    if grep -qIE -- "$SECRET_RE" "$f" 2>/dev/null; then
        report SECRET "$f" "" cat -- "$f" && hit=1
    fi
    if grep -qIE -- "$LAN_RE" "$f" 2>/dev/null; then
        report "LAN IP" "$f" "" cat -- "$f" && hit=1
    fi
    is_infra_exempt "$f" && continue
    if grep -qIE -- "$HOST_RE" "$f" 2>/dev/null; then
        report INFRA "$f" "" cat -- "$f" && hit=1
    fi
done < <(git ls-files)

# --- 2 + 3. Commits being pushed ---------------------------------------------
# Only in hook mode (--pre-push), where git feeds the refs on stdin. Scanning the
# range catches a secret that was added and later deleted: still in history.
scan_range() {
    local commit path blob class
    # The range arrives as separate revision arguments ("$@"), never as one string:
    # `git rev-list "A --not --remotes=origin"` is a single unknown revision, fails,
    # and (errors being discarded) scans nothing at all.
    while read -r commit; do
        [[ -n "$commit" ]] || continue
        # Commit messages travel with the history too.
        if git show -s --format=%B "$commit" 2>/dev/null | grep -qIE -- "$SECRET_RE|$LAN_RE|$HOST_RE"; then
            for class in SECRET "LAN IP" INFRA; do
                report "$class" "commit message $commit" "" git show -s --format=%B "$commit" && hit=1
            done
        fi
        # Every path the commit leaves with new content: anything but a deletion.
        # Each flag closes a way a commit's content goes unlisted, and so unscanned:
        #   --root        a parentless commit (a new repository's first commit, an
        #                 orphan branch) is diffed against the empty tree. Without it
        #                 diff-tree prints nothing for one.
        #   -c            a merge lists the paths that differ from every parent, which
        #                 is exactly the content the merge itself introduced (a
        #                 conflict resolution, an evil merge). Without it diff-tree
        #                 prints nothing for a merge. A path taken whole from one
        #                 parent is that parent's content, scanned with that commit.
        #   --no-renames  a rename is listed as its new path, whatever diff config says.
        #   --diff-filter=d  any status but a deletion. AM alone skipped a type change
        #                 (a symlink replaced by a file of the same name).
        #   -z            paths verbatim. Quoted, a non-ASCII name did not resolve
        #                 below and was skipped without a word.
        while IFS= read -r -d '' path; do
            [[ -n "$path" ]] || continue
            if is_private_path "$path"; then
                echo "PRIVATE $path  (in $commit — internal, must not be published)"; hit=1; continue
            fi
            is_exempt "$path" && continue
            blob=$(git rev-parse "$commit:$path" 2>/dev/null) || continue
            if git cat-file blob "$blob" 2>/dev/null | grep -qIE -- "$SECRET_RE"; then
                report SECRET "$path" "  (in $commit)" git cat-file blob "$blob" && hit=1
            fi
            if git cat-file blob "$blob" 2>/dev/null | grep -qIE -- "$LAN_RE"; then
                report "LAN IP" "$path" "  (in $commit)" git cat-file blob "$blob" && hit=1
            fi
            is_infra_exempt "$path" && continue
            if git cat-file blob "$blob" 2>/dev/null | grep -qIE -- "$HOST_RE"; then
                report INFRA "$path" "  (in $commit)" git cat-file blob "$blob" && hit=1
            fi
        done < <(git diff-tree --no-commit-id --root -r -c --no-renames --name-only \
                     --diff-filter=d -z "$commit" 2>/dev/null)
    done < <(git rev-list "$@" 2>/dev/null)
}

ZERO='0000000000000000000000000000000000000000'
if [[ $MANUAL -eq 0 && ! -t 0 ]]; then
    while read -r _local_ref local_sha _remote_ref remote_sha; do
        [[ -z "${local_sha:-}" ]] && continue
        [[ "$local_sha" == "$ZERO" ]] && continue          # branch deletion
        if [[ "${remote_sha:-$ZERO}" == "$ZERO" ]]; then
            # New branch/tag: scan what it adds beyond everything origin already has.
            scan_range "$local_sha" --not --remotes=origin
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
        echo "! secret-scan: allowing this push, because ${REMOTE:-this remote} is the PRIVATE repository." >&2
        echo "  Nothing above is public yet. The mirror publish refuses these shapes, so fix" >&2
        echo "  them in the source before the next publish. A real credential is exposed to" >&2
        echo "  everyone with access to the private repository once pushed: rotate it." >&2
        exit 0
    fi
    # The URL is not echoed: a remote URL can carry a token in its userinfo.
    echo "✗ secret-scan: refusing to push to ${REMOTE:-this remote}, which is not the private" >&2
    echo "  repository and is treated as public. Remove the above first." >&2
    echo "  A secret already in a pushed commit needs history rewritten, not just a new commit." >&2
    exit 1
fi
echo "✓ secret-scan clean"
