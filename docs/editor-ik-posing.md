# Bake a two-segment IK pose

Available in development source. Published 1.0.0 binaries do not include these
Editor tools. Editor remains a separately installed optional application.

1. Select the model layer, switch to **Model**, and choose an end bone with a
   direct parent and grandparent. These identify the middle and root joints.
2. Choose **Two-segment IK** and set the inclusive sample range. Equal start/end
   frames edit one native sample.
3. Enter a target position and a pole position in **MDL model coordinates**,
   before the scene layer’s position, rotation and scale. The pole selects the
   bend side. Its initial suggested value is visible and editable.
4. Select a preview frame inside the range and choose **Preview frame**. This
   pauses and temporarily solos the selected clip. The displayed endpoint error
   measures the encoded native result. Repeated previews replace both joint
   deltas; they do not accumulate or create history entries.
5. Choose **Bake IK pose** to publish one undoable MDL resource revision, or
   **Cancel** / Escape to discard the candidate.

For example, consider a straight chain at root `(-35,0,0)`, middle `(0,0,0)` and
end `(35,0,0)`, with both segments 35 units long. Target `(0,35,0)` and pole
`(-35,35,0)` rotate the root by +90° and the middle by -90° around Z. The middle
ends at `(-35,35,0)` and the end at the target; the root stays in place.

This tool solves exactly two segments using their sampled original lengths.
It changes only the root/middle local rotation samples. Local translations,
scales, end/descendant local tracks, bind transforms, other clips, events and
supported opaque MDL data remain intact. Each frame is solved from its original
pose, with equivalent Euler branches chosen near the previous solved sample.
Preview uses the exact deltas retained by that full-range candidate.

Root and ancestor local scales must be positive and uniform; the middle may
have positive nonuniform scale. Unsupported mirrored/nonuniform ancestors,
zero-length segments, a target coincident with the root, collinear poles and
unreachable targets produce explicit errors. Targets are not clamped, bones
are not stretched, and no joint limits or arbitrary-length chain solver are
provided. Degenerate user poles are never replaced silently. For an initially
straight chain, the suggested pole uses a deterministic perpendicular model
axis; an existing bend otherwise supplies its direction.

Target/pole components must be finite and representable in Float32. The solver
checks the actual encoded hierarchy and rejects an endpoint residual greater
than `1e-5 × (first segment length + second segment length)`. Native translation,
scale, world/skin matrices and animated vertex positions are also validated
before staging. Very large coordinates or Euler angles can therefore fail
explicitly when native precision cannot represent the requested solution.

Keeping the original default target and suggested pole preserves the exact
source pose, including a bent chain, and creates no history entry. Changing
only the pole still solves the new bend side. Scale eligibility is checked on
the actual samples being solved; inspection can open a clip whose other frames
have unsupported scales.

The target guarantee applies to the selected **integer samples**. Playback
between them uses existing native Euler interpolation; it is not a live IK
constraint and need not keep the end exactly on the target. Looping clips wrap
to frame zero at their exact end. Terminal samples can be baked and affect
interpolation approaching the boundary, but exact terminal preview is rejected
before applying a delta to the wrong wrapped sample.

Cancel reloads the authoritative renderer and restores the original clock and
playing/paused state without saving. Bake restores that playback state with the
new resource. Saved clip-layer assignments remain unchanged. Reload restarts
stateful scripts/particles; seeking a clock does not rewind their internal state.
Finish or cancel the dialog before saving or using history. An unfinished dialog
reports an error, including through native freeze; thaw restores its controls.
A staging failure retains the candidate for retry/cancel, and stale source bytes
or bindings cannot be overwritten.

Save/reopen retains the MDL revision. Loose and PKG export contain ordinary
native animation tracks; Main plays them without Editor or an IK solver.
Original source files remain unchanged. Sparse bone key authoring and the
SceneScript IDE remain separate roadmap work.

The tool reuses the pinned [WebWallGL](https://github.com/oneincase/webwallgl)
bone preview APIs, XYZ Euler semantics and existing
[MDL codec integration](editor-model-resources.md#reused-source). Its two-segment
analytic solver is implemented in this repository. Upstream license notices and
source hashes remain in `Editor/ThirdParty/`.
