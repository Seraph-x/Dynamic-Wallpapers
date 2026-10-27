# Editor Property Definitions Implementation Plan

> **For agentic workers:** Use `executing-plans` for implementation and `requesting-code-review` before integration. This continues the approved Editor work; the wallpaper application is outside this change.

**Goal:** Author user-property declarations and defaults in the independent Editor, with undo/redo, save/reopen, export and real playback validation.

**Architecture:** Edit only `project.general.properties` through `SceneDocument` history. Reuse the existing property catalog as an unchanged, build-copied Editor module; do not edit Main or its playback/bridge files. A Project workspace owns explicit Apply/Revert drafts and participates in existing freeze/save flushing. Existing keys and types stay stable; creating a copy requires a new exact key. Preserve unknown metadata, scripts and bindings.

**Tech Stack:** Offline ES modules, native HTML forms/dialog, existing WebWallGL engine, Node tests and Playwright/CEF acceptance.

## Scope and data contract

- Support bool, slider, color, textinput and combo declarations. Editable fields: display text, default value, order, slider bounds/step and combo option labels/values.
- New declarations use explicit user-chosen keys. Reject empty keys, collisions including preset names, and the pinned engine's unsupported `__proto__` key. Preserve exact Unicode identity.
- Existing unsupported/malformed/conditional/preset-only declarations remain visible read-only, with a reason. Invalid metadata inspection must not prevent ordinary canvas editing.
- Copy preserves unknown fields. Update permits only known editable fields and retains unknown fields. Failed edits are atomic and do not create history.
- Delete requires a dialog explaining that script/binding references are retained and may stop resolving. No guessed reference rewriting or silent conversion. Undo restores exact declarations.
- Drafts are visibly unsaved; valid drafts flush before snapshot/save/export/selection/workspace changes. Invalid drafts block capture with an explicit error and can be reverted. Open confirmation dialogs block capture until resolved.
- No persistent Main overrides, Main UI, renderer changes, app installation or release.

## Task 1: Definition transactions

Files: `Editor/Web/property-definitions.mjs`, `property-definitions.test.mjs`, `property-catalog.mjs`, `document.mjs`, `build.mjs`.

- [x] Write tests using real `SceneDocument` for all five types, optional metadata, exact-key collisions, immutable key/type, unknown preservation, unsupported rows, invalid atomic edits, copy/delete and undo/redo/save/reopen.
- [x] Run `node --test Editor/Web/property-definitions.test.mjs`, observe missing feature failures.
- [x] Implement `editPropertyDefinition(project, edit)` returning an owned project; `SceneDocument.propertyDefinition(edit)` applies it inside `#change`.
- [x] Build-copy the unchanged Main catalog to Editor's `property-catalog.mjs`; the source wrapper reexports the same module for Node tests.
- [x] Repeat targeted tests and all existing document/property tests.

## Task 2: Project workspace

Files: `Editor/Web/property-workspace.mjs`, `property-workspace-view.mjs`, `property-messages.mjs`, `property-workspace.css`, `app.mjs`, `index.html`, `localization.mjs`, `build.mjs`.

- [x] Add browser acceptance covering missing Project workspace, real create/edit/copy/delete, errors, revert, capture and undo/redo.
- [x] Implement labeled type-specific controls and accessible option rows. Use native constraints and interaction-delayed error styling; do not show errors while initially typing.
- [x] Integrate draft dirty/error/frozen/pending state, serialized edits, explicit Apply/Revert, native command flushing and workspace transitions.
- [x] Add five-language messages and responsive light/dark styling using existing theme tokens. Keep existing three workspaces usable.
- [x] Run browser acceptance with the pinned full browser, verify minimum window layout, keyboard submission/focus and screenshots.

## Task 3: Persistence and playback verification

Files: browser acceptance and fixtures under `Editor/Web`, `scripts/test-editor-native.py` if new runner phase is needed; Editor-only native test helpers if necessary.

- [x] Export actual authored loose/PKG projects through the real Editor encoder; reopen them and verify all definitions and unknown metadata.
- [x] Exercise exported defaults in the unchanged real scene runtime, including a bound property and SceneScript callback. Preserve unsupported metadata/errors explicitly.
- [x] Run the full Node suite, reproducible offline build check, existing native acceptance suite under unchanged 180-second build/60-second phase budgets, and relevant package/static checks.
- [x] Document features/limitations in `Editor/README.md` and `docs/editor-property-definitions.md`; correct the previous preview-only limitation.
- [x] Request independent code review, address findings, run changed-source privacy gate and inspect final diff. Assert no changed paths under `Sources/`, `Resources/` or `Package.swift`.
- [ ] Commit with configured real identity, create an English PR, verify exact tested head and merge when checks pass under existing authorization.

## Progress

- Prepared clean isolated worktree at main `6dc8311`; no production changes before the red test.
- Modern Web Guidance consulted: `forms`, `validate-input-after-interaction`; use visible labels, semantic submit controls, errors announced after submission, `:user-invalid` styling, no identifier autocorrection. This desktop CEF app uses its existing local command transport rather than adding website submission fallbacks.

- Transaction red/green completed; 414 JavaScript tests pass.
- Browser authoring/export/inspection/error cases passed; expanded five-language minimum-window checks are included in the full runner.
- Two real native persistence tests passed, including exact Unicode keys and both export metadata paths.
- Independent review found a repeated deletion race; regression reproduced it, and immutable confirmation identity plus synchronous dialog-button disabling fixed it. Re-review approved.
- Main/shared production paths remain unchanged. Offline build reproduces 81 workbench + 10 preview resources; model API bundle changes because its existing document dependency now includes definition transactions.

- Fresh full acceptance completed: 43/43 phases, 20 normal native CEF shutdowns. A strengthened native barrier helper was rebuilt and its complete property-definition mode passed separately under the same 60-second budget.
- Packaging checks: 5 Editor audio packaging, 42 app packaging, 42 product configuration and 16 public-export tests passed. Changed-source privacy gate clean; no Main/shared production changes.

- Full independent Editor Swift suite passed: 89 tests, zero failures. All code and test verification is complete; publication follows these checks.
