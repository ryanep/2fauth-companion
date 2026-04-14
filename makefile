SHELL := /bin/sh

TWOFAUTH_PORT ?= 8000
TWOFAUTH_BASE_URL ?= http://127.0.0.1:$(TWOFAUTH_PORT)
APP_KEY ?= base64:$(shell openssl rand -base64 32)

.PHONY: 2fauth-up 2fauth-reset 2fauth-token 2fauth-preflight 2fauth-preflight-bad-token ui-test-live e2e-live

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
	xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "$${XCODE_DESTINATION}" -only-testing:2FAuthUITests

e2e-live: ui-test-live
