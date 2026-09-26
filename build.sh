#!/bin/bash
#
# Builds LiveSubtitles and assembles a runnable .app bundle.
#
#   ./build.sh            # release build (default, what you want for daily use)
#   ./build.sh debug      # debug build, faster to compile
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/LiveSubtitles.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LiveSubtitles" "$APP/Contents/MacOS/LiveSubtitles"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Prefer a real signing identity: macOS remembers the Screen Recording grant per
# signature, so a stable identity means you only approve the permission once.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"

if [ -n "${IDENTITY:-}" ]; then
  echo "==> signing with: $IDENTITY"
  codesign --force --sign "$IDENTITY" --identifier com.local.LiveSubtitles "$APP"
else
  echo "==> signing ad-hoc (no signing identity found)"
  codesign --force --sign - --identifier com.local.LiveSubtitles "$APP"
fi

echo
echo "==> built $APP"
echo "    ./run.sh        # or: open $APP"
