# Native animation-layer mixing implementation plan

> **For agentic workers:** Use `executing-plans` inline with independent plan/code review and TDD. This is a usable subdivision of approved skeletal-animation roadmap PR 4, following merged PR #22.

**Goal:** Create, duplicate, reorder, remove and edit a model's native clip layers, with real sequential/additive mixing, complete history/save/export and actual Main playback.

**Architecture:** Edit the selected scene object's existing `animationlayers` array, retaining untouched fields and original representations. Add pure stack operations, a contextual Model controller/view and a document method. Reuse captured model/source ownership; when resource and layer drafts coexist, publish both in a single document transaction. Main's pinned engine and standard scene/MDL formats remain unchanged.

**Tech stack:** ES modules, existing document/resource transactions, semantic forms/dialogs, pinned WebWallGL 3.0.0 and real CEF/AppKit/Main acceptance.

## Confirmed behavior

- Extend approved roadmap without another interview. This PR completes native clip-layer stack authoring; sparse keys, event authoring, FK/IK and SceneScript IDE remain subsequent work.
- A collapsed **Clip layers** section lists native stack order and exposes name, clip ID, blend weight, rate, visible and additive. Selection does not edit content. Add appends a chosen available clip; Duplicate owns the selected constant row including unknown metadata; Up/Down changes sequential order. Remove requires a dialog, with Cancel/Escape unchanged. Removing the last row explicitly explains default first-clip playback. An empty/absent/null native table is default playback; do not serialize it merely by inspection.
- The pinned engine applies nonadditive rows sequentially: `acc = acc*(1-blend)+sample*blend`. Additive rows accumulate deltas from their clip reference pose (first sample; last sample for `single`), with native additive normalization above total weight 1. Their delta is applied only when total additive weight is positive; a first additive row before any nonadditive row initializes the base from its reference even at weight zero. Cover these cases in real pixels. Visible false disables that row; all explicit rows hidden produce bind pose, while no rows use the first clip. Explain these native semantics; do not replace them with normalized-average mixing.
- Blend/rate accept finite native numbers, including zero/negative rates and extrapolating weights; do not invent caps or silently clamp. New edits reject nonfinite input. Optional absent fields keep native defaults and remain absent when unchanged. Name is an optional string; duplicate names are permitted by the native format. Changing a row retains all unedited and unknown fields byte-equivalent as JSON.
- Imported object/script/animation-controlled known fields remain read-only and intact; other supported rows can be edited without rewriting them. Unknown/unavailable clip references are shown explicitly and never substituted. Controlled rows may be deliberately removed after confirmation; do not offer a fake constant-value editing path. A malformed whole table is visibly read-only and must not become empty/default on error. Existing confirmed **Use for playback/default** remains the explicit replacement route.
- Numeric row drafts participate in the combined Model flush. Invalid drafts block save/freeze/history/selection and remain recoverable with this tool's Revert. If resource drafts coexist, stage once and publish MDL version plus native table as one revision/Undo. Table-only edits do not stage model bytes. Failed reads/staging or stale source leave content unchanged. Revert clears only this tool's own draft/error, retaining other Model/Timeline drafts.
- Copy selected row state before asynchronous reads; retain full document/MDL/puppet JSON ownership until publication. Check every authored clip ID against the same loaded MDL candidate, including a combined clip edit. Hidden/shared layers keep their own tables; their clip references still block deletion through existing logic.
- Actual scene re-render previews committed mixing; do not hot-apply controlled fields using snapshot-only native APIs. Five languages, both themes, 850×540 with Timeline, associated labels, modal focus and trusted native keyboard paths remain supported. No runtime bundle/keychain/timeout changes.

## Task 1 — Pure layer operations and document transactions

Files: new `Editor/Web/model-mixing.mjs` and `.test.mjs`; `document.mjs`/tests; `model-clip-edit.mjs`/tests.

- [x] Write failing tests for inspect/default/malformed/control states; add/duplicate/update/move/remove; exact unknown-field/default preservation, owned copies, invalid finite/index/clip inputs and failures leaving original content intact.
- [x] Implement `inspectMixLayers(table,clips)` and `editMixLayers(table,operation,clips)`. Validate structural table entries and clip IDs. Preserve unsupported imported rows except explicit operations that leave them intact or confirmed removal.
- [x] Add `SceneDocument.modelAnimationLayers(id,layers)` with owned native-table data and exact Undo. Extend captured clip publication to optionally update table and resource in one `doc.transaction`; table-only publication skips staging. Test delayed mutation/stale document/MDL/puppet bytes and atomic history.

## Task 2 — Contextual stack UI and combined drafts

Files: new `model-mixing-tools.mjs`, `model-mixing-view.mjs`, `model-mixing-messages.mjs`; `model-workspace.mjs`, `app.mjs`, `localization.mjs`, `build.mjs` and generated offline resources.

- [x] Write real-browser acceptance before UI implementation, then add stack selection/forms/actions and confirmed removal. Keep canonical absent properties unchanged on no-op edits. Restore old selection after a failed draft flush; invalid focused fields and stage failures recover through own Revert.
- [x] Combine Model resource and mixing drafts atomically. Do not stage a model for table-only changes. Keep modal barriers stable and Cancel/Escape recoverable without clearing unrelated errors. Resource clip IDs and current native table are validated together.
- [x] Verify real known pixels for sequential order, weight, rate, visibility and additive semantics; exact history, independent unknown/controlled rows, save/reload and loose/PKG exports. Exercise five languages/themes/minimum window, labels, modal focus and keyboard cancellation.

## Task 3 — Actual native acceptance, docs and English PR

Files: new `Editor/Web/test-model-mixing.mjs`, `Tests/EditorRuntimeHarness/MixingAcceptance.h`; existing `main.mm`, `scripts/test-editor-native.py`; README and clip/mixing/standalone guides.

- [x] Add independent browser/native mixing phases at unchanged 60-second budgets; preserve all existing phases. Use fixture clips 7 (right Y 0/30/60) and 11 (90/120/150), both mirror/FPS2/2 intervals. Final rows: clip7 weight1, clip11 weight0.5, plus an invisible clip7 row retaining unknown metadata. Main must render 45..105 motion, known 75 interpolation and 105 peak. Native AppKit types second-row weight0.25 without blur, freezes to exact JSON only (no MDL override), saves/undoes/redoes, and previews 52.5 at .5s with Timeline visible. Every page releases and each runtime shuts down once.
- [x] Full JS and complete browser/native runner, reproducible offline build, independent Editor build/resource bridge, 3/42/16 product checks, independent final code review and changed-file privacy gate. Record failures/root causes honestly. Only the approved isolated test-host keychain is used.
- [x] Update READMEs and reused-project attribution, commit with configured real email, submit English PR, and leave it open for separate merge authorization. Submitted as [PR #23](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/23).

## Commands

- Baseline main `9c71145`; expected 230 existing JS tests.
- `node --test Editor/Web/model-mixing.test.mjs Editor/Web/model-clip-edit.test.mjs Editor/Web/document.test.mjs` (60-second targeted budget).
- `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs`.
- `node Editor/Web/build.mjs` and `node Editor/Web/build.mjs --check`.
- `EDITOR_NATIVE_TEST_KEYCHAIN=isolated SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' python3 scripts/test-editor-native.py`.
- Independent Editor build/bridge and product checks from `docs/testing/standalone-editor.md`.
