# Independent scene preview implementation plan

> **For agentic workers:** Use executing-plans task-by-task; checkbox steps track completion.

**Goal:** Deliver a usable File → Preview snapshot window that runs an owned current document/resource revision through the real scene runtime without an Editor authoring session.

**Architecture:** A native export API materializes a draft snapshot without saving the workspace. A native preview session owns a separate DWWebPage, unique origin, immutable private project copy and acknowledged pause/resume/restart/close. AppKit provides the window and localized controls. Reuse Main's unchanged pinned scene shell as separately copied Editor resources. This supplies the future IDE execution host; no source Apply UI is connected and existing workbench execution is not changed in this PR.

**Tech stack:** Swift/AppKit, WallpaperEditorCore descriptor-bound exports, existing CEF scene pages/protocol, pinned WebWallGL 3.0.0.

## Approved scope and boundary

The user approved the advanced-editor roadmap and independently tested infrastructure subdivisions. This PR implements a concrete preview action as the next execution-host step. Preview is explicit, muted and uses zero system spectrum, matching existing Editor preview audio behavior. It does not save or apply wallpaper. Restart closes the old page before creating a fresh origin/clock. An open preview keeps its captured revision; later edits require opening another snapshot. Closing Editor closes its previews before runtime shutdown and removes only each owned preview directory after page release.

The preview page has no Editor session, configuration/resource-stage endpoints or opener reference. Native scene commands expose playback only. This is origin/page and channel separation using the existing CEF host, not a promise of separate OS processes or protection from Chromium vulnerabilities. The current workbench can still execute imported scripts; the future IDE must disable that path before connecting source Apply. Script source/history and normal Main playback remain unchanged.

## Task 1 — immutable draft export (TDD)

Files: `Sources/WallpaperEditorCore/EditorProjectStore.swift`, a focused preview extension if cohesive, and `Tests/WallpaperEditorCoreTests/EditorPreviewExportTests.swift`.

- [x] Observe missing `exportPreview(_:basedOn:to:)` failure in real store tests.
- [x] Export a validated draft matching the baseline workspace identity/revision/entry/source package. Require the actual saved baseline still matches disk; validate all draft resource references, retaining strict collision/symlink/hash checks.
- [x] Revalidate baseline and draft resource versions after the media-stage await and before publication; explicitly test actor-reentrant baseline changes rather than relying on the first check alone.
- [x] Factor only the common existing loose-export body; persistent export behavior stays unchanged. Preserve unknown scene/project data, canonical project entry/title, loose extraction of source PKG and owned staged resource versions. Never mutate workspace.json or original resources and never overwrite an existing destination.
- [x] Test unsaved scene/title/resources, disk bytes/revision unchanged, independent copy after later edits, stale/mismatched baselines, missing/corrupt/cross-project resources, invalid destinations and destination collisions. Run targeted core tests with a 60-second budget after build.

## Task 2 — preview lifecycle and AppKit action (TDD)

Files: new `Editor/Sources/EditorApp/EditorScenePreviewSession.swift`, `EditorScenePreviewWindowController.swift`; modify `EditorWindowController.swift`, `EditorApplication.swift` and five `Localizable.strings`; add `EditorScenePreviewTests.swift`.

- [x] Write missing-session tests first. Inject only the replaceable native page factory and cleanup action; test doubles are explicit external-page fixtures, never production fallback renderers.
- [x] Session states: idle/loading/playing/paused/failed/closing/closed. Real adapter wraps DWWebPage, mutes output before start, reports actual readiness/errors and acknowledges playback commands. Only one lifecycle operation runs at a time; competing operations fail visibly. Stale ready/error callbacks from old pages cannot mutate a newer generation.
- [x] Restart awaits actual old-page release before new page creation. Close retains page/root ownership on failure; cleanup runs only after page release and can be retried after a cleanup error. Do not silently swallow close/restart/cleanup errors or claim shutdown success.
- [x] The session owns its root before page acquisition. Factory failure leaves a failed session that can close/clean or retry; start failure retains any acquired page until real close. A controller initialization failure before ownership transfer explicitly cleans its captured export. Test factory/start/restart failures and never lose page/root ownership.
- [x] AppKit window has localized status, pause/resume and restart buttons; standard close. It stays independently resizable, displays failures and never changes project history. Opening preview freezes/flushes the current browser snapshot, validates it, exports a private copy, then thaws on success/failure. No automatic save.
- [x] File → Preview snapshot is available only for a ready, non-busy project. Each project owns its preview controllers; project close/quit awaits their release before closing the workbench/runtime. Native close cancellation preserves ownership.
- [x] Test state transitions, ready-before/after close, stale callbacks, acknowledged pause/resume, restart ordering, failures and cleanup retries, busy rejection and exact snapshot parsing/unknown data.

