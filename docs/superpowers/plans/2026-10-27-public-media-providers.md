# Public media providers implementation plan

> For agentic workers: execute in order with `executing-plans`, TDD and independent review. The umbrella/user already approved this work; no repeated requirements interview.

**Goal:** Deliver the native public Music/Spotify provider foundation with real OS transport evidence and strict default-off persistence.

**Architecture:** Core owns source settings; a separate native target owns immutable data, public Apple Events, serial service and lifecycle controller. Main/CEF/UI follow in the dependent integration PR.

**Tech stack:** Swift, AppKit, Combine, Carbon public Apple Events, SwiftPM/XCTest and Python harness orchestration.

## 1. Settings and typed data

Files: `Sources/WallpaperCore/SystemMediaSource.swift`, `Sources/WallpaperCore/Models.swift`, `Sources/WallpaperMediaIntegration/SystemMediaSnapshot.swift`, `Tests/WallpaperCoreTests/SystemMediaSettingsTests.swift`, `Tests/WallpaperMediaIntegrationTests/SystemMediaSnapshotTests.swift`, minimal `Package.swift` target/product additions.

- [x] Add failing legacy/default/roundtrip/invalid-source tests, run the targeted Core tests (separate build, 60-second run).
- [x] Add source enum/persistence, immutable state/snapshot types and explicit unavailable artwork/lyrics semantics.
- [x] Verify Core tests and native module build.

## 2. Production Apple Events service

Files: `MediaAppleEventCodes.swift`, `MediaAppleEventAdapter.swift`, `SystemMediaService.swift`, `AppleEventMediaService.swift` in the new target, plus descriptor/permission/service tests.

- [x] Add failing descriptor decoding tests for valid metadata, no-track, unsupported state, malformed types, Unicode and Spotify milliseconds.
- [x] Implement raw property object specifiers and strict descriptor parsing; events use running PID and known event/property codes only.
- [x] Implement background serial service, explicit permission probe/request, finite visible timeout and no app launch.
- [x] Verify tests; inspect service source for private API and library-write events.

## 3. Shared lifecycle controller

Files: `SystemMediaController.swift` and `Tests/WallpaperMediaIntegrationTests/SystemMediaControllerTests.swift`.

- [x] Write and run failing tests for default off, no implicit prompts, demand sharing, stale results, queued transport, failure/retry, shutdown and resumed quit.
- [x] Implement published state and a single ordered async operation chain with generation/demand invalidation, explicit clear and no automatic failure retry.
- [x] Run targeted tests after cold build; report timeouts separately.

## 4. Real transport acceptance

Files: `Tests/MediaAutomationHarness/Fixture.swift`, `Client.swift`, `Info.plist`, `scripts/test-media-automation.py`, `docs/testing/public-media-providers.md`.

- [x] Write native fixture and failing production-adapter acceptance for reads and all five controls, malformed descriptors, explicit errors/timeouts, exited process and no app launch.
- [x] Build fixture/client separately; request execution slot from root before native GUI/runtime launch.
- [x] Run real Apple Events acceptance within 60-second execution budget, using temporary fixture state only.
- [x] Record truthful evidence and remaining vendor-app smoke requirement.

## 5. Review and delivery

- [x] Run native/Core tests, static/privacy/diff checks. Native 20 + Core 130 passed; real Music/Spotify dictionary adapters passed owned-fixture OS IPC. All 42 product-configuration tests passed in the authorized unsandboxed read-only run; see evidence below.
- [x] Ask existing completion reviewer for independent review; resolve findings and retest changed behavior.
- [x] Report exact files/interface/evidence to root. No commit/push/PR until root author identity and integration instructions arrive.

## Evidence and handoff

- Native `test-public-media.py --build-only`: default Xcode build system, selected SDK, no compile warnings.
- Final `test-public-media.py --run-only`: 20 native + 130 Core tests, zero failures, execution within 60 seconds.
- Actual OS acceptance `--run-only --automation --authorize-owned-fixture`: Music and Spotify dictionary adapters each passed metadata/Unicode/timeline, five controls, missing item, malformed data, explicit read/action errors, real timeout, changed-track consistency and exited process. Both owned clients and fixtures exited. No vendor app/library/preferences were touched.
- Actual transport service/adapter code was unchanged after that acceptance; later controller-only shutdown regressions passed in the final native suite.
- Python syntax and `git diff --check` passed; changed-source privacy scan passed all 22 changed/new files.
- First sandbox GUI launch failed in AppKit `_RegisterApplication` before fixture readiness; the approved unsandboxed invocation worked. Direct client exec returned real TCC denial; signed app launch through LaunchServices passed. The test launcher checks atomic client results and PID exit rather than treating `open` status as application success.
- Product configuration script: the first sandbox run failed only because nested `sandbox-exec` reported `sandbox_apply: Operation not permitted`. The authorized unsandboxed read-only rerun passed all 42 tests in 3.76 seconds. No product/test fallback was added.
- Artifacts remain under `.build`: `media-foundation-build.log`, `media-foundation-unit-final.log`, `media-foundation-acceptance-final.log`, `media-controller-queue-red.log`, `media-shutdown-red.log`, and `verification/public-media/run-*`.
- No commits/push or production UI exposure. Independent read-only review passed without blockers. Root updated the branch to Main `9472eda` and reran the 20 native plus 130 Core tests successfully; exact-head integration/commit belongs to the root completion workflow.
