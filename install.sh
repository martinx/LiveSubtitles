#!/bin/bash
#
# Builds LiveSubtitles and installs it into /Applications so it can be launched
# from Spotlight, Launchpad or the Dock.
#
#   ./install.sh
#
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

TARGET="/Applications/LiveSubtitles.app"

echo "==> quitting any running copy"
pkill -f "LiveSubtitles.app/Contents/MacOS/LiveSubtitles" 2>/dev/null || true
sleep 1

echo "==> installing to $TARGET"
rm -rf "$TARGET"
cp -R build/LiveSubtitles.app "$TARGET"

# Nudge Launch Services so Spotlight and Launchpad pick the new bundle up.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$TARGET" 2>/dev/null || true

echo
echo "==> installed: $TARGET"
echo "    Launch from Spotlight (Cmd-Space -> LiveSubtitles), or:  open -a LiveSubtitles"