## Task 3 — reproducible resources and actual native boundary

Files: `Editor/Web/build.mjs`, copied `Editor/Sources/EditorApp/Resources/ScenePreviewWeb/*`, `Editor/Package.swift`, `Editor/ThirdParty/provenance.json`, distribution checks; `Tests/EditorRuntimeHarness/PreviewAcceptance.h`, main/runner.

- [x] Independently copy all eight Main SceneRuntime files into ScenePreviewWeb; verify each against existing main source and exact hashes in a new provenance map. Package this separate resource directory; offline check fails on differences. No engine/main source changes or new dependencies.
- [x] Add a focused native-preview phase with 60-second budget, leaving existing phases intact. Use the actual new preview runtime directory with an owned fixture, alongside a real blank Editor page.
- [x] In actual CEF, probe missing opener/authoring globals; same-origin Editor config/event/resource writes and cross-origin workbench writes must be denied without changed snapshot or staged files. Probe names are test-only; no production unsafe bridge is added.
- [x] Verify actual script pixels/time, acknowledged pause/resume and a new-origin restart returning the initial state, exact read-only project bytes, separate Editor-page survival, close to zero pages and one runtime shutdown. Keep isolated keychain only in the already approved native test host.

## Task 4 — review, docs and English PR

- [x] Update both READMEs and preview/source/native-validation docs. State snapshot ownership, no automatic saving, mute/zero spectrum, explicit restart semantics, source attribution and remaining full-IDE/workbench-isolation scope.
- [x] Run independent plan/code review, focused TDD checks, independent Editor build/tests, all Node/offline/product/config/export checks and the full fresh-directory native runner. Do not represent focused checks as a full Main application test-suite pass.
- [x] Apply the sanitization skill to a changed-file copy; preserve upstream licenses and explicitly requested real author email. Inspect final diff and commit.
- [x] Submit an English PR and leave it open; record actual verification and link. PR #28 was merged before this work.

Plan review approved with the two explicit ownership/revalidation additions above.

## Verification record

- PR #28 merged at `698688b4edc7a004f1f72b48bc6d21794d84993a` using the requested real author identity; this work starts there.
- Baseline: 350 Node tests and 61 workbench resources passed.
- Core missing-API red observed; 41 actual core tests passed (9 new preview export tests). Removing the post-await checks produced both intended negative-control failures; restored code passed the full focused suite.
- Session missing-type red and missing-native-diagnostic API red observed. Packaging test initially failed because ScenePreviewWeb was absent.
- Independent Editor build and 15 tests passed, including 13 session/snapshot/packaged-resource checks and existing resource/workspace bridge tests.
- Reproducible offline build/check: 61 workbench plus 8 preview resources, each preview resource byte-identical to Main.
- Node checks: 350 passed; Editor product 3, configuration 42 and public-source export 16 passed.
- Independent production/native-code review found no actual blocking defects.
- Complete native runner passed all prior 26 phases, then the new native-preview query exposed a test-only DevTools submission assumption: calls outside CEF UI enqueue work and immediately return zero. The test now registers/submits inside TID_UI and matches the actual returned message ID, without retries or fabricated results.
- Independent actual native-preview phase passed: executed script-origin probes, all seven authoring/write requests denied, zero resource staging, unchanged surviving Editor, half-second pixels/clock pause/resume, new-origin restart, script warning delivery and complete release.
- A repeated full run exercised CSP as the first native rejection instead of the route denial. The test now requires the exact requested target URL plus an explicit route/CSP refusal category, preserving all seven requests and zero-write assertions. No production rejection or retry behavior changed.
- Three additional actual native-preview runs in separate new caches all passed. Native AppKit layout now also passed at minimum size in all five languages and both appearances, using actual localized bundles without starting CEF; total Editor tests 15.
- Final fresh-directory native runner passed all 27 phases, including native-preview; runtime shutdown/release checks passed.
- Final independent Editor build and 15 tests passed; 13 preview tests include real AppKit layout and actual bundled runtime bytes.
- Final changed-file gate: 39 files clean, zero unexpected findings. The existing packaging scanner regex is classified as a detector fixture; author commits retain the explicitly requested real email.
- Final independent review found no unresolved issues in source, native probes, packaging, localization or layout checks.
- The exact copied engine retains upstream shader-string whitespace. Its generated-file whitespace attribute follows the existing Main bundle convention; the remaining authored diff and offline byte checks pass.
- English PR submitted and left open: https://github.com/Seraph-x/Dynamic-Wallpapers/pull/29.
