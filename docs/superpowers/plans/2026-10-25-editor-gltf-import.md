# glTF/GLB model import implementation plan

> **For agentic workers:** Use `executing-plans` inline with independent plan/code review. This is the remaining import subdivision of approved skeleton-authoring roadmap PR 3, after merged PR #19.

**Goal:** Import local glTF 2.0/GLB models with hierarchy, skinning, base-color textures and baked animation as actual editable MDL resources, with complete history/save/export/Main playback.

**Architecture:** A native File-menu picker reads only the selected entry and referenced local resources through the existing no-symlink file boundary. A typed bytes-only `import-model` command opens a native HTML dialog in the trusted offline workbench. Pure glTF decoding/conversion produces candidate resources; an isolated real-engine model preview measures the target skin shader's actual palette. Only explicit confirmation stages immutable versions and atomically adds the model layer/resources. Source assets and conversion metadata remain in the project.

**Tech stack:** Existing Swift/Core file reader, strict ES modules, pinned lossless MDL codec, selected MIT WebWallGL glTF math/sampling/PNG helpers, native forms/dialog, existing resource RPC and actual browser/AppKit/CEF checks.

## Approved conversion and compatibility contract

- User approved: retain original input files, show conversion details before import, bake animation at a chosen FPS, require explicit approval before PBR-to-unlit material conversion, and reject unrepresentable skinning/extensions rather than dropping them.
- glTF 2.0 JSON and exact-length GLB v2 containers; embedded data URIs and root-relative local external buffers/PNG/JPEG textures. No network/file URLs, parent traversal, ambiguous case/Unicode paths, basename lookup, symlinks, missing-file substitution or background file access. HTML webpage file choosers remain denied. Native picker is the sole filesystem authority and sends only explicit owned bytes to the workbench.
- Decode interleaved/normalized/sparse vertex accessors with safe offsets/strides/counts and supported component/type combinations. Validate GLB chunk ordering/alignment/bounds, buffer lengths, accessor indices and finite values before conversion/allocation. Honor explicit scene selection; preserve all source metadata/resources in an import archive.
- Preserve selected scene hierarchy needed by meshes, joints/ancestors and animation targets. Compose node TRS/matrices, use inverse bind matrices, bake rigid bind-space transforms into vertex data, keep animated rigid nodes and non-joint ancestors as bones with their own local tracks, and map skinned influences without truncation or root-joint replacement. Merge duplicate joints, preserve positive influence ratios and reject a required fifth positive influence, zero total, invalid references, singular/world-overflow matrices, conflicting shared-joint binds and unsupported morph/compression/extensions.
- Encode ordinary MDL meshes/bones/clips; existing Model tools must work afterward. Preserve full representable names. Bake LINEAR/STEP/CUBICSPLINE translation/rotation/scale using quaternion interpolation and continuous ZYX Euler tracks. For a positive source duration D and chosen fps F, encode frameCount=ceil(D*F), sample each frame at t=f/F with source endpoint clamping, and encode fps=F. Do not rescale sample time to f*D/frameCount. Report source duration, encoded duration frameCount/F, frame count, FPS and the final fractional-frame approximation/hold; source interpolation between output frame samples is explicitly a baked approximation. For D=0, encode one constant interval (frameCount=1) and report encoded duration=1/F. Playback loop/single mode is an explicit import option. Include real-engine seek at 0.2s for a 0.37s/30fps source and assert known sampled displacement, alongside Main export motion. No skeletal clip-authoring UI claim.
- Import materials as unlit base color with PNG/JPEG, base-color factor, OPAQUE and baked MASK handling. BLEND is an explicit unsupported error because the pinned renderer cannot preserve transparent depth/sorting. Single-sided to two-sided material conversion needs separate visible disclosure and explicit material consent. PBR appearance is an explicit conversion, never an implicit fallback. Explain sampling/lighting differences; unsupported material extensions and unrepresentable attributes remain errors. Preserve material separation, image orientation and source pixels where no baking is needed; avoid lossy texture atlases.
- Show model name, scene, scale, placement, FPS, clip/mesh/bone statistics, original files and conversion notes in all five languages. Preview changes do not dirty content. PBR conversion starts unchecked. Cancel/Escape publishes nothing. A failed parse/preview/stage remains visible and cancellable/retryable, never a successful placeholder.
- Compile/preview the actual candidate with Main's pinned engine, not a dummy model or guessed GPU limit. Require its linked skin palette to fit; destroy preview contexts on replacement, cancellation and teardown. Use observable source/version ownership and sequence checks for asynchronous preparation.
- Before opening, flush valid Model/Timeline inputs. An open/pending import participates in Save/freeze/history/native insertion/selection barriers via its own stable error; closing clears only that barrier. Freeze retains existing close-state semantics. Disable confirmation/cancellation appropriately during commit; a stage failure publishes no partial layer/resource revision.
- Confirmation atomically adds a model layer and every output/archive resource. Verify destinations against current inventory before/after staging and at publication, pin document/content identity, avoid case/Unicode/directory collisions, and select the resulting Model workspace. One undo removes the layer and revisions; redo, saved reopen, loose/PKG export and Main playback restore actual content.

