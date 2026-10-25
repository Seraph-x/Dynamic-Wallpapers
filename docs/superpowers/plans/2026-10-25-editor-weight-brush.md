# Skin weight brush implementation plan

> **For agentic workers:** Use `executing-plans` inline, with independent plan/code review. This is a further subdivision of approved skeleton-authoring roadmap PR 3, after merged PR #17.

**Goal:** Paint actual mesh vertex influences through the existing Model bind-space map, with atomic resource history, cancellation, saved reopen and native export playback.

**Architecture:** A pure brush stroke operates on inspected mesh positions/weights and projected map points. It tracks minimum distance to the stroke's polyline, computes normalized influence edits from the original stroke weights and publishes one MDL revision through `commitModelResource` on release. A dedicated pointer controller owns transient input; Model remains the owner of selection, draft barriers, source identity and committed bytes.

**Tech stack:** Existing ES modules, native labeled form controls, Pointer Events/capture, Canvas 2D, pinned lossless MDL writer, real browser/AppKit/CEF acceptance. No new native bridge command, persistence schema or playback runtime.

## Contract and interaction

- The bind-space map defaults to **Select vertex**. **Paint weights** explicitly switches to brush input; painting affects the selected bone and selected mesh only. Numeric editing and map keyboard selection remain usable in Select mode. The current map still represents XY bind-space projection, not depth-based 3D picking; overlapping projected vertices are painted together.
- Labeled brush controls expose radius in map pixels (the existing 320 × 180 logical canvas), target weight [0,1] and strength [0,1]. Defaults are radius 24, target 1, strength 0.5. Radius must be positive finite and representable in distance calculations; no hidden coarsening or vertex cap. These controls and mode are preview settings, not saved content.
- Coverage is `max(0,1-distance/radius)` using minimum distance to each traversed line segment, including the initial point. Per-vertex coverage is the maximum across one stroke. The output selected weight is `original + strength * coverage * (target-original)`. Segment interpolation prevents gaps; sampling the same path at a different pointer frequency must not change the result. Separate strokes can build up weight.
- Normalize the original nonnegative finite influences without overflow, merge duplicate positive joints, and preserve the proportions of all other surviving influences. When painting the selected bone from zero, add its influence. Omit exact zero influences; reject a needed fifth positive influence instead of silently discarding an existing joint. A sole selected influence cannot be reduced without a surviving weighted joint: show a specific error, leaving the stroke unpublished. The ordinary numeric editor can explicitly assign replacement influences first. Unsupported mesh/capacity remains an explicit error.
- During pointer drag, show a transient weight-map preview and brush cursor; the main scene changes when the completed stroke is committed. One pointer release publishes one resource revision and one undo step. A stroke with no effective changes does not stage bytes or dirty history. Original MDL bytes and unpainted mesh/vertex data remain intact.
- Escape, pointercancel, unexpected lost capture and controller destruction discard the transient stroke. Pointer capture keeps a drag coherent outside the map. Only a primary pointer/left button starts painting. Multi-pointer input cannot replace the active stroke. A pending asynchronous start must observe cancellation/up before it starts; never commit a late stroke after cancellation.
- Before a stroke starts, prepare valid numeric/hierarchy drafts through the existing serial Model queue. Pin document/model version, mesh, bone, settings and map projection for the stroke. Disable selection/content controls while the stroke is active or being committed. Stroke termination remains usable. Source changes or stage failures publish nothing and visibly report the error; failed staging can be retried with a new stroke after explicit Revert recovery.
- Native snapshot/freeze/save, history, selection, Timeline edits and other content operations must not bypass an active/pending stroke. They expose an explicit finish/cancel error; they do not silently commit an unfinished stroke. Cancel remains reachable after a failed freeze once native thaw restores editing. Resource replies continue bypassing content/render queues.
- Preserve all five UI languages and both themes, 850 × 540 layout, existing map selection and model/image authoring flows. Existing skeleton rest editing, glTF import, skeletal clips and Script IDE remain subsequent roadmap work.

## Task 1 — Pure deterministic brush math

Files: create `Editor/Web/model-brush.mjs` and `.test.mjs`; export through `model-api-entry.mjs`.

- [x] Write failing tests for point/segment falloff, exact target/strength blending, other-weight ratios, zero/new/duplicate joints, fifth influence rejection, sole-weight reduction, no-op strokes, malformed input and source immutability.
- [x] Verify a stroke split into collinear segments equals the same unsplit path, and repeated samples do not accumulate beyond the stroke coverage. Test numeric representability and invalid vertices/settings.
- [x] Implement a stroke object with immutable base mesh, per-vertex minimum distances and preview/edits access. Use the existing `setSkinInfluences` writer for final bytes; no binary encoder changes. Run focused tests.

