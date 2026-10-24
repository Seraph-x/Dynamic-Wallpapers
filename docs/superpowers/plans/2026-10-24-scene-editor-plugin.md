# Optional Scene Editor Plugin Implementation Plan

> **For agentic workers:** Use executing-plans inline, task by task; apply
> test-driven-development to behavior changes and verification-before-completion
> before commits/PRs. Independent document/code reviews are required by the
> selected review skills. Keep user communication in Chinese, commits/PRs English.

**Goal:** Independently install/remove a usable offline scene editor from this repo.

**Architecture:** Native host controls installation, projects, file dialogs and
CEF child-view lifetime. `Plugins/SceneEditor` supplies versioned JS/CSS/HTML and
pinned WebWallGL editor API, linked by a small typed protocol.

**Tech Stack:** Swift/Foundation/CryptoKit, pinned ZIPFoundation, Objective-C++/CEF,
ES modules/esbuild, XCTest/node:test and native CEF acceptance harness.

## Task 1: Plugin package foundation

Files: new `Sources/WallpaperPluginCore/{PluginManifest,PluginPackage,PluginStore}.swift`,
`Tests/WallpaperPluginCoreTests/PluginPackageTests.swift`; modify Package.swift,
Package.resolved and dependency inventory/export preparation where needed.

- [ ] Run baseline scene node tests and `git diff --check` in this worktree.
- [ ] Add failing tests for the schema-1 scene-editor manifest: exact id/version/
  API/entry, SHA-256+size inventory, invalid types, missing entry and unsafe paths.
- [ ] Verify red; implement strict SemanticVersion/relative-path/manifest types.
- [ ] Add failing ZIP tests using real archives: valid install, wrong hash/size,
  duplicate/Unicode-case paths, traversal, symlink, extra file, corrupt ZIP,
  incompatible API, failed replacement retaining prior bytes, remove affecting
  only the plugin payload. Verify red, implement, run the focused suite.
- [ ] Pin ZIPFoundation exactly and retain its source revision/license; use its
  streaming entry API with CRC checking. Do not shell out to unzip/Node/Python.
- [ ] Store installation in a new staging directory, verify, atomically activate;
  verify again on lookup/launch. All rollback/release failures remain visible.
- [ ] Commit the tested foundation as a reviewable stage.

## Task 2: Owned scene projects

Files: new `Sources/WallpaperPluginCore/{EditorProjectStore,ScenePackageReader,
EditorProjectDocument}.swift`, `Tests/WallpaperPluginCoreTests/EditorProjectTests.swift`;
modify ApplicationPaths and add isolated fixture metadata where needed.

- [ ] Write failing tests for new project, loose import copy, unknown JSON fields,
  original preservation, save/reopen and failed atomic replacement.
- [ ] Implement schema-1 project records and separate UUID-owned project roots;
  reuse WallpaperCore scene references/managed-file validation where applicable.
- [ ] Write failing PKG tests: real authored PKGV0012 round trip, invalid header,
  truncated strings/table, overflow/out-of-range offsets, duplicate/traversal
  names and missing scene entry. Implement bounded reads against actual file
  length and safe extraction to a new owned project. Unsupported containers fail.
- [ ] Add tests for removal/reinstall preserving projects and loose export to new
  destinations preserving every unmodified resource. Implement and commit.

## Task 3: Native editor CEF page and protocol

Files: new `Sources/WebWallpaperBridge/{EditorProtocol.hpp,EditorProtocol.mm,
EditorPage.mm,EditorClient.cpp,EditorRequestContext.cpp}` and public editor page
API; adapt WebRuntimeInternal/WebRuntime ownership for both page kinds without
changing wallpaper rendering. New Swift `Media/CEFEditorPageSession.swift`.

- [ ] Add protocol tests for trusted mounts, methods/origin/session/generation,
  request IDs, exact payloads and cancellation after retirement. Verify red.
- [ ] Implement descriptor-bound plugin/project mounts and typed ready/dirty/
  document/export/error events with one fixed JSON command entry point.
- [ ] Create the CEF browser with SetAsChild under a native NSView; keyboard,
  selection, focus and resize use the actual native browser view. Do not fake
  readiness with OnLoadEnd or an offscreen placeholder.
