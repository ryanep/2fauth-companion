# Staged Docker Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep real Docker-backed 2FAuth screenshot tests reliable on the ARM macOS runner by preventing Docker and unused simulators from competing with Xcode builds.

**Architecture:** Build both simulator test bundles before starting Colima. Then start a small Docker VM, seed and preflight 2FAuth using a CI Compose override with a lightweight health check, run one simulator lane at a time, and shut down each simulator after use.

**Tech Stack:** GitHub Actions, Docker Compose, Colima/QEMU, Make, Xcode UI tests

## Global Constraints

- Keep `runs-on: macos-26`.
- Keep the real `2fauth/2fauth:6.1.3` Docker image and API.
- Do not change production app behavior.
- Run only one iOS simulator during each screenshot lane.
- Require exactly 16 PNG files before artifact upload.

---

### Task 1: Lightweight CI Container Health Check

**Files:**
- Create: `docker-compose.screenshots.yml`
- Modify: `.github/workflows/screenshots.yml`

**Interfaces:**
- Consumes: base `docker-compose.yml`
- Produces: a Compose service whose health check tests nginx without invoking Laravel/PHP-FPM

- [x] Add a CI-only Compose override replacing the full HTTP health check with a lightweight nginx-port check.
- [x] Configure screenshot backend commands and cleanup to use both Compose files.
- [x] Validate the merged Compose configuration.

### Task 2: Stage Builds Before Docker

**Files:**
- Modify: `.github/workflows/screenshots.yml`
- Modify: `makefile`

**Interfaces:**
- Consumes: selected iPhone and iPad simulator IDs
- Produces: prebuilt `.build/screenshots-iphone` and `.build/screenshots-ipad` bundles

- [x] Move Docker installation/start after the Xcode build-bundle step.
- [x] Keep Colima at a small allocation and start the backend only after builds complete.
- [x] Run backend reset, token generation, and preflight immediately before screenshot tests.

### Task 3: Isolate Simulator Lanes

**Files:**
- Modify: `.github/workflows/screenshots.yml`

**Interfaces:**
- Consumes: prebuilt bundles and seeded backend
- Produces: eight iPhone and eight iPad PNGs

- [x] Run the iPhone lane and shut down its simulator regardless of success.
- [x] Recheck backend health, run the iPad lane, and shut down its simulator regardless of success.
- [x] Preserve lane logs, Docker logs, exact screenshot-count validation, and artifact behavior.
- [x] Run workflow syntax checks, Make dry runs, and diff validation.
