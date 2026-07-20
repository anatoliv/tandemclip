#!/usr/bin/env bash
#
# Secret scanner for the public repo. TandemClip's `origin` IS the public
# GitHub repo (no sanitizing mirror), so this is the backstop between a bad
# commit and public history. Wired as a pre-push hook via:
#
#   git config core.hooksPath .githooks
#
# Scans the tracked tree for high-confidence secrets and private LAN infra.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Tokens, Sentry DSNs, private keys — never legitimate in the tree.
SECRET_RE='ghp_[0-9A-Za-z]{20,}|gho_[0-9A-Za-z]{20,}|glpat-[0-9A-Za-z_-]{18,}|xox[abprs]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}|sntry[a-z]_[0-9a-f]{32}|https?://[0-9a-f]{16,}@o[0-9]+\.ingest\.|-----BEGIN [A-Z ]*PRIVATE KEY'
# Private LAN IPs. The app ships a SecretGuard feature + test fixtures that
# legitimately contain sample IPs, so those paths are excluded.
LAN_RE='192\.168\.[0-9]+\.[0-9]+|(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+'

hit=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  # The SecretGuard feature + its tests, and this scanner, legitimately contain
  # secret-shaped sample strings. Skip them for both pattern checks.
  case "$f" in
    Tests/*|*SecretGuard*|*/secret-scan.sh) continue ;;
  esac
  if grep -InE "$SECRET_RE" "$f" >/dev/null 2>&1; then
    echo "SECRET  $f"; grep -InE "$SECRET_RE" "$f"; hit=1
  fi
  if grep -InE "$LAN_RE" "$f" >/dev/null 2>&1; then
    echo "LAN IP  $f"; grep -InE "$LAN_RE" "$f"; hit=1
  fi
done < <(git ls-files)

if [[ $hit -ne 0 ]]; then
  echo "" >&2
  echo "✗ secret-scan: refusing to push — remove the above before publishing." >&2
  exit 1
fi
echo "✓ secret-scan clean"