- [ ] Integrate callbacks/events, explicit requests, startup errors and real close
  barriers into CEFApplicationRuntime. Retain failed closes. Include editor pages
  in shared shutdown and existing optional spectrum ownership.
- [ ] Native harness: load a trusted tiny test page, interact via real controls,
  verify ready/commands/denials/resize/close and that existing scene tests pass.

## Task 4: Browser editor payload

Files: new `Plugins/SceneEditor/{package.json,package-lock.json,plugin.json,
src/index.html,src/editor.css,src/host.mjs,src/document.mjs,src/render.mjs,
src/editor.mjs,src/i18n.mjs,tests/document.test.mjs,tests/host.test.mjs}` plus
build script/provenance/notices. Use exact @webwallgl/editor and webwallgl 3.0.0.

- [ ] TDD pure document commands: selection, fields, rename, visible, reorder,
  duplicate/delete, image/text creation, undo/redo and unknown-field preservation.
- [ ] TDD protocol request ordering, cancellation, stale IDs, invalid responses
  and dirty/save-success semantics. Implement the fixed host adapter.
- [ ] Bundle a single offline editor engine; replace synthetic audio/media sources
  with explicit zero/host-provided data. No CDN, Node server or auto fallback.
- [ ] Implement layer tree, canvas selection/transforms, inspector, text editing,
  preview playback and undo/redo. Preserve scripted/animated bindings and identify
  read-only inspector fields. Native actions initiate file dialogs and save/export.
- [ ] Use upstream image model/material layout and buildScenePkg/checkWeCompat.
  Verify loose/PKG export resource closure and render-back of authored image/text.
- [ ] Match existing app language in all five catalogs; keyboard actions and
  errors must be accessible/visible. Run node tests and actual browser/CEF checks.

## Task 5: Application plugin manager and project windows

Files: new `Sources/WallpaperApp/Plugins/{SceneEditorPluginModel,
SceneEditorWindowController,PluginFileDialogs}.swift`, new
`UI/PluginSettingsSection.swift`; modify AppComposition/AppModel/SettingsView,
main commands/lifecycle and five-language resources/help.

- [ ] Add failing lifecycle tests for missing/incompatible plugin, install/open,
  replacement/removal after real close, unsaved Save/Discard/Cancel and failure
  retaining installed plugin, saved-project preservation and isolated paths.
- [ ] Implement observable manager/Advanced settings buttons (Download, Install
  ZIP, Open, Remove), native project chooser and editor window toolbar.
- [ ] Hook native user actions to safe project/store operations and request/response
  data. Mark dirty immediately, clear only after real successful save. Failed
  export/save remains actionable; the original source is never overwritten.
- [ ] Close every editor before app CEF shutdown. Cancellation may cancel ordinary
  editor close/removal; application quit must follow the app's existing confirmation
  policy and must not claim successful CEF release before completion.
- [ ] Update docs/acknowledgements and run relevant app/localization tests.

## Task 6: Independent package and end-to-end validation

Files: new `scripts/{build-scene-editor-plugin.py,test-scene-editor-plugin.py,
build-scene-editor-test.sh}`, native tests under `Tests/SceneEditorHarness/`,
`docs/testing/scene-editor-plugin.md`, `Plugins/SceneEditor/README.md`.

- [ ] Produce deterministic versioned ZIP and SHA256SUMS; inventory only actual
  runtime assets/notices. Record exact upstream integrity and bundling recipe.
- [ ] Verify a normal host package contains no editor JS/UI payload. Install the
  actual ZIP through the same host store into isolated validation paths.
- [ ] Native acceptance: create+image+text, edit, compare real pixels for edits and
  undo/redo, save/close/reopen, export loose+PKG and render both via the existing
  scene player. Verify original/unknown-resource preservation.
- [ ] Verify malicious ZIP rejection, cancelled unsaved close/removal, uninstall
  after actual CEF close and retained saved projects after reinstall.
- [ ] Build app/tests separately, then use 60 s budgets for focused Swift runs;
  run core/scene/audio/product/packaging/help regressions and independent review.
- [ ] Inspect final diff, validate pins/licenses/source-export inputs, create
  English feature PR(s) with actual evidence and real-email author. Do not merge
  or replace the published application release without the relevant instruction.
