#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CURSOR_BRIDGE_PORT="${CURSOR_BRIDGE_PORT:-8742}"

APP="$ROOT/Bridge/.build/CursorBridge.app"
APP_BINARY="$APP/Contents/MacOS/CursorBridge"

if [ ! -x "$APP_BINARY" ]; then
  echo "App bundle missing. Run ./scripts/build-bridge.sh first." >&2
  exit 1
fi

# Foreground: logs in this terminal (don't background with &).
if [[ "${1:-}" == "--foreground" || "${1:-}" == "-f" ]]; then
  exec "$APP_BINARY"
fi

# Default: launch detached via open so AppKit/SwiftUI get a proper GUI session.
# Running `exec … &` from zsh can trace-trap when the menu bar app starts.
open -na "$APP"
echo "Cursor Bridge started (menu bar)."
echo "Foreground logs: $ROOT/scripts/run-bridge.sh --foreground"
