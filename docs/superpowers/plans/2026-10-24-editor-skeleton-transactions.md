# Lossless skeleton transactions implementation plan

> **For agentic workers:** Use `executing-plans` to implement this plan task by task. This is the first infrastructure subdivision of roadmap PR 3; the model workspace, glTF/GLB importer, image-to-puppet creation and interactive brush remain required subsequent work.

**Goal:** Make skeleton reindexing and numeric skin edits preserve the rest of an MDL resource and participate in the existing resource history/export contract.

**Architecture:** Vendor the MIT upstream lossless MDL codec at a recorded commit. A pure model module rewrites explicit source-to-destination bone mappings, updating skin indices, positional animation tracks, attachments and recognized bone-sized tables together. Existing resource RPC/history is the integration path; this PR adds no native command, installed dependency or user-facing panel.

**Tech stack:** ES modules, the pinned WebWallGL 3.0.0 renderer/editor API, Node tests, existing Playwright/CEF acceptance harnesses.

## Contract and boundaries

- `rewriteSkeleton(bytes, {bones, replacements})` accepts a parent-before-child destination skeleton. Every existing bone identifies its original `source`; new bones use `source: null`, a name and an invertible TRS matrix. Existing metadata and local bind matrices are retained. Reparenting changes the parent relationship while retaining local transforms and local animation tracks; it does not promise to preserve world-space motion.
- Deleted positively weighted joints and attachments require an explicit replacement destination bone. Surviving weights and animation samples retain their values. New bones receive a constant local rest track in every existing clip. Track order, rather than the opaque `boneId` field, determines the renderer's bone association.
- Canonical MDLS tables are reordered without resetting their pose/draw values; new records use the upstream encoder's bind-pose representation. Empty tails stay empty. Dense MDLE bind-pose matrices follow the same map. Nonidentity permutations must still form a valid permutation after deletion.
- Unknown or raw bone-dependent sections, noncanonical MDLS tails, MDLE suffixes and nonzero animation trailers reject structural changes explicitly. Rename-only edits preserve these bytes. No unknown table is silently dropped or rebuilt. These are format limitations to document and expose in the later UI, not successful edits.
- Structural editing requires MDLV0023, MDLS0004, MDAT0001, MDLA0006 and MDLE0002 (when present), zero section flags, exactly one section of each type, an empty inter-section gap and a zero terminator. MDLA must have exactly one positional track per original bone, each with `(frameCount + 1) * 9` finite samples and exactly 31 zero trailer bytes; this excludes the codec's heuristic/ambiguous trailer parses. MDLS tails must be empty or exactly `14 + 84 * boneCount` bytes with the documented zero header/three flags and a bijective permutation. Reorder records by source, then remap the values in their permutation entries; reject deletions whose surviving entries would no longer be a permutation. Validate these constraints with independent same-size noncanonical and ambiguous-boundary fixtures.
- `setSkinInfluences(bytes, {mesh, edits})` accepts explicit vertex IDs and one to four unique bone/weight pairs, normalizes finite nonnegative weights and preserves every unedited vertex/section. Reject invalid joints, zero sums, duplicates and unsupported layouts without changing the input.
- Structural and numeric-weight operations require an explicit verified `boneLimit`. The pinned parser's 1024-bone limit does not override the shader palette's 128-bone ceiling or a smaller actual compiled GPU capacity. Reject absent/invalid/exceeded capacity instead of silently truncating. Rename-only edits do not alter this capability. Validate new matrices after native Float32 conversion, including the pinned parser's determinant tolerance.
- The module must be safe on malformed/truncated input and Uint8Array subviews. No operation mutates caller-owned bytes. The upstream codec's byte-for-byte round trip is checked before authoring, preventing edits through partially understood layouts.

## Task 1 — Pin the codec and independent fixtures

Files: `Editor/Web/vendor/mdl-codec.mjs`, `Editor/ThirdParty/mdl-codec-provenance.json`, `Editor/ThirdParty/WebWallGL-MDL-LICENSE`, `Editor/Web/model-fixtures.mjs`, `Editor/Web/model.test.mjs`.

- [x] Record the upstream commit, source URL and SHA-256; retain the complete MIT license and unmodified codec source.
- [x] Author a three-bone/two-mesh fixture with distinct per-bone animation samples, attachment, skin influences and opaque unrelated data.
- [x] Assert byte-identical codec round trips and equality with the pinned package's encoder on shared input.

