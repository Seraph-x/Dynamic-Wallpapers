# Native animation frame events implementation plan

> **For agentic workers:** Use `executing-plans` with independent plan/code review and TDD. Pure binary/JSON operations and native acceptance may be delegated independently of UI work. This is the frame-event subdivision of approved skeletal-animation roadmap PR 4, after merged PR #23.

**Goal:** Create, duplicate, edit, reorder and remove native MDL clip events while preserving unknown metadata, then verify real `animationEvent` callbacks through Editor and Main exports.

**Architecture:** Keep MDLA's existing `{time:Float32,json:string}` event records. A pure module edits only requested records and patches top-level frame/name JSON value spans without reserializing unknown data. Add a collapsed Model event controller/view using the existing selected clip, combined resource transaction and captured source ownership. No new event runtime, script IDE or schema.

**Tech stack:** Pinned lossless MDL codec/WebWallGL 3.0.0, ES modules and semantic forms/dialogs, real Chromium/CEF/AppKit/Main playback.

## Confirmed behavior

- The approved roadmap supplies scope; no repeated interview. Deliver frame-event authoring here. Sparse keys, FK/IK and SceneScript IDE remain subsequent work.
- Select an existing clip and event. Display frame, name, encoded time and raw JSON metadata. Selection does not edit content. Add asks for frame/name with Cancel; duplicate copies the exact selected record; Up/Down changes stored ordering; Delete asks for confirmation and restores exactly through Undo. Same-frame duplicates are allowed and native stable ordering is retained.
- Authored frames are integers in 0..frameCount; names are valid Unicode strings without NUL, including empty names supported by the native format. Native seconds are `Math.fround(frame/fps)`. The pinned codec supports up to 4096 event records; report that actual representation limit, with no other invented authoring cap.
- Existing readable events require an object with one unambiguous top-level frame and name, a native-range integer frame, string name and consistent encoded time. Unsupported/ambiguous records remain read-only for frame/name changes, visibly report why and retain exact bytes. Explicit duplicate/remove/reorder may preserve or deliberately remove opaque records; do not silently normalize them.
- Patch only changed top-level frame/name value spans. Preserve whitespace, key spelling/escapes, unknown nested values, number lexemes (including integers beyond JS precision), duplicate unknown keys and every unmodified event JSON/time exactly. A no-op edit is byte-exact. Reject duplicate known keys rather than choosing one. Never silently drop unknown metadata through JSON.parse/stringify round trips.
- Clip FPS/resize must reuse the same unambiguous event metadata/time validation. Replace the old timing path's last-key-wins JSON.parse behavior; a duplicate frame/name key, malformed record or inconsistent time rejects the whole timing edit without changing source bytes. Include a cross-tool FPS regression with duplicate frame keys whose last value otherwise looks consistent.
- No track, skeleton/bind, attachment, other clip or scene playback binding changes during event-only edits. Valid event, pose, clip, bone/rest/weight and mixing drafts publish as one resource revision/Undo; a simultaneous mixing draft shares the same document transaction. FPS edits recompute native event seconds using existing clip semantics. As before, move/commit an event out of a shortened-away range before shortening; conflicting drafts remain explicit errors, not clamped/dropped events.
- Invalid focused fields block save/freeze/history/selection and own Revert clears only this tool's error/draft. Failed stage/source drift changes no content. Capture original source/version during dialogs and pin actual MDL/puppet bytes through publication. Keep stable modal barriers, Cancel/Escape and busy/frozen ownership.
- Use the existing native event dispatch. Explicit `animationlayers` are needed for skeletal event dispatch in the pinned engine; the panel explains this and points to Clip layers / confirmed playback assignment. Do not silently create a binding. Playback/seek can dispatch crossed markers, and handlers may be stateful; seeking backward is not a simulation reset. Do not add a synthetic fire button or fabricate callback success.
- Preserve all five languages, both themes, minimum 850×540 with Timeline, associated labels, modal focus and trusted native input. No new execution/native-write channel, runtime bundle, production keychain behavior or timeout changes.

## Task 1 — Lossless event operations

