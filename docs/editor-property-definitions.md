# Author user properties

Use **Project** in the Editor's right sidebar to edit property definitions and
defaults saved in `project.json` → `general.properties`. These defaults travel
with saved projects and loose/PKG exports. Live values in an independent
[Run preview](editor-preview-properties.md) remain temporary.

## Create or edit a definition

Choose **New property**, enter an identifier, select a type and its default, then
choose **Apply changes**. Add a display name and optional display order if needed.
Existing identifiers and types are fixed; **Copy property** creates a new
identifier while preserving the source definition's other metadata.

| Type | Default and settings |
|---|---|
| Boolean | True/false checkbox. |
| Number | Finite number, optional minimum, maximum and positive step. No invented bounds or clamping. |
| RGB color | Three numbers from 0 to 1, for example `0.2 0.4 0.6`. |
| Text | Exact text, including an empty value. |
| Choice | Editable option labels and string values; choose one option as the default. Empty string values are allowed. |

Identifiers are exact strings, including Unicode; duplicate identifiers and
collisions with preset entries are rejected. The pinned renderer cannot deliver
`__proto__` as an ordinary property, so it cannot be created. Other names such as
`constructor` are permitted. Imported unsupported declarations, conditional
definitions and preset-only entries stay visible read-only with their reason.
Malformed metadata displays its inspection error without disabling other Editor
tools. Unknown fields in declarations and choice options are preserved.

Choose **Revert draft** to discard uncommitted input. Valid drafts are applied
before native save, snapshot, export, history navigation or workspace/selection
changes, even if the field still has keyboard focus. Invalid drafts stay visible
and block those captures until corrected or reverted. An open deletion
confirmation must be resolved before capture. Apply, copy and deletion use
ordinary project Undo/Redo; a rejected edit adds no history.

## Delete a definition

Choose **Delete property** and review the confirmation. Only the selected
definition is removed. Scripts, conditions, preset values and binding references
are retained and may stop resolving. The Editor does not guess or rewrite those
references. **Undo** restores the definition.

## Use the saved defaults

Existing scene bindings and `applyUserProperties(properties)` receive the saved
defaults during playback. Use the inspector's separate
[binding dialog](editor-property-bindings.md) to connect supported layer fields;
the Project workspace does not rewrite script source. Scripts remain disabled in the edit canvas; use **Run preview**
to observe callbacks and scene behavior. Main's ordinary wallpaper playback uses
the authored defaults and still has no persistent override interface. This
feature changes only the independent Editor and its offline resources.

## Verify the implementation

Run the focused transaction tests and offline reproducibility check:

```sh
node --test Editor/Web/property-definitions.test.mjs Editor/Web/document.test.mjs
node Editor/Web/build.mjs --check
```

`Editor/Web/test-property-workspace.mjs` exercises the real browser workbench;
`scripts/test-editor-native.py` includes that phase and native CEF property
definition acceptance. `EditorPropertyDocumentTests` verifies real native
save/reopen and both export metadata paths, including two canonically equivalent
Unicode identifiers with different defaults.
