SHELL := /bin/sh

TWOFAUTH_PORT ?= 8000
TWOFAUTH_BASE_URL ?= http://127.0.0.1:$(TWOFAUTH_PORT)
APP_KEY ?= base64:$(shell openssl rand -base64 32)

.PHONY: 2fauth-up 2fauth-reset 2fauth-token 2fauth-preflight 2fauth-preflight-bad-token ui-test-live ui-test-live-ipad watch-e2e-live e2e-live screenshot-review-set screenshot-review-iphone screenshot-review-ipad

2fauth-up:
	APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-up.sh

2fauth-reset:
	APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-reset.sh

2fauth-token:
	APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-token.sh

2fauth-preflight:
	@APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-preflight.sh

2fauth-preflight-bad-token:
	@APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" UI_TEST_API_TOKEN="not-a-real-token" EXPECT_AUTH_FAILURE=1 ./Scripts/e2e/local-2fauth-preflight.sh

ui-test-live: 2fauth-reset 2fauth-preflight
	@set -eu; \
	if [ -z "$${XCODE_DESTINATION:-}" ]; then \
		printf '%s\n' "Set XCODE_DESTINATION, for example: make -f makefile ui-test-live XCODE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'" >&2; \
		exit 1; \
	fi; \
	mkdir -p "Tests/UI/Generated"; \
	UI_TEST_BASE_URL="$${UI_TEST_BASE_URL:-$(TWOFAUTH_BASE_URL)}"; \
	UI_TEST_API_TOKEN="$${UI_TEST_API_TOKEN:-$$(APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-token.sh | tr -d '\r\n')}"; \
	printf '{"baseURL":"%s","apiToken":"%s"}\n' "$$UI_TEST_BASE_URL" "$$UI_TEST_API_TOKEN" > "Tests/UI/Generated/live-config.json"; \
	xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "$${XCODE_DESTINATION}" \
		-only-testing:2FAuthUITests \
		-skip-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendAddsTOTPAccount \
		-skip-testing:2FAuthUITests/TwoFAuthUITests/testLiveLoginPublishesWatchSyncMarker; \
	xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "$${XCODE_DESTINATION}" \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendAddsTOTPAccount

ui-test-live-ipad: 2fauth-reset 2fauth-preflight
	@set -eu; \
	if [ -z "$${XCODE_DESTINATION:-}" ]; then \
		printf '%s\n' "Set XCODE_DESTINATION, for example: make -f makefile ui-test-live-ipad XCODE_DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=26.4'" >&2; \
		exit 1; \
	fi; \
	mkdir -p "Tests/UI/Generated"; \
	UI_TEST_BASE_URL="$${UI_TEST_BASE_URL:-$(TWOFAUTH_BASE_URL)}"; \
	UI_TEST_API_TOKEN="$${UI_TEST_API_TOKEN:-$$(APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-token.sh | tr -d '\r\n')}"; \
	printf '{"baseURL":"%s","apiToken":"%s"}\n' "$$UI_TEST_BASE_URL" "$$UI_TEST_API_TOKEN" > "Tests/UI/Generated/live-config.json"; \
	xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "$${XCODE_DESTINATION}" \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLaunchOnIPad \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLoginScreenShowsNativeFormControlsOnIPad \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendUsesGridOnIPad \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendUsesGridOnIPadLandscape \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendFallsBackToListOnNarrowIPadWidth \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendSearchesOnIPadLandscape \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveBackendReturnsToGridAfterSettingsRoundTripOnIPad \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testSettingsScreenShowsNativeFormControlsOnIPad

watch-e2e-live: 2fauth-reset 2fauth-preflight
	@set -eu; \
	if [ -z "$${PHONE_SIM_ID:-}" ]; then \
		printf '%s\n' "Set PHONE_SIM_ID to a paired iPhone simulator UDID" >&2; \
		exit 1; \
	fi; \
	if [ -z "$${WATCH_SIM_ID:-}" ]; then \
		printf '%s\n' "Set WATCH_SIM_ID to the paired watch simulator UDID" >&2; \
		exit 1; \
	fi; \
	APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" PHONE_SIM_ID="$${PHONE_SIM_ID}" WATCH_SIM_ID="$${WATCH_SIM_ID}" ./Scripts/e2e/watch-e2e-live.sh

e2e-live: ui-test-live

