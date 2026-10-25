# Offline SceneScript code tools implementation plan

> Execute after the checked Script workspace PR is verified and merged. Existing approved roadmap and latest user instruction authorize implementation, English PR and self-merge without another interview.

**Goal:** Replace plain textarea with a usable offline CodeMirror editor, add truthful SceneScript completion/lifecycle templates and find/replace, keeping every draft/history/export contract.

**Architecture:** Bundle pinned CodeMirror modules into an offline resource; no CDN or source evaluation. A focused CodeEditor adapter owns text editing/selection/history/find, while ScriptDraft/Workspace retain committed project ownership. Completion/templates are a positive catalogue tied to actual WebWallGL3.0.0 factory/dispatch code; unsupported anchor/host combinations show their reason rather than fake callbacks.

## Task 1 — pure API catalogue and templates

Files: new Editor/Web/script-language.mjs + script-language.test.mjs; new docs/editor-script-api.md.

- [x] Use the actual pinned sandbox factories and dispatch sites as evidence; publish the supported catalogue in docs/editor-script-api.md with relative npm source paths/function names and provenance pins, never private research paths.
- [x] Red tests then implement globals/member completion for engine, input, typed thisLayer, thisScene conservative methods, Vec/WEMath/WEColor/WEVector. Avoid engine unknown-member no-op stubs, text dummy scene methods and host-disabled media operations. Distinguish scalar/vector/string/bool anchor values.
- [x] Provide supported init/update/user-properties/cursor/animation/resize/timer patterns and audio-update pattern; pair text init/cursor/timer with passthrough update so runtime actually retains them. Media category must explicitly explain current media:null host limitation. Restrict effect cursor and unsafe animation-scalar templates with clear reasons. No fictional dispose/timer/audioChanged hooks or visible console promise.
- [x] Each inserted template is real compiler-valid, never executed for completion/check; use complete starter templates with an explicit Replace draft / Cancel confirmation whenever current text is nonempty, retaining the old source in local undo. Empty drafts may use a starter directly. Never silently append duplicate lifecycle declarations or overwrite existing functions. Template insertion is a draft edit, not immediate Apply. Check actual engine execution for all provided templates and meaningful typed branches, including retained init/update, user-properties, audio/silence, bool/text, timer/resize/cursor and animation where offered. Completion/template capability limits do not make existing author-written source read-only: editability remains determined solely by the existing anchor/base/binding contract. Initial-only host user properties and preview zero spectrum must also be documented. Select text sandbox only for target===text, not every field on a text layer.

## Task 2 — offline code editor adapter and UI

Files: new code-editor-entry.mjs + code-editor.mjs; build.mjs, package.json/lock/provenance/notices, workspace view/controller/CSS/messages.

- [x] Pin npm registry versions researched: codemirror6.0.2, @codemirror/lang-javascript6.2.5, @codemirror/autocomplete6.20.4, @codemirror/search6.7.2, @codemirror/view6.43.15, @codemirror/state6.7.6 (and direct imports as required). Lock transitive dependencies. Keep licenses/provenance, assert no external bundle imports and reproducible offline asset hashes.
- [x] Red real-browser missing-feature assertions before UI implementation. Use CodeMirror's language highlighting, local history, bracket handling, search/replace panel and completion extension; do not build a fake hidden-textarea success path.
- [x] Small adapter owns read/set text, onChange, editable/frozen, internal focus and destroy. Public source selection/line reveal belongs to the subsequent captured-diagnostics navigation PR. Keep raw source distinct from normalized CodeMirror text; call setSource only on actual docChanged. Only reset text/history on a source selection change or actual external source replacement, preserving history for unrelated Timeline edits, never input/render/check/apply/mark-saved/theme/freeze/completion UI updates. Preserve no-input CRLF/mixed source and current consistent-CRLF input policy.
- [x] Keep native labelled source region, accessible editor content, visible focus, standard Tab navigation and no global Undo interception in contenteditable. Find and completion shortcuts stay editor-scoped. Template/select/buttons translated in five languages; minimum window and both themes keep canvas/controls usable.
- [x] Frozen/closed/read-only adapters set both EditorState.readOnly and EditorView.editable; template/replace-all/completion transaction paths also respect locking. Test a pre-open completion popup, IME composition and focused search panel at native freeze. All source edits flow through the same draft notification; selection-only transactions do not dirty content. Frozen/closed/read-only adapters cannot accept edits. Source draft dirty, invalid source, Apply/Revert/Remove, local Undo vs document Undo, native freeze and export all remain authoritative.

