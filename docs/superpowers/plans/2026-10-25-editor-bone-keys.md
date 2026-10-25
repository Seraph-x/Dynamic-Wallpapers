# Sparse bone authoring keys implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Author sparse bone keys with add/edit/move/copy/paste/duplicate/delete and lossless reduction, retain their locations through save/reopen, and bake ordinary MDL samples for Main.

**Architecture:** Store per-bone/per-clip authoring frame indices in a namespaced JSON member of the existing MDLS bone metadata. Native dense track samples remain the playback authority and key poses are those samples at the authored frames. A lossless JSON span patcher changes only owned metadata fields, preserving unknown lexemes/large integers, physics fields, other clips and sections. Each operation publishes one captured MDL resource revision. Existing dense/FK/IK tools remain usable; if they or duration resizing make sparse indices inconsistent with dense samples, report an out-of-sync authoring state and require explicit adoption or forgetting before further sparse edits. No workspace schema, sidecar path or Main runtime change is needed.

**Tech Stack:** JavaScript ES modules, existing MDL codec, pinned WebWallGL native Euler sampling, CEF/AppKit, standalone Swift Editor.

## Data and interaction contract

- Use bone metadata member `dynamicWallpaperBoneKeys` with `{version:1,clips:{"7":{frameCount:2,keys:[0,2]}}}`. Empty metadata can become a JSON object. Preserve non-owned JSON text, whitespace, duplicate unknown fields and unrounded integer lexemes. Duplicate owned fields, malformed/non-object metadata or future versions are read-only for sparse authoring, with explicit reason. Existing ordinary clip operations preserve unsupported metadata unchanged.
- Native samples are Float32 local TRS `[tX,tY,tZ,rX,rY,rZ,sX,sY,sZ]`. Sparse keys contain sorted unique integer frames and retain mandatory anchors at `0` and `frameCount`. Endpoints can be edited/copied, but not moved/deleted. The separate copy/duplicate/add controls permit new interior keys. No new timing/frame caps beyond the pinned codec.
- Adoption is explicit and confirmed: capture **all current samples** as keys, changing metadata only and preserving animation exactly. The same action can explicitly replace a recognized stale key map from current samples. A separate confirmed **Stop sparse authoring** removes only this clip's owned map and retains all dense playback samples. Unsupported future metadata cannot be replaced silently.
- A managed map is usable only when its frameCount matches and interpolation from its key samples recreates every dense component bit-exactly (including signed zero). Use the pinned single ±2π Euler delta wrap and Float32 writes. Otherwise show stale/read-only with explicit adoption/forget actions; never silently rebake stale data. Reversible dense edits and Undo can restore coherence without metadata rewriting.
- Add captures the chosen native sample as a key. Set/paste replaces a key pose; move/duplicate preserves its pose at the destination. Removal and every nontrivial key edit resample between surviving keys using native linear translation/scale and wrapped Euler interpolation. State clearly that these are sampled native curves; adding an anchor can re-round interpolated Float32 values. Validate finite/representable components and every resulting local/world/skin/vertex transform before publication. Input bytes remain unchanged after failure.
- **Reduce losslessly** changes only the frame-index map. Starting at endpoints, verify exact original dense samples against native interpolation; split failing intervals at their midpoint and retry. Balanced subdivision is O(frames log frames), stores no quadratic state and need not find the globally smallest key set. Keep every sample necessary for exact playback. Verify the reduced map before returning.
- Clip duplication copies recognized key records to the new ID; deletion removes its owned records; creation clears a recognized orphan record for a reused ID. Preserve unknown fields/lexemes while patching these maps. Name/FPS changes keep indices; frame-count changes retain the old map and expose its stale state. Bone hierarchy reorder keeps the metadata on the surviving bone alongside remapped animation tracks. This PR documents stale adoption rather than silently reducing/reseeding after a resize.
- Model gains a collapsed **Bone authoring keys** panel: integer frame selector, prev/next key, a compact SVG overview, count/status/reason, native TRS fields with Apply/Revert, Add, Move, Duplicate, Copy/Paste, Delete, Reduce, Preview, Adopt and Stop. A non-key frame is inspectable; Add enables authoring there. Ruler click selects an integer frame. Key markers may share a display pixel; aggregate visual strokes by actual SVG pixel width, without dropping data or creating thousands of DOM nodes. All functions are also available through numeric fields/buttons.
- Move/duplicate use a destination-frame modal; adoption and forgetting use explicit confirmation modals. Modal state captures immutable source/bone/clip and participates in the existing unfinished-dialog barrier. Confirm is one undoable resource transaction; Cancel/Escape stages nothing. Failed staging retains inputs for retry/cancel; stale ownership cannot overwrite source bytes. Restore focus after Model loading/busy state settles.
- Inline key TRS drafts join the existing Model prepare transaction after dense pose drafts and hierarchy mapping, before events/mixing. A conflicting dense draft that invalidates the sparse map causes a visible failure; independent Revert clears only its own draft/error. Freeze/save flushes valid drafts and blocks invalid input or unfinished dialogs. Selection, copying, ruler position and Preview do not modify content.
- Preview uses the existing queued clip+seek operation and saved resource revision. Loop exact endpoints expose native wrap-to-zero in the existing note. Five languages and both themes fit 850×540 with Timeline. Main remains independent and exports contain standard sampled MDL plus ignored authoring metadata.

