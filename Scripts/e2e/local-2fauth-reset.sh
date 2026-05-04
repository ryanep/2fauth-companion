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
        'service' => 'Amazon',
        'account' => 'john.doe.47@example.com',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Amazon:john.doe.47%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Amazon',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Google',
        'account' => 'john.doe.18@gmail.com',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha256',
        'digits' => 7,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Google:john.doe.18%40gmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Google&algorithm=SHA256&digits=7',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Microsoft',
        'account' => 'john.doe.62@outlook.com',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha512',
        'digits' => 8,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Microsoft:john.doe.62%40outlook.com?secret=JBSWY3DPEHPK3PXP&issuer=Microsoft&algorithm=SHA512&digits=8',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'PlayStation',
        'account' => 'john_doe_34',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'md5',
        'digits' => 9,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/PlayStation:john_doe_34?secret=JBSWY3DPEHPK3PXP&issuer=PlayStation&algorithm=MD5&digits=9',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Stripe',
        'account' => 'john.doe.53@company.com',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 10,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Stripe:john.doe.53%40company.com?secret=JBSWY3DPEHPK3PXP&issuer=Stripe&digits=10',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Discord',
        'account' => 'john_doe_08',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Discord:john_doe_08?secret=JBSWY3DPEHPK3PXP&issuer=Discord',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Dropbox',
        'account' => 'john.doe.31@workmail.com',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Dropbox:john.doe.31%40workmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Dropbox',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'GitHub',
        'account' => 'john_doe_12',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/GitHub:john_doe_12?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Nintendo',
        'account' => 'john_doe_21',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Nintendo:john_doe_21?secret=JBSWY3DPEHPK3PXP&issuer=Nintendo',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Notion',
        'account' => 'john.doe.14@proton.me',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Notion:john.doe.14%40proton.me?secret=JBSWY3DPEHPK3PXP&issuer=Notion',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'totp',
        'service' => 'Reddit',
        'account' => 'john_doe_27',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 6,
        'period' => 30,
        'legacy_uri' => 'otpauth://totp/Reddit:john_doe_27?secret=JBSWY3DPEHPK3PXP&issuer=Reddit',
    ],
    [
        'group_id' => $group->id,
        'otp_type' => 'steamtotp',
        'service' => 'Steam',
        'account' => 'john_doe_56',
        'secret' => 'JBSWY3DPEHPK3PXP',
        'algorithm' => 'sha1',
        'digits' => 5,
        'period' => 30,
        'legacy_uri' => 'otpauth://steam/Steam:john_doe_56?secret=JBSWY3DPEHPK3PXP&issuer=Steam',
    ],
]);
PHP
)

docker_compose exec -T 2fauth env XDG_CONFIG_HOME=/tmp php artisan tinker --execute="$SEED_SCRIPT"

APP_KEY="$APP_KEY" TWOFAUTH_BASE_URL="$BASE_URL" TWOFAUTH_PORT="$TWOFAUTH_PORT" "$PREFLIGHT_SCRIPT"
