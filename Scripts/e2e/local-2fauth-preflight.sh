#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TOKEN_SCRIPT="$SCRIPT_DIR/local-2fauth-token.sh"
TWOFAUTH_PORT=${TWOFAUTH_PORT:-8000}
BASE_URL=${TWOFAUTH_BASE_URL:-http://127.0.0.1:${TWOFAUTH_PORT}}
EXPECT_AUTH_FAILURE=${EXPECT_AUTH_FAILURE:-0}
RUBY_BIN=${RUBY_BIN:-/usr/bin/ruby}

if [ ! -x "$RUBY_BIN" ]; then
  RUBY_BIN=ruby
fi

EXPECTED_SERVICES='["HOTP Fixture","Steam Fixture","TOTP 10 SHA1","TOTP 6 SHA1","TOTP 7 SHA256","TOTP 8 SHA512","TOTP 9 MD5"]'
export EXPECTED_SERVICES
USER_ENDPOINT="$BASE_URL/api/v1/user"
ACCOUNTS_ENDPOINT="$BASE_URL/api/v1/twofaccounts?withSecret=1"
RESPONSE_BODY=$(mktemp)

cleanup() {
  rm -f "$RESPONSE_BODY"
}

trap cleanup EXIT HUP INT TERM

if [ -z "${UI_TEST_API_TOKEN:-}" ] && [ "$EXPECT_AUTH_FAILURE" != "1" ]; then
  UI_TEST_API_TOKEN=$(TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$TOKEN_SCRIPT" | tr -d '\r\n')
fi

if [ -z "${UI_TEST_API_TOKEN:-}" ]; then
  printf '%s\n' "No UI_TEST_API_TOKEN available for preflight" >&2
  exit 1
fi

request() {
  endpoint=$1
  if ! status=$(curl -sS -o "$RESPONSE_BODY" -w '%{http_code}' -H 'Accept: application/json' -H "Authorization: Bearer $UI_TEST_API_TOKEN" "$endpoint"); then
    printf '%s\n' "Preflight could not reach $endpoint" >&2
    exit 1
  fi

  printf '%s' "$status"
}

response_summary() {
  tr '\n' ' ' <"$RESPONSE_BODY"
}

if [ "$EXPECT_AUTH_FAILURE" = "1" ]; then
  status=$(request "$USER_ENDPOINT")
  if [ "$status" != "401" ]; then
    printf '%s\n' "Expected auth failure with bad token, got HTTP $status from $USER_ENDPOINT" >&2
    printf '%s\n' "Response: $(response_summary)" >&2
    exit 1
  fi

  printf '%s\n' "Bad-token preflight confirmed unauthorized API access (HTTP 401)."
  exit 0
fi

status=$(request "$USER_ENDPOINT")
if [ "$status" != "200" ]; then
  printf '%s\n' "Preflight auth failed with HTTP $status from $USER_ENDPOINT" >&2
  printf '%s\n' "Response: $(response_summary)" >&2
  exit 1
fi

status=$(request "$ACCOUNTS_ENDPOINT")
if [ "$status" != "200" ]; then
  printf '%s\n' "Preflight account fetch failed with HTTP $status from $ACCOUNTS_ENDPOINT" >&2
  printf '%s\n' "Response: $(response_summary)" >&2
  exit 1
fi

if ! "$RUBY_BIN" -rjson -e 'expected = JSON.parse(ENV.fetch("EXPECTED_SERVICES")); actual = JSON.parse(File.read(ARGV[0])).map { |account| account.fetch("service") }.sort; if actual != expected; warn "Expected services: #{expected.join(", ")}"; warn "Actual services: #{actual.join(", ")}"; exit 1; end' "$RESPONSE_BODY"; then
  printf '%s\n' "Preflight service verification failed for testinguser@2fauth.app" >&2
  exit 1
fi

printf '%s\n' "Preflight passed for testinguser@2fauth.app."
