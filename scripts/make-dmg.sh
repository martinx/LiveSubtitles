#!/bin/bash
#
# Packages the built app as a drag-to-Applications disk image.
#
#   scripts/make-dmg.sh
#
# Produces build/LiveSubtitles.dmg. Does not build or sign anything: package exactly
# what is in build/, so a signature or notarisation ticket is never disturbed.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/LiveSubtitles.app"
DMG="build/LiveSubtitles.dmg"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "nothing to package: run 'make build' first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The conventional macOS install gesture: drag the app onto this.
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Live Subtitles" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" > /dev/null

rm -rf "$STAGE"
echo "==> $DMG"
