<div align="center">
  <img width="100" height="100" alt="2FAuth Companion Icon" src="docs/icon.svg" />
  <h1>2FAuth Companion</h1>
  <p>Generate offline 2FA codes from your self-hosted 2FAuth server.</p>
</div>

## Introduction

2FAuth Companion is the mobile sidekick to your self-hosted [2FAuth](https://github.com/Bubka/2FAuth) server. It signs in with a 2FAuth personal access token, syncs accounts locally, and generates supported one-time passwords on iPhone, iPad, and Apple Watch while keeping you in control of your own infrastructure.

- App Store: <https://apps.apple.com/app/id6761366773>

## Features

- Connect and sync with your self-hosted 2FAuth server.
- Generate 2FA codes locally on iPhone, iPad, and Apple Watch.
- Quickly find accounts with fast text search.
- Use a clean, focused authenticator experience.

## Security And Privacy

- The 2FAuth API token is stored in the iOS Keychain.
- Account secrets are encrypted at rest, with watch secrets stored separately by the watch app.
- The app warns when the configured server URL uses insecure `http://` transport.
- The app does not include third-party analytics or advertising SDKs.

## Requirements

- Xcode with iOS and watchOS SDK support.
- iOS 17.0 or later for the iPhone/iPad app.
- watchOS 10.0 or later for the Apple Watch app.
- A reachable 2FAuth server and personal access token.
- Docker for the local E2E workflow.
- `swift-format` and SwiftLint for local formatting and lint checks.

## Getting Started

1. Open `2FAuth.xcodeproj` in Xcode.
2. Select the `2FAuth` scheme.
3. Choose an iPhone or iPad simulator, or a signed physical device.
4. Build and run the app.
5. Enter your 2FAuth server URL and personal access token.

The app syncs accounts after login and stores enough local data to generate supported codes without repeatedly fetching secrets from the server.

## Development

Open `2FAuth.xcodeproj` in Xcode and run the `2FAuth` scheme for day-to-day app development.

Before submitting changes, run the relevant local checks:

Format Swift files:

```bash
./Scripts/format-swift.sh
```

Check Swift formatting:

```bash
./Scripts/check-swift-format.sh
```

Run SwiftLint:

```bash
./Scripts/check-swiftlint.sh
```

Run unit tests:

```bash
xcodebuild test -project "2FAuth.xcodeproj" -scheme "2FAuth" -destination "platform=iOS Simulator,name=iPhone 16,OS=18.5" -only-testing:2FAuthTests
```

Build the watch target:

```bash
xcodebuild build -project "2FAuth.xcodeproj" -scheme "2FAuthWatch" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO
```

## Live E2E Tests

The repo includes a Docker-backed local 2FAuth stack pinned to `2fauth/2fauth:6.1.3`. The make targets start the backend, seed deterministic accounts, mint a test token, and run UI smoke tests.

See `docs/runbook/e2e-tests.md` for the full workflow.

Common entry points:

```bash
make -f makefile 2fauth-up
make -f makefile 2fauth-reset
make -f makefile 2fauth-preflight
make -f makefile ui-test-live XCODE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'
make -f makefile ui-test-live-ipad XCODE_DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=26.4'
make -f makefile watch-e2e-live PHONE_SIM_ID='<paired-iphone-udid>' WATCH_SIM_ID='<paired-watch-udid>'
```

## License

Licensed under the MIT license.
