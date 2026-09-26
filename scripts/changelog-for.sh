#!/bin/bash
#
# Prints the release notes for a version, taken from CHANGELOG.md.
#
#   scripts/changelog-for.sh v0.1.5
#
# CHANGELOG.md is the single source of truth for what changed; this keeps the GitHub
# release description and the file from drifting apart. Exits non-zero when the version
# has no section, so a release cannot silently ship with empty notes.
#
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag or version>" >&2; exit 2; }
VERSION="${TAG#v}"

NOTES="$(awk -v want="$VERSION" '
  /^## \[/ {
    if (matching) exit
    line = $0
    sub(/^## \[/, "", line)
    sub(/\].*$/, "", line)
    if (line == want) { matching = 1; next }
  }
  matching { print }
' CHANGELOG.md)"

# Trim leading and trailing blank lines.
NOTES="$(printf '%s\n' "$NOTES" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$NOTES" ]; then
  echo "no CHANGELOG.md section for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$NOTES"
