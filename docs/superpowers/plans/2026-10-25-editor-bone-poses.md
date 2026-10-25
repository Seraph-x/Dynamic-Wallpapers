# Native bone pose frames implementation plan

> **For agentic workers:** Use `executing-plans` inline, with independent plan and final code review. This is another independently usable subdivision of approved skeletal-animation roadmap PR 4, after merged PR #21.

**Goal:** Edit a selected bone's native per-frame TRS samples, copy/paste/reset poses, and bake interpolation between chosen endpoints; preserve exact unrelated data through undo, save/reopen and actual Main loose/PKG playback.

**Architecture:** MDLA already stores one local TRS pose at each integer frame (N intervals, N+1 samples). Expose these native dense samples explicitly, without inventing sparse-key metadata. Add a pure pose module and a contextual Model pose controller/view. Reuse captured MDL/puppet ownership, the existing Model operation queue and a single combined resource transaction.

**Tech stack:** Existing ES modules and pinned lossless MDL codec, semantic numeric forms, Swift/CEF and real Chromium/Main acceptance.

## Confirmed behavior and boundaries

- Existing approved roadmap supplies requirements; no repeated interview. This PR provides native dense pose-frame authoring. Sparse authored key positions, clip mixing, frame-event authoring, FK/IK and SceneScript IDE remain subsequent subdivisions, not silently removed or claimed complete.
- Select the existing Model bone and clip; select an integer frame in 0..frameCount. Show local translation, Euler rotation in degrees and scale, plus exact frame time. Selection/copy/preview are not content edits. Editing one bone/frame must preserve other bones, other frames, other clips, events, attachments and bind matrices exactly.
- Apply writes nine Float32 components to that sample. Reset pose explicitly writes that bone's actual local bind pose to that sample. Copy owns nine canonical components; Paste populates a draft and commits through Apply/save. No OS clipboard permission or project metadata is needed.
- Bake between two distinct selected endpoint frames rewrites only the selected bone's interior samples, retaining both endpoints exactly. Use pinned single-wrap Euler interpolation; warn in the visible description that existing interior poses are replaced. Endpoints are read from the committed/combined candidate. One Undo restores all interiors. No event retiming or clip-duration change.
- Preserve canonical Float32 radians when a displayed degree value is unchanged. Reject nonfinite values, invalid indices, singular/inexpressible local transforms, Float32 world/skin/vertex overflow and unsupported source layouts. Expose errors and leave the current document unchanged; never silently clamp or substitute values.
- Valid pose, clip, bone/rest and weight drafts flush into one candidate and one history revision. A hierarchy reindex maps the selected bone before applying its pose. Invalid drafts block history/save/freeze/selection; pose Revert clears only its own error/draft. Preserve unrelated pending tools. Stage failures remain visible and recoverable.
- Separate pose-frame selection from pending values. Changing frame/bone/clip flushes first, then refreshes controls; failed selection restores the inspected frame. Extend `previewModelClip` with an optional target time: replacing the table and seeking to frame/FPS must be one runtime queue task, preserving subsequent Timeline seeks. Frame samples are local, not world transforms; bind/rest editing remains separate.
- Expose actual native loop endpoints: at frameCount/FPS a loop returns to sample zero; its final sample controls interpolation approaching that boundary. The visible preview note states this. Mirror/single modes can show the exact final sample. Never silently synchronize first/last samples or alter unrelated frames to disguise this behavior.
- Five languages, light/dark themes, minimum 850×540 window with Timeline and associated labels. Keep pose controls collapsed by default. No production keychain, timeout or playback-format changes.

## Task 1 — Pure dense-pose operations

Files: create `Editor/Web/model-poses.mjs`, `model-poses.test.mjs`; modify `model-api-entry.mjs`; extract shared strict clip resource parsing/pose validation from `model-clips.mjs` only where needed.

- [x] Write and observe failing tests for exact inspection, local radians, owned copies, one-frame edits, unchanged siblings/clips/events/bind, reset from bind rather than animation frame zero, endpoint-preserving range interpolation including multi-turn rotations, invalid values/indices/layout and Float32 world overflow. Inputs remain exact after every failure.
- [x] Implement `inspectBonePose(bytes,{clip,bone,frame})` and `editBonePose(bytes,{type,clip,bone,frame,pose,start,end})`. Types: set/reset/interpolate. Return owned bytes; validate the changed clip through existing exact native transform semantics and lossless round trip.

## Task 2 — Contextual UI and atomic drafts

Files: create `model-pose-view.mjs`, `model-pose-tools.mjs`, `model-pose-messages.mjs`; modify `model-workspace.mjs`, `model-clip-tools.mjs`, `runtime.mjs`/`runtime-model-preview.test.mjs`, `localization.mjs`, `build.mjs` and offline resources.

- [x] Build associated frame/TRS/range controls, Apply/Revert, Copy/Paste, Reset and Preview actions; retain canonical radians across unchanged values. Clearly describe dense samples, local coordinates and interior replacement.
- [x] Integrate one combined Model transaction, original-to-new bone mapping, captured source ownership, busy/frozen state, exact selection restoration and own-error recovery. Keep timing and pose drafts atomic; out-of-range combined edits fail explicitly.
- [x] Add real browser regressions before UI implementation: numeric edits, pixel displacement at exact and intermediate times, copy/paste/reset, interpolation, no-op radians, atomic history, invalid focus/stage recovery, save/reload and both exports. Cover five-language/themed minimum layout and labels.

## Task 3 — Real native acceptance and delivery

Files: create `Editor/Web/test-model-poses.mjs`, `Tests/EditorRuntimeHarness/PoseAcceptance.h`; modify `main.mm`, `scripts/test-editor-native.py`; update README, Editor README, clip/pose guide and standalone validation.

- [x] Add separate browser/native pose phases with unchanged 60-second budgets. Real AppKit typing and unblurred freeze verify encoded TRS/hash, exact undo/redo, saved acknowledgment, known pose pixels, actual Main moving loose/PKG playback, full page release and one shutdown. Retain all previous coverage.
- [x] Run JS suite, reproducible offline resources, independent Editor build/bridge, product/configuration/source-export checks and complete browser/native runner with the already approved test-host isolated keychain. Record any failed attempt and its root cause accurately.
- [x] Independent code review, final diff and changed-file privacy gate. Commit with the configured real email and create an English PR; do not automatically merge it. Submitted as [PR #22](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/22).

## Verification commands

- Baseline main `3788119`; expected 214 existing JS tests.
- `node --test Editor/Web/model-poses.test.mjs` (60-second targeted budget).
- `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs`.
- `node Editor/Web/build.mjs` and `node Editor/Web/build.mjs --check`.
- `EDITOR_NATIVE_TEST_KEYCHAIN=isolated SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' python3 scripts/test-editor-native.py`.
- `(cd Editor && python3 ../scripts/swift_sdk.py build --build-tests --disable-sandbox)`; real `EditorResourceBridgeTests`; product checks in `docs/testing/standalone-editor.md`.
