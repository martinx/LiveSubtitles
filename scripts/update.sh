#!/bin/bash
#
# Pull the latest source and reinstall locally.
#
#   scripts/update.sh            # pull main, rebuild, install to /Applications
#   scripts/update.sh --fetch    # only fetch and report whether there is anything new
#
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="${UPDATE_BRANCH:-main}"
FETCH_ONLY=0
[ "${1:-}" = "--fetch" ] && FETCH_ONLY=1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git checkout" >&2
  exit 1
fi

echo "==> fetching origin/$BRANCH"
git fetch --quiet origin "$BRANCH"

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "already up to date at $(git rev-parse --short HEAD)"
  exit 0
fi

echo "==> $(git rev-list --count "HEAD..origin/$BRANCH") new commit(s):"
git --no-pager log --oneline "HEAD..origin/$BRANCH" | sed 's/^/    /'

[ "$FETCH_ONLY" = "1" ] && exit 0

if [ -n "$(git status --porcelain)" ]; then
  echo
  echo "You have local changes; commit or stash them first." >&2
  exit 1
fi

echo
echo "==> fast-forwarding to origin/$BRANCH"
git merge --ff-only "origin/$BRANCH"

scripts/install.sh
