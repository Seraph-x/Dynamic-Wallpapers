# Bone rest-transform editing implementation plan

> **For agentic workers:** Use `executing-plans` inline, with independent plan/code review. This is the next subdivision of approved skeleton-authoring roadmap PR 3, after merged PR #18.

**Goal:** Edit an existing bone's local bind/rest translation, Euler rotation and scale as a complete resource/history/save/export operation.

**Architecture:** Reuse the pinned lossless MDL codec and existing `restPose`/`restMatrix` math. A pure transaction changes only the selected MDLS local bind matrix; Model combines pending rest, numeric-weight and hierarchy drafts in its existing serial resource transaction. The existing playback engine recomputes world bind/inverse-bind matrices from MDLS; do not add an Editor-only evaluator.

**Tech Stack:** ES modules, native labeled numeric forms, existing immutable resource revisions, pinned WebWallGL 3.0.0, real browser/AppKit/CEF acceptance.

## Contract

- The Model inspector exposes a collapsible **Local rest transform** form with local XYZ translation, XYZ Euler rotation in degrees (Rz * Ry * Rx), and XYZ scale. Apply commits; Revert cancels pending Model input. Selection/form disclosure is preview state.
- This edits the local **bind** matrix, not an animation key. Mesh vertex bytes, weights, parent links, bone metadata, all other bone matrices, animation samples/events, attachments, MDLS static-pose tail and MDLE authored-pose data remain unchanged. Those authored poses are absolute; changing bind inverses can change their deformation, including descendants. Explain this beside the form rather than silently retargeting clips or rewriting distinct poses.
- Require the actual verified GPU palette capacity and a valid ordered skeleton. Validate finite TRS and Float32 matrix representation through existing math. Additionally validate ordered parent-composed Float32 world bind matrices with the pinned renderer’s partial-pivot inversion semantics (a pivot below 1e-12 is invalid, never an accepted identity). Reject non-finite composed matrices/inverses and validate every bone, including affected descendants. Reflections and gimbal cases supported by existing math remain supported. Unsupported source shear/perspective shows its specific reason with the original matrix available; it is not silently decomposed or repaired.
- Unchanged displayed values do not drift the matrix or create history. Preserve source bytes and unknown sections byte for byte. Failed parsing, unsupported transforms or staging publish nothing and remain visible.
- Rest drafts participate in Model preparation everywhere: Save/freeze/close, native insertion, history, workspace/bone/layer selection, Timeline and brush preparation. Valid combined rest/weight/hierarchy drafts publish one resource revision; weights/rest use original bone IDs before any hierarchy reindexing. Invalid drafts remain editable through thaw; explicit Revert recovers. Rest commits must preserve an unrelated Timeline draft.
- Existing image conversion, brush, all five languages, both themes and 850x540+Timeline remain usable. Main plays saved/exported results with no Editor dependency. No clip-authoring or glTF import claim.

## Task 1 — Pure bind-matrix transaction

Files: `Editor/Web/model.mjs`, `model-math.mjs`, `model-api-entry.mjs`; new `model-rest.test.mjs`.

- [x] Write failing tests for `setBoneRestTransform(bytes,{bone,pose,boneLimit})`: selected matrix changes to known TRS; all unselected data and source bytes remain identical; descendants remain local; optional MDLE/static/unknown sections are retained; no-op preserves exact source.
- [x] Test reflected/rotated/gimbal transforms, nonzero byte offsets, malformed input, invalid skeleton/bone/capacity, zero/underflow/overflow scales and non-finite values. Include Z scale 1e-13 (existing local decomposition accepts it but renderer inversion does not), cumulative parent/child scales below the 1e-12 pivot boundary, Float32 composition/inverse overflow, and ordinary valid scales/sheared world matrices.
- [x] Implement using existing lossless reader, capacity checks and matrix math. Validate Float32 matrix representation and composed bind inverses without imposing arbitrary limits; recognize unchanged canonical TRS before recomposing to avoid drift. Export in the offline model API. Run focused tests red then green.

## Task 2 — Model form and draft integration

Files: new `Editor/Web/model-rest-view.mjs`; modify `model-view.mjs`, `model-workspace.mjs`, `model-messages.mjs`, `build.mjs`; reproduce offline resources/provenance.

