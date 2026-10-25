# Native FK delta posing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Apply local FK translation/rotation/scale deltas to a selected bone over an inclusive native sample range, with cancellable native preview and ordinary MDL export.

**Architecture:** Extend the approved skeletal-animation milestone with one complete subset. A pure MDL transform adds local translation/Euler rotation and multiplies local scale, matching the pinned engine’s `setBonePose`. A modal owns its candidate and captured immutable source; preview never stages resources or edits history. Confirmation uses the existing clip-resource transaction, preserving copy-on-write and stale-source checks. Cancel recreates the current document renderer and restores the pre-dialog clock/play state. Existing clip-layer assignments remain saved unchanged. Numeric local controls are the manipulation interface for this PR; canvas gizmos, IK and sparse key authoring remain separate work.

**Tech Stack:** JavaScript modules, pinned WebWallGL 3.0.0, native MDL codec, CEF/AppKit test host, SwiftPM.

## Contract

- The Model workspace exposes an FK delta dialog for the selected clip/bone. Start/end are inclusive integer samples; start=end edits one sample. A preview frame must lie within the range. Fields default to zero translation/rotation and unit scale. Rotation displays degrees and stores radians.
- Native preview pauses and solos the selected clip temporarily; explain this explicitly. Local rotation uses native XYZ Euler addition, not quaternion/world-space rotation. Child transforms follow through FK; other bones’ local tracks and bind transforms stay unchanged.
- Loop terminal samples can be baked, but exact terminal-frame preview is unavailable: the native engine wraps that time to sample zero. Reject Preview for that combination with a visible explanation, retain the candidate and allow Bake/Cancel. Document that the terminal sample affects interpolation approaching the boundary. Test a distinct first/last pose, terminal-only bake, unchanged frame zero and real playback immediately before the endpoint.
- Bake validates every affected pose and Float32 conversion before staging. Unknown supported MDL sections/events remain lossless. Invalid ranges, malformed data, overflow/underflow, singular transforms and stale ownership report errors without publishing a document.
- The modal participates in the existing unfinished-dialog save/history barrier. Cancel/Escape ignores invalid inputs, restores the current authoritative renderer, original time and playing state, clears only its own errors, and returns focus to the opener. Apply creates one undoable revision, closes the dialog and restores the original playback clock/state; the reloaded renderer consumes committed MDL. A stage failure keeps the dialog/candidate usable.
- No production Main dependency on Editor. All five languages and both themes retain their existing layout at 850×540 with Timeline open.

## Task 1 — pure FK transform (TDD)

Files: create `Editor/Web/model-fk.mjs`, `Editor/Web/model-fk.test.mjs`; extend `Editor/Web/model-api-entry.mjs`.

- [x] Write failing tests for `bakeBoneDelta(bytes,{clip,bone,start,end,delta})`, where delta is nine numbers `[tx,ty,tz,rx,ry,rz,sx,sy,sz]`.
- [x] Run `node --test Editor/Web/model-fk.test.mjs` and observe missing-feature failure.
- [x] Implement with `readClipModel`, native Float32 delta quantization, inclusive samples and `validateClipPoses`. Preserve input bytes and untouched clips/tracks/sections exactly. Reject underflow/overflow before and after applying components; validate local and world/skin transforms.
- [x] Cover translated/rotated/scaled parents, descendants, signed scales, single-frame/full-range boundaries, sequential edits, invalid selectors and losslessness. Run targeted tests green.

## Task 2 — modal and renderer preview lifecycle

Files: create `Editor/Web/model-fk-{tools,view,messages}.mjs`; extend `runtime.mjs`, `runtime-model-preview.test.mjs`, `model-workspace.mjs`, `localization.mjs`, `build.mjs`, offline resources/provenance.

