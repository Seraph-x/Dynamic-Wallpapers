# Manage skeletal animation clips

Select a loaded image-puppet or model layer, open **Model**, and expand
**Animation clips**. This library edits the model's native MDL clips; exported
scenes use the same playback engine in Dynamic Wallpaper.

Choose a clip to inspect its name, FPS, frame intervals, playback mode and
duration. Selection alone does not edit the project. The Model tools display
unsupported resource reasons and retain the original bytes after failed edits.

## Create, copy and change timing

**Create clip** makes a constant clip from the bones' actual local bind matrices.
It does not use the first frame of an existing animation as a substitute.
**Duplicate clip** copies the selected clip's samples, events and metadata with
a new unique ID. Existing IDs and unrelated binary sections stay unchanged.

Edit the name, **Playback FPS**, **Frame intervals** or mode, then apply or save:

| Setting | Result |
| --- | --- |
| FPS | Keeps sample count; changes playback speed and duration |
| Frame intervals | Resamples the whole motion over the new count, retaining endpoints |
| Duration | Intervals divided by FPS; an N-interval track has N+1 samples |
| Loop | Repeats the clip |
| Mirror | Plays forward and backward |
| Play once | Clamps at the final sample |

Rotation interpolation follows the pinned renderer's Euler wrapping. Resampling
is a baked approximation between new samples. Timing changes preserve readable
frame-event JSON and unknown fields, recomputing native seconds when FPS changes.
A resize that would exclude an existing event fails instead of moving or
dropping it. Opaque events remain exact during edits that do not affect timing.

The pinned reader's subsequent-header discovery supports up to 256 clips,
64-character new names, 100000 frame intervals and FPS in `(0, 240]`. Unsupported
new headers fail explicitly; existing names are never truncated. Singular bind
poses, invalid tracks and Float32 sample/world overflows also remain errors.

Valid pending bone, bind/rest, weight and clip fields publish together as one
resource revision. One Undo restores that revision. Invalid drafts block saving
and native operations until corrected or reverted. A failed resource stage does
not publish a partial edit; clip Revert recovers its own failed draft.

## Preview versus saved playback

**Preview clip** temporarily replaces the selected layer's runtime animation
table, pauses at zero and uses the actual renderer. It changes no saved content.
Use the Timeline to seek or play afterward. A scene re-render restores the saved
assignment. Preview replacement and initial seeking share the runtime queue so
later user seeks retain their order.

**Use for playback** opens a confirmation before replacing the selected layer's
entire native `animationlayers` table with one full-weight, normal-speed clip.
Existing mixing and scripts in that table are removed only after confirmation;
Undo restores the exact previous table and unknown fields. Other layers keep
their assignments. **Use default playback** similarly confirms removal of the
table, using the model's first clip, or the static bind pose when none remain.

Saving, reopening and loose/PKG export preserve both model resources and these
native scene assignments. Main needs no Editor installation to play them.

## Delete a clip

Deletion affects every layer sharing the model resource. Hidden puppet layers
and explicit references are included. A clip still named by a layer's native
animation table cannot be deleted; deliberately reassign or default that layer
first. Unknown or controlled reference tables require resolution, rather than
being treated as empty. Source MDL bytes, image-model JSON and document identity
are checked across asynchronous reads and staging.

The first clip is default playback, not the skeleton's bind reference. Deleting
it while other clips remain requires an explicit replacement default; the dialog
lists default-playback layers. Surviving IDs remain unchanged. Deleting the last
clip leaves an empty native animation table and restores static bind geometry.
The confirmation explains this result. Cancel/Escape changes no content.

[Bone pose frames](editor-bone-poses.md) edit native local samples, copy/paste/reset
poses and bake interpolation between endpoints. [Clip layers](editor-clip-mixing.md)
edit native ordered normal/additive mixing, speed and visibility. Sparse authoring keys
and FK/IK tools remain
subsequent work in the [approved roadmap](superpowers/specs/2026-10-24-advanced-editor-roadmap-design.md).
This clip library does not claim those tools are already available.

[Frame events](editor-frame-events.md) now provide native marker authoring with
lossless metadata. Clip timing reuses their unambiguous frame/name/time checks.

The implementation uses the existing MIT [WebWallGL lossless MDL codec](editor-model-resources.md#reused-source)
and pinned 3.0.0 editor/playback APIs. Clip editing is implemented here to preserve
events and use actual bind poses. See [standalone validation](testing/standalone-editor.md)
for the browser/native checks and reproducible commands.