## Task 3 — regression and acceptance

- [x] Migrate old source workspace tests to operate the visible real editor (public CodeMirror APIs only for read-only test inspection, never native source writes as a fake input). Retain all old history/source-byte/readonly/close/export assertions; don't delete coverage to make the widget pass.
- [x] New browser/native phases use real completion selection, template insertion, local undo/redo, search/replace/Replace all, keyboard selection, syntax highlighting DOM and frozen behavior. Every resulting source goes through Save/reopen/loose/PKG and real Main pixels.
- [x] Native tests use actual attached CEF typing/selection and real Enter. If smart indentation changes typed bytes, assert independently expected actual behavior, don't programmatically assign model text or weaken byte checks.
- [x] Run all JS/offline checks, independent Editor build/tests and Core/product/config/export checks. Full fresh-directory browser/native runner retains all earlier phases/budgets; only test host uses isolated keychain.

## Task 4 — review, docs, publish and merge

- [x] Plan review then implementation review focused on source data loss, readonly/frozen editor behavior, composition, local/document histories, escape surfaces and truthful API hints.
- [x] Update both READMEs/source/API/validation docs, credit CodeMirror alongside pinned WebWallGL, distinguish completion from runtime/type guarantee and retain explicit unsupported host/hook details.
- [ ] Gate changed-file public export, real author email, final diff and checks; submit English PR, verify remote exact head, self-merge only verified content, sync clean main. Then implement source-linked runtime diagnostics as the final planned PR.


## Plan review resolutions

- Source editability stays independent of the positive completion/template capability catalogue.
- A text layer's non-text property may use the object sandbox; classify by the actual target dispatch.
- Keep raw source and normalized CodeMirror text separate, preserve local history for Apply/mark-saved/diagnostics/theme and unrelated content edits, and notify only actual document changes.
- Enforce state readOnly plus DOM editable and guard all insertion/replace/completion paths; cover active popup, IME and search focus at freeze.
- Complete starter templates replace nonempty drafts only after explicit confirmation and remain one undoable local edit. No duplicate lifecycle declarations are silently appended.
- Document actual current host media restrictions, initial-only verified property delivery, preview zero spectrum and upstream value/sandbox limitations; all offered template paths need real-runtime acceptance, not just compiler entries.

## Review and regression record

- Real browser red/green covered equal-text cross-layer history identity, template confirmation freeze/thaw/Cancel, read-only focus/project Undo, a fixed-clock template-to-typing history boundary, and raw-only mixed-line-ending source replacement after project Undo.
- CodeMirror native entry is actual attached CEF keyboard input. Tests acknowledge focus/selection and the pinned completion interaction window; generated closing brackets are removed by a real keyboard selection/deletion before exact independent source assertions. No hidden textarea or programmatic source write substitutes for native input.
- Actual pinned factory tests distinguish Vec3 from vector snapshots/live angle proxies and reject nonexistent helper members. Supported templates execute through the real renderer; compilation alone is not runtime validation.

Verified delivery: 384 JavaScript tests; independent Editor build and 30 tests; 41 targeted Editor Core tests; 80 reproducible offline resources (72 workbench, eight preview); full fresh-directory 34-phase browser/native acceptance; three product, 42 configuration and 16 public-source checks. Main/independent preview runtime files remain unchanged.
