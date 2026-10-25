# Two-segment IK posing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Solve and bake a selected two-segment bone chain toward a model-space target and pole, through cancellable native preview, history, save/reopen and Main export playback.

**Architecture:** This independently usable subset continues the approved skeletal-animation milestone after FK. Selecting an end bone identifies its parent (middle) and grandparent (root). A pure analytic solver changes only root/middle local rotation samples and retains translations, scales, bind transforms, other tracks/clips and metadata. It computes each selected sample from the original animation, validates the actual Float32/native-delta result and writes ordinary MDL. A modal reuses Model serialization, captured clip ownership, resource transactions and FK renderer restoration. A queued batch bone-pose API previews both joints without exposing a half-applied operation to later Timeline input.

**Tech Stack:** JavaScript modules, pinned WebWallGL 3.0.0/MDL codec, real Chrome and CEF/AppKit acceptance, independent Swift Editor application.

## Contract and numerical method

- The selected tip must have a direct parent and grandparent; solve exactly those two segments. Numeric target and pole positions are in MDL model coordinates, before scene-layer origin/rotation/scale. The pole defines the bend side; it is not a persistent rig constraint. No stretching, arbitrary-length-chain solver or joint limits are claimed by this PR.
- Root and ancestors require positive uniform local scales, so world-space alignment is representable without shear. Middle scale may be positive nonuniform; endpoint local TRS and all descendant local samples are preserved. Mirrored/nonuniform ancestors, zero-length segments, target at the root, collinear pole, invalid input and unreachable targets report a specific error. Never clamp an unreachable target to apparent success.
- For root A, middle B, tip C and target T, compute original world segment lengths a,b; direction d=(T-A)/|T-A| and pole direction v as its perpendicular projection. Desired elbow E=A+d*x+v*h, where x=(a²-b²+|T-A|²)/(2|T-A|) and h=sqrt(a²-x²). Only Float64 round-off at reach boundaries may be normalized within a named machine-epsilon tolerance.
- Rotate the root's current B-A toward E-A and then the middle's current C-E toward T-E. The pole plane supplies the deterministic half-turn axis. Convert rotations back through the actual parent transform into native local XYZ Euler angles; choose equivalent angles near the prior solved sample to avoid gratuitous turns. Retain original local translations/scales byte-exact.
- Native hot poses add Float32 Euler deltas. Quantize each delta and bake `fround(original + delta)` so preview and saved samples share semantics. Recompute the encoded hierarchy and reject endpoint error beyond a documented 1e-5 of total segment length; expose residual on preview. Validate all final local/world/skin/vertex transforms before staging.
- Modal fields: inclusive start/end (equal = one sample), preview frame, target XYZ and pole XYZ. Defaults use frame zero endpoint and an explicit visible suggested pole: current bend direction where defined, otherwise a deterministic perpendicular model axis. User-provided degenerate poles always fail. Suggested defaults are not solver fallbacks.
- Preview pauses and solos the chosen clip, validates the complete range candidate, and hot-updates both joints in one runtime queue operation. Repeated previews replace both deltas. Exact terminal preview for a loop is rejected before mutation; terminal baking remains available and affects playback approaching the wrap boundary.
- Cancel/Escape ignores invalid draft fields, reloads the authoritative renderer, restores the original clock/play state and focus, and stages nothing. Reload restarts stateful scripts/particles, as in FK. Bake creates one undoable owned revision; unchanged candidates produce no revision. Stage failure retains the candidate for retry/cancel. Stale source bytes/bindings cannot be overwritten. Existing unfinished-dialog save/history/freeze barrier remains visible and recoverable after thaw.
- All five languages and light/dark themes fit 850×540 with Timeline. Editor remains optional; exported MDL needs no solver or Editor installation in Main.

## Task 1 — analytic solver and native samples (TDD)

Files: create `Editor/Web/model-ik.mjs`, optional focused `model-ik-math.mjs`, and `model-ik.test.mjs`; export through `model-api-entry.mjs`.

- [x] Add red tests for `inspectIkChain(bytes,{clip,bone,frame})`, `solveTwoBoneIk(bytes,{clip,bone,frame,target,pole})`, and `bakeTwoBoneIk(bytes,{clip,bone,start,end,target,pole})`.
- [x] Run targeted Node tests and observe missing-feature failures.
- [x] Implement analytic geometry, native-compatible Float32 deltas, continuity and encoded endpoint verification without mutating input. Add a nonzero-start range crossing an Euler wrap/gimbal boundary; the requested candidate preview must reproduce its exact encoded rotation sample. Inspection returns `{root,middle,tip,positions,pole,fps,frameCount,mode}`; solve returns `{poses:[{bone,delta}],positions,residual}`; bake returns `{bytes,preview}` where optional `previewFrame` requests the exact full-range candidate’s `{poses,positions,residual}` at that sample. Preview consumes these stored deltas, not a standalone solve, so prior-sample Euler continuity and Float32 addition match Bake exactly. Add names if useful for accessible context.
- [x] Test known right-angle solution, opposite poles, actual 3D targets/rotated parents, uniform ancestor and nonuniform middle scales, animated chains, single/inclusive/loop-terminal samples, unrelated siblings/children/events/clips, antiparallel alignment, invalid/degenerate/unreachable cases, overflow/underflow and owned byte-exact no-op. Run green.

## Task 2 — queued preview and modal