- [x] Add failing runtime lifecycle tests: preview deltas replace rather than accumulate, selected clip+seek+pose execute atomically, cancellation recreates renderer and restores clock/play state, invalid/closed/frozen calls fail visibly.
- [x] Implement queued `previewModelBonePose` and `restoreModelPreview`. Capture the original clock/play state before pausing on dialog entry; do not modify saved layer assignments.
- [x] Implement labelled native numeric fields in a named `<dialog>` and real form. Validate on Preview/Bake, show errors inside the modal, disable controls only while an operation runs, keep Cancel available after errors. Re-enable and restore autofocus after queued work. Preview validates the complete candidate using Task 1 before calling the native pose API.
- [x] Integrate `ModelFkTools` with workspace operation serialization, busy state, selected clip/bone context and stable modal barrier; confirm through captured clip source and `options.write`. No additional persistent FK state/schema.
- [x] Build resources and run JS suite plus reproducible `build.mjs --check`.

## Task 3 — real browser/native acceptance

Files: create `Editor/Web/test-model-fk.mjs`, `Tests/EditorRuntimeHarness/FkAcceptance.h`; extend native harness `main.mm` and `scripts/test-editor-native.py`.

- [x] Add browser test before UI implementation and observe missing controls; use existing real engine fixture with independently encoded expected MDL, not the new mutator as an oracle.
- [x] Verify local parent delta deforms descendants through native bone points and GL pixels; repeated preview does not accumulate; Cancel/Escape fully restores renderer/playback/doc; single-frame and range bakes, undo/redo, stage failure recovery, stale ownership, unfinished-dialog snapshot barrier, focused input and five languages/themes at minimum size.
- [x] Save/reopen workspace and export loose/PKG, verify expected binary tracks and unchanged inputs. Native Editor opens exports; Main actual CEF scene playback verifies intermediate frames/pixels and shutdown.
- [x] Run the complete fresh-directory `scripts/test-editor-native.py` with isolated test-host keychain. Keep existing phase budgets/coverage unchanged and add separate 60-second FK phases.

## Task 4 — review and PR

Files: update `README.md`, `Editor/README.md`, relevant native testing docs, and this plan.

- [x] Document workflow, exact delta/range/loop-boundary semantics, cancellation and unsupported deferred tools; retain upstream attribution.
- [x] Independently review diff against this plan and master spec; fix material findings with regression tests.
- [x] Verify independent Editor build/resource bridge, product configuration, public-source export, offline hashes and `git diff --check`. Scan a copy of changed files with sanitized-public-export; real author email remains per user instruction.
- [ ] Commit with the real configured author and create an English PR. Leave this new PR open for review. Record verification evidence and PR URL here.

## Progress and evidence

- PR #24 merged as `49509c7cd4356f1fc81788c32b08ff2d99de55dc`; this feature branches from that main revision.
- Plan review approved after making the loop-terminal preview limitation explicit.
- Baseline: 261 JavaScript checks; FK core red (missing module) then 15 green; runtime preview red (missing API) then seven green. Combined Editor/runtime/spectrum checks: 279 passing.
- Browser missing-control red test preceded UI implementation. Expanded real-engine browser acceptance passes actual parent/child pixels, repeated preview, paused/playing cancellation, Escape, transient stage retry/cancel, source-byte drift, freeze/thaw, exact single/range/loop-terminal history, save/export, five languages and both themes at 850×540 with Timeline.
- The modal dims canvas screenshots, so preview assertions read actual WebGL draws. Native save-barrier diagnostics resize the canvas; assertions normalize against its actual center rather than a stale screen origin. Native snapshot deliberately blurs inputs, so focus is checked before requesting it.
- Read-only independent code review found no material production defect; its three requested lifecycle evidence gaps (retry, stale ownership, freeze/thaw) were added and pass in browser acceptance.
- Complete fresh-directory native runner passed all existing phases plus `browser-fk` and `native-fk`, each with its own unchanged 60-second phase budget. Native FK used trusted keyboard input and exact independently encoded MDL/hash, verified four known GPU samples after save/reopen, both Main export formats (parent 20px plus child 0/15/30/60px), zero retained pages and one runtime shutdown.
- Independent Editor build passed (83.57 seconds); the real EditorResourceBridgeTests passed (one test). Product checks passed 3/3, configuration 42/42 and source export 16/16. Reproducible offline build checks all 53 resources. `git diff --check` is clean.
- Sanitized-public-export gate passed on the 30 changed files; the configured real commit author is retained as explicitly requested. Final review of the expanded lifecycle checks found no remaining blocker.
