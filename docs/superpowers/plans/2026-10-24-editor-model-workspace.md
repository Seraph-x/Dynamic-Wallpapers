# Model workspace implementation plan

> **For agentic workers:** Use `executing-plans` for inline implementation with independent review. This is the user-facing workspace subdivision of roadmap PR 3, following merged PR #15.

**Goal:** Let users edit skeleton hierarchy and numeric skin influences in an imported loose/PKG model, with real rendering, undo, save/reopen and export.

**Architecture:** Add a contextual Model workspace alongside Properties. Pure hierarchy operations use the lossless model resource API. A workspace controller resolves the selected revision, stages edited bytes, checks ownership/revision conflicts and commits a single resource reference. The existing pinned renderer supplies bone screen points and the actual linked GPU palette capacity; no new model format or native command is introduced.

**Tech stack:** Native HTML forms/dialogs, ES modules, existing themes/five languages, WebWallGL 3.0.0, resource RPC, Playwright and native CEF acceptance.

## Scope and semantics

- Select Properties or Model using native buttons with pressed state and explicit panel visibility. Model is optional and starts closed. Ordinary image/text editing retains its current layout and behavior.
- A loaded puppet/mesh shows bones, parent relationships, rest matrices (read-only for existing bones), mesh/vertex counts and numeric influences. A bind-space mesh/weight map displays triangles and selectable vertices; the main preview can show selectable bone points/links from the renderer. Window-local workspace/selection/overlay changes do not dirty the scene.
- Rename, create, reparent and delete bones. New bones use name, parent and local TRS values. Reparenting keeps local transforms/tracks and therefore changes world-space motion. Topologically sort destination records, then use PR #15's coherent mapping. Reject cycles and preserve original metadata.
- Delete uses a native confirmation dialog explaining removed animation tracks, child reparenting and influence/attachment transfers. Require an explicit surviving replacement only when weighted vertices or attachments reference the removed bone. Children move to the removed bone's parent with their local transforms unchanged. Cancel changes no content; deleting the final bone fails visibly.
- Numeric influence editing accepts one to four joint/weight pairs and normalizes them through the existing pure API. Mesh and vertex selection are local UI state. Rest-transform mutation of existing bones, painting, glTF/GLB import and image-to-puppet creation remain required later subdivisions; no placeholder controls claim these exist.
- Save/freeze/undo/redo, layer/workspace changes and other document edits first drain queued model operations and apply valid drafts. Invalid drafts remain visible and block dependent actions until corrected or reverted. Disable the model fieldset only during a committed operation; preserve focused values. Native resource replies bypass preparation barriers as before.

## Task 1 — Observe actual model capacity

Files: `Editor/Web/model-capacity.mjs`, `Editor/Web/model-capacity.test.mjs`, `Editor/Web/runtime.mjs`, runtime tests.

- [x] Write failing tests showing context creation arguments, draw return values/errors and receiver identity are unchanged; linked `u_skin[0]` uniform size is captured, missing capacity stays unavailable and disposal restores original method descriptors.
- [x] Create an owned canvas and pass it as the public `createScene(canvas, options)` element. The pinned API explicitly supports HTMLCanvasElement. Install a per-canvas `getContext` observer before the engine creates WebGL; after the real context is returned, observe its draw calls without changing arguments, shaders, program bindings or GL state.
- [x] Inspect each actually drawn program once using read-only GL queries. Capture the linked `u_skin[0]` array size, including the renderer's lower shader-link retry capacity. Never infer a palette from MAX_VERTEX_UNIFORM_VECTORS. Observation errors are retained and reported when an edit needs capacity; native draw errors still propagate.
- [x] Dispose observers on render replacement/destruction; retain the existing one-active-renderer lifecycle. Expose the measured capacity and revision-aware resource read method to the workbench controller.
- [x] Verify real browser/CEF behavior; no fake WebGL test result counts as rendering evidence.

## Task 2 — Pure model inspection and hierarchy commands

Files: `Editor/Web/model.mjs`, `Editor/Web/model-hierarchy.mjs`, `Editor/Web/model-math.mjs`, corresponding tests and model API bundle.

- [x] Add failing tests for inspection ownership, rename/create/reparent/delete, stable sorting, cycles, child handling, explicit replacement mapping and new TRS matrices.
- [x] Add model inspection that copies parsed skeleton/skin/mesh data. Unsupported mesh layouts report their reason while still allowing safe rename. Check vertex/index sizes and ranges before exposing editable mesh data.
- [x] Implement `editModelHierarchy(bytes, edit)` using original bone IDs internally and stable parent-first sorting. Preserve source identities for the lossless rewrite and return its old-to-new map for selection updates.
- [x] Generate new local matrices from finite TRS values, validate the exact native Float32 representation and use the measured bone capacity for structural commands.
- [x] Run all model/capacity tests and the existing JS suite; confirm failures before implementation and preserve input bytes on all errors.