## Task 1 — Source boundary and pure decoding (TDD)

Files: new `Sources/WallpaperEditorCore/EditorModelImportSource.swift` and `Tests/WallpaperEditorCoreTests/EditorModelImportSourceTests.swift`; new `Editor/Web/gltf-source.mjs`, `gltf-accessors.mjs`, related `.test.mjs` and owned fixtures/helpers.

- [x] Write failing tests for strict glTF/GLB decoding, data/local buffers, malformed/truncated/duplicate chunks, URI/path boundaries, missing refs, normalization/interleaving/sparse data and invalid metadata/offsets/strides/counts. Test actual Swift selected-root reads, referenced-only inventory, symlink/root redirection, Unicode/case ambiguity and byte ownership.
- [x] Implement native source collection through `EditorProjectFiles`, without exposing arbitrary paths to JavaScript. Decode and validate source bytes independently in JS. Preserve exact originals and reject unsupported/invalid source explicitly.
- [x] Record provenance for selected upstream helpers, pinned commit/blob/hash and MIT license; do not reuse its silent basename lookup, influence truncation, invalid-weight fallback, skipped primitives or ignored features.

## Task 2 — Geometry, skin and animation conversion (TDD)

Files: new `gltf-model.mjs`, `gltf-animation.mjs`, `gltf-materials.mjs`, tests; selected vendored helper modules; `model-api-entry.mjs`/build/provenance as appropriate.

- [x] Author independent glTF/GLB fixtures with known two-bone textured geometry, nonidentity inverse bind, animated rigid mesh nodes, animated non-joint ancestors driving joints, two materials and an existing moving joint. Include non-integral duration and constant zero-duration fixtures. Assert exact hierarchy, mapped skin/positions/UVs, unedited metadata archive, sampled poses and malformed cases before implementing.
- [x] Implement geometry/bind and dense animation conversion with explicit compatibility validation and Float32 world/inverse checks. All warnings that imply dropped content must become errors. Preserve time/clip metadata in conversion notes.
- [x] Generate unlit material/texture resources and explicit conversion requirements. Decode/bake images only from supplied bytes; validate decode failures and factors. Require explicit PBR conversion consent before publication.

## Task 3 — Transaction, preview and import dialog

Files: new `gltf-import-edit.mjs`, `gltf-import-view.mjs`, `gltf-import.mjs` and tests; new shared destination helper if reused; modify `document.mjs`, Model workspace/app/runtime command integration, five-language messages/build resources.

- [x] Write failing transaction tests for atomic resource+layer history, stale document/inventory collisions, second-stage failure, source immutability and explicit conversion consent.
- [x] Add `SceneDocument.addModel` and compose a single revision only after actual shader-capacity preview and explicit confirmation. Preserve original source assets and import manifest under unique project paths.
- [x] Implement actual isolated engine preview/capacity measurement and lifecycle; native semantic controls/labels/modal focus, preview settings and stable barriers. Add real-browser red/green cases for cancel, import pixels, one-step history, editable imported skeleton/weights, invalid drafts, stage recovery, save/reopen and exported files.

## Task 4 — Native picker and acceptance

Files: `Editor/Sources/EditorApp/EditorModelImport.swift`, `EditorApplication.swift`, `EditorWindowController.swift` and all five `Resources/*.lproj/Localizable.strings`; `Editor/Web/runtime.mjs`, `app.mjs` and typed command tests; new `Editor/Web/test-gltf-import.mjs`, `Tests/EditorRuntimeHarness/GltfAcceptance.h`, runtime `main.mm`, and `scripts/test-editor-native.py`.

