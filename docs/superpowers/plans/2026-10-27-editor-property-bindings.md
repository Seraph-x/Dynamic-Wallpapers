# Editor Property Bindings Implementation Plan

> **For agentic workers:** Use `executing-plans` for implementation and `requesting-code-review` before integration. Continue the authorized Editor work without changing the wallpaper main program.

**Goal:** Connect user-property definitions to layer fields through an explicit, undoable Editor binding dialog, then save/reopen/export and play the result through the existing renderer.

**Architecture:** A pure Editor binding module inspects supported layer fields and property metadata, then edits only the selected scene field through `SceneDocument` history. Existing property validation is reused. The inspector opens a modal after flushing existing drafts; the modal owns an immutable document/field capture and explicit Apply/Remove/Cancel. Open or failed dialogs block native capture until resolved. No Main, shared bridge/runtime, root package or persistent override changes.

**Tech Stack:** Offline ES modules, native HTML forms/dialogs, existing WebWallGL pin, Node/Playwright/CEF and Editor Swift tests.

## Scope and engine contract

- Text and font-size bindings use saved defaults on scene load. The pin does not rebuild them from temporary live property updates; the UI and docs state this explicitly. No replacement renderer or fallback is introduced.
- Fields: layer visibility, opacity, RGB color; text and point size on text layers. Unsupported fields keep their existing inspector behavior.
- Direct declarations: bool → visibility; slider → opacity/point size; color → RGB color; textinput or compatible combo strings → text. Combo → visibility uses the renderer's native `{user:{name,condition},value}` condition form.
- Preserve the original literal/base `value`. Validate declaration/default and target value domain before binding. Expose the pin's actual `valueShape` compatibility rule, including numeric-looking text bases; do not silently change fallback values or coerce identifiers.
- Combo equality follows the pinned renderer: integer-shaped option values compare numerically. Explain this in the modal and test it against the real renderer. Do not invent alternative equality semantics.
- Replacing a script/animation/user control is an explicit modal confirmation showing the current raw field and the controls to be replaced. Remove only the selected field's known control keys; preserve unknown wrapper metadata. Undo restores the complete original field. Remove binding deletes only `user`, retaining the exact base and any remaining metadata/control fields.
- Existing malformed/unsupported bases, missing definitions and incompatible definitions remain visible with their real reason. Opening inspection never mutates content. Changes to definition defaults can make an existing binding invalid; show this explicitly when inspecting rather than rewriting the definition or binding.
- Freeze/save/export/selection flushes wait for queued dialog operations. An unresolved dialog blocks capture; thaw/cancel recovers. Fix the confirmation target at open, validate the captured identity before apply, and disable all modal submission controls synchronously while running.
- Keep exact Unicode property names, literal/script bytes, unknown scene/project/declaration fields and immutable source files.

## Task 1: Pure binding transactions

Files: `Editor/Web/property-bindings.mjs`, `property-bindings.test.mjs`, `document.mjs`, `build.mjs`.

- [x] Write tests for supported fields/types, exact keys, combo condition/equality, absent default fields, invalid/missing/duplicate layer IDs, incompatible bases/defaults, explicit replacement, removal and unknown preservation.
- [x] Run `node --test Editor/Web/property-bindings.test.mjs`; observe missing API failures.
- [x] Add a pure `inspectPropertyBinding(document, selection)` and `editPropertyBinding(document, edit)`; connect `SceneDocument.bindProperty(edit)` to one atomic history operation.
- [x] Re-run focused tests, including exact undo/redo/no-op history and JSON save/reopen.

## Task 2: Inspector binding dialog

Files: `Editor/Web/property-binding-dialog.mjs`, `property-binding-view.mjs`, `property-binding-messages.mjs`, `property-binding.css`, `interface.mjs`, `app.mjs`, `localization.mjs`, `index.html`, `build.mjs`.

- [x] Write a real browser acceptance test that initially fails on missing Bind controls.
- [x] Add labeled per-field Bind controls and a modal with property/default inspection, optional combo condition, original raw field, replacement explanation, Apply/Remove/Cancel and explicit errors.
- [x] Integrate modal pending/error/frozen state with native capture, draft flushing, source navigation and page teardown. Use an immutable capture and synchronous busy controls to prevent repeat actions affecting another target.
- [x] Verify five languages, both themes, 850×540 layout, keyboard/focus/Escape, invalid and pending captures, stale captures, repeated actions and exact undo/redo.

## Task 3: Persistence, playback and publication

Files: browser fixtures/tests under `Editor/Web`, Editor-only tests under `Editor/Tests`, test-only CEF harness/runner, `Editor/README.md`, `docs/editor-property-bindings.md` and property-definition guide.

- [x] Save/reopen and export actual authored loose/PKG projects. Check exact metadata, fallback values and wrapper/script bytes.
- [x] Verify direct bindings and combo visibility through the actual pinned runtime, GPU output and independent callback observations, including live property updates and removal behavior. Test native dialog barriers with valid command payloads and specific errors.
- [x] Run full JS and independent Editor Swift suites, reproducible offline build, existing native acceptance with unchanged 180-second build/60-second phase budgets and relevant packaging/config checks.
- [x] Request independent review; fix findings with regressions. Update docs and run a changed-source privacy gate. Assert no changes under root `Sources/`, `Resources/` or `Package.swift`.
- [ ] Commit using the configured real identity, create an English PR, verify exact tested head/check status, then merge under the existing authorization.

## Progress

- Isolated worktree starts at main `83290c3` (merged PR #36). Baseline is unchanged.
- Modern Web Guidance search for typed binding selection/replacement returned a low-similarity dialog guide; the guide catalogue and `forms` are being checked. Preserve the local offline transport; no website fallback is introduced.

- Transactions passed red/green; independent review findings for malformed current descriptors and hidden raw data are fixed with regressions. Empty property names are rejected because the pin cannot resolve them.
- Exact stale field/declaration/document captures are tested through the same production guard used by the dialog (10 focused tests passed); unrelated changes remain valid.
- Workbench five-language/theme/850×540 and independent runtime numeric-choice/text-shape/removal tests passed.
- Native targeted CEF authoring and actual loose/PKG pixel playback passed, including real text layer initial state and its explicit load-time capability boundary. Test text was moved away from visibility/color probe regions after a genuine pixel failure exposed overlap; pixel assertions were retained.
- One native store persistence test passed with a 60-second execution budget; a stale package is explicitly rejected rather than substituted for a new encoding.

- Final full native runner passed 46/46 phases with 21 normal CEF shutdowns, including final source capture guard and readable compatibility reasons. All budgets retained.
- Full JavaScript suite passed 424 tests; offline build reproduces 86 workbench + 10 preview resources. Packaging/configuration/public-source tests and changed-source privacy gate passed.

- Final complete independent Editor Swift suite passed 90 tests, zero failures. Publication follows exact-head verification and the final staged-source privacy gate.
