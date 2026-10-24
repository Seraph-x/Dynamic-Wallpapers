# Standalone Editor validation

The Editor is a separate Swift package/application. Main does not depend on its
authoring target, UI resources or installation. PR 1 supplies file contracts;
PR 2 supplies the Editor; PR 3 supplies the optional Main handoff and packaging.

## Reproducible checks

Prepare the pinned CEF dependencies and Editor browser build dependencies as
described in `Editor/README.md`. Build before running targeted Swift tests.

```sh
python3 scripts/swift_sdk.py build --build-tests --disable-sandbox
python3 scripts/test.py --skip-build --filter 'WallpaperCoreTests|WallpaperEditorCoreTests|AudioSpectrumAnalyzerTests|SystemAudioSpectrumControllerTests|SceneSurfaceTests|LocalizationResourceTests'
node --test Editor/Web/document.test.mjs Editor/Web/runtime.test.mjs
node Editor/Web/build.mjs --check
cd Editor
python3 ../scripts/swift_sdk.py build --disable-sandbox
```

From the repository root, `python3 scripts/test-editor-native.py` builds an
isolated application, verifies the typed protocol, exercises the real browser
workbench, and then runs native CEF acceptance. `SCENE_CHROMIUM_EXECUTABLE`
explicitly selects an installed Chromium/Chrome executable; otherwise Playwright
requires its matching browser installation. Node is a build/test dependency only.
Each acceptance execution phase has a 60-second budget; compilation has 180.

## Verified behavior

- Unicode file links, strict versions/fields, malformed descriptors and local
  file boundaries; project copies, unknown fields/resources, atomic saves,
  revision conflicts, symlink root redirection, and checked PKG tables.
- Actual text/image pixels, color edits, exact undo/redo pixels, hit testing and
  canvas dragging, one-step drag undo, and real upstream PKG export.
- Focused text fields flush before snapshot/freeze. Asynchronous preview/save
  acknowledgement preserves focused input. Frozen keyboard shortcuts cannot
  modify the document; thaw restores editing. Native Cancel/save-failure paths
  were separately reviewed for retained ownership and explicit thaw.
- Native `SetAsChild` browser view attachment, actual AppKit keyboard input,
  window resize, explicit browser close, matching opened/released resources,
  and exactly one CEF shutdown. The test drains AppKit autorelease pools just
  as the application's normal event loop does.
- Exported loose and PKG scenes are read by Main's existing scene runtime and
  must produce actual green image/red text pixels. Both forms produced 3,200
  green pixels and 16,329 red pixels in the authored acceptance scene, then
  closed with all resources released. Texture upload is awaited explicitly;
  engine readiness alone is insufficient evidence for texture content.

The broader existing application suite includes UI and media tests unrelated to
Editor. Generate its real authored media fixtures with
`bash scripts/feasibility/mpv/fixtures.sh` before running that suite. Full-suite
failures must be recorded separately from focused Editor acceptance; do not
describe a successful focused run as a successful full suite.

## Broad-suite limits recorded during PR 2

The focused 164 Swift tests and 17 JavaScript tests passed. The complete existing
Swift suite was also attempted and did not pass: media cases initially lacked
generated MPV fixtures, and several existing AppKit UI assertions failed. After
generating the real media fixtures, the 21 selected playback/routing/MPV tests
passed. The accent-outline accessibility failure was reproduced on unchanged
`main` at `59afd3d` as well. These broad-suite results are not represented as an
Editor acceptance pass; unrelated Main UI code is unchanged in this PR.
