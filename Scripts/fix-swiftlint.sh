#!/usr/bin/env bash
set -euo pipefail

if command -v swiftlint >/dev/null 2>&1; then
  SWIFTLINT_BIN="$(command -v swiftlint)"
elif [ -x "/opt/homebrew/bin/swiftlint" ]; then
  SWIFTLINT_BIN="/opt/homebrew/bin/swiftlint"
elif [ -x "/usr/local/bin/swiftlint" ]; then
  SWIFTLINT_BIN="/usr/local/bin/swiftlint"
else
  echo "error: swiftlint is not installed. Install it with 'brew install swiftlint'." >&2
  exit 1
fi

"$SWIFTLINT_BIN" lint --fix --config .swiftlint.yml
