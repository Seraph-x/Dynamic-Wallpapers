# Edit a model's skeleton and skin

Open a loose/PKG scene, select an ordinary image or an existing puppet/skinned
model, and choose **Model** beside **Properties**. The workspace shows the skeleton,
local bind matrices, mesh/vertex information and numeric skin influences.
Switching workspace, selecting bones/vertices and showing overlays are preview
choices; they do not change the saved project.

This checkpoint creates skinned grids from images and edits model hierarchies
and painted/numeric skin weights. Direct glTF/GLB import, editing an
existing bone's rest transform, skeletal clip authoring and the Script IDE
remain separate roadmap work. Existing bind matrices are displayed read-only.

## Create a mesh from an image

On an ordinary image layer, choose **Create mesh from image…**. Enter the root
bone name and choose 4, 8, 16 or 32 cells along each axis; the dialog displays
vertex/triangle counts and defaults to 8. Confirm with **Create mesh**, or use
Cancel/Escape to leave the project unchanged. The new centered XY grid retains
the image's top-left texture orientation and binds every vertex to one identity
root. An explicit positive constant layer `size` defines the grid dimensions;
otherwise the model's natural dimensions are used. Its constant **Rest** clip keeps the bind pose until animation is authored.

The conversion creates adjacent UUID-named model, MDL and material resources,
then retargets only the selected layer. The copied material disables mesh
lighting to retain the original flat image appearance. Layer transforms, color,
opacity, visibility, property animations, scripts and unknown JSON metadata are
retained. Other layers sharing the original model/material keep their resources.
The three resource revisions and layer binding publish in one undoable history
transaction; failed reads, staging or detected conflicts publish no partial edit.

A supported source has explicit positive finite natural `width`/`height` and no
existing `puppet`; **File → Add image** creates these dimensions. Autosized or
missing dimensions are rejected explicitly. Property-bound, scripted or animated
layer sizes cannot be preserved by constant mesh geometry and are rejected
explicitly; their current value is never baked silently. The material must have one
`genericimage2`/`genericimage4` pass and one project texture, without shader
constants/combos or render-target bindings/textures. Dimensions, grid spacing,
indices and buffers must survive native Float32/u32 encoding. Unsupported input
shows its specific error and remains cancellable, without guessed dimensions,
flattened effects or altered density. The density presets are UI choices, not
an encoder cap.

After creation, the existing hierarchy and numeric-weight tools apply. Save,
reopen and loose/PKG export use the same resource pipeline, and Main plays the
export without Editor installed. A pending creation dialog must be finished or
cancelled before Save or other native document barriers proceed.

## Change the hierarchy

Select a bone in the outline or on the canvas. Change **Bone name** or **Parent**,
then **Apply**, or use **Revert** to discard pending input. Parent choices
exclude the selected bone and its descendants. Reparenting retains local bind
transforms and animation samples, so world-space placement/motion can change.
The resource transaction sorts parents before children and remaps skin,
animation, attachment and recognized auxiliary references together.

**Create bone** opens a native modal dialog. Enter its name, parent, position,
rotation in degrees and scale. Zero scales, nonfinite values and transforms
which the native Float32/TRS representation cannot preserve are rejected. The
new bone receives a constant rest track in existing clips. **Cancel** or Escape
discards unconfirmed input. Once submission starts, the dialog remains busy
until the transaction succeeds or reports an error.

**Delete bone** explains the affected vertices, attachments and children.
Children move to the removed bone's parent while retaining local transforms;
the removed bone's animation tracks are deleted. If it has weighted vertices
or attachments, explicitly choose a surviving replacement. There is no implicit
replacement. Cancel changes no content; the final bone cannot be deleted.
Undo restores the complete previous resource, including references and tracks.

All layers sharing an MDL resource receive its edit. The workspace calls this
out because the file belongs to the project rather than to one layer instance.

## Change numeric weights

Choose a mesh and vertex. The bind-space map shows triangle edges, vertices and
the selected bone's influence; click a vertex or use the index input. The map
also supports Left/Right/Up/Down and Home/End. A ring and numeric controls
identify the selected vertex without relying exclusively on color.

Enter up to four distinct joint/weight pairs. Choose **Unused** with weight 0
for an empty slot. Weights must be finite and nonnegative with a positive sum;
Apply normalizes them. Duplicate joints, invalid vertex IDs and unsupported
layouts fail without publishing a revision. Unedited vertices remain intact.
The main preview immediately uses the authored MDL, and Undo restores its
previous deformation.

## Paint weights

Select a mesh and bone, then choose **Paint weights** under **Map tool**. Set
**Radius (map px)**, **Target weight** and **Strength**. Defaults are 24 map
pixels, target 1 and strength 0.5. The map has a 320 × 180 logical coordinate
space independent of its displayed size. Radius must be positive and finite;
target and strength range from 0 to 1. These are preview settings, not saved
project content. Their validity is checked when a stroke starts.

Drag on the map to preview the selected bone's weight. Release applies the
stroke to the actual model as one resource revision and one undo step. Escape,
pointer cancellation or unexpected lost capture discards the stroke. Save,
selection and Timeline content edits require an unfinished stroke to be finished
or cancelled. If you already released while preparation is pending, Save waits
for that completed stroke, including across native freeze. A no-op stroke does
not stage a resource or dirty history. Pointer capture follows a drag outside
the map; only its primary owning pointer can end it.