- [x] Add a real-browser failing case for editing Right's bind X from 35 to 45 and verifying its green mesh moves left exactly 10 scene units while Left and the existing Y animation remain unchanged.
- [x] Add labeled required XYZ controls in fieldsets/legends and a collapsible disclosure; show the original matrix, specific unsupported errors and binding/animation semantics in five languages.
- [x] Add `restDraft` to preparation, conflict detection, validation, render-preservation and explicit Revert/recovery. Build rest and hierarchy in one final candidate via `editModelHierarchy(type:update)`, after numeric weights on original IDs, in one revision. Validate the final candidate rather than rejecting an invalid intermediate parent/rest combination. Retain brush and native freeze barriers. Structural hierarchy transactions must also validate the final composed bind matrices, so a combined rest/reparent cannot bypass inverse checks.
- [x] Exercise valid focused Save/freeze, invalid scale, Timeline/native insertion barriers, selection preparation, combined drafts, no-op, staging failure/recovery and unrelated Timeline draft retention. Verify no hidden content edits.

## Task 3 — Save/export and native acceptance

Files: new `test-model-rest.mjs`; extend `test-model.mjs`, `test-model-layout.mjs`, native runtime harness and `scripts/test-editor-native.py` as needed.

- [x] Save/reopen the actual UI-authored resource and export RestLoose/RestPackage independently of existing fixtures. Assert known stationary left and shifted/animated right pixels through Main's actual CEF runtime at intermediate times. Retain all previous fixture assertions and phase budgets.
- [x] Add a separate native rest acceptance phase with real focused keyboard input, freeze/Save, staged MDL hash/matrix and one-step undo/redo. Require normal page release and exactly one runtime shutdown. Use the previously user-approved native-test-only isolated keychain; production remains unchanged.
- [x] Test the controls in all five languages, both themes and minimum window with Timeline open. Confirm labels, no overflow and no dirty content when merely inspecting transforms.

## Task 4 — Review, documentation and English PR

Files: `README.md`, `Editor/README.md`, `docs/editor-model-workspace.md`, `docs/testing/standalone-editor.md`, this plan.

- [x] Run focused JS and offline reproducibility, complete browser/native acceptance, independent Editor build/bridge and relevant product/configuration/source-export checks. Record failures honestly and keep existing budgets.
- [x] Obtain independent code review; fix important findings with regression coverage. Inspect final diff and run the sanitized-public-export gate on changed owned files.
- [x] Update usage/limitations and test evidence, retain upstream attribution, commit with configured real email and create an English PR against merged main. Do not merge the new PR automatically.

## Baseline and source evidence

- Baseline main: `7cf3a53` (merged PR #18), isolated `feat/editor-rest-transforms` worktree. 88 focused JS checks and all 28 offline resources pass before changes.
- Pinned local `webwallgl.mjs` parsing computes `invBindWorld` from MDLS parent-composed matrices; `computeSkinMatrices` multiplies sampled world pose by inverse bind. MDLS static-pose tails and MDLE are distinct authored data, not duplicate inverse-bind tables.
- Model codec source/license stays pinned in `Editor/ThirdParty/mdl-codec-provenance.json`. The local pinned source is the authority; an attempted online source fetch returned a cache miss.

## Verification record

- 98 focused JS tests pass; all 29 offline resources reproduce. 3 Editor product,
  42 product-configuration and 16 source-export checks pass.
- The complete protocol/browser/image-brush/browser-rest/native/native-brush/
  native-rest run passes with unchanged budgets. All three native phases close
  normally and observe exactly one runtime shutdown. Main asserts stationary
  left and ten-pixel shifted right bind placement plus intermediate Y animation
  in both actual rest exports. Native rest types into the focused input, checks
  actual MDL matrix/hash, Save acknowledgement and one-step history.
- A second native brush/rest execution with fresh contexts also passed actual
  input, resource history, both exports and normal single shutdowns.
- The independent Editor builds successfully and its real resource bridge test
  passes. The production executable omits the test-keychain marker. No broad
  application-suite or system-keychain integration pass is claimed.
- Independent plan/code reviews found and regression-tested final-world inverse
  checks and atomic final-candidate handling of both legal and illegal combined
  parent/rest edits. Matrix precision/no-op and missing-pose regressions passed
  red then green. The final reviewer reports no remaining important findings.
- Earlier browser/native failures remain failures: overlay pixels polluted the
  first centroid comparison; a test misunderstood the existing freeze contract;
  an asynchronous selection assertion ran before selection completed; the first
  complete native run observed no brush weight change. Scene comparisons now
  share the same overlay state, freeze checks dirty/old document plus rejected
  snapshot, selection awaits command preparation, and native inputs wait for
  actual focused/typed input or trusted pointerup acknowledgement. No pixel
  tolerances, production freeze behavior or shutdown assertions were weakened.

English pull request: [#19](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/19).
Feature commit: `1181b7a`. The new PR remains open for review; it is not merged.
Commits use the configured real author email.
