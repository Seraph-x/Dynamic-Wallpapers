# Live text property bindings implementation plan

> Execute with TDD, independent review and verification before merge. This is
> a renderer PR in the authorized remaining-work completion series.

**Goal:** Bound text and point size update in real Main and Editor playback,
including acknowledged paused rendering frames, without remounting the scene.

**Architecture:** Verify the untouched pinned upstream entry, then transform it
through an exact-match, recorded local patch before esbuild. Keep the public
data-only property API, propagating its actual render-frame promise. Update
bound text state and automatic text boxes through the existing layout/texture
pipeline. Preserve scripts and original source files; no polling remount or
generated script replaces a binding.

**Files:** `scripts/scene-engine-patches.mjs`, its Node tests,
`scripts/scene-bundle.mjs`, WebWallGL provenance/notices, generated Main/Editor
offline bundles, browser/native binding acceptance, binding UI messages/docs.

## Steps

- [x] Add a real pinned-engine regression for playing and paused text/point-size
  changes; confirm current source fails. Record actual layer values, canvas text
  raster calls and GPU output. Test repeated patches, empty/Unicode text,
  grow/shrink, source immutability, no remount and close during frame await.
- [x] Add patch-integrity tests: expected upstream anchor count, changed source
  rejection, deterministic patched digest and unchanged input bytes.
- [x] Implement an exact-match source transform with a stable patch identifier,
  purpose and hashes. Use esbuild's input loader for the transformed entry;
  never modify the dependency cache or hand-edit the minified output.
- [x] Preflight a live patch against directly bound point-size fields before
  changing state: reject non-finite/non-positive sizes explicitly and atomically.
  Then update text/point-size state from resolved source bindings. Route reflow
  through existing text widgets, preserving authored boxes/anchors and script
  control. Compare grow/shrink with a fresh scene loaded at the same defaults.
- [x] Return the actual frame promise through public setProperties without
  exposing Editor controls. A paused patch requests a real forced frame without
  seek/resume; disposal rejects pending acknowledgement.
  Prepare text textures before drawing the frame, and capture each frame's
  waiter batch before the asynchronous renderer starts. An older in-flight frame
  must not resolve a later patch's waiter; disposal rejects pending and active
  batches. Test GPU pixels at promise resolution, paused single-frame repaint,
  and a deliberately held real renderer frame before applying a second patch.
- [x] Rebuild Main and Editor resources and provenance; update corresponding
  source-material hashes and describe the local patch under the original license.
- [x] Replace earlier load-time-only capability assertions with real live text
  and point-size assertions. Retain all existing condition/color/visibility,
  history/source-preservation and native lifetime checks. Update five UI
  languages and current docs to the actual supported behavior.
- [x] Run targeted JS/runtime tests, actual CEF Main loose/PKG + Editor preview
  playing/paused tests, full relevant regressions and reproducible builds with
  the original budgets. Use independently authored expected text/font/pixels.
- [x] Request code review, fix findings with regressions, inspect the final diff,
  run the public-source privacy gate and commit with the configured real identity.
- [ ] Create an English PR, verify the exact tested head/check status and merge.
  Record evidence/PR in the completion ledger; continue the other work packages.

## Evidence and guidance

- Baseline Main and Editor offline resources reproduce at upstream pin 3.0.0.
- The pin updates visibility/color/alpha but not text/point-size layer state.
- Public setProperties currently discards its render result; private Editor
  declareUserProperties already awaits the actual render frame.
- Modern Web Guidance canvas/text searches and catalogue are checked; generic
  HTML-in-canvas guides do not describe this pinned WebGL texture pipeline.

## Recorded verification

- Red: the unmodified pin failed the actual public frame promise assertion.
  The transform integrity tests also failed before their implementation.
- Real pinned Chromium tests passed live text/font rasterization, paused single
  GPU repaint and frozen time, empty/Unicode strings, grow/shrink, three fixed-box
  anchors, authored script precedence, atomic invalid-size rejection, no remount,
  held-real-draw frame ownership and disposal rejection.
- Independent review found no P1 and identified fractional positive point sizes
  below one. A real fresh-scene comparison reproduced the mismatch; reflow now
  uses the same minimum render em calculation as the original mount pipeline.
- Fresh/fresh controls established one-level 8-bit glyph-edge quantization on
  Metal. Geometry and layer state compare exactly; every screenshot channel
  must differ by at most that measured single level, with no differing-pixel
  fraction allowance. Diagnostic source rasters/control PNGs remain in ignored
  verification artifacts.
- 415 Node tests passed. Main bundle and all 86 workbench plus 10 preview
  resources reproduced. The complete 47-phase browser/native CEF runner passed
  with its existing 180-second build and 60-second phase budgets; all 21 native
  runtime instances shut down normally. Main and Editor preview each passed
  real playing/paused text/font raster checks for loose and PKG scenes.
- Authored-source whitespace checks pass. Generated bundles preserve upstream
  shader-template literal whitespace; it is not stripped from vendor strings.
  Logs are in ignored `.build/verification/scene-text-live/`.
