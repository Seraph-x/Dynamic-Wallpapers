# Author sparse bone keys

Available in development source. Published 1.0.0 binaries do not include these
Editor tools. Editor remains a separately installed optional application.

1. Select a model layer, switch to **Model**, choose a bone and clip, and open
   **Bone authoring keys**.
2. Choose **Adopt current samples** and confirm. Every existing native sample
   becomes a key, preserving the animation exactly. This also explicitly replaces
   a recognized older map when you need to recover from an out-of-sync state.
3. Choose **Reduce losslessly** to remove keys whose native samples can be
   recreated exactly. This changes only the authoring map, not playback samples.
4. Select a frame numerically, with **Previous/Next key**, or on the overview.
   Non-key samples remain inspectable; **Add & bake key** captures their pose.
5. Edit local translation, Euler rotation in degrees and scale, then **Apply**.
   **Revert** discards that draft. Move/duplicate use a destination-frame dialog;
   copy/paste and deleting interior keys are also available.
6. Use **Preview frame** to pause and temporarily solo the clip at that frame.
   Save/reopen retains the key map. Loose and PKG export play in Main without
   Editor or a sparse-key runtime installed.

Keys at frame zero and the terminal sample are required anchors. They can be
edited/copied, but not moved or deleted. Interior destinations must be free
integer frames. Every content operation creates one resource-history revision;
copying, selecting and previewing do not. A valid pending pose flushes before
save/freeze, selection or another edit, including unblurred native menu actions.
Invalid fields and unfinished dialogs produce visible, recoverable errors.

For example, on a 4 FPS clip with terminal frame 4, retain keys at 0 and 4.
Changing the last bone pose Y from 60 to 120 produces native Y samples
`0, 30, 60, 90, 120`; preview at 0.5 seconds displays Y=60. Other bones, clips,
bind transforms, events, physics metadata and supported opaque data remain
unchanged.

## Native interpolation and exact reduction

The playback format still contains a local Float32 TRS sample at every integer
frame. Translation/scale use the pinned engine’s weighted interpolation;
rotations use its XYZ Euler interpolation with one ±2π wrap. Editing, adding,
moving, copying to a new frame or deleting a key rebakes between keys and may
re-round intermediate values. Unchanged displayed degree values retain their
canonical native radians. Endpoints preserve their exact stored sample bits.

Lossless reduction tests the original dense samples against native interpolation
and recursively splits failing intervals at their midpoint. It keeps the keys
needed for an exact result, including signed-zero differences, and does not
claim to find the globally smallest key set. Balanced subdivision takes at most
O(frames log frames) work; there is no artificial key-count cap. The SVG overview
aggregates markers sharing a display pixel while numeric navigation retains
access to every key.

Looping clips wrap their exact terminal time to frame zero. The final sample
still affects playback approaching that boundary. Mirror/once can display the
terminal sample. Preview is temporary and does not change saved clip layers.

## Recover after other authoring tools change a track

Dense pose, FK/IK and duration edits remain usable. If their result cannot be
recreated from the stored key locations, the panel reports an out-of-sync map
and disables sparse edits. It does not silently overwrite the new animation.
Undo can restore a compatible revision. Alternatively:

- **Adopt current samples** explicitly replaces the selected bone/clip map with
  every current sample and preserves current playback.
- **Stop sparse authoring** explicitly removes that map and preserves all baked
  samples. Other metadata stays intact. Undo restores the map.

Clip names and FPS changes keep frame indices. Clip duplication copies recognized
maps to the new ID; deletion removes their owned records, and creating a clip
clears a recognized obsolete record for a reused ID. Duration changes retain the
old map and report it stale instead of silently inventing fractional keys.
Hierarchy reorder keeps the map attached to its surviving bone.

If the underlying resource changes while inputs are pending, discard the
invalidated drafts with their Revert controls. Discarding only a key draft does
not release another pending Model draft. A failed stage retains values for
retry/cancel; stale source bytes cannot be overwritten.

## Stored authoring data and source reuse

A namespaced member in the existing MDLS bone JSON metadata stores frame indices:

```json
{"dynamicWallpaperBoneKeys":{"version":1,"clips":{"7":{"frameCount":4,"keys":[0,4]}}}}
```

Key poses remain the dense samples at those frames. Span edits preserve unrelated
JSON text, unknown fields, large-integer lexemes and metadata on other clips.
Malformed/non-object metadata, duplicate owned fields and future versions remain
read-only for sparse authoring with an explicit reason. Ordinary clip operations
preserve unsupported metadata. No workspace schema migration or sidecar is used.

This integrates the pinned [WebWallGL](https://github.com/oneincase/webwallgl)
clip preview and native sampling behavior with the existing
[lossless MDL codec](editor-model-resources.md#reused-source). Its authoring-map
logic is implemented in this repository. Upstream licenses and pinned hashes
remain in `Editor/ThirdParty/`. SceneScript IDE work is a separate roadmap item.