- [x] Add localized File → Import model using NSOpenPanel for one glTF/GLB entry; collect only referenced owned bytes, prepare model/timeline state and send `import-model`. Keep Main and webpage file permissions unchanged.
- [x] Verify command identity/fields/cancellation and existing resource-reply bypass. Add a separate browser/native glTF phase without changing existing budgets or dropping prior coverage.
- [x] Native CEF imports actual owned fixture bytes, confirms through real UI input and checks staged hashes/MDL bytes, Save, one-step history, normal closure and single shutdown. Main renders both exported representations at known intermediate motion frames.
- [x] Check all five languages/themes and 850×540 controls with Timeline; retain source archive bytes across exports. Use only the previously approved native-test-host mock keychain; production remains unchanged.

## Task 5 — Final verification, docs and English PR

Files: README, Editor README, model/import usage docs, standalone validation docs and this record.

- [x] Independent code review, resolve important findings with regression tests, final diff and changed-owned-file privacy gate.
- [x] Focused JS/Swift source-boundary checks, offline reproducibility, independent Editor build/bridge, full browser/native acceptance and fresh-context relevant repeat. Run product/configuration/source-export checks; record failures honestly and distinguish focused results from full-suite coverage.
- [x] Update source attribution, exact conversion/unsupported semantics and verification evidence; prepare the verified feature branch for English PR delivery against merged main with the configured real author email. PR submission follows the implementation commit; no automatic merge.

## Baseline / references

- PR #19 merged; baseline main `9453f25`, isolated `feat/editor-gltf-import` worktree. 98 focused JS checks and 29 offline resources pass before changes.
- User explicitly approved the material conversion/source retention/animation baking policy during this task.
- glTF format authority: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
- Candidate helper source: WebWallGL `editor/gltf.ts`, fixed commit `197abe54266c31d346cebc314e49a26b70c960cc`, Git blob verified, SHA-256 `c57cb61cf1aefd222a0ae981e80c410bcbcbd76ed142dc921b828322110e8b22`. Full source contains silent fallback paths that are explicitly excluded from this design.

## Reproducible execution commands

- `node --test Editor/Web/gltf-*.test.mjs` (targeted tests must fail for the expected missing behavior, then pass).
- `node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs`.
- `node Editor/Web/build.mjs` and `node Editor/Web/build.mjs --check`.
- `python3 scripts/swift_sdk.py build --build-tests --disable-sandbox`, then `python3 scripts/test.py --skip-build --filter EditorModelImportSourceTests` (60-second targeted budget).
- `(cd Editor && python3 ../scripts/swift_sdk.py build --build-tests --disable-sandbox)` and `(cd Editor && python3 ../scripts/test.py --skip-build --filter EditorResourceBridgeTests)`.
- `SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' node Editor/Web/test-gltf-import.mjs`.
- `EDITOR_NATIVE_TEST_KEYCHAIN=isolated SCENE_CHROMIUM_EXECUTABLE='<installed Chromium executable>' python3 scripts/test-editor-native.py` (existing per-phase budgets; new independent glTF phases).
- `python3 scripts/test-editor-product.py`, `python3 scripts/test-product-configuration.py`, `python3 scripts/test-export-public-source.py`.

## Final acceptance record

- 170 JavaScript tests; 15 native glTF source-boundary tests; one real native Editor resource-bridge test passed. Root and independent Editor builds passed.
- All 36 offline resources reproduce; independent product/configuration/source-export checks passed 3/42/16 tests.
- Final clean-directory full browser/native acceptance passed all existing phases and both new glTF phases without budget changes; precise 0.2-second CEF pose, Main loose/PKG motion, source hashes, history and complete release passed.
- Fixed discovered issues with regression evidence: directory-enumeration descriptor ownership, control-character paths, preallocation bounds, rigid/joint bind reuse, animation world overflow, transparent RGB readback, default-material consent and pending-dialog cleanup.
- Target renderer limitations are explicit: PBR-to-unlit and single-to-double-sided conversions require unchecked consent; BLEND depth/sorting is rejected. Original archives bypass upstream .pkg filtering and retain exact bytes in both exports.
- Native input and close failures in the newly added harness were fixed in test-only AppKit event routing/autorelease lifetime, retaining real trusted keyboard and closure checks. Production deadlines and keychain configuration did not change.
