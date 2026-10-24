# Image-to-puppet authoring implementation plan

> **For agentic workers:** Use `executing-plans` for inline work with independent plan/code review. This is another subdivision of approved skeleton-authoring roadmap PR 3, after merged PR #16.

**Goal:** Create an editable skinned grid from an ordinary image layer, so model authoring does not require an external model file.

**Architecture:** Generate a standard MDLV0023 grid with one root bone. Copy the image's model/material metadata to unique adjacent resource paths, retaining its texture references. Publish those resources and the selected layer's new model binding as one resource/history transaction. The existing renderer, Model workspace, resource RPC and export path remain the authority.

**Tech stack:** Pure ES modules, the already pinned lossless MDL encoder, native forms/dialog, existing five languages/themes, Node tests, real browser/AppKit/CEF acceptance.

## Contract

- In Model, an ordinary image layer offers **Create mesh from image…**. It opens a confirmation dialog with a root-bone name and density presets (4, 8, 16 or 32 cells per axis, default 8); show the resulting vertex/triangle counts. Presets are a UI convenience, not a hidden API limit. Cancel/Escape changes nothing. Keep ordinary image editing unchanged unless the user confirms conversion.
- Generate a centered XY grid at the image model's positive finite natural width/height, Y up and top-left UV origin, with correct triangle winding, four influence slots per vertex and root weight 1. Use a single identity root and constant Rest clip. Validate cell/count values as safe integers; validate geometric dimensions and final coordinates as finite Float32-representable numbers. Check native 32-bit index/byte lengths before allocating; support both 16- and 32-bit mesh indices. No arbitrary grid cap or silent coarsening is introduced.
- Use positive finite natural width/height explicitly declared by image-model JSON; native File → Add image always provides these. The pinned public layer API exposes no natural size, so reject autosized/missing-dimension sources explicitly instead of guessing dimensions from a transformed outline. Honor explicit positive constant layer size when generating geometry; reject size bindings/scripts/animations explicitly rather than baking a resolved snapshot. Do not bake layer origin, scale, rotation, color, opacity, visibility, property animation or script bindings into mesh coordinates. Existing layers sharing the old model/material remain unchanged.
- Only convert readable image-model JSON without an existing puppet, using a supported single-pass, single-texture `genericimage2`/`genericimage4` material without shader constants/combos or render-target bindings. Reject missing/malformed model/materials and unrepresentable shaders or passes with a specific error, without flattening them. Retain unknown JSON fields. Copy the material to a new path and explicitly disable default mesh lighting to preserve the flat image appearance; do not modify the shared source material.
- Choose UUID-based new model/MDL names adjacent to the source model and a new material name adjacent to the source material. Check all destinations for existing resources and reserved/ambiguous references before publication. Never overwrite a resource to create the mesh.
- Read the current revision's model/material bytes. Capture document identity, layer ID/image binding and resource versions; verify ownership before/after asynchronous reads and staging. Stage all three resources, then commit their references and retarget only the selected layer in one synchronous document transaction. A failed read/stage/conflict publishes no partial scene edit. Unreferenced staged blobs follow the existing retention policy.
- Conversion needs only one bone, which every successfully linked pinned model shader can represent. The first actual model draw still supplies the Model workspace's measured capacity for subsequent bone/weight operations. The existing resource RPC gains a read-only workspace-scoped `list` action for collision checks; no new native content command, installation path, workspace schema or playback format is needed.
- The conversion dialog participates in Model freeze/draft barriers and busy/focus behavior. Other content operations cannot bypass a pending dialog. Invalid creation remains visible and can be cancelled. Once created, the ordinary Model workspace supports its hierarchy/numeric weights; brush, existing-rest editing, glTF/GLB import and skeletal clips remain explicit subsequent work.

## Task 1 — Pure grid and material/model creation

Files: `Editor/Web/image-puppet.mjs`, `Editor/Web/image-puppet.test.mjs`, model API entry/build.