## Task 1 — metadata, pure sparse editing and clip lifecycle (TDD)

Files: create `Editor/Web/bone-key-metadata.mjs`, optional focused JSON span helper, `model-keys.mjs`, `model-keys.test.mjs`; extend `model-api-entry.mjs`, `model-clips.mjs` and appropriate lifecycle tests.

- [x] Add failing tests for `inspectBoneKeys(bytes,{clip,bone,frame}) -> {kind,keys,frame,pose,fps,frameCount,reason?}`, and `editBoneKeys(bytes,{type,clip,bone,frame?,to?,pose?}) -> Uint8Array` for adopt/forget/add/set/remove/move/duplicate/reduce.
- [x] Observe missing-feature failures, then implement metadata span edits and managed/stale/unsupported classification. Inspection may expose valid current native pose even for unmanaged/stale data; no invalid/future metadata becomes an empty managed map.
- [x] Implement immutable edits, native interpolation/Float32 checks, lossless balanced reduction and final complete clip validation. No-op set/adopt/reduce must keep exact bytes when nothing changes.
- [x] Add clip create/duplicate/delete synchronization for recognized owned records without import cycles; metadata helpers must not import model-clips. Test IDs, unknown/future maps, raw JSON preservation, hierarchy reorder, duration/FPS edits and dense/FK/IK staleness.
- [x] Test mandatory endpoints, collisions/ranges/invalid poses, native Euler wrapping, signed-zero identity, singular interpolated scale, independent expected whole MDL, clip/bone isolation, malformed metadata and source immutability. Run targeted suites green.

## Task 2 — Model UI and transaction integration

Files: create `model-keys-{tools,view,messages}.mjs`; modify Model workspace/localization/CSS/build and generated resources/provenance. Add `Editor/Web/test-model-keys.mjs` before UI implementation.

- [x] Observe real-browser missing-panel failure with the existing three-bone green fixture.
- [x] Build the accessible frame input, SVG overview, key navigation/TRS editor and operations. Keep canonical Float32 radians for unchanged degree inputs. Use real labelled numeric fields and named dialogs with cancellation and focus recovery.
- [x] Integrate pending inline drafts with bone reindexing, busy/frozen Model queue, source capture and owned resource commits. Stable dialog barriers and own-error reset follow existing event/clip tools.
- [x] Cover non-key inspection, add & bake, move/duplicate confirmations, clipboard/selected key operations, reduction and adoption/forget recovery. No dynamic Main dependency.
- [x] Rebuild/check offline resources and run complete Editor/runtime/spectrum Node checks.

## Task 3 — actual rendering, save and export

