# Skeletal clip library implementation plan

> **For agentic workers:** Use `executing-plans` inline with independent plan/code review. This is the first usable subdivision of approved roadmap PR 4, after merged PR #20. Follow checkbox tasks; use TDD for the resource/transaction logic.

**Goal:** Create, duplicate, rename, resize, change playback settings and delete MDL animation clips, then explicitly assign a clip for exported playback, with complete resource history and actual Main rendering.

**Architecture:** Extend the existing Model workspace with a compact Clips disclosure, using the same loaded MDL/source/version and combined Model draft transaction. Pure lossless MDL clip operations retain every untouched section/track/event. An explicit playback action edits native scene `animationlayers`; clip selection and a temporary preview do not change content. No new workspace schema, renderer or engine bundle.

**Tech stack:** Existing Swift/CEF host, ES modules, pinned lossless MDL codec and editor APIs, semantic forms/dialogs, five-language messages, browser/native acceptance.

## Confirmed scope and behavior

- Existing approved roadmap supplies requirements; do not repeat a product interview. This PR delivers clip library management. Bone pose keys, animation mixing, frame-event authoring and FK/IK remain subsequent independent PRs, without dropping those features.
- Inspect the model's clip list and full names. Create a clip from actual local bind/rest transforms, or duplicate an existing clip preserving all track and event bytes with a new unique u32 ID. Do not substitute source frame zero for bind pose.
- Edit name, playback FPS, interval/frame count and loop/mirror/single mode. Show encoded duration. Changing FPS changes playback speed at fixed frame count; resizing samples the existing motion over normalized time, retaining endpoints and the pinned renderer’s single-wrap Euler rotations. Explain this before confirmation. No hardcoded authoring count caps beyond actual codec/renderer representation.
- The first clip is default playback, not the bind reference: actual bind matrices come from MDLS. Allow deletion of any unreferenced clip. Deleting the first of multiple clips requires an explicit replacement default and a confirmation listing affected default-playback shared layers; move that surviving clip first without renumbering IDs. Deleting the final clip leaves an empty MDLA and displays the bind/static pose after explicit confirmation. Reject deleting a clip used by an explicit native animation-layer table until its layer is deliberately reassigned/defaulted. Never silently rewrite unrelated layers.
- Existing frame events remain opaque/exact when unaffected. Timing changes require readable frame/name metadata and consistent event times; preserve JSON/unknown fields, recompute native seconds on FPS change, and reject a resize excluding an event instead of clamping/dropping it. Event authoring remains subsequent work.
- Reject raw/ambiguous MDL sections, duplicate IDs, invalid tracks, malformed events, nonfinite/unrepresentable timing and sample/world matrices. Untouched resources remain byte-exact; a failure leaves the current document unchanged.
- Clip selection only changes inspected settings. **Preview clip** uses actual native animation layers at full weight and seek(0), pauses the shared clock and is explicitly temporary. Re-render restores the saved scene assignment. **Use for playback** / **Use default playback** uses a confirmation dialog before replacing the selected layer's animation table; undo restores all original unknown binding fields.
- Clip forms participate in the existing combined Model draft flush: valid pending bone/rest/weight/clip inputs publish one resource revision; invalid drafts block save/freeze/history/selection/native insertion. Revert clears only that tool's draft/error. Creation/deletion/playback dialogs cancel without content edits and use source/version ownership checks.
- Preserve all five languages, themes and 850×540 layout with Timeline. Keep clip content collapsed by default. Maintain native pointer/keyboard ownership and production keychain behavior.

## Task 1 — Pure clip library and tests

Files: new `Editor/Web/model-clips.mjs`, `model-clips.test.mjs`; existing `model-fixtures.mjs` only if needed; `model-api-entry.mjs` exports.

- [x] Write failing tests over the independent three-bone moving fixture, multiple clips, unknown event JSON and section metadata. Cover unique IDs, rest creation, exact duplicate, metadata, normalized resize (including multi-turn Euler samples), default replacement, final-clip static playback, explicit-reference protection, unsupported layout, event preservation and every failure leaving input unchanged.
- [x] Implement `inspectClips(bytes)` and `editModelClips(bytes,operation)` returning `{bytes,id}`. Operations: `{type:'create',name,fps,frameCount,mode}`, `{type:'duplicate',id,name}`, `{type:'update',id,name,fps,frameCount,mode}`, `{type:'delete',id,replacement?,referenced:[ids]}`. Confirm exact lossless round-trip and preserve unrelated binary sections.
- [x] Validate new/changed sampled poses with existing pinned Float32 transform semantics. Keep bind matrices and surviving clip IDs intact; append new IDs, and reorder only an explicitly chosen replacement default.

