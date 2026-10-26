# Edit inline SceneScript

The Script workspace is an offline CodeMirror source editor with JavaScript
highlighting, local undo/redo, SceneScript API hints, lifecycle starters and
find/replace. Checked drafts retain normal project history/save/export. [Runtime diagnostics](editor-script-diagnostics.md) retain actual issues and
open current or captured source. Breakpoint debugging is
outside the approved IDE scope.

Source never executes in the workbench. **Run preview** captures valid current
edits in an independent script-enabled scene window; applying source does not
restart or change an already captured preview.

## Select and edit a source

Select a layer, choose **Script** beside **Properties / Model**, then choose a
property in **Property / source**. The layer list and canvas remain available.
The source field scrolls horizontally for long lines; the workspace and Timeline
retain the minimum-window layout, light/dark appearances and five UI languages.
Text input and composition use the visible CodeMirror content. Tab moves focus
out of the source editor; local undo/redo stays scoped to its current source.
Read-only source remains keyboard-focusable for selection and copying.

For example, choose a layer's `alpha` target and enter:

```js
export function update(value) {
  return 0.5;
}
```

Use **Check**, then **Apply source**, and **Run preview** to execute it in the
captured scene. The offline checker validates syntax with the pinned engine;
the checker does not type-check API members. Runtime API availability and
rendered behavior still require actual playback.

| Action | Source and history behavior |
| --- | --- |
| Check | Compiles the current text without executing it or changing history; shows actual errors/lines and no-entry warnings |
| Apply source | Checks current text and commits one undoable source edit; identical committed text adds no history |
| Revert draft | Discards pending text and explicitly reloads the current committed source, including after a conflict |
| Remove script | Discards pending text and removes the committed script member in one undoable edit; retains base and other metadata |

An empty source is distinct from no script. Explicit Apply on an empty constant
target creates `script: ''` and displays the checker's no-entry warning. Typing
and locally undoing back to that initially empty field leaves it unchanged;
navigation or freeze does not create a script. Removing from a constant target
with only a pending draft discards the draft without a content-history step.

Use text undo while the source field has focus. Toolbar/native Undo and Redo
operate on project history after processing a valid draft. For example, a source
draft flushed by Undo is first committed and then undone as a document revision.
Selection, workspace choice and Check are not content edits.

## Complete, search and start a script

**Complete** opens a static catalogue for the selected field. For example, type
`engine.ru` and choose `runtime`; vector targets also offer Vec3 members on
`value`, while number and boolean targets do not. Hints neither evaluate source
nor resolve arbitrary expressions. The catalogue omits unavailable host operations
and known no-op engine members; accepting a hint still requires real playback
validation. See the [API catalogue](editor-script-api.md) for actual pinned
members and target-specific limits.

**Find / Replace** opens CodeMirror's search panel. The editor-scoped find
shortcut opens the same panel. Search and match selection do not change a draft;
**Replace** changes one match and **Replace all** changes every matching range.
The changes use the same source draft and local history as typing.

Choose a lifecycle starter, then **Use template**. Empty drafts receive the
complete starter immediately. Nonempty drafts first show **Replace draft /
Cancel**; nothing is installed or executed by this choice. Replacement is one
locally undoable edit, and **Apply source** is still required to commit it.
Starters are never appended to existing lifecycle functions. Finish or cancel an
open replacement question before saving, exporting or previewing; after a failed
freeze and thaw, Cancel restores the normal snapshot path.

Unavailable starters stay visible with their reason. The current app passes
`media: null`, receives only initial user properties, and supplies zero audio
spectrum to the edit canvas. Muted snapshot previews support separately enabled
[system audio response](editor-preview-audio.md). Main can supply real spectrum or silence.
Pinned numeric initialization and animation-dispatch limitations restrict some
starters; they do not make existing author-written source read-only.

Apply, Check, theme changes, save acknowledgements and unrelated Timeline edits
preserve the current source's local history. Changing source identity or receiving
an actual external source replacement resets that local state. Frozen/read-only
editors set both CodeMirror's state and DOM access controls; completion, templates
and search replacement cannot bypass native freeze.

## Apply pending text at operation boundaries

Changing source, layer or workspace, canvas editing, Timeline edits and native
save/preview/history/load/import/resource operations process pending source
first. Valid text is checked and applied once. Invalid text blocks the operation
with its compiler error while preserving the draft and prior selection. Correct
the text or choose **Revert draft** or **Remove script** explicitly.

