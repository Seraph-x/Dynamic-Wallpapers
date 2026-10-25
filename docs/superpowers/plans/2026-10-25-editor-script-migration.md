# Separate workbench editing from SceneScript execution

> **For agentic workers:** Use executing-plans task-by-task; checkbox steps track completion.

**Goal:** Stop imported SceneScript from executing in the authoring page and provide a direct, localized Run preview action using the independent native snapshot host.

**Architecture:** Every workbench createScene call uses the pinned native `scripts:false` option. Property curves and MDL animation continue in edit mode; source wrappers/resources stay unchanged. A persistent mode explanation and semantic button distinguish this canvas from actual script playback. A strict payload-free Editor preview-request event invokes the existing native snapshot path, with no caller-supplied paths/source/commands. Only independent scene pages run SceneScript. Source Apply/IDE UI remains a subsequent PR.

**Tech stack:** pinned WebWallGL 3.0.0, existing JS workbench and native scene host, strict CEF Editor protocol, Swift/AppKit.

## Approved design

The approved advanced-editor roadmap requires script execution separated from the workbench native write/control channel. PR #28 delivered source/compiler contracts and #29 delivered a usable separate preview window. This PR completes the mount-time execution migration before a source Apply interface is connected. The change is visible: the edit canvas explicitly does not run SceneScript and provides Run preview, which captures current valid edits without saving. Main playback and the independent snapshot runtime remain script-enabled. No fallback to executing scripts in the workbench is permitted.

## Task 1 — strict native preview request (TDD)

Files: `Sources/WebWallpaperBridge/SceneProtocol.mm`, `WebPage.mm`, public header; `Editor/Sources/EditorApp/EditorWindowController.swift`; protocol tests.

- [x] Add a missing-feature red protocol test for `{type:'preview',session,generation}`. Accept exactly those fields; reject payload/path/source/id/command extras, stale identities and invalid generation. Retired sessions ignore it using existing rules.
- [x] Expose optional `onEditorPreview` callback on native Editor pages only. Dispatch through the existing event drain. A missing handler is an explicit error. No arbitrary JS, native command or path argument is introduced.
- [x] The owning Editor controller invokes its existing previewSnapshot path, preserving freeze/flush/thaw, valid draft checks, resource ownership and page-before-directory cleanup. Scene-only pages still reject Editor events/commands; no source writing capability is added to preview pages.
- [x] Verify actual owning-controller wiring with explicit injected external page/window services in native unit tests (production defaults remain real DWWebPage/native window). Exercise callback to previewSnapshot, valid snapshot capture without save and invalid-draft rejection/thaw; do not substitute a callback counter/manual scene creation as evidence of the controller path. Keep test fixtures out of production runtime selection.

## Task 2 — no execution in edit mode and a usable run action (TDD)

Files: `Editor/Web/runtime.mjs`, `gltf-preview.mjs`, focused runtime/import-preview tests, `app.mjs`, `index.html`, `editor.css`, localization; copied workbench resources/provenance.

- [x] Observe a failing runtime test before setting scripts:false. Assert all initial/rebuilt/loaded/undo/redo workbench mounts receive false, while the scene document and exported source remain unchanged. No renderer fake is used to claim pixel success.
- [x] Use the supported option directly on every workbench mount. Do not strip/rewrite script wrappers, user bindings, curves or resources, and do not enable setLayerScript hot evaluation. Keep standard property and skeletal animation, selection and editing functional.
- [x] Cover the glTF import subpreview too: it shares the privileged authoring page and must also pass scripts:false, even though its converted scene is locally generated. Audit all authoring createScene call sites and test both options.
- [x] Add a persistent localized edit-mode explanation and native semantic Run preview button with accessible description. The existing play/pause labels describe animation playback. Run reports the fixed preview event using the existing session identity; frozen/closed workbenches reject the action visibly. Failed transport surfaces normally. No programmatic fake click or new keyboard-only handler.
- [x] The Run action awaits only event transport acknowledgement, never native preview completion, so native freeze cannot wait on its own pending action. Review Timeline/IK/frame-event help text in all five languages and remove old promises that edit playback executes or restarts SceneScript.
- [x] Verify five languages, light/dark and minimum window with Timeline; focus and native button activation; no content/history edits from mode UI or preview requests. Use modern-web-guidance for the client changes.

## Task 3 — real scripts, exports and migration regressions

Files: new `Editor/Web/script-migration-fixture.mjs`, `test-script-migration.mjs`; `Tests/EditorRuntimeHarness/MigrationAcceptance.h`; main/runner; adapt existing event acceptance where it formerly expected execution in the Editor page.

- [x] Author a real fixture with recognizable top-level/lifecycle source probes at object/text/effect/material anchors supported by the pinned engine. Demonstrate the exact fixture executes those probes in the independent script-enabled scene host; unknown script-like metadata stays data. Do not substitute unsupported anchors to manufacture no-execution success.
- [x] Actual browser/CEF authoring pages load/seek/edit/undo/redo/reload without source probes executing, resource stages or source network calls. Keep exact original inline/resource bytes and export loose/PKG unchanged. Verify real non-script curves/MDL samples still animate.
- [x] Browser Run preview emits exactly one fixed request and no content mutation; native callback dispatch reaches the snapshot-host path. Native independent playback uses the captured revision in another origin and still renders real script changes, while authoring snapshot/history remain intact. Authoring endpoints remain denied in preview.
- [x] Update old frame-event tests to assert script callbacks do not execute in edit mode; retain binary event CRUD/history/order assertions and positive callback playback in independent/Main scene pages. Do not delete positive playback coverage to make tests pass.
- [x] Add separate browser/native migration phases with existing 60-second budgets; run full fresh-directory native acceptance, preserving all earlier phases and test-only isolated keychain scope.

## Task 4 — independent review, docs and English PR

- [x] Independently review the plan and source/bridge execution boundary. Correct findings with focused regression tests.
- [x] Update both READMEs plus source/preview/native-testing docs: distinguish edit animation from independent script playback, explain Run action and remaining full IDE work, retain WebWallGL attribution. Do not claim OS-process isolation or full IDE completion.
- [x] Verify all Node/offline checks, independent Editor build/tests, focused core/protocol checks, product/config/export checks and full real browser/native phases. Report actual counts; no full Main application suite claim.
- [x] Scan a changed-file copy with the sanitization skill, retaining explicitly requested real author email; inspect final diff.
- [ ] Submit an English PR and leave it open. PR #29 was merged before this work.

Plan reviewed with the glTF subpreview, transport-only acknowledgement, actual controller wiring/draft checks and help-text audit additions above.

## Verification record

- PR #29 merged as `1678f294cf8b82abb29dfa62399b874513d510e1` before this branch.
- Runtime/protocol/owner request tests observed missing-feature failures before implementation; the final checks pass.
- 353 JavaScript tests; 70 offline resources (62 workbench + 8 preview).
- Independent Editor build and 19 tests; root test build and 41 Editor Core tests.
- 3 Editor product, 42 product configuration and 16 public-source export tests.
- Corrected native migration target and the full fresh-directory 29-phase browser/native run passed. The test-only isolated keychain stays out of production.
- Independent production-boundary review found no remaining blockers. No Main scene or independent preview runtime bytes changed.
- A changed-file export passed the sanitization gate; final staged content is scanned again before publishing. The user-requested real commit identity is retained.
