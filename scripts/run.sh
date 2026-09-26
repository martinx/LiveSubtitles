#!/bin/bash
#
# Quit any running copy, then launch the freshly built app.
#
# Debug switches (LIVESUBTITLES_DEBUG, LIVESUBTITLES_DUMP_SRT,
# LIVESUBTITLES_OPEN_SETTINGS) are honoured: `open` does not forward environment
# variables, so when any of them is set the executable is run directly instead,
# which also keeps its log output on your terminal.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/LiveSubtitles.app"
BIN="$APP/Contents/MacOS/LiveSubtitles"

pkill -f "LiveSubtitles.app/Contents/MacOS/LiveSubtitles" 2>/dev/null || true
sleep 1

if [ -n "${LIVESUBTITLES_DEBUG:-}${LIVESUBTITLES_DUMP_SRT:-}${LIVESUBTITLES_OPEN_SETTINGS:-}" ]; then
  exec "$BIN"
fi

open "$APP"
