#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Bridge"
swift build -c release
echo "Built: $ROOT/Bridge/.build/release/CursorBridge"
echo "Run: $ROOT/Bridge/.build/release/CursorBridge"
