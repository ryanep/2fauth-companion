# Account Icon Hardening Design

## Goal

Resolve the five remaining account-icon review findings while preserving immediate warm-launch rendering, same-origin security, dependency-free SVG support, and existing lifecycle behavior.

## Delivery

The work is delivered as five independent implementation commits. Each commit must include focused regression tests, pass the complete unit target, pass `git diff --check`, and be pushed before the next implementation begins.

## 1. Session-Safe Sync

Account synchronization must not apply results after its captured session is replaced or invalidated. A shared session revision identifies the active credentials and server configuration. Login attempts and destructive session transitions advance the revision synchronously.

Repository sync captures the revision before network access and validates it after the response but before mutating SwiftData. Foreground and background callers validate it again before updating session state, timestamps, Watch data, icon allowlists, credentials, or encryption keys. Stale success, unauthorized, and transient results become no-ops.

This protects both account persistence and icon pruning. Comparing credentials alone is insufficient because users may log out and back in with identical values.

## 2. Startup Recovery

The startup Reset Data action must remove both the SwiftData store and persistent account-icon cache. Cache directory resolution and synchronous persistent-file deletion will be shared between normal actor clearing and pre-model-container recovery.

Recovery remains synchronous so the existing UI reports success only after all targeted data is removed. Missing files are treated as success.

## 3. Resource Bounds

All production raster and SVG results will be normalized to metadata-free 128x128 PNG data before memory or disk storage. The cache will enforce:

- Maximum source download: 2 MiB
- Maximum source dimension: 2,048 pixels
- Maximum source pixels: 4,194,304
- Maximum normalized dimension: 128 pixels
- Maximum aggregate memory: 16 MiB, actor-isolated LRU eviction
- Maximum aggregate disk: 32 MiB and 256 files, oldest-first eviction
- Maximum concurrent downloads: four
- Maximum concurrent rasterizations: four

Admission queues must react to cancellation so obsolete work does not delay current icons. Pruning remains authoritative and removes entries outside the active allowlist before applying aggregate eviction.

## 4. Visible Refreshes

The cache will expose a per-URL `AsyncStream<Data>` using `.bufferingNewest(1)`. A subscriber receives cached stale data immediately and receives normalized replacement data after successful revalidation. Registration occurs before loading to avoid missing a fast refresh.

`AccountIconView` consumes the stream in its existing filename-and-scene-phase task. Every value is checked against task cancellation and current account metadata before updating the `UIImage`. Background phases remain cache-only and cancel unowned refresh work.

Streams deduplicate identical bytes and remove their continuation on termination. Clearing or pruning finishes observers for disallowed URLs.

## 5. Responsibility Split

The final commit is a behavior-preserving refactor:

- `AccountIconCache.swift`: actor state, orchestration, coalescing, admission, observers, memory policy
- `AccountIconURLResolver.swift`: same-origin URL construction, path validation, cache keys
- `AccountIconRasterProcessor.swift`: type detection, ImageIO validation, visibility checks, PNG normalization
- `AccountIconDiskStore.swift`: cache paths, reads, writes, inventory, trimming, persistent removal
- `AccountIconDownloader.swift`: ephemeral session, redirect rejection, response validation, bounded streaming
- `SVGIconRasterizer.swift`: MainActor WebKit rendering and cleanup

Mutable cache state remains in one actor. Extracted helpers are stateless or immutable, and `SVGIconRasterizer` remains MainActor-isolated. Existing `AccountIconCache` caller-facing methods remain stable.

## Testing

Tests will cover:

- Stale foreground success cannot mutate accounts or prune the replacement session.
- Stale background success and unauthorized responses cannot mutate or wipe the replacement session.
- Startup recovery removes store sidecars and icon files and is idempotent.
- Memory and disk limits evict deterministically under small injected limits.
- Download and raster admission never exceed configured concurrency and cancelled waiters drain immediately.
- Small and large raster inputs and SVG output become bounded PNG data without source metadata.
- A stale stream yields stale then refreshed bytes, and visible consumption accepts the replacement.
- The final file split preserves the complete passing suite and target membership.

## Non-Goals

- Adding a third-party image library
- Sending icons to the Watch app
- Changing server icon metadata or E2E fixtures
- Reworking unrelated repository synchronization behavior
