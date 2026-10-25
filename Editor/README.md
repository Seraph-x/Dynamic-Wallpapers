# Dynamic Wallpaper Editor

A standalone macOS scene editor, developed in the same repository as Dynamic
Wallpaper. It has its own application, process, version, projects and CEF cache.
It is not installed with the wallpaper application. Removing either application
does not delete the Editor's saved projects.

The initial version supports new scenes; importing loose or PKG projects;
image/text layers; layer ordering, visibility and duplication; position, scale,
rotation, color and opacity; canvas picking/dragging; live preview with
play/pause; property keyframe animation; image-to-mesh creation; model hierarchy
and local rest transforms; painted/numeric skin weights; undo/redo; save/reopen; and loose/PKG export.
Script and property-bound fields remain read-only in the inspector.
Preview is muted with explicit zero
system spectrum; exports preserve audio response for wallpaper playback.
The [Model workspace](../docs/editor-model-workspace.md) uses immutable resource
revisions for complete undo/save/export transactions.
[File → Import model…](../docs/editor-gltf-import.md) accepts local glTF/GLB
models, retains originals and previews the conversion before publication.
[Skeletal clip tools](../docs/editor-clips.md) provide creation, duplication,
deletion, timing, preview and saved playback assignments.
[Bone pose frames](../docs/editor-bone-poses.md) edit local sampled TRS,
copy/paste/reset poses and bake between endpoints. [Clip layers](../docs/editor-clip-mixing.md)
edit ordered normal/additive blending, speed and visibility.
The script IDE remains subsequent roadmap work.
[Frame events](../docs/editor-frame-events.md) create/edit/copy/order native
markers, preserve opaque metadata and trigger existing imported handlers.
[FK local deltas](../docs/editor-fk-posing.md) provide cancellable native preview
and inclusive sample-range baking of local translation, rotation and scale.
[Two-segment IK](../docs/editor-ik-posing.md) provides model-space target/pole
posing, cancellable preview and native rotation-sample baking for a root/middle/end chain.
[Sparse bone keys](../docs/editor-bone-keys.md) provide adoption/lossless reduction,
key editing and relocation, clipboard operations and native sample baking, with
authoring locations retained through save/reopen and export.

Use **File → New Project** or **Open Project**. Imports create complete owned
copies. **Save** writes the Editor workspace; **Export** creates a standard scene
folder without replacing an existing destination. Reopen `workspace.json` from
the Editor's `Projects` directory to continue a saved workspace. User data is
stored under `~/Library/Application Support/DynamicWallpaperEditor/`.

## Workbench appearance

The workbench follows the system light/dark appearance. The Appearance control
can override it for the current window. Warm neutral surfaces, a clay accent,
serif headings and quiet controls take visual direction from Claude's interface;
the workbench uses system fonts and original icons. Layers stay on the left,
the live canvas stays central, and grouped properties scroll independently on
the right. Text formatting appears before transforms for text layers. Changing
appearance does not alter or mark the scene as edited.

## Create a skinned mesh from an image

