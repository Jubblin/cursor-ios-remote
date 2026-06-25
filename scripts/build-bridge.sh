#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Bridge"
swift build -c release

BINARY="$ROOT/Bridge/.build/release/CursorBridge"
APP_DIR="$ROOT/Bridge/.build/CursorBridge.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.0.0-dev")"
VERSION="${VERSION#v}"

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY" "$APP_DIR/Contents/MacOS/CursorBridge"
chmod +x "$APP_DIR/Contents/MacOS/CursorBridge"
sed "s/VERSION_PLACEHOLDER/${VERSION}/g" "$ROOT/Bridge/Resources/Info.plist" > "$APP_DIR/Contents/Info.plist"

echo "Built: $BINARY"
echo "App bundle: $APP_DIR"
echo "Run: $ROOT/scripts/run-bridge.sh"
