# Edit model resources without losing references

This is the resource layer used by the [Model workspace](editor-model-workspace.md)
for skeleton hierarchy, numeric/painted weights and local rest editing.
[glTF/GLB import](editor-gltf-import.md) and image-to-mesh creation publish through
the same immutable resource history.

`Editor/Web/model.mjs` exports pure operations over MDL bytes. The reproducible
offline build exposes them in `model-api.mjs`. They use the existing immutable
resource transaction/history/export path; no new native command or workspace
schema is needed. Opening the application does not load or run model edits.

## Reorder or change a skeleton

```js
import { rewriteSkeleton } from './model-api.mjs';

const result = rewriteSkeleton(originalBytes, {
  boneLimit: verifiedTargetCapacity,
  bones: [
    { source: 0, parent: -1 },
    { source: 2, parent: 0, name: 'Right' },
    { source: 1, parent: 0, name: 'Left' },
  ],
});
// Stage result.bytes through the existing resource service, then commit its
// version at the original MDL path using SceneDocument.resource().
```

`source` identifies an original bone. Destination parents use destination
indices and must precede their children. Existing matrices, metadata and opaque
bone header fields survive. Reparenting retains local bind transforms and local
animation samples; it intentionally changes their world-space parent chain.
It does not bake world-space motion or replace existing rest matrices.

New bones use `source: null`, `name`, `parent` and a 16-component invertible local
TRS matrix. Every existing animation receives a constant rest track for that
bone. Perspective, shear and matrices which become invalid in native Float32
encoding are rejected. The pinned renderer's determinant tolerance also applies.

Omitting an original bone deletes its record and positional animation track.
Surviving skin indices, attachment bone references and recognized bone-sized
tables follow the same mapping. A deleted bone with positive skin weight or an
attachment requires an explicit replacement, for example
`replacements: { 2: 1 }` maps original bone 2 to destination bone 1. Replacement
indices refer to the final skeleton. Surviving weights are unchanged; duplicate
joint slots created by a replacement remain equivalent weighted contributions.
Zero-weight deleted slots become joint 0 with zero weight.

These are low-level operations. The Model workspace presents destructive
changes and obtains confirmation before committing them. This API does not
display an installation prompt or any other user dialog.

## Change numeric influences

```js
import { setSkinInfluences } from './model-api.mjs';

const edited = setSkinInfluences(originalBytes, {
  boneLimit: verifiedTargetCapacity,
  mesh: 0,
  edits: [{ vertex: 12, influences: [
    { joint: 1, weight: 3 },
    { joint: 2, weight: 1 },
  ] }],
});
```

This writes normalized weights 0.75 and 0.25, clears the remaining two slots and
leaves other vertices and sections untouched. Each vertex accepts one to four
unique joints, finite nonnegative weights and a positive total. Invalid or
repeated vertex/joint IDs fail the entire operation. Normalization scales by the
largest input weight to avoid overflow. Caller-owned input bytes never change,
including when an operation fails.

## Capacity and format limits

`boneLimit` is required for structural edits and numeric influences. It is a
verified capacity for the target renderer, not a requested quality setting.
There is no default and no clamping. The pinned MDL parser accepts at most 1024
bones, but the shader palette has a hard ceiling of **128** and can compile a
smaller palette on a GPU. The Model workspace must establish the actual
target capacity before exposing these operations; the Model workspace observes
the actual linked shader uniform size for this purpose. The integration
fixture explicitly verifies a three-bone target in both Editor and Main.
Rename-only edits do not change rendering capacity and need no new budget.

Structural editing currently requires MDLV0023, MDLS0004 and, when present,
MDAT0001, MDLA0006 and MDLE0002, with zero section flags, unique sections, an
empty gap and a zero terminator. Animation clips must have one positional track
per original bone, `(frameCount + 1) * 9` finite values per track and exactly 31
zero trailer bytes. `boneId` is retained as opaque data: the pinned renderer
associates tracks with bones by position.

Skeleton tails must be empty or use the verified `14 + 84N` layout with its
expected flags and a bijective permutation. Records and permutation values are
both remapped; a deletion which breaks the surviving permutation is rejected.
Existing pose and draw-order values are preserved, rather than reset to bind
pose. New records use the upstream encoder's bind-pose representation. MDLE
must contain exactly one 64-byte matrix per bone without an additional suffix.
Unsupported vertex layouts cannot receive new skin indices or weights.

Unknown bone-dependent tails, raw sections, ambiguous animation boundaries and
nonzero animation trailers remain unchanged on rename. Structural edits reject
them with a specific error. No retry, alternate parser or section deletion
converts that failure into a successful edit. Byte-identical codec round trips
are required before authoring; additional layout validation is still necessary
because a round trip alone cannot prove the meaning of opaque references.

## Verify the resource contract

```sh
node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs
node Editor/Web/build.mjs --check
python3 scripts/test-editor-native.py
```

The model tests cover reorder, insertion, deletion/replacement, metadata,
attachments, event payloads, dense bind tables, noncommuting permutations,
ambiguous animation boundaries, numeric influences and Float32/TRS failures.
A separately assembled binary fixture avoids relying exclusively on the codec
to generate its own expected bytes. The browser additionally compares the
vendored encoder byte for byte with `@webwallgl/editor` 3.0.0.

Real rendering checks use two skinned meshes: the left bone stays still, while
the right moves vertically by a known 0..60 pixels. Browser checks sample the
middle frame, reindex and weight changes, undo/redo, save acknowledgement and
reload of the saved resource-revision document. Exported loose/PKG fixtures are
then opened by Main's actual CEF scene runtime. Native assertions require known
bind positions, a stationary left mesh and intermediate right-mesh deformation,
followed by full page/runtime release.

Image-to-mesh creation uses the same pinned encoder to write MDLV0023, an
80-byte skinned vertex layout, one identity root and a constant Rest clip. It
chooses 16-bit or 32-bit indices from the actual vertex count. Source image
model/material metadata is copied to distinct resource paths; publication and
the selected layer binding form one document transaction. See the
[image conversion contract](editor-model-workspace.md#create-a-mesh-from-an-image)
for supported materials and dimension requirements.

## Reused source

The lossless codec is the unmodified MIT-licensed
[WebWallGL MDL writer](https://github.com/oneincase/webwallgl/blob/197abe54266c31d346cebc314e49a26b70c960cc/renderer/vendor/we-scene/pkg/mdl-write.js).
Its commit, source URL and file hashes are recorded in
`Editor/ThirdParty/mdl-codec-provenance.json`; every offline build verifies them.
The complete license is packaged as `Editor/ThirdParty/WebWallGL-MDL-LICENSE`.
This adds no runtime network fetch and does not modify the pinned playback
engine or its existing API bundle.
