#!/usr/bin/env bash
#
# Refuse unless this checkout's secret-scan pre-push hook is actually active.
#
#   Scripts/check-hooks-path.sh [repository]     (default: this script's repository)
#
# The hook in .githooks/pre-push only runs if `core.hooksPath` points at .githooks.
# Nothing in a clone sets that, and an unset hook fails silently: every push simply
# goes out unscanned, and nothing in the output of a push says so. So the release
# path asks the question itself instead of trusting that someone once set it.
#
# Active means all three: core.hooksPath resolves to <top>/.githooks (a relative value
# is relative to the top of the working tree, as git reads it); .githooks/pre-push is
# there; and it is executable, because git skips a hook without the execute bit.
set -euo pipefail

REPO="${1:-$(dirname "$0")/..}"
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: $REPO is not a git working tree, so there is no push hook to check." >&2
    exit 1
}
FIX="git -C \"$TOP\" config core.hooksPath .githooks"

refuse() {
    echo "error: the secret-scan pre-push hook is not active in $TOP." >&2
    echo "       $1" >&2
    echo "       Until it is, every push goes out unscanned. Enable it with:" >&2
    echo "         $FIX" >&2
    exit 1
}

HP="$(git -C "$TOP" config --get core.hooksPath 2>/dev/null || true)"
[[ -n "$HP" ]] || refuse "core.hooksPath is not set, so git runs the empty default hooks directory."

case "$HP" in
    /*) HOOKS="$HP" ;;
    "~"/*) HOOKS="$HOME/${HP#"~/"}" ;;
    *) HOOKS="$TOP/$HP" ;;
esac
WANT="$(cd "$TOP/.githooks" 2>/dev/null && pwd -P)" \
    || refuse "this checkout has no .githooks directory."
GOT="$(cd "$HOOKS" 2>/dev/null && pwd -P || true)"
[[ "$GOT" == "$WANT" ]] || refuse "core.hooksPath is '$HP', not .githooks."

[[ -f "$WANT/pre-push" ]] || refuse ".githooks/pre-push is missing."
[[ -x "$WANT/pre-push" ]] || refuse ".githooks/pre-push is not executable, and git skips a hook without the execute bit."

echo "secret-scan pre-push hook active (core.hooksPath=$HP)"
