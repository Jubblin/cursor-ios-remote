#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT/Bridge"
DIST_DIR="$BRIDGE_DIR/dist"
APP_NAME="Cursor Bridge"
APP_BUNDLE="$DIST_DIR/CursorBridge.app"
TAG="${1:-dev}"
VERSION="${TAG#v}"
ARCH="${ARCH:-$(uname -m)}"
DMG_NAME="CursorBridge-${TAG}-macos-${ARCH}.dmg"

case "$ARCH" in
  arm64)
    BUILD_PATH="$BRIDGE_DIR/.build-arm64"
    BUILD_CMD=(swift build -c release --build-path "$BUILD_PATH")
    BINARY="$BUILD_PATH/release/CursorBridge"
    ;;
  x86_64)
    BUILD_PATH="$BRIDGE_DIR/.build-x86_64"
    BUILD_CMD=(arch -x86_64 swift build -c release --build-path "$BUILD_PATH")
    BINARY="$BUILD_PATH/release/CursorBridge"
    ;;
  *)
    echo "Unsupported ARCH: $ARCH (use arm64 or x86_64)" >&2
    exit 1
    ;;
esac

echo "==> Building CursorBridge (release, ${ARCH})"
cd "$BRIDGE_DIR"
"${BUILD_CMD[@]}"

echo "==> Creating app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/CursorBridge"
chmod +x "$APP_BUNDLE/Contents/MacOS/CursorBridge"

sed "s/VERSION_PLACEHOLDER/${VERSION}/g" "$BRIDGE_DIR/Resources/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing app bundle"
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Creating DMG"
STAGING="$(mktemp -d)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$ROOT/$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$ROOT/$DMG_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --sign - "$ROOT/$DMG_NAME" || true
fi

shasum -a 256 "$ROOT/$DMG_NAME" > "$ROOT/${DMG_NAME}.sha256"

echo "Created: $ROOT/$DMG_NAME"
echo "Checksum: $ROOT/${DMG_NAME}.sha256"
