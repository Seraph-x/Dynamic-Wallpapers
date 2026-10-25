# Edit inline SceneScript

The Script workspace is an offline source editor using a native HTML textarea.
It supports checked source drafts and normal project history/save/export. Syntax
highlighting, SceneScript API completion, lifecycle templates, find/replace and
source-linked runtime diagnostics will arrive in separate PRs. Breakpoint
debugging is outside the approved IDE scope.

Source never executes in the workbench. **Run preview** captures valid current
edits in an independent script-enabled scene window; applying source does not
restart or change an already captured preview.

## Select and edit a source

Select a layer, choose **Script** beside **Properties / Model**, then choose a
property in **Property / source**. The layer list and canvas remain available.
The source field scrolls horizontally for long lines; the workspace and Timeline
retain the minimum-window layout, light/dark appearances and five UI languages.
Ordinary text input, composition, Tab and local text undo retain browser behavior.

For example, choose a layer's `alpha` target and enter:

```js
export function update(value) {
  return 0.5;
}
```

Use **Check**, then **Apply source**, and **Run preview** to execute it in the
captured scene. The offline checker validates syntax with the pinned engine;
runtime API availability and rendered behavior still require actual playback.

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

The textarea displays normalized LF line endings. Merely opening, checking or
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

The preview's current runtime warning/error is visible as selectable plain text.
The retained issue list and links to captured source locations are later work;
current runtime messages do not imply a source location. The independent preview
and Main receive no Editor authoring session. Exported loose/PKG projects use
native SceneScript and play without installing Editor. Page/origin/channel
separation within CEF does not imply operating-system process isolation. See
[snapshot ownership](editor-scene-preview.md) and
[execution migration](editor-script-migration.md).

## Implementation and attribution

`ScriptDraft` owns temporary source, while `SceneDocument` owns committed content
and undo/redo. The workspace uses the existing checked proposal transaction and
adds no source-evaluation endpoint, animation format or code-editor dependency.
The [source API](editor-script-contracts.md) and
[validation guide](testing/standalone-editor.md#script-workspace-acceptance)
describe the developer contracts and reproducible checks.

Compilation, source semantics and package generation reuse pinned WebWallGL
3.0.0 / `@webwallgl/editor` 3.0.0. See the
[upstream project](https://github.com/oneincase/webwallgl),
[recorded provenance](../Editor/ThirdParty/provenance.json) and retained
[MIT license](../Editor/ThirdParty/WebWallGL-Editor-LICENSE).