Files: `Editor/Web/test-model-keys.mjs`, `Tests/EditorRuntimeHarness/KeysAcceptance.h`, native main/runner (separate browser-keys/native-keys phases, 60 seconds each).

- [x] Browser independently encodes a right-bone track with keys at frames 0 and 4 on a 4 FPS clip, end pose Y=120 (middle sample at frame 2 has Y=60). Verify midpoint GPU displacement, all key operations/history, lossless reduction/adoption, default no-op, stale dense edits and explicit resync, draft barriers/recovery, stage retry/cancel, external source drift and five-language minimum layout.
- [x] Save/reopen the authored resource and export `KeysSource` (original model), `KeysLoose`, `KeysPackage` plus `keys-native-expected.mdl`. Expected bytes/metadata are encoded independently of new mutators. Native host authors the same endpoint through trusted AppKit input, checks full MDL/hash/map/history and saved-resource reopen.
- [x] Main actual loose/PKG CEF playback verifies the static left mesh and right motion at known 0/30/60/120px levels; Editor preview checks exact seeks. Check complete page release and one runtime shutdown.
- [x] Run the entire fresh-directory browser/native runner with approved test-host isolated keychain, preserving every existing phase/budget.

## Task 4 — docs, independent review and English PR

Files: README, Editor README, `docs/editor-bone-keys.md`, native testing docs and this plan.

- [x] Document metadata/source reuse, adoption/lossless reduction, native interpolation, endpoints, external-edit staleness and recovery, clip lifecycle and save/export. Do not claim a new runtime or minimal-key optimizer.
- [x] Independent review of metadata compatibility, numerical behavior, immutable transactions and UI lifecycle; fix material findings with regression tests.
- [x] Verify independent Editor build/resource bridge, product/configuration/source-export checks, offline hashes and final diff. Gate a changed-file copy with sanitized-public-export and keep the user-requested real commit email.
- [x] Submit a new English PR, leave it open and record verified evidence/link.

## Verification and review record

- PR #26 merged as `2c9789838ce5527e3678a2c4aafc4adf9bf141ec`. The isolated feature worktree starts from that main revision; baseline 302 checks passed. Independent plan review approved the metadata/native-sample approach.
- Missing APIs and the missing browser panel were observed red before implementation. Core tests then exposed and fixed native weighted interpolation order, noncanonical JSON no-op behavior, and explicit adoption of an already sparse managed map. Targeted core/clip checks passed 41 tests; combined Editor/runtime/spectrum checks passed 322 tests.
- Full real-browser acceptance passed exact independently encoded MDL, key/ruler/clipboard operations, no-op history, stale adoption/forget, source drift, stage retry/cancel, frozen/invalid inputs, saved reopen, preview/export pixels and five-language light/dark layout at 850×540 with Timeline.
- Independent review found a workspace-owned source invalidation error that key Revert could not release. A test-only route exposing the actual Editor instance reproduced the failure using real staging and document revision changes. The fix retains invalidation until all affected Model drafts are discarded, and does not let another draft reset release stale inputs. Both single-key and multiple-draft/ruler regressions passed; final read-only review approved the changes. Forget also restores focus to the enabled frame selector when its former opener becomes disabled.
- The complete fresh-directory runner passed all original phases plus separate 60-second browser-keys/native-keys phases with the approved test-host isolated keychain. Native checks passed confirmed adoption/reduction, trusted unblurred endpoint typing, full independent MDL/map/hash, exact pre-edit history, real saved-resource reopen and known 0/30/60/120px Editor samples. Main loose/PKG observed the expected motion levels and stationary left mesh; pages fully released and runtime shutdown was exactly once.
- Independent Editor build passed (66.28 seconds), and its real resource-bridge test passed (one test). Product checks passed 3/3, configuration 42/42 and public-source export 16/16. Reproducible build verified all 59 resource hashes; final diff is clean.
- Documentation links and upstream attribution are retained. The changed-file privacy gate passed all 32 files. Submitted [PR #27](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/27) from `feat/editor-bone-keys`; it remains open for review. Commits retain the configured real author email per user instruction.
