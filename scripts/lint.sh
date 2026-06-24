#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATHS=(
  "$ROOT/Bridge/Sources"
  "$ROOT/iOS/CursorRemote"
  "$ROOT/Shared"
)

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing $1. Install with: brew install $1" >&2
    exit 1
  fi
}

require swiftformat
require swiftlint

echo "==> SwiftFormat (check)"
swiftformat --lint "${PATHS[@]}"

echo "==> SwiftLint"
swiftlint lint --strict --config "$ROOT/.swiftlint.yml"

echo "Lint passed."
