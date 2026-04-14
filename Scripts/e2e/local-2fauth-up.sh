#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
TWOFAUTH_PORT=${TWOFAUTH_PORT:-8000}
BASE_URL=${TWOFAUTH_BASE_URL:-http://127.0.0.1:${TWOFAUTH_PORT}}
APP_KEY=${APP_KEY:-base64:$(openssl rand -base64 32)}
DOCKER_BIN=${DOCKER_BIN:-/Applications/Docker.app/Contents/Resources/bin/docker}
BRANCH_NAME=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-2fauth-$(printf '%s' "$BRANCH_NAME" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')}

if [ ! -x "$DOCKER_BIN" ]; then
  DOCKER_BIN=docker
fi

docker_compose() {
  APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$DOCKER_BIN" compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

docker_compose up -d --wait
docker_compose exec -T 2fauth php artisan 2fauth:install --force

attempt=0
until curl -fsS "$BASE_URL" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    printf '%s\n' "2FAuth did not become reachable at $BASE_URL" >&2
    docker_compose logs 2fauth >&2 || true
    exit 1
  fi
  sleep 2
done
