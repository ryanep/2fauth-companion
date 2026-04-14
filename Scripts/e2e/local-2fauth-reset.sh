#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
PREFLIGHT_SCRIPT="$SCRIPT_DIR/local-2fauth-preflight.sh"
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

APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$UP_SCRIPT"

docker_compose exec -T 2fauth php artisan 2fauth:reset-testing --no-confirm

SEED_SCRIPT=$(cat <<'PHP'
use App\Models\User;
use Illuminate\Database\Eloquent\Model;

$user = User::where('email', 'testinguser@2fauth.app')->firstOrFail();
Model::unguard();
$user->tokens()->delete();
$user->twofaccounts()->delete();
$user->groups()->delete();

$group = $user->groups()->create([
    'name' => 'Live E2E',
]);

$user->twofaccounts()->createMany([
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'TOTP 6 SHA1',
        'account' => 'totp-user',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/TOTP%206%20SHA1:totp-user?secret=JBSWY3DPEHPK3PXP&issuer=TOTP%206%20SHA1',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'TOTP 7 SHA256',
        'account' => 'totp-7',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha256',
        'digits' => 7,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/TOTP%207%20SHA256:totp-7?secret=JBSWY3DPEHPK3PXP&issuer=TOTP%207%20SHA256&algorithm=SHA256&digits=7',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'TOTP 8 SHA512',
        'account' => 'totp-8',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha512',
        'digits' => 8,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/TOTP%208%20SHA512:totp-8?secret=JBSWY3DPEHPK3PXP&issuer=TOTP%208%20SHA512&algorithm=SHA512&digits=8',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'TOTP 9 MD5',
        'account' => 'totp-9',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'md5',
        'digits' => 9,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/TOTP%209%20MD5:totp-9?secret=JBSWY3DPEHPK3PXP&issuer=TOTP%209%20MD5&algorithm=MD5&digits=9',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'TOTP 10 SHA1',
        'account' => 'totp-10',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 10,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/TOTP%2010%20SHA1:totp-10?secret=JBSWY3DPEHPK3PXP&issuer=TOTP%2010%20SHA1&digits=10',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'hotp',
        'service' => 'HOTP Fixture',
        'account' => 'hotp-user',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'counter' => 0,
        'legacy_uri' => 'otpauth://hotp/HOTP%20Fixture:hotp-user?secret=JBSWY3DPEHPK3PXP&issuer=HOTP%20Fixture&counter=0',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'steamtotp',
        'service' => 'Steam Fixture',
        'account' => 'steam-user',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 5,
        'period' => 30,
        'legacy_uri' => 'otpauth://steam/Steam%20Fixture:steam-user?secret=JBSWY3DPEHPK3PXP&issuer=Steam%20Fixture',
    ],
]);
PHP
)

docker_compose exec -T 2fauth env XDG_CONFIG_HOME=/tmp php artisan tinker --execute="$SEED_SCRIPT"

APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$PREFLIGHT_SCRIPT"
