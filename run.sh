#!/bin/bash
# Quit any running copy, then launch the freshly built app.
set -euo pipefail
cd "$(dirname "$0")"
pkill -f "LiveSubtitles.app/Contents/MacOS/LiveSubtitles" 2>/dev/null || true
sleep 1
open build/LiveSubtitles.app
