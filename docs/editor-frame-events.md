# Author animation frame events

Select a puppet/model layer, open **Model**, choose a clip in **Animation clips**,
and expand **Frame events**. Select a marker to edit its integer frame and name.
The inspector shows its encoded seconds and original JSON metadata.

Events are native MDL clip records consumed by the existing SceneScript
`animationEvent` hook. They are not a separate Editor event runtime. Creating
handlers and a Script IDE remain outside this feature; existing imported
handlers continue to work in Editor and Main exports.

## Create and manage markers

| Action | Result |
| --- | --- |
| Add event | Opens frame/name fields; Cancel creates nothing |
| Apply | Commits the selected marker's valid pending fields |
| Duplicate | Copies the exact record next to its source, including opaque metadata |
| Move up/down | Changes stored order; same-frame callbacks retain that order |
| Delete | Asks before removing the marker and all its metadata |
| Revert | Discards this tool's draft and clears its own input/staging error |

Frames range from zero through the clip's frame-interval count. Seconds are
stored as Float32 `frame / FPS`; for example frame 2 at 4 FPS encodes 0.5 seconds.
Names support valid Unicode, including empty and multiline names, without NUL.
Existing CR/LF sequences remain exact when only the frame changes or the
displayed name is unchanged. Duplicate names and same-frame duplicates are
allowed. Swapping identical records is a content no-op and adds no Undo step.

The pinned lossless reader supports up to 4096 events per clip. Reaching that
actual reader limit reports an error without changing the current resource.
Creation failure followed by Cancel restores the original selection; subsequent
copying or editing still targets that original marker.

## Preserve imported metadata

Only changed top-level `frame` and `name` value spans are patched. Unchanged JSON
retains whitespace, escaped key/string spellings, unknown nested values, unknown
duplicate keys and numeric text beyond JavaScript's exact integer range. Other
events, tracks, clips, skeleton/bind data and attachments remain intact.

An editable event requires one unambiguous top-level frame/name pair, a supported
frame/name value and encoded time consistent with that frame. Duplicate known
keys, string frames, missing names or inconsistent times are visibly read-only;
the raw record remains available. Exact Duplicate/Move and confirmed Delete
remain possible. A resource the pinned codec cannot parse is rejected explicitly,
rather than being turned into an empty event list.

FPS and clip resizing reuse the same strict metadata check. Duplicate known keys
cannot bypass validation through a timing edit. Existing event JSON remains exact
while seconds change. Move and commit a marker into the surviving range before
shortening a clip past it; conflicting drafts fail instead of dropping or
clamping markers. Clip name or playback-mode edits that do not affect timing retain
unmodified opaque event records.

## Play and verify events

The pinned engine dispatches skeletal events through **explicit clip playback
layers**. Use [Clip layers](editor-clip-mixing.md) or the clip library's confirmed
playback assignment. Merely inspecting or editing events does not create a
binding. A model may animate through default first-clip playback while its
markers have no explicit layer through which to dispatch.

Play or seek through the Timeline to cross markers. Existing handlers can alter
scene properties, such as changing a material's color. Same-frame order matters
when multiple handlers affect the same value. Loop/mirror boundaries use native
crossing rules, and markers can be dispatched again when seeking backward.
Handlers may retain state: reverse seeking is not a simulation reset. Reopening
the scene creates a fresh runtime. Metadata history stores content, not a snapshot
of callback state.

## Save, undo and recover

Valid event, pose, clip, bone/rest and weight drafts publish one resource revision.
A simultaneous mixing-table draft joins the same document transaction. One Undo
restores all committed fields and resources. Scene bindings and scripts stay
unchanged during event-only edits; standard loose/PKG exports preserve the native
records and execute them in Main without requiring Editor.

Invalid focused input blocks save/freeze/history/selection until corrected or
reverted. Failed staging publishes no partial event edit. Event **Revert**
preserves another tool's valid draft. Each tool owns its errors; a mixing-owned
publication failure is resolved through that tool. Dialog source/version and
actual MDL/puppet bytes are pinned across asynchronous publication.

This implementation reuses the MIT [WebWallGL lossless MDL codec](editor-model-resources.md#reused-source)
and pinned 3.0.0 native event dispatch/SceneScript hooks. Lossless JSON span editing
is implemented here; upstream notices remain packaged. See
[standalone validation](testing/standalone-editor.md) for actual callback color
checks, AppKit input and Main export playback. Sparse authoring keys, FK/IK and
SceneScript IDE remain subsequent [roadmap](superpowers/specs/2026-10-24-advanced-editor-roadmap-design.md) work.
