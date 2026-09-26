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

# A release passes VERSION explicitly. Otherwise derive it from the nearest tag, so a
# locally built app reports something meaningful instead of the placeholder in
# Info.plist - which would otherwise make the in-app update check offer a "newer"
# version than the code actually running.
if [ -z "${VERSION:-}" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  if DESC="$(git describe --tags --long --dirty 2>/dev/null)"; then
    VERSION="$(printf '%s' "$DESC" | sed 's/^v//; s/-dirty$//; s/-[0-9]*-g[0-9a-f]*$//')"
    BUILD_NUMBER="$(printf '%s' "$DESC" | sed -n 's/.*-\([0-9]*\)-g[0-9a-f]*.*/\1/p')"
    BUILD_NUMBER="${BUILD_NUMBER:-0}"
  fi
fi

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
  # Prefer Developer ID when it exists: it is the identity releases are signed with, so
  # local builds then share the same code identity - and therefore the same Screen
  # Recording grant - as the copy people download. Apple Development is the fallback.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development/{print $2; exit}')"
  fi
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