## Task 2 — Native scene assignment and transaction safety

Files: `Editor/Web/document.mjs` / tests; new `model-clip-edit.mjs` / tests; existing `model-resource-edit.mjs` as needed without changing unrelated behavior.

- [x] Test and implement explicit `SceneDocument.modelAnimation(id,clipID|null)` for a selected image/model layer. Write native single-layer array `{animation:clipID,blend:1,rate:1,visible:true}` or remove the field for default; preserve all other fields and restore exact originals through undo.
- [x] Capture document/source revision and resolve every model-sharing layer for deletion references; resource reads/staging must reject stale document, binding, shared-path or content changes. Unknown reference tables fail explicitly rather than being assumed empty. Stage once then publish one resource revision. A failed stage changes no content.
- [x] Keep existing `animationlayers` untouched until explicit replace/default confirmation. Resource duplication never silently changes scene playback.

## Task 3 — Model Clips UI and combined draft barriers

Files: new `model-clips-view.mjs`, `model-clips-messages.mjs`; `model-workspace.mjs`, `model-view.mjs`, `model.css`, `localization.mjs`, `build.mjs` and generated offline resources.

- [x] Add semantic associated clip selection/settings controls, duration/status, create/duplicate/delete/preview/use/default actions and confirmation dialogs. Preserve full names; display unsupported reason and allow leaving/recovery.
- [x] Integrate selected clip/draft/source state into Model's existing preparation/flush/revert/frozen/busy lifecycle without recursive Model/Timeline waits. Bone/rest/weight and clip drafts produce one candidate and history revision.
- [x] Verify temporary preview uses the actual engine and never edits content; persisted assignment survives re-render, reopen and export. Undo, redo and selected-source changes refresh clip lists without stale drafts.

## Task 4 — Actual acceptance and English PR

Files: new `Editor/Web/test-model-clips.mjs`; new `Tests/EditorRuntimeHarness/ClipAcceptance.h`, `main.mm` flag and `scripts/test-editor-native.py` independent phases; README/Editor README, model/clip guides and standalone validation.

- [x] Real browser: create rest clip, duplicate moving clip, edit settings, known intermediate poses, preview versus saved assignment, cancellation, first/default/last and referenced deletion, invalid focused drafts, failed stage, atomic combined history, save/reopen and both exports. Check five languages/themes/minimum window with Timeline and keyboard modal focus.
- [x] Native CEF: real AppKit typing, trusted confirmation, focused freeze, resource hash and saved binding/history; actual Main loose/PKG pixels show the authored assigned clip at known intermediate motion. Normal page release and exactly one shutdown. Add independent 60-second phases; preserve existing coverage/budgets. Use only approved test-host isolated keychain.
- [x] Run relevant JS checks, reproducible offline build, independent Editor build, product/configuration/source-export checks, independent code review and changed-file privacy gate. Document exact scope, limitations and upstream references.
- [x] Commit using configured real author email and submit an English PR against merged main; do not merge this new PR automatically. Submitted as [PR #21](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/21).

## Baseline and commands

- main after PR #20: `694f374`; baseline 170 JavaScript tests, zero failures. Worktree `feat/editor-skeletal-clips`.
- `node --test Editor/Web/model-clips.test.mjs Editor/Web/model-clip-edit.test.mjs Editor/Web/document.test.mjs` (60-second targeted budget).
- `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs`.
- `node Editor/Web/build.mjs` and `node Editor/Web/build.mjs --check`.
- `EDITOR_NATIVE_TEST_KEYCHAIN=isolated SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' python3 scripts/test-editor-native.py`.
- `(cd Editor && python3 ../scripts/swift_sdk.py build --build-tests --disable-sandbox)` and relevant native bridge checks; `python3 scripts/test-editor-product.py`, `test-product-configuration.py`, `test-export-public-source.py`.
