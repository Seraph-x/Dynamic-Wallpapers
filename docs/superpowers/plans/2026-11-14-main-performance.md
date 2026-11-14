# Main performance implementation plan

> Execute sequentially with test-driven-development, requesting-code-review, and
> verification-before-completion. The user authorized all six stages and a commit
> after each; continue through the checkpoints without another requirements interview.

**Goal:** Remove the six identified sources of repeated work and commit each independently.

**Architecture:** Preserve existing playback and ownership boundaries. Coalesce
requests at their owner, separate transient editing from durable commits, reuse
immutable frame storage only after its consumers release it, and schedule
background work from actual demand.

**Tech stack:** Swift/AppKit/SwiftUI/Combine, Objective-C++, CEF, libmpv, XCTest and native harnesses.

## Verification commands

Swift checks use `scripts/test.py` with its 60-second targeted budget. Reuse
`/tmp/dynamic-wallpaper-performance-build`, the temporary module/package caches,
and `--build-system native` from the previous verified run. Build separately if
compilation exceeds that budget. GUI/native playback checks need normal macOS
window/notification access. Keep logs in `.build/verification/main-performance-six/`.

## 1. Coalesce thumbnail requests
- [x] Add failing same-source overlap and independent-cancellation tests to `Tests/WallpaperAppTests/ThumbnailRequestTests.swift`.
- [x] Update `Sources/WallpaperApp/Media/ThumbnailLifetime.swift` with subscription-owned shared requests and source-aware cache entries; update `UI/MediaPreview.swift` to use source-aware loading.
- [x] Cover final-subscriber cancellation, fresh requests after cancellation, changed-source cache misses, removal, shutdown, and release errors.
- [x] Run thumbnail, inspector and managed-media lifecycle tests; review; commit `perf: coalesce thumbnail decoding requests`.

## 2. Separate audio editing and persistence
- [x] Add edit-session tests proving many updates yield one save, immediate audio application, cancellation/stale target handling, and observable save failures.
- [x] Add a focused audio-edit owner and wire `EntryAudioEditor`, `CurrentWallpaperAudioMenu`, inspector and application shutdown to it.
- [x] Apply audio through existing playback endpoints without whole-library reconciliation on every sample; persist through the existing transaction at edit completion.
- [x] Run audio/editor/lifecycle tests and native panel-close and real playback checks; review; commit `perf: commit volume edits once per interaction`.

## 3. Index library validation and reuse filtering
- [x] Add large-library and duplicate/missing-reference tests in `Tests/WallpaperCoreTests/LibraryStoreTests.swift` (or a focused validation test file).
- [x] Build indexes in `WallpaperCore/Models.swift` after duplicate validation; retain all existing validation errors.
- [x] Reuse `filteredMedia` in `UI/LibraryView.swift`; make inspector selection test its selected item directly using the shared predicate in `BatchActions.swift`.
- [x] Run core/library/selection tests and record a fixed large-library workload; review; commit `perf: index library validation and reuse filtered media`.

## 4. Reuse extended-video frame storage
- [x] Add native buffer ownership/reuse tests that hold old frames across newer renders and resize.
- [x] Introduce frame storage owned by actual consumers in `Sources/MPVBridge`; integrate allocation reuse into `MPVBridge.mm`.
- [x] Preserve update consumption, failure drain, queue ownership and close behavior; run pending-frame/source and Swift extended-playback acceptance.
- [x] Record allocation counts under repeated same-size frames; review; commit `perf: reuse released mpv frame buffers`.

## 5. Reduce web-frame copying
- [x] Add native damage/copy tests for first frame, partial damage, unchanged frames, retained images, resize and invalid input.
- [x] Wire dirty rectangles from `WebClient.cpp` to frame storage and `WebPage.mm`; preserve image snapshots and frame-ready accounting.
- [x] Run native Web/scene frame and thumbnail/readiness/close checks; record copied-byte counts on known damage patterns.
- [x] Review; commit `perf: reduce web wallpaper frame copies`.

## 6. Schedule background work by demand
- [x] Add tests for enabled interaction with no eligible target, paused/resumed targets, preview demand, and fresh menu evidence before clicks.
- [x] Reconcile click-observer demand in `Playback/DesktopCoordinator.swift` and reduce page lifecycle scans separately from `WebRuntime.mm` message pumping.
- [x] Verify prepare/error/close completion and idle behavior using native and Swift lifecycle tests.
- [x] Review; commit `perf: schedule wallpaper background work on demand`.

## Completion
- [x] Run cross-stage regression checks once after stage 6, inspect six commits and final status, and record exact results and limitations.
