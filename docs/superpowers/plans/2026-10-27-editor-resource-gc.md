# Editor Resource Collection Implementation Plan

> **For agentic workers:** Execute this approved plan inline with review checkpoints. Do not commit, push, merge, or launch GUI/CEF; the parent agent owns integration and native acceptance.

**Goal:** Reclaim abandoned content-addressed resource versions only after every editing session has released them.

**Architecture:** Shared process-held project leases protect all editor history and pending stages. An exclusive nonblocking collector, followed by the workspace lock, validates the saved manifest and descriptor-relative inventory before removing unreferenced blobs.

**Tech Stack:** Swift, Foundation, Darwin flock/openat/fstatat/unlinkat, XCTest.

---

- [x] Review this design with parent before production edits.
- [x] Add failing core tests for saved-reference collection, active-session exclusion and malformed inventory; run the targeted cold-build/check command and record missing API failure.
- [x] Implement `Sources/WallpaperEditorCore/EditorResourceSession.swift` and descriptor helpers in `EditorProjectFiles.swift`; expose explicit session lifetime and consistent lock acquisition. Add regular lock-file and pinned-root validation.
- [x] Implement `EditorResourceCollection.swift`, validating all deletion candidates before changes and returning visible per-project reports. Add real subprocess lock/crash, root/symlink and inventory tests.
- [x] Require matching sessions in `EditorResourceStore.stageResource`; protect read/open/save and async materialization with operation-local leases. Update resource transaction/preview tests to retain explicit staging sessions. Add capture-versus-collection regression coverage.
- [x] Integrate session acquisition/retirement into `EditorApplication.swift`, `EditorWindowController.swift` and `EditorResourceBridge.swift`. Await true browser close and native resource task completion before lease release. Add lifecycle assertions to `Editor/Tests/EditorAppTests` without launching GUI/CEF until parent coordination.
- [x] Document automatic collection scope, reports, session caller responsibilities and crash recovery in `docs/testing/standalone-editor.md`.
- [x] Build the core-only and EditorApp XCTest targets with `scripts/swift_sdk.py build --disable-sandbox --target ...`; run their compiled bundles through `xcrun xctest` supervised by `scripts/test.py`'s unchanged 60-second `run_tests` budget. GUI fixtures run only in parent-coordinated windows. Inspect `git diff --check` and final diff; preserve reproducible commands and evidence under ignored `.build/verification/editor-resource-gc/` and report remaining native acceptance to parent.

## Recorded verification

- Initial core target build failed on the intentionally missing resource-session/collection API before production implementation.
- Final core target build passed; compiled XCTest bundle: 52 tests, 0 failures, 32.197 seconds under the unchanged 60-second supervisor.
- Final EditorApp target build passed; parent-coordinated AppKit fixture selection: 22 tests, 0 failures, 3.505 seconds under the unchanged 60-second supervisor. No CEF was launched.
- Independent read-only review found no P1 issues. The additional nil-error/`closed == false` callback case was added and passed.
- The complete standalone Editor Swift suite also passed: 93 tests, 0 failures, 9.672 seconds after a separate cold build. This run includes the native AppKit fixtures; it does not claim CEF acceptance.
- The staged-source publication scan checked all 19 changed files and reported clean. `git diff --check` passed. Full commands, logs, complete patch and file manifest are preserved in ignored `.build/verification/editor-resource-gc/`.
