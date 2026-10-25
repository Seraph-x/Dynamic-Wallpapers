# SceneScript workspace implementation plan

> **For agentic workers:** Use executing-plans task-by-task; checkboxes track completion.

**Goal:** Deliver the first usable source workspace, then independently deliver code-editor tools and linked diagnostics as subsequent PRs, verifying and merging each as the user authorized.

**Architecture:** Reuse source-only prepare/apply contracts and the script-disabled workbench. A temporary draft is separate from document history. Explicit Apply and all existing flush boundaries compile and commit a valid draft once, or expose an error without losing its text. Revert discards the draft. The native snapshot host executes only captured revisions. No source evaluation, new native write endpoint or custom animation runtime is added.

**Tech stack:** existing JavaScript workbench, pinned WebWallGL compiler, Swift/AppKit/CEF snapshot host. No new dependency in the first PR.

## Approved scope and delivery

The approved 2026-10-24 advanced-editor specification and the user's 2026-10-26 instruction authorize all remaining IDE features and self-merging each verified English PR. PRs 28–30 already delivered compiler/source transactions, independent snapshot execution and workbench execution migration. Breakpoint debugging is outside the approved scope.

1. Source workspace: layer/property selection, supported source anchors, explicit read-only reasons for incompatible bindings/unknown metadata, source draft, Check/Apply/Revert/Remove, native flush barriers and history/save/export integration.
2. Offline code-editor experience: syntax highlighting, pinned SceneScript API completion, lifecycle templates and find/replace without source evaluation.
3. Runtime diagnostic navigation: retained issue list, precise captured source identity/line mapping when actually available, visible unmapped diagnostics, stale-preview distinction, and complete final user/API documentation. Never invent locations or assume current source matches an older snapshot.

Each PR must preserve five languages, light/dark appearance, minimum-window layout, existing model/timeline tools, loose/PKG compatibility and Main independence. A feature is accepted only through edit, undo/redo, save/reopen, both exports and actual Main playback.

## Task 1 — draft contract (TDD)

Files: new `Editor/Web/script-draft.mjs`, `script-draft.test.mjs`.

- [x] Write missing-feature red tests against the real SceneDocument/compiler. Expose ScriptDraft(document, selection), state/source/dirty/diagnostics, setSource, check, apply(document), remove(document), revert(document).
- [x] Retain the original document identity and snapshot; reject stale/replaced documents before commit. Check never executes source or edits history. Syntax failure keeps the draft and old committed source. Actual compiler messages/line and NO_ENTRY warning stay observable.
- [x] Apply uses the existing checked proposal exactly once within editor.change, creates one history step, preserves wrappers/unknown fields/CRLF/Unicode; no-op text adds no history. Unmodified imported source bytes stay exact; textarea display normalization must not rewrite CRLF. Actual input retains a consistently CRLF source style; mixed imported line endings remain exact until edited and edited mixed text follows the explicitly documented LF policy. Test real DOM input/undo and exports. Removal is explicit, preserves the base and other metadata. Revert can deliberately reload the current source after a conflict; no silent overwrite.

## Task 2 — authoring workspace and barriers

Files: new `script-workspace.mjs`, `script-workspace-view.mjs`, `script-workspace-messages.mjs`, `script-workspace.css`; app/index/build/localization; small ModelWorkspace activation ownership change.

