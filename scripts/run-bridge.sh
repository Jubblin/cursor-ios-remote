#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CURSOR_BRIDGE_PORT="${CURSOR_BRIDGE_PORT:-8742}"
exec "$ROOT/Bridge/.build/release/CursorBridge"