Files: create `Editor/Web/model-ik-{tools,view,messages}.mjs`; modify `runtime.mjs`, `runtime-model-preview.test.mjs`, `model-workspace.mjs`, `localization.mjs`, `model.css`, `build.mjs`, generated resources/provenance.

- [x] Add red runtime tests for `previewModelBonePoses(id,{animation,time,poses})`: both deltas remain atomic before later seek, invalid/duplicate bone selectors fail before any native layer mutation, invalid Float32 components and closed/frozen state fail visibly. Existing FK wrapper behavior remains compatible.
- [x] Implement the batch helper; preserve single-bone FK API as a wrapper.
- [x] Add browser missing-control red acceptance before UI. Build a named native dialog with labelled numeric groups, visible residual/error, primary Bake and Cancel/Escape. Use the existing modal busy/focus restoration and stable barrier ownership.
- [x] Integrate selected clip/tip, pending Model preparation, source capture and one resource commit. Do not add persistent solver/schema state or modify Main.
- [x] Build/check all offline resources and run the full JS Editor/runtime/spectrum suite.

## Task 3 — actual engine and native exports

Files: create `Editor/Web/model-ik-fixture.mjs`, `test-model-ik.mjs`, `Tests/EditorRuntimeHarness/IkAcceptance.h`; extend native main/runner with separate 60-second browser-ik/native-ik phases.

- [x] Use an independently authored serial chain A=(-35,0,0), B=(0,0,0), C=(35,0,0), three separately colored skinned marker meshes, constant native clip samples. Target (0,35,0), pole (-35,35,0) yields root +π/2 and middle -π/2. Independently encode expected full MDL without calling the new solver.
- [x] Browser: verify native root/middle/tip GPU positions, repeated preview, Cancel/Escape/playback restoration, invalid and unreachable inputs, failed-stage retry/cancel, stale source, freeze/thaw, single/range baking, exact history, saved reopen, loop boundary, five languages/themes and minimum layout. Export `IkSource`, `IkLoose`, `IkPackage` and independent `ik-native-expected.mdl`.
- [x] Native: open unposed source, select tip 2, trusted target/pole typing, actual GPU preview, independent full MDL/hash after Bake, one-step history, save/real reopen, unchanged inputs, Main loose/PKG marker positions, zero retained pages and exactly one shutdown.
- [x] Run a complete fresh-directory native runner with the approved isolated test-host keychain. Preserve all existing phases and budgets.

## Task 4 — documentation, independent review and English PR

Files: `README.md`, `Editor/README.md`, `docs/editor-ik-posing.md`, `docs/testing/standalone-editor.md` and this plan.

- [x] Explain two-segment scope, model-space target/pole, supported scales, reachability, sample-only guarantees/intermediate interpolation, native loop boundaries, history/export and upstream reuse. Do not claim constrained IK or arbitrary chain support.
- [x] Independently review code/math/lifecycle and fix material findings with regressions.
- [x] Verify independent Editor build/resource bridge, product/configuration/public-source checks, offline hashes and final diff. Gate a copy of changed files with sanitized-public-export; preserve real commit email per user instruction.
- [x] Push and submit an English PR, leave it open and record actual evidence/link.

## Progress and verification evidence

- PR #25 merged as `d7dd312ce0ee89c5296f11748ae8a16646b4bd94`. This worktree starts from that main revision; baseline 279 checks passed.
- Independent plan review required retaining the exact full-range candidate’s preview deltas across Euler branch choices; the implementation and a nonzero-start wrap/gimbal test follow that contract.
- TDD: missing-core/missing-UI/missing-batch-API failures were observed before implementation. Core now has 21 tests; the core/runtime subset has 30 passing checks, and the combined Editor/runtime/spectrum suite has 302 passing checks. All 56 offline resource hashes reproduce.
- Actual browser acceptance passes three-color joint positions, independently encoded full MDL, exact range/single/terminal history, between-sample interpolation, saved reopen/exports, repeated preview, cancellation/playback/focus, invalid geometry, failed-stage retry/cancel, stale source, freeze/thaw and all five languages/themes at minimum size.
- Native puppet images use one shared layer texture. The first fixture’s separate mesh materials therefore rendered one color; the final fixture uses a UV atlas and 16×16 markers whose pixels survive the reduced canvas. No production engine fallback was added.
- Independent code review found and verified fixes for two P2 cases: untouched bent defaults losing one Euler ULP, and a later default sample bypassing continuity after a changed sample (4π jump). Exact default-coordinate identity preserves bytes until a range actually changes; subsequent samples then follow the prior encoded Euler branch. Explicit pole edits still solve. Inspection does not reject a clip merely because a different, unselected sample has unsupported scales.
- A browser regression also verified that editing a candidate clears the old displayed residual. The final read-only review passed, independently rerunning all 30 focused checks.
- The pre-review native run was deliberately stopped with the test driver’s owned-process cleanup (status 143); it is not counted as final validation. The new-directory full run using the final resources passed all phases, including separate 60-second browser-IK/native-IK phases.
- Independent Editor build and real resource bridge passed. Product/configuration/source-export checks passed 3/42/16 tests. Native IK passed trusted keyboard input, all three actual GPU joint positions, independent whole MDL/hash, history, real saved-resource reopen and complete release. Main loose and PKG held the three known solved centroids for at least 0.5 seconds (150/151 observations), without Editor installed. Pages returned to zero active instances and runtime shutdown was exactly once. The changed-file privacy gate passed all 32 files. Submitted [PR #26](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/26) from `feat/editor-ik-posing`; it remains open for review.
