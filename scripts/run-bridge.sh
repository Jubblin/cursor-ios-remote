#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CURSOR_BRIDGE_PORT="${CURSOR_BRIDGE_PORT:-8742}"

APP_BINARY="$ROOT/Bridge/.build/CursorBridge.app/Contents/MacOS/CursorBridge"
if [ ! -x "$APP_BINARY" ]; then
  echo "App bundle missing. Run ./scripts/build-bridge.sh first." >&2
  exit 1
fi

# Run from inside the .app bundle so LSUIElement and menu bar events work correctly.
exec "$APP_BINARY"
