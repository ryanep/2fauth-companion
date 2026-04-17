# Local 2FAuth E2E

This repo can run UI smoke tests against a real local `2fauth/2fauth:6.1.3` container using SQLite and deterministic seeded data.

## Prerequisites

- Docker Desktop installed and running
- Xcode with an available iOS Simulator destination
- `curl`, `openssl`, `perl`, and `ruby` available on the host

## First Run

The local stack now uses the repo-root `docker-compose.yml` with inline environment values. `APP_KEY` is generated at runtime by the helper scripts or per `make` invocation and is not stored in a local env file.

## Commands

Start the pinned local stack:

```bash
make -f makefile 2fauth-up
```

Reset the stack to deterministic live test data:

```bash
make -f makefile 2fauth-reset
```

Mint a personal access token for `testinguser@2fauth.app`:

```bash
make -f makefile 2fauth-token
```

Verify the backend is ready for UI tests:

```bash
make -f makefile 2fauth-preflight
```

Verify auth fails clearly with a bad token before launching the UI suite:

```bash
make -f makefile 2fauth-preflight-bad-token
```

Run the live UI smoke suite:

```bash
make -f makefile ui-test-live XCODE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'
```

Run the full end-to-end flow:

```bash
make -f makefile e2e-live XCODE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'
```

Run the paired watch end-to-end flow:

```bash
make -f makefile watch-e2e-live PHONE_SIM_ID='<paired-iphone-udid>' WATCH_SIM_ID='<paired-watch-udid>'
```

This flow boots the paired simulators, runs a dedicated iPhone UI prep test against the real local backend, waits for the production watch sync path to publish its application context, and then runs the watch UI suite on the paired watch simulator.

## Seeded Data

`make -f makefile 2fauth-reset` uses the upstream testing reset command and then replaces the default user accounts with these deterministic entries for `testinguser@2fauth.app`:

- `TOTP 6 SHA1`
- `TOTP 7 SHA256`
- `TOTP 8 SHA512`
- `TOTP 9 MD5`
- `TOTP 10 SHA1`
- `HOTP Fixture`
- `Steam Fixture`

The reset now runs preflight verification immediately and fails if any extra demo accounts remain for `testinguser@2fauth.app`.

## Upgrading The Docker Image

The local stack is pinned in `docker-compose.yml`.

When upgrading:

1. Change `2fauth/2fauth:6.1.3` to the new exact tag.
2. Rerun `make -f makefile 2fauth-reset`.
3. Rerun `make -f makefile 2fauth-preflight`.
4. Rerun `make -f makefile ui-test-live ...`.

Do not switch to `latest`.

## Troubleshooting

If the stack does not come up:

```bash
/Applications/Docker.app/Contents/Resources/bin/docker compose --project-name "2fauth-feat-tests" -f docker-compose.yml logs 2fauth
```

If preflight returns `401`, rerun reset first:

```bash
make -f makefile 2fauth-reset
make -f makefile 2fauth-preflight
```

If UI tests fail before launch, make sure `XCODE_DESTINATION` matches a simulator installed on this machine:

```bash
xcodebuild -showdestinations -project "2FAuth.xcodeproj" -scheme "2FAuth"
```

To find paired simulator UDIDs for the watch flow:

```bash
xcrun simctl list devices available
```

If you want a different port:

```bash
make -f makefile e2e-live TWOFAUTH_PORT=9000 TWOFAUTH_BASE_URL=http://127.0.0.1:9000 XCODE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'
```
