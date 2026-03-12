#!/usr/bin/env bash
set -euo pipefail

if command -v swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT_BIN="$(command -v swift-format)"
elif xcrun --find swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT_BIN="$(xcrun --find swift-format)"
else
  echo "error: swift-format is not installed. Install it with 'brew install swift-format'." >&2
  exit 1
fi

"$SWIFT_FORMAT_BIN" lint --recursive Sources Tests
