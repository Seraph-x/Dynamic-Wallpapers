# macOS Scene Wallpaper Implementation Plan

> For agentic workers: execute with `executing-plans`; use focused independent
> workers only where the file ownership below permits it. Follow TDD and retain
> observable failures; do not introduce simulated rendering or silent fallback.

**Goal:** Deliver four dependent PRs that add real local scene wallpaper playback
on macOS through pinned WebWallGL and the existing CEF runtime.

**Architecture:** Typed scene metadata and managed copies feed a trusted scene
shell. CEF serves bundled runtime assets and assigned project files through
separate fixed mounts; typed lifecycle events gate real first-frame readiness.
A scene-specific surface integrates with the existing playback controller.

**Tech stack:** Swift 6 toolchain (repository Swift 5 language mode), AppKit,
Objective-C++/CEF 152, WebGL2, WebWallGL 3.0.0, Python packaging, XCTest/Node tests.

## State / ownership

- Base: main `33f1fba413734875303b0f8d56ef6bcfc43ea39b`.
- Worktree: `.worktrees/scene-wallpapers`, branch `feat/scene-wallpaper-support`.
- Native dependency cache is prepared in the primary checkout and reused by
  reference. All test profiles, libraries, rendering fixtures and evidence use
  task-specific temporary paths. No installed/user-running app is a test target.
- Progress: design approved by user scope selection and independent spec review;
  implementation not started when this plan was written.

## Task 1 — Scene project contracts and schema (PR 1)

Files: new `Sources/WallpaperCore/SceneProjectReference.swift`; modify
`Models.swift`, `WebProjectReference.swift` (backend enum), `LibraryStore.swift`,
`LibraryMigration.swift`, `ManagedMediaStore.swift`; new/updated core tests.

- [ ] Add failing tests for scene syntax, old-schema rejection, round-trip and
  legacy version-3 load/save without an eager rewrite.
- [ ] Add `.scene` kind/backend and optional `MediaItem.sceneProject`.
  `SceneProjectReference` stores a local root, safe relative entry, and explicit
  package/loose form. Reference validation rejects empty/traversal/NUL/remote
  paths and mismatched extensions. Only scene schema 4 accepts this metadata.
- [ ] Support owned scene copies under `<Media>/<id>/Project`; staged/final
  references, origin identity, rollback and removal share existing descriptor
  safeguards. Do not copy a project containing the managed Media directory.
- [ ] Cover stage/commit/discard/remove and symlink failure in real temp trees.
- [ ] Run core tests, compile affected Swift modules, inspect diff and commit.

## Task 2 — Host scene project inspection (PR 1)

Files: new `Sources/WallpaperApp/Media/SceneProjectProbe.swift`; modify
`ManagedMediaImport.swift`, `AppModel.swift` (an internal scene import entry),
`SystemWallpaperSourceVersionReader.swift`; host/core tests.

- [ ] Write failing tests for this entry decision table:
  declared existing safe JSON -> loose; declared existing safe PKG -> package;
  declared missing conventional scene JSON + exactly one conventional existing
  scene.pkg -> package; missing/ambiguous files or non-scene type -> explicit
  error. A declared unsafe path is always an error, never a search fallback.
- [ ] Inspect only through descriptor-bound project access. Validate metadata
  and source representation before staging/committing; use a documented preview
  viewport where no authoritative design size exists.
- [ ] Preserve imported project provenance/name and source-version fingerprint
  across all project files. Reject scene snapshot publication explicitly.
- [ ] Run user-reachable import service tests against real files and save failure.
- [ ] Publish PR 1 only after tests pass; describe it as foundation, not complete
  end-user rendering. Leave no UI entry point that advertises absent playback.

## Task 3 — Pin engine assets and trusted browser shell (PR 2)

Files: `Resources/ThirdParty/WebWallGL/` provenance/license; new scene shell assets
under app resources; packaging/build/verification scripts; JS tests.

- [ ] Verify tarball integrity for webwallgl 3.0.0:
  SHA256 `f242409bf74db2eafeaa8fac2244328c82ee9e87e4fd346939975b1e3097a865`;
  npm integrity `sha512-If5DUW3hHeWOyyhvswHkycWm0U5mWJUpKb4ws/J+jrwK3gUbmpoyyACfezKClrcpMB8u2UNyl/ni3M0Z2gjjww==`.