## Task 2 — Reindex references atomically

Files: `Editor/Web/model.mjs`, `Editor/Web/model-tables.mjs`, `Editor/Web/model-math.mjs`, `Editor/Web/model.test.mjs`.

- [x] Write failing tests for swapping siblings, deletion with replacement, insertion, parent validation, metadata/animation/event/attachment preservation and no input mutation. Run `node --test Editor/Web/model.test.mjs`; confirm missing implementation fails.
- [x] Implement parsed-layout validation and explicit bone mapping. Preserve opaque fields and write all dependent references as one new Uint8Array.
- [x] Add failures for cycles, duplicate sources, invalid joints, missing replacements, malformed data, unsupported tables and unrepresentable new rest matrices. Verify input bytes remain identical on every failure.
- [x] Verify renamed-only models retain unfamiliar tails and structural edits fail with a specific reason.
- [x] Run the focused tests after every implementation increment and inspect the diff.

## Task 3 — Numeric weights

Files: `Editor/Web/model.mjs`, `Editor/Web/model.test.mjs`.

- [x] Write failing tests for single/multiple vertex edits, normalization, zero slots, four influence limit, invalid joints and unedited byte preservation.
- [x] Implement normalized influence writes using the verified vertex layout; reject duplicate vertex edits instead of depending on order.
- [x] Run `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs` and require all checks to pass.

## Task 4 — Offline/history/export/playback integration

Files: `Editor/Web/build.mjs`, `Editor/ThirdParty/provenance.json`, generated `Editor/Sources/EditorApp/Resources/EditorWeb/model-api.mjs`, `Editor/Web/test-model.mjs`, `Editor/Web/test-rendering.mjs`.

- [x] Bundle the model module as `model-api.mjs` without changing the engine bytes. Verify the vendored codec hash on every build/check.
- [x] In the real browser harness, generate the authored animated fixture, stage an edited MDL through existing resource RPC, and verify undo/redo and resource reload. Assert known geometry motion at intermediate seek times before/after sibling reindexing, using actual rendered pixels rather than file length.
- [x] Export both loose resources and PKG using existing paths; reload exported content through the pinned runtime and compare intermediate deformation. Keep native CEF acceptance and existing timeline checks green.
- [x] Extend `Tests/EditorRuntimeHarness/main.mm` and `scripts/test-editor-native.py` to pass the distinct model loose/PKG fixtures into Main's actual CEF scene runtime. Assert known intermediate deformation there as well as in the browser. Reopen the saved resource-revision document before exporting the fixture.
- [x] Run reproducible offline build checks, JS checks, relevant native acceptance and privacy scans. Document exact results, limitations and pending user-facing scope.

## Task 5 — Review and PR

Files: `docs/editor-model-resources.md`, `Editor/README.md`, this plan.

- [x] Explain source licensing, supported layouts, local-transform semantics and explicit failures. Do not claim a skeleton editing UI exists.
- [x] Obtain independent code review, address material findings and rerun affected verification.
- [x] Commit using the configured real email; open an English PR against main. Do not merge or publish a release under this checkpoint's authorization.


## Verification record

- Independent plan and implementation reviews approved after fixes for Float32 matrix conversion, actual rendering capacity and independent fixture coverage.
- 46 JavaScript checks passed, including 15 model checks.
- Reproducible build verified all 17 offline resources. The playback engine and existing Editor API bundle hashes remain unchanged.
- Product/source checks passed: 3 independent Editor product tests, 42 product-configuration tests and 16 public-source export tests.
- Real browser and native CEF acceptance passed. Both Main loose/PKG model exports retained horizontal bind positions, a stationary left bone and known intermediate right-bone skin deformation. Resource undo/redo, saved-document reload and full runtime release passed.
- Public-export scan: the exact unmodified upstream MIT license is excluded from contact detection because it includes the required upstream author attribution. Its full bytes remain SHA-256 checked by the offline build. All other changed files are scanned normally.
- Remaining roadmap work includes the Model workspace, glTF/GLB importer, image-to-puppet creation, brush/rest tools, skeletal clips and Script IDE. This infrastructure checkpoint does not claim those features are delivered.

Delivery: [PR #15](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/15), merged into main on 2026-10-24. The Model workspace continues in the companion implementation plan.