## Task 3 — Workspace, drafts and history integration

Files: `Editor/Web/model-workspace.mjs`, `Editor/Web/model-view.mjs`, `Editor/Web/model-overlay.mjs`, `Editor/Web/model-messages.mjs`, `Editor/Web/model.css`, `Editor/Web/app.mjs`, `Editor/Web/index.html`, localization/build lists.

- [x] Add a failing real-browser workspace scenario before UI implementation: inspect the known three-bone model, change parent/name, create/delete/cancel, edit influences, and verify content/history rather than merely visible controls.
- [x] Implement native labeled forms and confirmation dialogs with descriptive text, keyboard cancellation and focus restoration. Keep the Properties panel behavior and both themes. Add all labels in English, Simplified Chinese, Japanese, French and Spanish.
- [x] Implement bone list, local TRS creation inputs, bind-space vertex/weight map and numeric influence rows. Draw current bone links/points using `getBonePoints`; overlay selection must not start a layer drag.
- [x] Serialize model content operations. Capture selected document identity, layer/model path and resource version before async read/stage; reject stale commits. Stage bytes before the single history transaction. Failed staging leaves the current document intact.
- [x] Track draft/load/operation promises. Flush valid drafts on native/content/selection barriers, keep invalid input visible and provide explicit Revert. Avoid re-rendering focused fields while they are dirty. Model refresh during a resource commit cannot wait on the commit queue it is completing.
- [x] Verify minimum 850×540 layout in all five languages with Timeline open/closed, local-only UI state, focused input, rapid actions, stale operations and resource errors.

## Task 4 — Full acceptance and delivery

Files: `Editor/Web/test-model.mjs`, additional workspace acceptance helpers, `Tests/EditorRuntimeHarness/main.mm`, `scripts/test-editor-native.py`, `docs/editor-model-workspace.md`, READMEs.

- [x] Exercise real user forms plus pending-draft save/freeze, undo/redo, deletion cancellation, layer/mesh/vertex switching, save acknowledgement and reload. Assert the GPU capacity is measured on actual MDL draws.
- [x] Preserve the known model fixture's animation through hierarchy edits and exported loose/PKG playback in Main's CEF runtime. Verify weight edits actually change deformation, then undo to the known animated export fixture.
- [x] Regenerate and verify all offline resources, run JS and relevant native/product/source-export checks, inspect the final diff and run the changed-file privacy gate (retaining the exact pinned upstream license attribution).
- [x] Request independent plan/code review, fix material findings and rerun affected checks. Update English documentation with actual features, semantics, limitations and source references.
- [x] Commit with the configured real email and submit an English PR against the merged main. PR #15 is already merged; this new workspace PR is not automatically merged by that authorization.


## Verification record

- PR #15 was merged first; this branch starts from main `5014fa3` with a clean 46-check baseline.
- Independent plan and code review approved. Two material findings were fixed: failed model inspection no longer traps workspace navigation, and Timeline/native content operations prepare model drafts. Real-browser regression cases cover both fixes.
- 55 JavaScript checks passed, including 24 model/capacity/hierarchy/resource checks. All 24 offline resources reproduce; playback engine and existing editor API hashes remain unchanged.
- Full browser/native CEF acceptance passed, including five-language minimum-window layouts, both themes, real model UI edits, injected read failure, unsupported-data recovery, measured GPU capacity and resource history.
- The native Model workbench passed actual AppKit typing, unblurred freeze, staged MDL name/hash verification, saved acknowledgement and undo/redo. Both user-authored model export forms passed Main's bind-position and intermediate-deformation pixel assertions. All pages closed normally and the runtime shut down once.
- Product/source checks passed: 3 Editor product tests, 42 product-configuration tests and 16 public-source export tests. No full application-suite result is claimed.
- An initial combined run failed because a layout helper changed the viewport used by later pixel comparisons (368 versus 612 canvas pixels wide). It now restores its entry viewport; the pixel tolerance and known deformation assertions were retained. The subsequent complete native run passed.
- Changed-file privacy scan passed for all 46 changed files without detector exemptions. No merge or release of this new PR is authorized by the previous PR's merge request.

Delivery: [PR #16](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/16), submitted against main and not merged.
