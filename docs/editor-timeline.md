# Property keyframe timeline

This is the second advanced-authoring PR, following resource transactions. The
approved scope is the property timeline portion of
[the authoring roadmap](superpowers/specs/2026-10-24-advanced-editor-roadmap-design.md).
Skeleton authoring, skeletal clips and SceneScript IDE work remain separate.

## Editing a scene

Open **Timeline** in the standalone Editor and select a layer. Animate Position,
Scale, Rotation, Color or Opacity. Each vector component has its own row and
keys. Rotation uses radians; RGB and opacity values use 0–1. A key's numeric
frame uses its property's FPS, while the playhead displays seconds. Different
properties may retain different frame rates.

Use **Add key** to sample the current rendered property, then adjust its frame,
value and tangents and press **Apply**. Enable **Snap keys to frames** for whole
frame insertion, drag and paste. Custom imported tangents remain preserved;
choosing Linear or Smooth explicitly replaces the selected key's tangent mode.
Change playback FPS, frame duration or Once/Loop/Ping-pong in Track settings.

Track name selects a component; a diamond selects a key. Left/Right moves a
focused key one frame, Shift moves ten. When the track area is focused, arrows
step the scene instead. Copy/Paste key uses a window-local clipboard. Undo/Redo
includes numeric edits, dragging, insertion, removal and binding conversion.

**Revert** discards pending form input. Save, layer changes and history actions
process pending drafts before proceeding. Invalid input stays available for
correction; cancelling close or save does not replace it with old document
values. Each channel keeps at least one reference key; Remove animation keeps
the current sampled value as a constant. Shortening past existing keys/events
and moving into an occupied frame fail explicitly.

## Playback and compatibility

View start/end, playhead, snapping and preview range looping are local controls;
they do not modify the exported scene. Property playback settings and keys do.
Changing FPS preserves native frame positions and therefore changes timing.
The collapsed default and compact layout preserve normal Editor canvas use.

The Editor writes the same native curve representation consumed by Main's
pinned WebWallGL engine. Relative curves keep their base/delta representation
while the form displays absolute values. Unknown metadata and custom handles
survive ordinary edits. Script/user-bound fields, linked animations,
script-started tracks and unsupported representations are not silently flattened.
Replacing such a binding requires an explicit confirmation and remains undoable.
Seeking evaluates property curves; it cannot rewind stateful script or particle
history. See [the renderer reference](../Editor/README.md#references-and-notices)
and [reproducible acceptance](testing/standalone-editor.md).

## Implementation boundaries

`animation.mjs` owns format validation and immutable per-property edits;
`SceneDocument.animate` commits them into existing history. `timeline-clock.mjs`
serializes engine seeks and relative frame steps. `timeline.mjs` owns interaction
state, captured targets, draft revisions and input preparation. `timeline-view.mjs`
renders native controls, channel rows, curves and key selection. It does not
evaluate scene animation.

Snapshots, freeze and history commands wait for pending application and timeline
edits. Resource replies keep their separate path so that a pending render can
read its immutable assets. The native host adds only a fixed seek command; Main
does not gain an Editor dependency or a separate animation runtime.
