# Mix animation clips

Select a puppet/model layer, open **Model**, and expand **Clip layers**. The
list shows the selected scene object's native `animationlayers` order. Choose
a row to edit its name, clip, blend weight, speed multiplier, visibility and
additive mode. Selection itself does not edit the project.

**Apply** commits valid fields; saving also flushes them. Changes use the actual
scene renderer and persist through reopening and loose/PKG export. Main needs
no Editor installation or additional animation format to play the result.

## Build the stack

| Action | Result |
| --- | --- |
| Add clip layer | Appends the chosen available clip at full weight and normal speed |
| Duplicate | Copies the selected constant row, including its name and unknown metadata |
| Move up/down | Changes native sequential mixing order |
| Delete | Asks before removing the row, its bindings and metadata |
| Revert | Discards this tool's draft and clears its own input or staging failure |

Deleting the final row explains that playback will return to the model's first
clip. Cancel/Escape changes nothing; Undo restores the exact original table.
Absent, null and empty tables retain their original representation when merely
inspected. Existing optional fields remain absent when their displayed native
defaults are unchanged. Duplicate names are supported; names can be edited
independently when scripts need to distinguish rows.

## Understand native blending

Ordinary layers apply in list order, starting from the bind pose:

```text
accumulatedPose = accumulatedPose * (1 - blend) + sampledPose * blend
```

This is sequential TRS mixing, not a normalized weighted average. A later
ordinary layer with weight 1 replaces earlier results. For a first clip whose
Y is 30 and a second clip whose Y is 120, second-layer weight 0.5 produces 75.
Moving a full-weight first clip after that overlay produces 30 instead.

Additive layers use deltas from their reference sample: the first sample, or
the final sample for **Play once** clips. A first additive layer before any
ordinary layer may establish the base from that reference even with weight 0.
The total additive delta is applied only when total additive weight is positive;
totals above 1 are normalized by the native renderer. Rotation wrapping and
special scale handling follow the pinned engine. Negative weights therefore
do not mean unrestricted signed additive summation.

Weights and rates accept finite native numbers without automatic clamping.
Weights outside 0..1 extrapolate ordinary layers. Speed 0 samples that clip at
time zero; negative speed follows its native loop/mirror/once behavior. This is
an absolute scene-clock multiplier, rather than a separate pause-at-current-pose
command. Unchecking **Visible** disables that row. If every explicit row is
disabled, the engine shows the bind pose; an empty table uses the first clip.

## Preserve imported bindings and resources

Known fields controlled by scripts, animation or other object wrappers remain
read-only. The row's original JSON is shown, and other supported rows remain
editable. Reordering preserves the row; deletion requires explicit confirmation.
Unknown metadata remains intact. Missing clip references are displayed rather
than substituted. A malformed whole table is visibly read-only and never
silently rewritten as default playback.

The existing clip library's confirmed **Use for playback** / **Use default
playback** actions remain the deliberate route for replacing an entire table.
Mixing changes re-render the scene so existing supported scripts/curves are
mounted normally; they are not reduced to snapshot-only hot-update values.

Table-only edits change scene JSON and do not stage or rewrite MDL resources.
If bone/rest, weight, clip or pose fields are pending too, valid changes stage
one resource and publish its version together with the native table as one
revision. One Undo restores everything. Source document, MDL bytes and puppet
JSON ownership are checked through asynchronous publication.

Invalid focused input blocks save/freeze/history/selection until corrected or
reverted. A failed stage publishes neither a partial table nor a resource
revision. Mixing **Revert** preserves another tool's valid pending draft.
Other scene layers, including layers sharing the MDL, retain their own tables;
their explicit references continue to protect clips from deletion.

Sparse authoring keys, frame-event authoring, FK/IK and SceneScript IDE remain
subsequent parts of the [approved roadmap](superpowers/specs/2026-10-24-advanced-editor-roadmap-design.md).
This feature reuses the MIT [WebWallGL](editor-model-resources.md#reused-source)
3.0.0 native animation-layer parser, blending and scene playback APIs, plus this
project's existing transaction layer. Upstream notices remain packaged.
See [standalone validation](testing/standalone-editor.md) for actual browser,
AppKit/CEF and Main export acceptance.
