#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
UP_SCRIPT="$SCRIPT_DIR/local-2fauth-up.sh"
DOCKER_BIN=${DOCKER_BIN:-/Applications/Docker.app/Contents/Resources/bin/docker}
TWOFAUTH_PORT=${TWOFAUTH_PORT:-8000}
BASE_URL=${TWOFAUTH_BASE_URL:-http://127.0.0.1:${TWOFAUTH_PORT}}
APP_KEY=${APP_KEY:-base64:$(openssl rand -base64 32)}
BRANCH_NAME=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-2fauth-$(printf '%s' "$BRANCH_NAME" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')}

if [ ! -x "$DOCKER_BIN" ]; then
  DOCKER_BIN=docker
fi

docker_compose() {
  APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$DOCKER_BIN" compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$UP_SCRIPT" >/dev/null

TOKEN_SCRIPT=$(cat <<'PHP'
$user = \App\Models\User::where('email', 'testinguser@2fauth.app')->firstOrFail();
$user->tokens()->where('name', 'local-e2e')->delete();
echo $user->createToken('local-e2e')->accessToken;
PHP
)

docker_compose exec -T 2fauth env XDG_CONFIG_HOME=/tmp php artisan tinker --execute="$TOKEN_SCRIPT"
printf '\n'
