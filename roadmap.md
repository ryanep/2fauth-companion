# 2FAuth Architecture Roadmap

This roadmap translates the architecture review into an execution plan with practical sequencing, effort, and risk.

## Phase 0: Immediate hardening (this week)

### 1) Define transport policy for user-provided servers
- [ ] Not started
- **Goal:** Establish a clear, explicit security posture for arbitrary self-hosted domains.
- **Scope:**
  - Choose and document policy: HTTPS-only, HTTPS-first with explicit HTTP opt-in (recommended), or HTTP+HTTPS compatibility mode.
  - Align ATS config with chosen policy (global allowance may remain required for arbitrary HTTP domains).
  - Add login UX guardrails for `http://` (warning + confirmation) and document App Store review rationale.
- **Files:** `Resources/Info.plist`, `Sources/App/AppModel.swift`, `Sources/Features/Login/LoginView.swift`, release/docs notes
- **Effort:** S-M
- **Risk:** Medium (security posture and misconfiguration risk)
- **Success criteria:** Transport behavior is intentional, user-visible, and documented; no mismatch between expected and actual security posture.

### 2) Normalize base URL validation across flows
- [ ] Not started
- **Goal:** Use one validation policy for login, foreground sync, and background sync.
- **Scope:** Extract a shared URL validator and apply it in `AppModel` and `BackgroundSyncManager`.
- **Files:** `Sources/App/AppModel.swift`, `Sources/Background/BackgroundSyncManager.swift` (+ new shared utility)
- **Effort:** S
- **Risk:** Low
- **Success criteria:** Same malformed/valid URL handling in all paths; no duplicate validation logic.

### 3) Expand CI quality gates
- [ ] Not started
- **Goal:** Catch regressions earlier than archive-only checks.
- **Scope:** Add unit test and UI test jobs to GitHub Actions, keep existing lint/security scripts and archive gate.
- **Files:** `.github/workflows/release-archive.yml` (or split workflows)
- **Effort:** S-M
- **Risk:** Low
- **Success criteria:** CI runs formatting checks, guardrails, tests, and archive on PRs.

## Phase 1: Performance and reliability (1-2 weeks)

### 4) Optimize OTP rendering path
- [ ] Not started
- **Goal:** Reduce per-row timer/decrypt overhead in Accounts list.
- **Scope:**
  - Replace row-local timer with shared ticker.
  - Avoid decrypting secrets every second by caching decrypted material in-memory while unlocked.
  - Invalidate cache on lock/logout/relogin wipe.
- **Files:** `Sources/Features/Accounts/AccountsView.swift`, `Sources/App/AppModel.swift`
- **Effort:** M
- **Risk:** Medium (must avoid extending secret lifetime unintentionally)
- **Success criteria:** Lower CPU usage on large account lists; unchanged UX and code correctness.

### 5) Consolidate relogin/wipe policy
- [ ] Not started
- **Goal:** Ensure unauthorized handling is consistent in foreground and background sync.
- **Scope:** Introduce a dedicated session/security policy service used by both `AppModel` and `BackgroundSyncManager`.
- **Files:** `Sources/App/AppModel.swift`, `Sources/Background/BackgroundSyncManager.swift` (+ new shared service)
- **Effort:** M
- **Risk:** Medium
- **Success criteria:** Single implementation for wipe/relogin side effects; behavior parity across execution contexts.

## Phase 2: Structural refactor (2-4 weeks)

### 6) Break up `AppModel` into focused components
- [ ] Not started
- **Goal:** Reduce complexity and improve maintainability/testability.
- **Scope:** Split responsibilities into focused units, e.g.:
  - `SessionStateController`
  - `AuthService`
  - `SyncService`
  - `OTPService`
- **Files:** `Sources/App/AppModel.swift` (+ new files under `Sources/App` and/or `Sources/Domain`)
- **Effort:** L
- **Risk:** Medium-High (touches core app flow)
- **Success criteria:** Smaller types with clear ownership; easier targeted tests; behavior unchanged.

### 7) Introduce protocol-first dependency boundaries
- [ ] In progress
- **Goal:** Decouple composition root from concrete implementations.
- **Scope:** Add protocols for API client, secret storage, crypto, repository/sync service; wire dependencies in `TwoFAuthApp`.
- **Implementation checklist:**
  - [x] Define and adopt a `SecretStore` protocol with a concrete `KeychainSecretStore` implementation.
  - [x] Switch `AppModel`, `BackgroundSyncManager`, and `CryptoStore` to depend on protocol `SecretStore` instead of concrete keychain storage.
  - [ ] Define protocol boundary for `APIClient`.
  - [ ] Define protocol boundary for `CryptoStore`.
  - [ ] Define protocol boundary for `AccountRepository` sync/wipe/decrypt surface.
  - [ ] Update tests to prefer protocol-driven test doubles where appropriate.
  - [ ] Confirm unit/UI/archive checks pass after full dependency-boundary migration.
- **Files:** `Sources/App/TwoFAuthApp.swift`, `Sources/Networking/APIClient.swift`, `Sources/Security/*.swift`, `Sources/Repository/AccountRepository.swift`
- **Effort:** M-L
- **Risk:** Medium
- **Success criteria:** App startup composes protocols; test seams no longer depend on concrete classes.

### 8) Reduce overuse of `@MainActor`
- [ ] Not started
- **Goal:** Keep UI state on main actor while running I/O and compute off-main where appropriate.
- **Scope:** Audit actor annotations; remove unnecessary main-actor constraints from networking/repository where safe.
- **Files:** `Sources/Networking/APIClient.swift`, `Sources/Repository/AccountRepository.swift`, `Sources/Background/BackgroundSyncManager.swift`
- **Effort:** M
- **Risk:** Medium (concurrency correctness)
- **Success criteria:** No UI jank from avoidable main-actor work; tests pass without data races.

## Phase 3: Long-term architecture hardening (post-1.0.x)

### 9) Define SwiftData migration strategy
- [ ] Not started
- **Goal:** Prepare for schema evolution safely.
- **Scope:** Establish schema versioning and migration policy; add migration tests and release checklist entries.
- **Files:** `Sources/Persistence/AccountEntity.swift`, `Tests/Unit/*` (+ migration docs)
- **Effort:** M
- **Risk:** Medium
- **Success criteria:** Versioned migration path documented and tested before schema changes ship.

### 10) Isolate OTP engine into a focused module
- [ ] Not started
- **Goal:** Keep cryptographic code small, pure, and independently testable.
- **Scope:** Move Base32/TOTP/HOTP/Steam code into a dedicated module/target with focused tests (and optional micro-benchmarks).
- **Files:** `Sources/TOTP/*.swift`, `Tests/Unit/*`
- **Effort:** M
- **Risk:** Low-Medium
- **Success criteria:** OTP logic has independent test surface and minimal coupling to app/UI layers.

## Suggested execution order

1. Phase 0 items 1-3
2. Phase 1 item 5 (policy consolidation), then item 4 (performance)
3. Phase 2 items 6-8 (refactor in small PRs)
4. Phase 3 items 9-10

## Tracking format (for PRs/issues)

For each roadmap item, track:
- **Status:** Not started / In progress / Blocked / Done
- **Owner:**
- **Target release:**
- **Validation:** tests, perf measurements, and/or manual QA notes