## Task 2 — Controls and pointer lifecycle

Files: create `model-brush-view.mjs`, `model-brush-controller.mjs`; modify `model-workspace.mjs`, `model-view.mjs`, `model-messages.mjs`, `model.css`, `model-overlay.mjs`, `build.mjs`; reproduce resources/provenance.

- [x] Add a failing real-browser brush scenario before implementing the UI. Use the existing real image grid plus an independent stationary bone and known test-only MDLA root motion.
- [x] Add Select/Paint mode, labeled radius/target/strength and cursor/status in five languages; preserve existing numeric controls and keyboard selection. Refactor map-point projection into a reusable pure helper without changing map coordinates.
- [x] Implement pending/active/committing pointer ownership, capture, cancel/Escape, minimum-distance updates and transient map drawing. Protect asynchronous starts and pointer termination before/after preparation. Add controller tests with controlled pending promises and actual event/state semantics; no fake success paths.
- [x] Integrate Model preparation/source ownership/one-step commit/no-op detection and draft barriers. Error recovery is visible and explicit; cancel never clears an unrelated invalid draft. Validate pointercancel/lost capture, frozen commands, selected layer/bone changes and stage failure.

## Task 3 — End-to-end authoring and playback

Files: extend `test-image-puppet.mjs` (or a focused helper), `test-image-puppet-layout.mjs`, `Tests/EditorRuntimeHarness/ImagePuppetAcceptance.h`; retain `scripts/test-editor-native.py` phase budgets.

- [x] Paint a known corner from root to the stationary bone with the actual pointer UI. Verify the expected intermediate deformation in actual pixels and one-step undo/redo. Verify Escape/pointercancel and no-op leave the document identical.
- [x] Cover pending start/release/cancel, active-stroke snapshot/Timeline barriers, stage failure/recovery, unsupported influence edits and selection mode behavior. Check five languages/themes and minimum-window controls without dirtying content.
- [x] Save/reload the actual painted resource, export loose/PKG and verify changing root-driven vertices plus the known stationary painted corner in Main's actual CEF frames. Distinguish this authored brush result from the documented test-only animation fixture; no clip-authoring UI claim.
- [x] Exercise brush mode/pointer preparation through native Editor where feasible and retain actual keyboard/freeze/resource/history/lifetime checks. All pages close normally, exactly one runtime shutdown.

## Task 4 — Verification and English PR

Files: `README.md`, `Editor/README.md`, `docs/editor-model-workspace.md`, `docs/testing/standalone-editor.md`, plan record.

- [x] Run all focused JS tests and reproducible offline build, complete protocol/browser/image-browser/native acceptance, relevant product/source checks. Run existing standalone Editor bridge checks if native integration changes. No full application-suite claim without its evidence.
- [x] Obtain independent code review, resolve important findings with regression tests; inspect final diff and run the sanitized-public-export gate on changed owned files.
- [x] Document usage, exact stroke/normalization/cancellation semantics, XY projection and unsupported cases; preserve upstream source/license references. Commit with the configured real email and open an English PR against merged main. Do not merge this new PR automatically.

## Verification record

- 88 focused JavaScript checks pass; all 28 offline resources reproduce.
- Complete protocol, browser, image/brush browser, native and native-brush
  acceptance passes within the original phase budgets. Both native phases close
  normally and observe exactly one runtime shutdown. Actual CEF pointer input,
  staged hashes/history and fixed painted-corner export pixels are asserted.
  A second native-brush execution with a fresh context also passed.
- The independent Editor build and real native resource-bridge test pass;
  product checks pass 3 Editor, 42 configuration and 16 source-export tests.
- Independent final integration review found no remaining important issues.
  The changed-owned-source privacy scan is clean; no broad application-suite
  or system-keychain integration pass is claimed.
- Earlier native shutdown attempts failed at the 60-second budget. Matching-UUID
  symbolication identified `KeychainPassword::GetPassword` /
  `SecItemCopyMatching` pending macOS authorization while the main thread waited
  in `TaskTracker::CompleteShutdown`. Unrelated temporary argv/message-pump
  experiments did not resolve it and were not applied to production source.
- The user explicitly approved Chromium's test-only `--use-mock-keychain`.
  `EDITOR_NATIVE_TEST_KEYCHAIN=isolated` enables it only in the native harness;
  unset/system retains the default system keychain. Real rendering and shutdown
  checks remain intact. The built production Editor omits the test marker.
- A separate sandboxed run could not launch the real browser, and the product
  configuration check hit SwiftPM's nested sandbox restriction. Both remain
  failed attempts; the explicit outside-sandbox executions above passed.

English pull request: [#18](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/18).
Feature commit: `34a5261`. The preceding image-to-mesh PR #17 is merged;
this brush PR remains open for review. Commits use the configured real email.