- [x] Write failing tests for grid counts, centered positions, top-left UVs, winding, bone/weight slots, root/rest clip, source metadata retention and unlit copied material. Test texture references and natural dimensions without altering input objects.
- [x] Add invalid dimension/count/name/JSON/material cases and a 32-bit-index fixture crossing 65,535 vertices. Reject unsafe/overflowing native lengths before array allocation.
- [x] Implement generation using the recorded upstream encoder and inspect the result through the current model API/pinned renderer. Run focused tests after each step.

## Task 2 — Atomic layer/resource conversion

Files: `Editor/Web/document.mjs`, `Editor/Web/image-puppet-edit.mjs`, corresponding tests.

- [x] Add a narrow image-model retarget document operation with expected-source validation; test a transaction combining resources/binding as one undo and preserving every other layer field.
- [x] Write failing async tests for selected-layer ownership, current model/material versions, destination collisions, failed second/third staging and stale document/layer/version changes. Input/source files stay unchanged.
- [x] Implement capture/read/validate/generate/stage/commit. All three resources use fresh paths; no side effect reaches the document until the complete validated transaction is ready.

## Task 3 — Model dialog and integration

Files: `Editor/Web/image-puppet-view.mjs`, Model messages/view/workspace, offline resources and browser acceptance helper.

- [x] Add a failing real-browser image-layer scenario before UI implementation. Convert a known asymmetric colored image; compare the original image's real pixels with the generated puppet and verify it is an actual loaded model.
- [x] Add the explicit Create entry, density choices/counts and root-name dialog in all five languages. Use associated visible labels, native modal focus, Cancel/Escape, busy handling and the existing freeze/content barriers.
- [x] Preserve source revision/selection across async staging and retain invalid input/errors. Support Model immediately after successful conversion; no editor installation prompt is added.
- [x] Verify cancellation, malformed/unsupported materials, one-step undo/redo, property/animation preservation, shared-resource isolation, failed stage/conflict and minimum-window theme/language behavior.

## Task 4 — Save/export/native validation and delivery

Files: browser/native model acceptance helpers, `Tests/EditorRuntimeHarness/main.mm`, `scripts/test-editor-native.py`, workspace/resource guides and READMEs.

- [x] Reopen the saved image-generated model and create an independent constant-pose bone through Model. Inject a documented test-only dense MDLA root-motion fixture through the existing resource replacement hook, then edit numeric weights through the real Model UI and verify a known changing deformation. This is a playback/history fixture, not a claim of skeletal animation-authoring UI. Undo the weight change to the known root-motion export pose.
- [x] Materialize loose/PKG forms and open them through Main's actual CEF runtime. Assert the asymmetric texture/orientation, bind geometry and authored motion; verify normal page/resource/runtime release.
- [x] Exercise creation via the native Editor page using its real owned image files and confirm the resulting resource map/binding. Existing native Model keyboard/freeze/history checks remain required.
- [x] Regenerate/check offline resources; run focused JS, relevant native/product/source-export checks, independent code review and changed-file privacy scan. Document exact scope, restrictions, upstream references and results without claiming unfinished roadmap features.
- [x] Commit with the configured real email; open an English PR against merged main. This new PR is not automatically merged or released by PR #16's merge request.

## Verification record

- 70 focused JavaScript checks pass; all 25 offline resources reproduce.
- Independent Editor Swift build and native resource bridge test pass.
- Full protocol/browser/browser-image/native acceptance passes; final image-browser
  and native acceptance pass again, including Main
  image quadrant placement/orientation and intermediate skeletal motion in
  loose/PKG form, normal closure and one runtime shutdown.
- Product checks pass: 3 Editor product, 42 configuration and 16 source-export.
- Independent review findings fixed with regression tests: explicit layer sizes,
  unsupported bound sizes, original-inventory aliases/directory collisions,
  final asynchronous-check races and render-target texture references.
- Existing source JSON, shared layers and unsupported features are not silently
  replaced. Upstream encoder provenance and license remain recorded.
- The changed-file privacy gate reports 42 files, no unexpected findings and exit 0.

Delivered in [PR #17](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/17).