Select an ordinary image layer, choose **Model → Create mesh from image…**,
name the root bone and choose a grid density. **Create mesh** produces a new
unlit mesh/model/material set for that layer. The original image, other layers
and shared source resources remain intact. Cancel/Escape changes nothing.
Conversion, undo/redo, save/reopen and loose/PKG export use normal project
resource revisions. Use the existing bone and numeric-weight tools afterward.
Images require declared natural dimensions and a supported single-pass textured
material; unsupported sources report their reason without conversion. See the
[workspace guide](../docs/editor-model-workspace.md#create-a-mesh-from-an-image)
for the exact format restrictions. Mesh encoding reuses the MIT-licensed
[WebWallGL MDL writer](https://github.com/oneincase/webwallgl/blob/197abe54266c31d346cebc314e49a26b70c960cc/renderer/vendor/we-scene/pkg/mdl-write.js),
with recorded provenance and a packaged license.

## Edit an imported model

Select a puppet/skinned model layer and choose **Model** beside **Properties**.
Pick bones in the outline or canvas; rename, create, reparent or delete them.
Deletion asks for confirmation and an explicit replacement for weighted vertices
or attachments. Parent changes retain local transforms and animation samples,
which can change world-space motion. Expand **Local rest transform** to edit
local XYZ position, Euler rotation in degrees and scale. Apply publishes one
resource revision; Revert discards pending Model input. This changes binding,
while keeping mesh data and existing animation/static poses; their deformation
can change. Unsupported source shear/perspective remains explicitly read-only.

Choose a mesh/vertex in the bind-space map and edit up to four normalized joint
weights. **Paint weights** adds a radius/target/strength brush for the selected
bone in XY bind space. Drag previews the weight map; release applies one
undoable stroke, and Escape cancels. Other influence proportions are retained;
unsupported fifth influences or sole-weight reductions report explicit errors.
**Select vertex** restores map picking and keyboard navigation. Apply commits;
Revert discards pending input. Native Save, history,
selection changes and Timeline edits prepare model input first. Invalid drafts
remain visible. Read/format failures show their reason and allow returning to
Properties; Reload model explicitly retries. Edits affect every layer sharing
the model resource. See the [workspace guide](../docs/editor-model-workspace.md)
for GPU capacity, format support, confirmation semantics and recovery.

## Animate a property

Open **Timeline**, select a layer and choose Position, Scale, Rotation, Color or
Opacity, then **Animate property**. Vector properties have separate X/Y/Z tracks
(R/G/B for color). Select a diamond to edit its frame, absolute property value
and linear/smooth tangents. **Apply** commits the fields together; **Revert**
discards pending input. Saving, changing layers and undo/redo first process
pending input, so an unapplied value is not silently lost. Invalid drafts stay
editable and block the affected action. Undo restores each content edit.

**Add key** samples the renderer at the playhead, **Copy key / Paste key** copies
within the current window, and **Delete key** removes a selected key. Keep one
reference key per channel, or use **Remove animation** to retain the current
rendered value as a constant. Drag a key or use Left/Right while it is focused;
Shift moves ten frames. Occupied destinations fail without overwriting a key.
**Snap keys to frames** affects insertion, dragging and pasting; turn it off for
fractional key positions.

Time is displayed in seconds; Previous/Next move one frame at the selected
track's FPS. The labeled native slider also supports keyboard navigation. View
start/end and **Loop preview range** are window-local preview controls and do
not dirty or change the exported scene. Track FPS, duration in frames and
Once/Loop/Ping-pong are saved in the scene itself. Changing FPS keeps key frame
numbers, changing playback speed. Shortening a track past existing keys or events
is rejected until those entries have been moved or removed.

The timeline writes WebWallGL's native property animation channels and Bezier
tangents; Main needs no Editor-specific playback code. Relative animations show
absolute values while retaining their original base/delta format. Custom
imported handles and unknown fields are preserved until an explicit edit changes
them. Linked, script-started or unrecognized animations remain intact and show a
reason instead of being flattened. Replacing a script/user binding or unsupported
animation requires **Replace binding… → Replace** and is undoable. Seeking samples
property curves; it does not rewind the history of stateful scripts or particles.

The timeline starts collapsed. It scrolls independently and can be closed to
restore canvas space; the compact layout keeps the canvas visible at the
minimum native window size in all five interface languages.
See [timeline timing and compatibility](../docs/editor-timeline.md) for the
saved format, input rules and implementation boundaries.

## Development

Requires Apple Silicon, macOS 14+, Xcode and the repository's pinned CEF SDK and
wrapper. The Editor does not link MPV/FFmpeg or the wallpaper executable. Its
Swift package consumes the repository's shared library products.

From the repository root (Node/npm are build-time dependencies):

```sh
python3 scripts/prepare-public-build.py cef
mkdir -p Editor/Web/.build
cp Editor/Web/package.json Editor/Web/package-lock.json Editor/Web/.build/
npm ci --prefix Editor/Web/.build --ignore-scripts
node Editor/Web/build.mjs --check
(cd Editor && python3 ../scripts/swift_sdk.py build --disable-sandbox)
```

From the repository root, build an independent candidate with its own CEF
framework/helpers, offline editor resources, legal notices and ZIP:

```sh
python3 scripts/build-editor-app.py --output 'dist/editor/Dynamic Wallpaper Editor.app' --zip
```

The output must be new; the script never replaces an installed app. It verifies
the pinned CEF download, release executable SDK, all Mach-O dependencies, ad-hoc
signatures, five localizations and the ZIP after extraction. The checksum file
accompanies the ZIP. No Editor release is published by this command. See
[installation/removal](../docs/editor-install.md) and [acceptance tests](../docs/testing/standalone-editor.md).

The wallpaper menu-bar **Editor** action opens the installed application or
offers **Download Editor / Cancel**. A handoff from Main offers read-only scene
references; imports create Editor-owned copies. **File → Import from Dynamic
Wallpaper** selects from those offers. **File → Open in Dynamic Wallpaper** saves
an immutable standard scene snapshot and imports it into Main's library without
applying it or adding it to a playlist. Each application keeps its own changes;
no automatic file synchronization occurs. Both can run and quit independently.

## Project layout and ownership

`Editor/Package.swift` builds this application using the repository's local
`WallpaperCore`, `WallpaperEditorCore` and `WebWallpaperBridge` library products.
`Sources/EditorApp/` contains the native host and bundled offline resources;
`Web/` contains the workbench source/tests. Keep the complete repository when
building from source. The packaged application carries its own CEF framework,
helpers and workbench, and needs no installed wallpaper app.

Under `~/Library/Application Support/DynamicWallpaperEditor/`:

```text
Projects/<project ID>/
├── workspace.json     # Saved editable document and revision
├── Project/           # Original owned scene files and resources
└── Resources/         # Private immutable versions of edited resources
Handoffs/              # Immutable standard scene exports for Main to import
CEFCache/              # Editor-only browser data
```

Main's separate data root is `~/Library/Application Support/DynamicWallpaper/`.
File handoffs create copies; saving in either application does not overwrite the
other application's managed copy. Quit Editor and remove its app bundle to
uninstall while retaining projects.

`DYNAMIC_WALLPAPER_EDITOR_DATA_ROOT` explicitly selects isolated data for native
acceptance tests. Normal users do not need to configure it.

Unedited legacy workspaces keep schema 1. Resource edits use schema 2, which
requires this Editor or newer; opening a project does not migrate it. Standard
loose/PKG exports materialize the selected revision at its original logical
resource paths, so Main does not need the workspace or private blob directory.
Immutable versions are retained for undo and revision safety; automatic blob
garbage collection is not included. Reserved paths and ambiguous case/Unicode
aliases fail explicitly rather than overwriting scene or project metadata.

## References and notices

- [WebWallGL](https://github.com/oneincase/webwallgl): actual pinned playback
  engine and `@webwallgl/editor` API, version 3.0.0; upstream image/text scene
  layout, native property animation/tangent conventions and PKG builder inform
  this editor. Both are MIT licensed. Our native
  host and focused workbench are implemented in this repository.
- WebWallGL's [lossless MDL codec](../docs/editor-model-resources.md#reused-source)
  is vendored at a recorded commit for skeleton/resource transactions, with its
  complete MIT license and source hashes in `ThirdParty/`.
- Selected WebWallGL [glTF helpers](../docs/editor-gltf-import.md#source-references)
  provide matrix/quaternion math, curve sampling and PNG encoding. The strict
  importer and native file boundary are implemented here; provenance records
  the exact upstream commit and selected-source checksum.
- [DSH Wallpaper Engine](https://github.com/elysia395/dsh-wallpaper-engine):
  scene-hosting design reference; no DSH application source is vendored here.
- [CEF](https://bitbucket.org/chromiumembedded/cef/): native browser runtime.
- [Mediabunny](https://github.com/Vanilagy/mediabunny): dependency in the shared
  WebWallGL bundle.

See `ThirdParty/` and the repository's `Resources/ThirdParty/{CEF,WebWallGL}/`
for pinned provenance, upstream license text and distribution status. The Editor
uses the same verified WebWallGL module bytes as Main, and packages its complete
runtime so it can operate independently.