Files: new `Editor/Web/model-events.mjs`, `model-events.test.mjs`; cohesive `event-json.mjs`/tests reused by `model-clips.mjs` timing and its tests; `model-api-entry.mjs` exports.

- [x] Write/observe red tests over real MDL fixtures: inspection, owned copies, add/duplicate/update/move/remove, same-frame order, canonical Float32 time and exact unchanged records/sections. Cover escaped keys/strings, nested arrays/objects, duplicate known vs unknown keys, whitespace, huge integer lexemes, no-op spelling preservation and malformed/read-only records.
- [x] Implement `inspectFrameEvents(bytes,clipID)` → `{clip,frameCount,fps,events:[{index,frame?,name?,time,raw,reason?}]}`; `editFrameEvents(bytes,{type,clip,index?,frame?,name?,to?})` → owned bytes. Types add/duplicate/update/move/remove. Enforce codec's actual 4096 bound and lossless verification; failures never mutate input.

## Task 2 — Contextual UI and atomic drafts

Files: new `model-events-tools.mjs`, `model-events-view.mjs`, `model-events-messages.mjs`; `model-workspace.mjs`, `model-clip-tools.mjs` callback, `app.mjs`, `localization.mjs`, `build.mjs` and generated resources.

- [x] Write real-browser acceptance before UI implementation. Add collapsed event list, frame/name fields, encoded time/raw metadata, Apply/Revert, create/duplicate/order/delete actions and modal cancellation. Keep imported opaque records visible with explicit reasons.
- [x] Integrate selected clip refresh and all Model draft/barrier/busy/frozen/source ownership paths. Apply event drafts after clip timing and pose edits; preserve existing rejection when shortening excludes an event. Share publication with mixing drafts. Invalid fields use tool-owned nonempty errors; failed selection restores the inspected event.
- [x] Verify exact history, combined bone/clip/pose/mixing edits, invalid focused recovery, failed staging, opaque metadata, save/reload and loose/PKG exports. Five languages/themes/minimum layout and keyboard focus/cancellation pass without content edits.

## Task 3 — Actual callbacks and independent delivery

Files: new browser `test-model-events.mjs` and authored fixture helper if useful; new `Tests/EditorRuntimeHarness/EventAcceptance.h`; existing `main.mm`, `scripts/test-editor-native.py`; READMEs and event/clip/standalone guides.

- [x] Author fixture: clip7 loop, FPS4, 8 intervals, three-bone static geometry from modelFixture. Event records reset@0, middle@2 with unknown/large-number JSON, reset@6. An existing inline color SceneScript returns green on reset, red on fire or Native fire; update preserves its current color. Rename middle to fire through UI and export EventsLoose/EventsPackage. Rendered red/green, not merely a counter, proves the actual handler responds. Preserve explicit clip7 playback table.
- [x] Native expected MDL is independently encoded by the fixture from the exported event JSON with only fire→Native fire changed, without calling the new event mutation function. Native AppKit types Native fire without blur, freeze/hash/exact MDL/save/Undo/Redo pass. With Timeline visible and paused, forward seek0→0.5→1.5 must show actual green→red→green and actual native event names. Main independently renders both colors and fixed mesh placement from both exports. Every page releases and each runtime shuts down once.
- [x] Add independent browser-events/native-events 60-second phases; retain every prior phase/budget. Run full JS, reproducible offline build, standalone Editor/real resource bridge, 3/42/16 product checks, complete browser/native runner, independent final code review and changed-file privacy gate. Only approved test-host isolated keychain is used; document every actual failure/root cause.
- [x] Update READMEs and upstream attribution; commit with configured real email, submit English PR and leave it open for separate merge authorization. Submitted as [PR #24](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/24).

## Verification

- Baseline main `a088aa4`; expected 246 existing JS tests.
- Target pure tests with a 60-second budget, then `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs`.
- `node Editor/Web/build.mjs` and `node Editor/Web/build.mjs --check`.
- `EDITOR_NATIVE_TEST_KEYCHAIN=isolated SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' python3 scripts/test-editor-native.py`.
- Independent Editor build/bridge and product checks from `docs/testing/standalone-editor.md`.
