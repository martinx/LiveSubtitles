#!/bin/bash
#
# Builds LiveSubtitles and assembles a runnable .app bundle.
#
#   scripts/build.sh            # release build (default, what you want for daily use)
#   scripts/build.sh debug      # debug build, faster to compile
#
# Environment:
#   VERSION=1.2.3               stamp CFBundleShortVersionString
#   BUILD_NUMBER=42             stamp CFBundleVersion
#   CODESIGN_IDENTITY="..."     sign with this identity
#   CODESIGN_IDENTITY=adhoc     force ad-hoc signing (skips identity lookup)
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/LiveSubtitles.app"
BUNDLE_ID="ai.bitey.livesubtitles"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LiveSubtitles" "$APP/Contents/MacOS/LiveSubtitles"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Releases are stamped from the git tag by the release workflow.
if [ -n "${VERSION:-}" ]; then
  SHORT="${VERSION#v}"
  plutil -replace CFBundleShortVersionString -string "$SHORT" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
  echo "==> version $SHORT (build ${BUILD_NUMBER:-1})"
fi

# Prefer a real signing identity: macOS remembers the Screen Recording grant per
# signature, so a stable identity means the permission is only approved once.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ "$IDENTITY" = "adhoc" ]; then
  IDENTITY=""
elif [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> signing with: $IDENTITY"
  if [[ "$IDENTITY" == Developer\ ID* ]]; then
    # Hardened runtime and a secure timestamp are required for notarisation.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
      --identifier "$BUNDLE_ID" "$APP"
  else
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  fi
else
  echo "==> signing ad-hoc (no signing identity)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo
echo "==> built $APP"
echo "    scripts/run.sh      # or: open $APP"