A draft belongs to the document and revision where editing began. If that
identity or content changes externally, Apply and Remove reject the stale draft;
the editor does not overwrite newer content. Explicit Revert reloads the current
source. Redraw and save acknowledgements retain pending text, and recovery clears
the script's own error without clearing unrelated tool failures.

Native freeze disables user input before flushing accepted operations. Its
close-state reply can contain the valid committed document and `dirty: true`
while an invalid draft remains visible. A subsequent validated snapshot rejects
that draft; it cannot become a successful Save or Run preview. Close retains
**Save / Discard / Cancel**: explicit Discard may close, while Cancel or failed
Save thaws the workbench with its draft intact. Draft-only edits also mark the
native window as changed.

Export saves the checked revision and keeps authoring frozen through resource
enumeration, package generation and loose/PKG publication. Editing resumes after
publication or a reported failure. A later source input cannot slip between the
saved workspace and its export; direct package commands also flush pending
source and reject an invalid draft.

## Preserve imported source and bindings

Editable targets cover native layer transforms, color, opacity, visibility,
supported existing scalar bases, text and `effects[N].visible`. See the
[source contract table](editor-script-contracts.md#supported-source-anchors) for
the exact defaults and base requirements. User-property/animation bindings,
malformed bases and ambiguous layer identities stay read-only with their reason.
Unknown inline source metadata discovered on the selected layer is shown with
its structural path and retained without editing or execution. External material,
particle and package-resource scripts are outside this workspace's source scan.

The code editor displays normalized LF line endings. Merely opening, checking or
saving imported source preserves its exact bytes, including Unicode, CRLF and
mixed line endings. Actual input preserves a consistently CRLF source's style.
Editing source that originally mixed line endings writes the displayed LF style.
Unrelated wrappers, unknown JSON members and resource bytes remain intact.

## Preview and exported playback

The edit canvas and model-import preview use the pinned engine's `scripts:false`
option. Property curves and skeletal animation still play there. **Run preview**
captures the current valid revision without saving or applying wallpaper.
**Restart from beginning** restarts that same captured revision in a fresh page;
later source edits require a new Run preview. Seeking an animation does not
reverse stateful scripts or particles.

The preview retains actual script issues and renderer warnings in a selectable
list. Open source navigates only when the owning document, unique anchor and
exact source still match; otherwise it shows an independent read-only capture
without flushing or overwriting a pending draft. Missing, transformed or
out-of-range locations remain explicitly unmapped. See
[runtime diagnostics](editor-script-diagnostics.md) for line, count and upstream
retention limits. The independent preview
and Main receive no Editor authoring session. Exported loose/PKG projects use
native SceneScript and play without installing Editor. Page/origin/channel
separation within CEF does not imply operating-system process isolation. See
[snapshot ownership](editor-scene-preview.md) and
[execution migration](editor-script-migration.md).

## Implementation and attribution

`ScriptDraft` owns temporary source, while `SceneDocument` owns committed content
and undo/redo. The workspace uses the existing checked proposal transaction and
adds no source-evaluation endpoint or animation format. `CodeEditor` owns the
visible editing widget and its local history; source identity includes both layer
and anchor, preventing history from crossing into another source with equal text.
The [source API](editor-script-contracts.md) and
[validation guide](testing/standalone-editor.md#script-workspace-acceptance)
describe the developer contracts and reproducible checks.

Compilation, source semantics and package generation reuse pinned WebWallGL
3.0.0 / `@webwallgl/editor` 3.0.0. See the
[upstream project](https://github.com/oneincase/webwallgl),
[recorded provenance](../Editor/ThirdParty/provenance.json) and retained
[MIT license](../Editor/ThirdParty/WebWallGL-Editor-LICENSE).

The source widget reuses [CodeMirror](https://codemirror.net/) 6 and its JavaScript,
completion, history and search modules. These modules are bundled offline; they
require neither a CDN nor Node when the app runs. The build records exact direct
pins, bundled transitive versions and resource hashes in
[Editor provenance](../Editor/ThirdParty/provenance.json), and retains complete
[MIT notices](../Editor/ThirdParty/CodeMirror-LICENSES.txt). The SceneScript catalogue
and starters are implemented here against the actual pinned WebWallGL API.
