# Editor Resource Transactions Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task.

**Goal:** Commit JSON and immutable resource references as one undoable revision,
and resolve that revision consistently for preview, save/reopen and exports.

**Architecture:** Keep original Project files intact; store SHA-256 blobs under
the owning workspace's Resources directory. Schema-2 workspace documents and
browser snapshots carry logical-path-to-blob-ID overrides. Native resource RPC
validates ownership and content; each preview/export resolver captures its map.

**Tech Stack:** Swift/Foundation/CryptoKit, JavaScript modules, existing CEF
typed event/command bridge and pinned WebWallGL APIs.

## Task 1: Immutable native resources and revision schema

Files: add `Sources/WallpaperEditorCore/EditorResourceVersion.swift` and
`EditorResourceStore.swift`; modify `EditorProjectDocument.swift`,
`EditorProjectStore.swift`, `EditorProjectResources.swift`; add
`Tests/WallpaperEditorCoreTests/EditorResourceTransactionTests.swift`.

- [ ] Write failing tests for schema-2 decoding, strict IDs/reserved paths,
  schema-1 preservation and schema-2 retention with an empty map.
- [ ] Run `python3 scripts/test.py --filter EditorResourceTransactionTests`
  with its default 60-second budget; expect missing API or assertion failures.
- [ ] Implement `EditorResourceVersion` (64 lowercase hex SHA-256 ID), document
  schema/overrides, `stageResource(id:data:)`, `resource(id:version:)`, and
  revision-bound resource reads/inventory. Deduplicate verified existing blobs;
  never overwrite a corrupt blob. Reuse descriptor-relative file access.
- [ ] Add/run failing tests for corruption, missing/cross-workspace resources,
  symlinks, stale saves and atomic write failure, then implement validation under
  the workspace lock and atomic manifest publication. Keep old call sites working
  by preserving previous overrides when no replacement map is supplied.
- [ ] Apply overrides in staged loose export, retain unknown files, exclude
  workspace/blob metadata, then assert exact exported bytes and new paths.
- [ ] Run all `WallpaperEditorCoreTests`; commit the native foundation.

## Task 2: Browser transactions and fixed native resource RPC

Files: add `Editor/Web/resources.mjs` and `resources.test.mjs`; modify
`document.mjs`, `runtime.mjs`, their tests; `SceneProtocol.hpp/.mm`, `WebPage.mm`,
`include/WebWallpaperBridge.h`; `EditorWindowController.swift` (extract resource
callback handling to `EditorResourceBridge.swift`); protocol harness tests.

- [ ] Write/run failing document tests for a one-step JSON+reference transaction,
  exact undo/redo, validation failure rollback and mutation isolation. Implement
  a transaction draft using the existing patch rules plus resource references.
- [ ] Define resource event `{type:'resource',id,action:'stage',data}` or
  `{type:'resource',id,action:'read',version}` plus existing session/generation;
  reject unknown keys, invalid IDs, malformed base64 and stale identities.
- [ ] Test protocol parsing red, then add the event and native callback. Swift
  resolves requests only against its controller's workspace. Return a typed
  `resource-reply` command with request ID and result/error; request failures
  remain explicit and do not mark the document saved or dirty.
- [ ] Browser RPC tracks pending IDs, reports real native failures and rejects
  pending requests on disposal. Resource replies bypass the render/native
  command queue's wait so a paused render cannot deadlock waiting for a read.
  Test in-flight reads during freeze, unsolicited replies and close.
- [ ] Thread resource maps through browserDocument, snapshot, save and native
  saved acknowledgement. Keep legacy no-override snapshots compatible.
- [ ] Bind preview and PKG reads to one snapshot map and union override paths
  into the original inventory. Test two maps for the same logical resource and
  newly added paths. Regenerate resources with `node Editor/Web/build.mjs`.
- [ ] Run JS/document/RPC/protocol and Swift checks; commit bridge integration.

## Task 3: Actual rendering/export acceptance and review

Files: extend `Tests/EditorRuntimeHarness/` browser/native tests as appropriate,
`docs/testing/standalone-editor.md`, `Editor/README.md`; update the offline build
resource list and packaging list if the new resources module is separately shipped.

- [ ] Use an authored color/image/material replacement and a new logical asset;
  stage, commit, undo, redo, save/reopen, export loose and PKG. Assert exact data
  and actual changed pixels in Main's existing runtime. No mock execution paths.
- [ ] Exercise native resource request failure/cancellation and ordinary legacy
  editor operations; assert normal CEF close and no retained command callbacks.
- [ ] Run `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs
  scripts/test-scene-spectrum.mjs`, native protocol tests, focused Swift tests,
  offline reproducibility check, and `scripts/test-editor-native.py` with the
  installed Chrome executable. GUI phases stay sequential. Run a fresh second
  native acceptance pass after fixes to establish repeatability.
- [ ] Request independent code review against main and this spec. Resolve
  substantive findings with regression tests and rerun affected acceptance.
- [ ] Inspect final diff, verify owned source privacy and source-export/product
  checks, then commit and create an English PR using the real configured author
  email. Do not claim the four later feature PRs are implemented, or merge/publish
  the new PR without authorization for that action.