The brush works in the existing XY **bind-space projection**. Vertices sharing
the same projected XY position are painted together, including vertices at
different depths. It is not depth-aware 3D surface picking. The main scene updates
on release; the weight-map preview is transient until then. Choose **Select
vertex** to use ordinary map picking and Home/End/arrow navigation again. Numeric
influence fields remain the keyboard-accessible authoring path.

Each stroke uses the maximum linear falloff coverage along its full polyline.
For coverage `c`, original selected weight `w`, strength `s` and target `t`, the
result is `w + s*c*(t-w)`. Extra pointer samples or retracing the same stroke do
not build up additional strength; a new stroke does. Normalize existing
influences and preserve all other surviving joints in proportion. Exact zero
influences disappear. A fifth positive influence is rejected without discarding
an existing one. Reducing the sole weighted joint requires another surviving
weighted joint: assign one explicitly with the numeric controls first. Native
Float32-unrepresentable influence values are rejected instead of silently lost.

Failed preview strokes leave the document unchanged and show the actual error.
A failed resource stage also publishes nothing; use **Revert** in the numeric
weights form to clear the failed commit before retrying. Error cleanup removes
only that stroke's own barrier; it does not discard an invalid Timeline draft.
Painted resources use ordinary save/reopen and loose/PKG export, including
playback in Main without Editor installed.

## Save pending input safely

Save/freeze, undo/redo, layer/workspace changes, native image insertion and
resource replacement first prepare model drafts. Timeline content operations
also prepare model drafts. Invalid input remains editable and blocks dependent
content changes until corrected or reverted. A confirmation dialog must be
completed or cancelled before a native document barrier proceeds.

Pending weight and hierarchy forms publish one resource revision. Weights are
interpreted using the original joint IDs before hierarchy remapping, so a
simultaneous parent change cannot silently retarget them. A model resource edit
preserves an independent property-timeline draft; the next native barrier
prepares Model, then Timeline. The controllers do not wait on each other's
operation queues in both directions.

Resources are staged before one document-history edit. The commit checks the
selected document identity, layer/model path and resource version both before
and after the asynchronous write. Image creation also checks the original
workspace resource inventory through a read-only, workspace-scoped resource RPC
and rechecks current overrides at the synchronous publication boundary. A stale write or disk error does not publish
the edit. Resource replies continue to bypass preparation/render queues, so
initial loading and Save cannot deadlock on their own blob read.

Saved workspaces and loose/PKG exports use the same resource-version path as
other Editor changes. Exported models play in Main without the Editor installed.
No new workspace schema, native command or playback format is introduced.

## Capacity, unsupported files and recovery

The workspace reads the actual linked `u_skin[0]` uniform array size on the
Editor renderer's first model draw. It does not infer capacity from device
limits: the pinned shader can link a smaller palette after a failed attempt.
The observer is attached only to the Editor-owned canvas/context, forwards
context options and native draw calls unchanged, then restores the original
method descriptors immediately after loading.

A model must actually draw to obtain this capacity. A hidden/non-drawing model
can therefore show capacity unavailable; make it visible in preview before
structural/weight authoring. Rename-only changes do not need a new palette.
Missing capacity or an exceeded limit is an explicit error, with no guessed
default or clamping. Other machines can have different GPU capacities.

The [model resource contract](editor-model-resources.md) lists supported binary
layouts. Unknown mesh data remains unavailable for weight editing with its
reason displayed; readable bones can still be renamed safely. A resource read
failure or an unsupported skeleton displays its error and leaves normal
Properties/layer selection available when there is no dirty model draft.
**Reload model** explicitly retries inspection; **Revert** discards pending
input if a source changed underneath it. Unsupported data is never flattened
or replaced by a fabricated editable model.

## Validation and source references

The workspace uses the pinned WebWallGL model inspection, bone screen-point
and rendering APIs together with the lossless codec credited in the
[resource contract](editor-model-resources.md#reused-source). The engine and
existing Editor API bundle remain unchanged. Forms use visible associated
labels; creation/deletion use native `dialog.showModal()` focus behavior.

Run the documented checks in [standalone Editor validation](testing/standalone-editor.md).
The browser exercises real forms, overlay picking, destructive cancellation,
influence/attachment replacement, actual deformation, history, unblurred input,
cross-tool/native barriers and error recovery. Five languages and both themes
are checked at 850 × 540, including an open Timeline. User-authored model bytes
continue through save/reopen and both exports into Main's CEF pixel assertions.
The native harness additionally types a bone name through AppKit, freezes it
without blur and verifies the staged MDL name/hash, save acknowledgement and
undo/redo before closing the CEF page normally.

Image conversion acceptance additionally compares the exact rendered image pixels
before/after conversion, excluding only SVG controls and rounded UI clipping.
It verifies shared-source isolation, failed second-stage writes, unsupported
sources, one-step history, saved reload, modal focus and all five languages/themes.
A documented test-only MDLA root-motion fixture exercises numeric weight changes;
it does not represent a skeletal clip-authoring UI. Main CEF verifies all four
texture quadrants and known intermediate motion for both image-generated exports,
while native Editor creation checks actual staged resource hashes and history.

Brush acceptance uses real pointer strokes and asserts the authored weight
resource, expected fixed-corner deformation, atomic undo/redo, saved reload and
both exports. It covers cancellation, preview/staging failures, no-op barriers,
keyboard selection, unrelated invalid drafts, and delayed preparation followed
by pointerup/freeze. Pointer ownership and implicit release follow the
[Pointer Events specification](https://www.w3.org/TR/pointerevents/).