- [x] Add a Script workspace beside Properties/Model. Keep layer list and edit canvas, widen source panel when active; scroll code horizontally rather than growing the window. Use labelled native select/textarea/buttons, plain-text diagnostics, aria-invalid and described errors after validation. Do not intercept ordinary typing/IME/Tab or input undo.
- [x] Source target options cover registered properties and layer effect visibility; expose unknown inline scripts read-only with their structural paths. Unsupported bindings remain intact with an explicit reason. Selecting another source/layer/workspace flushes valid drafts or blocks with the old selection/text intact.
- [x] ScriptWorkspace API: update(document,layerId), flush(), activate(), deactivate(), setFrozen(), destroy(), dirty/error. A serial operation queue captures accepted work before native freeze. Own error recovery clears only the script's error, leaving unrelated tool failures visible.
- [x] Wire script flush into act/select/canvas drag and native snapshot/freeze/undo/redo/load/resource/import barriers. Flush before editor.command freezes runtime; freeze disables user input immediately. Native dirty state must include source drafts; invalid draft prevents successful save/preview and unconfirmed discard. Existing close Save/Discard/Cancel stays authoritative: explicit Discard may close, while Cancel or failed Save must thaw and preserve text. Test draft-only dirty status and all three close choices. Mark-saved and redraw must not erase pending source text or bypass a source conflict.
- [x] Coordinate workspace buttons in app rather than competing asynchronous event listeners. Retain ModelWorkspace programmatic activation for glTF after flushing source. No hidden source drafts or fabricated success paths.
- [x] Add all five translations and offline resources/provenance. Follow modern-web-guidance accessibility rules.

## Task 3 — real browser/native acceptance

Files: new `Editor/Web/test-script-workspace.mjs`, new `Tests/EditorRuntimeHarness/ScriptWorkspaceAcceptance.h`; native main/runner.

- [x] Browser tests use actual UI and compiler: edit/check/apply/revert/remove, syntax failure, unavailable bindings, unknown source, valid and invalid navigation, local textarea undo vs document history, native focused freeze/snapshot and recovery. Probe code must remain unexecuted and resource staging zero.
- [x] Browser save/reload and loose/PKG artifacts preserve exact independently expected script bytes/wrappers; actual separate scene playback demonstrates the authored script. Test five languages, both themes, Timeline and minimum size without overflow.
- [x] Native test enters source using real attached CEF input, exercises the actual authoring command barrier and inspects canonical history. Saved exported fixtures run through Main loose/PKG with known pixels and no Editor bridge. Distinguish harness receiver coverage from existing actual Swift owner/store tests; do not claim the harness substitutes for the production owner.
- [x] Add separate 60-second browser/native phases, retain all earlier positive playback checks, and run the entire fresh-directory suite. Test-only isolated keychain remains confined to EditorNativeTests.

## Task 4 — review, docs, PR and merge

- [x] Independently review plan, then substantial implementation and draft/barrier races. Fix important findings with regression tests.
- [x] Update READMEs and source/validation documentation with actual behavior, remaining next-PR scope and upstream attribution. Use docs-generator and sanitized-public-export on the changed-file export; user-requested real commit email overrides the skill's noreply default.
- [x] Verify all JS/offline checks, independent Editor build/tests, Core and product/config/export tests, and all fresh native phases. Check final diff and source/preview runtime byte preservation.
- [x] Commit as Seraph-x with the configured real email, publish an English PR, verify remote head, merge after all checks, synchronize clean local main. Then start the next planned PR without another approval question.

## Verified first-PR delivery record

- Starting main: PR #30 merge `0094b85ae3743b71fa1cb99de262aa429e803a96`.
- Draft/compiler/runtime/view tests observed missing-feature red failures before green. Additional regression checks caught malformed effect metadata, implicit draft rebasing and native dirty notifications.
- Independent review corrected warning persistence, repeated/unchanged Apply validation and no-op empty textarea Undo. Close tests preserve Save/Discard/Cancel semantics; export tests keep the saved revision frozen through actual publication.
- Final: 373 JavaScript tests; 75 offline resources (67 workbench + 8 preview); independent Editor build and 30 tests; root build and 41 Core tests; 3 product, 42 configuration and 16 public-export checks.
- The first complete native run hit its unchanged browser timeout. Reproduction caught a read-only Model inspection error wrongly blocking Undo. The corrected UI retains that diagnostic without treating it as a pending content edit; strict programmatic activation still rejects failed inspection.
- Final fresh-directory 31-phase browser/native run passed, along with repeated focused browser/native source authoring, both Main export forms and exact source bytes. Test-only keychain remains confined to EditorNativeTests.
- Main and independent scene runtime bytes remain unchanged. No new source-evaluation endpoint or production test mode was introduced.

Merged delivery: [PR #31](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/31), merge commit `732be59a4eba5d6c763eeba8a7c29a5013498194`. The offline code tools follow in their separate implementation plan.
