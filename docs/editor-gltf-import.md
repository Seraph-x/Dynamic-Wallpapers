# Import a glTF model

Choose **File → Import model…** in the standalone Editor and select a local
`.gltf` or `.glb` file. Keep referenced buffers and PNG/JPEG images beside the
entry file in their original relative locations. Network URLs, parent paths,
symlinks and ambiguous case/Unicode names are rejected. The webpage receives
owned bytes from the native picker, never permission to browse your filesystem.

The dialog shows a real renderer preview, the selected scene, model scale,
position, bake FPS and loop/once playback. Change conversion settings and choose
**Update preview** before importing. PBR materials require a separate, initially
unchecked agreement to convert to unlit base color. Single-sided materials also
require agreement to the renderer's two-sided surfaces. Cancel or Escape leaves the
project unchanged. Finish or cancel the dialog before saving or editing the scene.

**Import model** adds one model layer and its resources in one undo step. The
Model workspace opens for hierarchy, bind/rest and weight editing. Save/reopen
and loose/PKG export retain the converted model. **File → Open in Dynamic
Wallpaper** sends a copy through the existing application handoff.

## Understand the conversion

| Source | Result |
| --- | --- |
| Scene nodes, joints and inverse binds | MDL bones, including rigid mesh nodes and animated ancestors |
| Triangle primitives and separate materials | Separate MDL meshes; no texture atlas |
| Up to four positive influences after merging duplicate joints | Preserved weight ratios; a necessary fifth influence is an error |
| LINEAR, STEP and CUBICSPLINE TRS animation | Dense local MDL tracks at the selected FPS |
| Unlit/base-color PNG and JPEG textures | Unlit wallpaper materials with factor, OPAQUE and baked MASK processing |
| PBR materials | Only after consent: lighting, metallic/roughness, emission and other PBR effects are discarded |
| Original entry, buffers and images | Exact source bytes under `imports/editor/<ID>/source/` |
| Conversion settings, clip durations and notes | `imports/editor/<ID>/conversion.json` |

Both loose and PKG exports preserve the archive's original paths and bytes,
including legal glTF buffers with a `.pkg` suffix. Runtime texture conversion
still applies to generated material resources, separately from this archive.

Animation is a sampled approximation between output frames. For duration `D > 0`
and FPS `F`, the model has `ceil(D × F)` intervals and samples at `frame / F`.
The encoded duration is `ceil(D × F) / F`; the final sample clamps to the source
endpoint. A fractional final interval is therefore an approximation, not a
rescaling of the entire animation. For example, 0.37 seconds at 30 FPS becomes
12 intervals, 0.4 encoded seconds, with the 0.2-second sample taken at exactly
0.2 seconds. A zero-duration clip becomes one constant interval. Each clip's
original/encoded duration, interval count and FPS appear before confirmation.

The pinned renderer uses clamp and linear/mipmap texture sampling; glTF wrap
and filter choices can look different. Texture transforms are baked into the
selected UV channel. Alpha masks are baked into pixels, with possible edge
filtering differences. Color factors are applied in linear space. Texture
readback preserves unpremultiplied RGB, including transparent pixels whose RGB
becomes visible in glTF OPAQUE mode. All original image bytes remain archived.

Morph targets, nontriangle primitives, unsupported attributes/extensions,
BLEND transparency (the pinned renderer cannot preserve transparent depth
and sorting semantics),
conflicting shared-joint bind matrices and unrepresentable transforms are
explicit errors. Unknown source metadata remains in the archived originals;
it is not presented as an editable feature. The candidate must actually render
and fit its linked GPU skin palette before publication. No guessed capacity,
missing-resource substitution or influence truncation is used.

## Source references

Parsing and compatibility follow the [Khronos glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).
Selected matrix, quaternion, sampling and PNG helpers are adapted from MIT
[WebWallGL `editor/gltf.ts`](https://github.com/oneincase/webwallgl/blob/197abe54266c31d346cebc314e49a26b70c960cc/editor/gltf.ts).
The upstream parser, basename lookup, influence truncation and conversion
fallbacks are excluded. Source commit, checksum, adaptation and local hashes
are recorded in `Editor/ThirdParty/gltf-provenance.json`; the complete MIT
notice is in `Editor/ThirdParty/WebWallGL-MDL-LICENSE`.

See [standalone Editor validation](testing/standalone-editor.md) for reproducible
checks. The native import picker and resource transaction are implemented here;
the Editor and wallpaper app keep their independent processes and data roots.
