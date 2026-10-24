# Standalone Scene Editor Implementation Plan

> **For agentic workers:** Execute inline task by task with executing-plans;
> test-driven-development for behavior and verification-before-completion before
> commits/PRs. Independent design/code reviews are required by selected skills.

**Goal:** Deliver a separately installed Editor.app with a two-way file interface.
**Architecture:** Main supplies one optional menu action and typed handoff. Editor
is an independent project/process using shared scene/IO/rendering source modules.
**Tech Stack:** Swift/AppKit/Foundation/CryptoKit, native CEF, pinned WebWallGL
editor API 3.0.0, ES modules/esbuild, XCTest/node:test and native acceptance.

## PR 1: Shared contracts and authoring projects

Files: `Sources/WallpaperCore/EditorExchange.swift`, new
`Sources/WallpaperEditorCore/{EditorProjectDocument,EditorProjectStore,
ScenePackageReader}.swift`, corresponding core/editor tests; Package.swift
library products/target. No Editor UI or Main menu behavior in this PR.

- [x] Baseline: existing 11 scene/spectrum node tests and clean diff.
- [x] Write failing URL/interface tests: v1 Main/Editor actions, Unicode/space
  file URLs, round trip, unknown versions/actions/fields, duplicate query fields,
  remote hosts and invalid scene entry paths. Verify red, implement strict types.
- [x] Write failing descriptor tests for scene offers and optional read-only
  renderer reference (exact version/hash), malformed present values and paths.
  Implement schema-1 serializable data. No implicit filesystem writes.
- [x] Expose existing WallpaperCore/WebWallpaperBridge as local library products;
  add authoring-core library used only by Editor, not Main's app target.
- [x] Project tests first: new canvas/title, loose copy, unknown metadata/resource
  preservation, original untouched, atomic save/reopen and revision conflicts.
  Implement one workspace document plus stable owned resource root; reuse the
  existing ManagedMediaStore copy boundary rather than a second unsafe copier.
- [x] PKG tests first: authored PKGV0012 round trip, invalid/truncated metadata,
  overflow/offset overlap/out-of-range, duplicate/traversal paths, missing entry.
  Implement checked package reads/extraction, with explicit unsupported errors.
- [x] Test saved-project persistence independent of either app's installation.
- [x] Run focused Swift/core tests and review. Commit and open English PR 1.

## PR 2: Independent Editor application

Files: `Editor/{Package.swift,product.json,README.md}`, native sources under
`Editor/Sources/EditorApp/`, browser sources/build/locks under `Editor/Web/`;
new native editor page/protocol/client in Sources/WebWallpaperBridge.

- [x] Define own app id/version (0.1.0), project-data root/cache, five-language
  resources and a process lease per store. Test duplicate instance activation and
  one live window per project; externally changed saves fail instead of overwrite.
- [x] Native CEF protocol tests first: descriptor mounts, origin/method/session/
  generation, fixed JSON requests/replies, stale/cancelled requests and errors.
  Implement EditorPage with actual SetAsChild view; preserve offscreen playback.
- [x] Add a native CEF harness for real ready frame, keyboard/form interaction,
  resize, blocked resource access and complete close. Include new files in build
  source lists and do not report load-end as renderer readiness.
- [x] Browser TDD: JSON document edits, image/text layers, rename/visible/reorder,
  transform/duplicate/delete, undo/redo and unknown field/resource preservation.
  Implement inspector/tree/canvas UI using published editor controls and real
  rendering, with explicit zero audio/media and offline assets.
- [x] Pin @webwallgl/editor/webwallgl 3.0.0 and bundler integrity/provenance. Record
  all notices; no Node server/CDN/runtime dependency on a running Main app.
- [x] Native file actions use safe project store; cancel save preserves dirty state.
  Rebuild/seek preview for structural edits; preserve controlled-field bindings.
- [x] Export loose/PKG via upstream builder/compatibility reader; test both by
  re-importing and rendering through existing scene playback.
- [x] Verify Editor own shutdown/close failure and unsaved Save/Discard/Cancel.
  It remains alive when Main quits. Run independent review and open English PR 2.

## PR 3: Main handoff and independent packaging

Files: `Sources/WallpaperApp/Editor/{EditorLauncher,EditorExchangePublisher}.swift`,
MenuContent/AppDelegate and five-language resources; Editor handoff handlers;
`scripts/build-editor-app.py`, editor-native test runner, docs/help/credits.

- [x] Add tests proving Main startup/playback/quit never installs, downloads,
  looks up/hashes Editor or waits on Editor. Only its explicit Editor action does.
- [x] Add exactly one menu-bar Editor action. Discover/focus targeted independent
  app; if absent, give on-demand Download Editor/Cancel confirmation.
  Errors stay within this action and never enter wallpaper playback failure.
- [x] Main publishes a v1 read-only scene/resource descriptor only for handoff.
  Editor imports an owned copy and may reuse only an exact pinned shared render
  module; always keep its identical bundled module for independent operation.
- [x] Editor Open in Main materializes a standard project and invokes targeted
  v1 import. Main uses its existing managed scene probe/import, selects the item,
  and does not change active wallpaper until user applies it.
- [x] Own Editor build/package derives product/helper ids and its independent CEF
  cache correctly. Reuse CEF build/source inputs; package a complete standalone
  closure. Main default build contains no Editor app, UI or editor engine.
- [x] Native E2E: actual app build; open new/image/text/edit/undo/redo/save/reopen;
  export loose+PKG and render both in Main. Test two apps simultaneously and
  Main quit/relaunch while unsaved Editor persists; repeated launch focuses it.
- [x] Remove Editor.app and confirm Main's existing playback still works and
  saved projects survive. Missing/invalid app and failed download are action-only.
- [x] Run targeted tests after building (60 s), core/scene/audio/product/package/
  localization/help regressions; inspect pins/notices, source export and signatures.
- [ ] Create English PR 3 with dependencies/evidence. Independently downloadable
  Editor artifact is separate from Main releases; publish only when requested.
