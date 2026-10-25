# Bake a local FK delta

Development source only; the published 1.0.0 application does not include these
Editor tools. Editor is an optional, separately installed application.

1. Open a scene containing a readable skinned MDL and choose its layer.
2. Switch to **Model**, select a bone and animation clip, then choose
   **FK local delta**.
3. Set the inclusive start/end sample range. Equal endpoints edit one sample.
   For example, frames 0–2 on a 2 FPS clip cover samples at 0, 0.5 and 1 second.
4. Enter local translation offsets, XYZ Euler rotation offsets in degrees, and
   scale multipliers. Zero offsets and unit multipliers leave the model unchanged.
5. Choose a preview frame inside the range and **Preview frame** to inspect it.
   Preview pauses playback and temporarily solos this clip. Repeated previews
   replace the previous delta; they do not accumulate or create history entries.
6. Choose **Bake FK delta** to write the selected bone’s native samples in one
   undoable resource revision. **Cancel** or Escape discards the candidate.

Translation and rotation add to each original local sample; scale multiplies it.
These are native local XYZ Euler deltas, not world-space or quaternion rotations.
Children follow the transformed parent through the existing FK hierarchy; their
local tracks, bind transforms, other clips, events and unrelated resources remain
unchanged. The operation preserves existing animation rather than flattening the
whole selected range to one pose.

A loop wraps to sample zero at its exact end. Its terminal sample influences
interpolation approaching the boundary. You can bake a terminal-only range, but
Preview reports that an exact terminal pose is unavailable in loop mode. It does
not apply that delta to the wrapped first sample. Bake, then inspect playback
just before the endpoint. Mirror/once clips can preview their terminal sample.

Cancel rebuilds the authoritative document renderer and restores the original
clock and playing/paused state. Bake restores the same playback state with the
committed resource. Existing saved clip-layer assignments remain unchanged.
Rebuilding restarts stateful scene scripts and particles; restoring a clock is
not a rewind of their internal state.

Finish or cancel the dialog before saving, changing selection or using history.
An unfinished dialog produces a visible error instead of saving a preview.
Invalid numbers, singular transforms, Float32 overflow/underflow and stale
resources are rejected. A staging failure keeps the candidate available to retry
or cancel. No generated MDL is published before staging succeeds.

Save/reopen retains the authored resource revision. Loose and PKG export contain
ordinary MDL tracks and play in Main without Editor installed. Source project
files remain unchanged. This PR provides numeric FK manipulation; IK posing,
sparse authoring keys and the SceneScript IDE remain separate roadmap work.

The implementation uses the pinned **WebWallGL 3.0.0** native bone pose and
animation APIs. The existing MDL codec is attributed in
[MDL source attribution](editor-model-resources.md#reused-source).