- [ ] Package only the engine distribution required by the shell plus all legal
  notices; retain exact provenance and hashes. No CDN, npm runtime install,
  donation artwork, example projects or unlicensed wallpaper assets in the app.
- [ ] Write JS contract tests before implementing shell loading, lifecycle,
  abort/stale-generation handling, real engine ready/error callbacks and zero
  audio-spectrum injection. Tests use the real pinned engine where feasible;
  a rendering smoke test must actually render rather than only count callbacks.
- [ ] Implement a Source over the scene project virtual mount. Support package
  and loose assets and abort semantics. Source/network failures remain visible.
- [ ] Expose a narrow fixed command interface for lifecycle, fit, gain, FPS and
  pointer input. Report typed ready/error events; never interpolate source data
  into executable JavaScript. No automatic picture/video substitution.

## Task 4 — CEF scene mounts and event boundary (PR 2)

Files: WebWallpaperBridge public/internal interfaces, `WebPage.mm`,
`WebClient.cpp`, `LocalWebRequestContext.*`, local resource tests/native harness.

- [ ] Add failing native route tests for isolated runtime/project mount prefixes,
  traversal, cross-origin requests, stale events and invalid event payloads.
- [ ] Introduce scene page configuration without changing ordinary web-page
  request behavior. Trusted shell/config and assigned project resources have
  separate bound roots, served on the existing per-page HTTPS origin.
- [ ] Use a narrow same-origin local event endpoint for scene ready/error state;
  validate request method, payload and page ownership. Combine engine-ready and
  actual committed CEF pixels before publishing readiness.
- [ ] Execute only fixed shell commands with JSON-serialized arguments; gate
  output gain natively. Close must join actual CEF/audio/resource release.
- [ ] Compile native CEF target against prepared pinned dependencies and exercise
  a self-authored real animated scene in an isolated native harness.
- [ ] Publish PR 2 targeting PR 1's branch, with actual evidence/limits.

## Task 5 — Scene surface and playback control (PR 3)

Files: new `SceneSurface.swift`/scene page session; SurfaceFactory,
CEFApplicationRuntime, WebPageSession-related interfaces only where necessary;
playback and lifecycle tests.

- [ ] Add failing tests for silent prepare, actual readiness, play/pause/resume,
  clock preservation, stale callbacks, change/delete/shutdown and failed close.
- [ ] Implement PlaybackSurface ownership using real engine pause/resume rather
  than reloading a scene on each pause. Keep native audio silent until commit.
- [ ] Route `.scene` through its surface; retain native/extended/web routes.
- [ ] Map fit/FPS/mute/entry gain/crossfade. Respect grouped resume barriers and
  the existing interaction opt-in; transform pointer movement/leave/click using
  display viewport geometry and page identity. No system audio capture.
- [ ] Run existing playback regression suites plus new scene state tests; then
  native real-scene pause/resume/pointer and close-resource checks.
- [ ] Publish PR 3 targeting PR 2's branch.

## Task 6 — Import UI, localization and packaged acceptance (PR 4)

Files: WallpaperImportView, metadata/support labels, localized strings/offline
help, fixture/harness tests and bundle verification.

- [ ] Add user-path tests for choosing a scene project, importing its owned copy,
  applying it, pausing/resuming and switching away; test invalid projects and
  unsupported screen-saver publication visibly fail.
- [ ] Add a scene project choice and metadata presentation in all five locales;
  scenes use fixed timing and existing audio/interaction controls. No property
  editor or editor UI is added. Author property defaults remain engine-owned.
- [ ] Add self-authored loose and PKG scene fixtures with animated pixels and a
  pointer-visible response. Keep third-party wallpapers out of the repository.
- [ ] Build an isolated app through repository scripts; run packaged default-path
  acceptance, resource containment, screenshots/frame differences, pause/resume,
  cancellation and closure. Record actual WebGL renderer and test geometry.
- [ ] Run relevant existing suites and packaging/license/dependency checks.
  Report every failure/timeout and platform limitation honestly.
- [ ] Publish PR 4 targeting PR 3's branch. Cross-link all four PRs in order,
  verify clean trees and real author email. Do not merge without user request.

## Final review

- [ ] Review each PR's final diff against its own base and rerun its authoritative
  checks after fixes. Request independent code review for resource/native and
  lifecycle boundaries; resolve material findings before publication.
- [ ] Keep a concise progress record here as tasks complete. Do not claim Scene
  support shipped from an infrastructure-only PR or untested mock path.
