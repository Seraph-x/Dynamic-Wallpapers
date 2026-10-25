# Edit bone pose frames

Select a puppet/model layer, open **Model**, choose a bone and select its clip
in **Animation clips**. Expand **Bone pose frames** and enter an integer frame
from zero through the clip's frame-interval count. The status shows the selected
bone, frame and time in seconds.

These are the MDL format's **dense local samples**: every integer frame already
stores a pose. They are not sparse authoring keys. No additional key-position
metadata or Editor-only playback format is introduced. The same native clip
plays in Main without installing Editor.

## Change a pose

Edit local XYZ position, Euler rotation in degrees and scale, then choose
**Apply**. Saving also flushes a valid pending pose. Rotation values retain their
original Float32 radians when the displayed value is unchanged. Selecting a
different frame, bone or clip first flushes the current valid draft; selection
itself changes no project content.

Only the selected bone's selected sample changes. Other frames, bones, clips,
events, attachments, bind transforms and unknown metadata remain intact.
Descendants and geometry influenced by this bone naturally follow its animation.
Binding/rest editing remains a separate tool.

| Action | Result |
| --- | --- |
| Copy pose | Copies nine local components into the Editor's own transient clipboard |
| Paste pose | Fills the current pose draft; Apply/save commits it |
| Reset to bind pose | Writes this bone's actual local bind transform to this sample |
| Revert | Discards this tool's pending values and clears its own failed input/staging error |
| Preview frame | Temporarily previews the selected clip at frame/FPS, without changing saved playback |

The clipboard works across bones and clips without requesting system clipboard
access. It contains local components, not a world-space retargeting operation.
Reset changes no other sample and does not use animation frame zero as a
substitute for the actual bind pose. Undo restores the entire prior revision.

Preview replaces the runtime animation table temporarily and pauses. Table
replacement and seeking share one queue operation, so later Timeline seeks
retain their order. Re-rendering restores the saved scene assignment. Use the
clip library's confirmed **Use for playback** action to change saved playback.

The native **loop** mode wraps to sample zero at its exact end. Its last sample
affects interpolation approaching that boundary; selecting and previewing the
final frame exposes the wrap. Mirror/once modes can display the last sample.
The Editor does not silently synchronize the first and last samples.

## Bake between endpoints

Set **Start frame** and **End frame**, leaving at least one interior frame, then
choose **Bake between frames**. This replaces only the selected bone's interior
poses with linear translation/scale and the pinned renderer's single-wrap
Euler-angle interpolation. Both endpoints remain exact. Events and timing do
not change. One Undo restores the previous interiors.

For example, with endpoint Y values 10 and 50 at frames 0 and 4, the interior
Y samples become 20, 30 and 40. Intermediate sampled poses replace earlier
animation deliberately; the visible description explains this before baking.
Unused range settings are not project edits and do not prevent saving.

## Save, undo and recover

Valid pose, clip, bone/rest and weight fields publish together as one immutable
resource revision. Reparenting that changes bone indices maps the selected bone
before applying its pose. One Undo restores the combined revision. A pending
pose outside a simultaneously shortened clip fails explicitly.

Invalid input blocks save/freeze/history/selection until corrected or reverted.
Empty focused inputs and failed staging recover through pose **Revert**, without
discarding another tool's draft. Source MDL bytes, puppet JSON and document
ownership are checked through asynchronous resource staging. Failed edits leave
the current valid document unchanged.

Nonfinite or Float32-unrepresentable components, singular local/world transforms,
overflowing skin/vertex results and unsupported source layouts remain visible
errors. In particular, interpolating scales through zero fails rather than
accepting the renderer's singular-transform substitution.

Saving/reopening and loose/PKG export preserve the actual authored MDL. Sparse
authoring keys, event authoring and FK/IK remain subsequent
parts of the [approved roadmap](superpowers/specs/2026-10-24-advanced-editor-roadmap-design.md).

[Clip layers](editor-clip-mixing.md) can now edit native ordered normal/additive
mixing, rate and visibility independently of these pose samples.

This implementation reuses the existing MIT
[WebWallGL lossless MDL codec](editor-model-resources.md#reused-source), pinned
3.0.0 playback APIs and our resource transaction layer. Pose editing and range
baking are implemented here; upstream licenses and provenance remain packaged.
See [standalone validation](testing/standalone-editor.md) for reproducible checks.
