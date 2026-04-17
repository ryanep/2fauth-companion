#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

if [ -z "${PHONE_SIM_ID:-}" ]; then
  printf '%s\n' 'PHONE_SIM_ID is required' >&2
  exit 1
fi

if [ -z "${WATCH_SIM_ID:-}" ]; then
  printf '%s\n' 'WATCH_SIM_ID is required' >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/Tests/UI/Generated"

UI_TEST_BASE_URL="${UI_TEST_BASE_URL:-${TWOFAUTH_BASE_URL:-http://127.0.0.1:8000}}"
UI_TEST_API_TOKEN="${UI_TEST_API_TOKEN:-$(APP_KEY="${APP_KEY}" TWOFAUTH_BASE_URL="${TWOFAUTH_BASE_URL}" TWOFAUTH_PORT="${TWOFAUTH_PORT}" "$REPO_ROOT/Scripts/e2e/local-2fauth-token.sh" | tr -d '\r\n')}"
WATCH_SYNC_MARKER_PATH="$REPO_ROOT/Tests/UI/Generated/watch-sync-marker.json"
WATCH_BUILD_DIR="$REPO_ROOT/.build/watch-e2e"
WATCH_APP_PATH="$WATCH_BUILD_DIR/Build/Products/Debug-watchsimulator/2FAuthWatch.app"

rm -f "$WATCH_SYNC_MARKER_PATH"
rm -rf "$WATCH_BUILD_DIR"
printf '{"baseURL":"%s","apiToken":"%s"}\n' "$UI_TEST_BASE_URL" "$UI_TEST_API_TOKEN" > "$REPO_ROOT/Tests/UI/Generated/live-config.json"

xcrun simctl boot "$PHONE_SIM_ID" >/dev/null 2>&1 || true
xcrun simctl boot "$WATCH_SIM_ID" >/dev/null 2>&1 || true

xcodebuild build -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "platform=iOS Simulator,id=${PHONE_SIM_ID}" -derivedDataPath "$REPO_ROOT/.build/iphone-e2e"
xcrun simctl install "$PHONE_SIM_ID" "$REPO_ROOT/.build/iphone-e2e/Build/Products/Debug-iphonesimulator/2FAuth.app"

xcodebuild build -project "2FAuth.xcodeproj" -scheme "2FAuthWatch" -destination "platform=watchOS Simulator,id=${WATCH_SIM_ID}" -derivedDataPath "$WATCH_BUILD_DIR"
xcrun simctl install "$WATCH_SIM_ID" "$WATCH_APP_PATH"
xcrun simctl launch "$WATCH_SIM_ID" "com.ryanep.2fauth.watchos" >/dev/null
xcrun simctl launch "$PHONE_SIM_ID" "com.ryanep.2fauth" >/dev/null

sleep 3

UI_TEST_WATCH_SYNC_MARKER_PATH="$WATCH_SYNC_MARKER_PATH" \
xcodebuild test-without-building -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "platform=iOS Simulator,id=${PHONE_SIM_ID}" -only-testing:2FAuthUITests/TwoFAuthUITests/testLiveLoginPublishesWatchSyncMarker

sleep 5

xcodebuild test-without-building -project "2FAuth.xcodeproj" -scheme "2FAuthWatch" -destination "platform=watchOS Simulator,id=${WATCH_SIM_ID}" -only-testing:2FAuthWatchUITests/TwoFAuthWatchUITests/testWatchAppLaunches