screenshot-review-iphone: 2fauth-reset 2fauth-preflight
	@set -eu; \
	if [ -z "$${SCREENSHOT_OUTPUT_DIR:-}" ]; then \
		printf '%s\n' "Set SCREENSHOT_OUTPUT_DIR to a writable folder" >&2; \
		exit 1; \
	fi; \
	if [ -z "$${IPHONE_SIM_ID:-}" ]; then \
		printf '%s\n' "Set IPHONE_SIM_ID to an iPhone simulator UDID" >&2; \
		exit 1; \
	fi; \
	mkdir -p "Tests/UI/Generated" "$$SCREENSHOT_OUTPUT_DIR"; \
	UI_TEST_BASE_URL="$${UI_TEST_BASE_URL:-$(TWOFAUTH_BASE_URL)}"; \
	UI_TEST_API_TOKEN="$${UI_TEST_API_TOKEN:-$$(APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-token.sh | tr -d '\r\n')}"; \
	printf '{"baseURL":"%s","apiToken":"%s"}\n' "$$UI_TEST_BASE_URL" "$$UI_TEST_API_TOKEN" > "Tests/UI/Generated/live-config.json"; \
	printf '%s\n' "$$SCREENSHOT_OUTPUT_DIR" > "Tests/UI/Generated/screenshot-output-dir.txt"; \
	xcrun simctl boot "$$IPHONE_SIM_ID" >/dev/null 2>&1 || true; \
	xcrun simctl bootstatus "$$IPHONE_SIM_ID" -b; \
	cleanup_status_bar() { \
		result=$$1; \
		trap - 0 HUP INT TERM; \
		xcrun simctl status_bar "$$IPHONE_SIM_ID" clear >/dev/null 2>&1 || true; \
		exit $$result; \
	}; \
	trap 'cleanup_status_bar "$$?"' 0; \
	trap 'cleanup_status_bar 129' HUP; \
	trap 'cleanup_status_bar 130' INT; \
	trap 'cleanup_status_bar 143' TERM; \
	xcrun simctl status_bar "$$IPHONE_SIM_ID" override --time "9:41"; \
	UI_TEST_SCREENSHOT_OUTPUT_DIR="$$SCREENSHOT_OUTPUT_DIR" xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "platform=iOS Simulator,id=$$IPHONE_SIM_ID" -derivedDataPath ".build/screenshots-iphone" \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneLoginLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneLoginDarkScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneAccountsLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneAccountsDarkScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneSettingsLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPhoneSettingsDarkScreenshot

screenshot-review-ipad: 2fauth-reset 2fauth-preflight
	@set -eu; \
	if [ -z "$${SCREENSHOT_OUTPUT_DIR:-}" ]; then \
		printf '%s\n' "Set SCREENSHOT_OUTPUT_DIR to a writable folder" >&2; \
		exit 1; \
	fi; \
	if [ -z "$${IPAD_SIM_ID:-}" ]; then \
		printf '%s\n' "Set IPAD_SIM_ID to an iPad simulator UDID" >&2; \
		exit 1; \
	fi; \
	mkdir -p "Tests/UI/Generated" "$$SCREENSHOT_OUTPUT_DIR"; \
	UI_TEST_BASE_URL="$${UI_TEST_BASE_URL:-$(TWOFAUTH_BASE_URL)}"; \
	UI_TEST_API_TOKEN="$${UI_TEST_API_TOKEN:-$$(APP_KEY="$(APP_KEY)" TWOFAUTH_BASE_URL="$(TWOFAUTH_BASE_URL)" TWOFAUTH_PORT="$(TWOFAUTH_PORT)" ./Scripts/e2e/local-2fauth-token.sh | tr -d '\r\n')}"; \
	printf '{"baseURL":"%s","apiToken":"%s"}\n' "$$UI_TEST_BASE_URL" "$$UI_TEST_API_TOKEN" > "Tests/UI/Generated/live-config.json"; \
	printf '%s\n' "$$SCREENSHOT_OUTPUT_DIR" > "Tests/UI/Generated/screenshot-output-dir.txt"; \
	xcrun simctl boot "$$IPAD_SIM_ID" >/dev/null 2>&1 || true; \
	xcrun simctl bootstatus "$$IPAD_SIM_ID" -b; \
	cleanup_status_bar() { \
		result=$$1; \
		trap - 0 HUP INT TERM; \
		xcrun simctl status_bar "$$IPAD_SIM_ID" clear >/dev/null 2>&1 || true; \
		exit $$result; \
	}; \
	trap 'cleanup_status_bar "$$?"' 0; \
	trap 'cleanup_status_bar 129' HUP; \
	trap 'cleanup_status_bar 130' INT; \
	trap 'cleanup_status_bar 143' TERM; \
	xcrun simctl status_bar "$$IPAD_SIM_ID" override --time "9:41"; \
	UI_TEST_SCREENSHOT_OUTPUT_DIR="$$SCREENSHOT_OUTPUT_DIR" xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "platform=iOS Simulator,id=$$IPAD_SIM_ID" -derivedDataPath ".build/screenshots-ipad" \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadLoginLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadLoginDarkScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadAccountsLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadAccountsDarkScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadSettingsLightScreenshot \
		-only-testing:2FAuthUITests/TwoFAuthUITests/testCaptureIPadSettingsDarkScreenshot

screenshot-review-set: screenshot-review-iphone screenshot-review-ipad
