# Standalone Editor validation

The Editor is a separate Swift package/application. Main does not depend on its
authoring target, UI resources or installation. PR 1 supplies file contracts;
PR 2 supplies the Editor; PR 3 supplies the optional Main handoff and packaging.

## Reproducible checks

Prepare the pinned CEF dependencies and Editor browser build dependencies as
described in `Editor/README.md`. Build before running targeted Swift tests.

```sh
python3 scripts/swift_sdk.py build --build-tests --disable-sandbox
python3 scripts/test.py --skip-build --filter 'WallpaperCoreTests|WallpaperEditorCoreTests|EditorLauncherTests|EditorInstallPromptTests|EditorHandoffTests|AudioSpectrumAnalyzerTests|SystemAudioSpectrumControllerTests|SceneSurfaceTests|LocalizationResourceTests'
node --test Editor/Web/document.test.mjs Editor/Web/runtime.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs
node Editor/Web/build.mjs --check
cd Editor
python3 ../scripts/swift_sdk.py build --disable-sandbox
```

For resource-transaction coverage also run all Editor browser modules and the
independent native host bridge test:

```sh
node --test Editor/Web/*.test.mjs scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs
(cd Editor && python3 ../scripts/swift_sdk.py build --build-tests --disable-sandbox)
(cd Editor && python3 ../scripts/test.py --skip-build --filter EditorResourceBridgeTests)
```

## Resource revision acceptance

Schema-1 documents retain their format until resource edits need schema 2.
Schema-2 revisions retain their version even after undo/removal leaves no
overrides. Tests exercise content hashes, immutable deduplication, corrupt or
missing blobs, workspace isolation, symlinks, revision conflicts, actual manifest
write failure and exact saved bytes after failure. Case/Unicode aliases of
reserved files, existing resource spellings and file/directory collisions are
rejected before a revision is published. Single-resource reads verify the
requested bytes without rehashing unrelated versions; reopen/save still verify
the complete revision.

The browser exercises adding a new texture and replacing an existing material,
including exact rendered undo/redo and the same resolver in PKG export. Native
CEF acceptance stages/reads a resource, acknowledges a save, then reopens the
revision with a resource read before first-frame readiness. Resource replies
bypass the rendering wait, so both an initial render and an in-progress native
command can finish. The standalone Swift bridge test uses the actual store and
checks malformed requests, cross-workspace denial and the empty-map saved
snapshot representation.

The updated authored export has a half-green/half-blue image and red text.
Two fresh complete browser/native executions rendered 1,600 green, 16,327 red
and 1,600 blue pixels in both loose and PKG form in Main's actual scene runtime.
Each execution completed normal CEF closure and exactly one runtime shutdown.
The focused checks passed 182 root Swift tests, one independent Editor host
test, 24 JavaScript tests, three Editor product tests, 42 product configuration
tests, 16 source-export tests and reproducibility of all ten offline resources.
The owned-source privacy gate was clean.

A prior native attempt failed because the harness blurred the input before the
final native keyboard event reached CEF's renderer (the observed title was
`Keyboar`). The harness now waits for actual DOM receipt, acknowledged through
its test-only reply slot, before blur. The complete text assertion is unchanged;
the failed attempt remains a failure, not a passing retry. An outer sandbox also
prevented SwiftPM's manifest sandbox from starting during a product-config check;
that check passed when run outside the outer sandbox. No product checks were
disabled. These focused results do not establish a full application-suite pass.

## Property timeline acceptance

The timeline uses the pinned engine's native `animation.c0/c1/c2` channels,
frame-based `options` and front/back Bezier handles. The renderer is the sampling
authority; there is no second animation evaluator in the Editor. Model tests
cover one-step undo, failed-edit rollback, duplicate-frame rejection, relative
values, unknown fields, custom handle preservation, explicit binding replacement,
copy/paste and conversion back to a sampled constant. Clock tests verify engine
time, preview wrapping, freeze behavior and queued relative frame steps.

`Editor/Web/test-timeline.mjs` runs inside the existing real-browser acceptance.
It creates and edits position, scale, rotation, RGB and opacity tracks, checks
known linear and smooth intermediate values, verifies exact snapped sampling,
and exercises drag, copy/paste, native/toolbar undo, keyboard movement and the
preview range. It tests conversion cancellation/restoration and that seeking
does not dirty content. All five languages open the timeline at 850 × 540
without horizontal overflow while retaining a usable canvas.

The input cases are deliberately asynchronous: canvas selection, adding a layer,
title/property changes and native save must retain unapplied key/settings drafts.
Edits arriving while an older commit is rendering must remain pending or be
committed as the next revision. A queued Add key must retain its original target
when another property is selected. Rapid key movement spans both an old DOM
node and a rebuilt node, then verifies each undo step. Invalid drafts survive
freeze/thaw; rejected occupied-frame drags restore the actual key position.

Native store tests save/reopen and reimport loose/PKG versions of a curve while
preserving its unknown metadata and tangents. Native CEF acceptance additionally
plays the exported animated scene in Main's existing runtime and observes the
green image's centroid move by more than three pixels in each representation.
This establishes actual playback, beyond metadata checks or a static first
frame. Text and image pixel assertions, resource release and exactly one CEF
shutdown remain required. Pixel counts may vary with moving image/text overlap;
they are not treated as identical static screenshots.

Validation failures found while implementing these cases are recorded as
failures. In particular, the first selection implementation retained an old key
form briefly, old selection paths discarded drafts, relative steps could collapse,
and asynchronous commits could erase newer input. Their regressions must stay
in the suite; disabling the interactions or adding successful mock replies is
not an acceptance strategy. Independent review rechecked the fixes, including
the fixed resource-reply bypass of input/command barriers.

The final focused checks passed 183 root Swift tests, one independent native
Editor bridge test and 31 JavaScript tests. Product checks passed three Editor,
42 configuration and 16 source-export tests; all 16 offline resources reproduce.
Several fresh complete browser/native runs finished within the existing phase
budgets. The final runs include twelve rapid key moves across DOM generations
and twelve undo steps, actual native CEF track creation, unblurred key input
flushed by freeze, a clean save acknowledgement and typed seek. Main played
both export formats with a moving image centroid, and all pages/resources closed
before the single CEF shutdown. The final browser also exercises native range
keyboard and pointer scrubbing, so a passing programmatic seek alone cannot
stand in for a working timeline slider. These remain focused checks, not a
passing claim for the unrelated complete application suite.

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

## Main handoff and independent package

Build a new candidate, never an installed destination:

```sh
python3 scripts/test-editor-product.py
python3 scripts/test-export-public-source.py
python3 scripts/test-product-configuration.py
python3 scripts/build-editor-app.py --output 'dist/editor/Dynamic Wallpaper Editor.app' --zip
```

The builder copies sources into a neutral temporary directory and recompiles
CEF's wrapper there. Reusing a wrapper previously built under a personal home
embeds its paths even when the current Swift source directory is remapped.
The first integration candidate exposed this; the builder now checks generic
macOS/Linux/Windows home paths in every packaged file, including ZIP extraction.
CEF's built-in Chromecast wallpaper and DNS-provider privacy strings are URL
paths, not local home directories. The external privacy skill
gate additionally scans owned files/installation notes; fixed upstream CEF
runtime and copyright notices are checked separately and retained intact.

The candidate has its own 0.1.0/build 1 metadata, five helper identifiers,
offline workbench, complete CEF framework, five languages and license notices.
All Mach-O dependencies, arm64/macOS 14 targets and deep ad-hoc signatures are
verified before and after ZIP extraction. This does not publish or install it.

Integration coverage includes no lookup/download/filesystem work at launcher
construction; missing Editor Download/Cancel without automatic installation;
installed Editor opening without a prompt; visible validation failures; centered
first-row logos and exactly two localized buttons; bounded ordinary descriptor
files; redirected exchange roots; exact scene entry matching before copying;
and managed Main imports that select the library item without changing display
assignments or adding to playlists. The shared permission-dialog header also
retains its existing layout contract.

Real application acceptance uses isolated Editor data and a Main validation
bundle identity/data root. A typed link opens a Main-managed scene in Editor;
File → Open in Dynamic Wallpaper saves an immutable handoff that imports back
as another owned Main scene. Main's playlist entries and display assignments
remain unchanged. Repeated scene links reuse the same process/project while
preserving unsaved input; quitting Main leaves Editor's animated preview and
unsaved edits alive. Saved projects are outside the application bundle.

Native integration exposed reordered JSON dictionary keys incorrectly leaving
the document dirty after a successful save. The document comparator now ignores
object key ordering while preserving array order and copies the saved snapshot.
Regression coverage includes native dictionary round trips, external mutation,
undo/redo and meaningful array-order changes.

An expanded native harness initially exceeded its unchanged 60-second execution
budget at CEF shutdown. Its exported-playback scopes now drain autoreleased
AppKit temporaries before shutdown, matching the normal application event loop
and the Editor setup scope. Timed-out attempts are recorded as failures, even
when SIGTERM subsequently causes shutdown to finish; they are not passing runs.

Final integration verification passed 176 focused Swift checks (including the
existing shared-header layout regression), 18 JavaScript tests, 42 product
configuration checks, 16 source-export checks, 3 independent-product checks and
14 offline-help checks. After the harness lifetime fix, an isolated native run
and a new-directory complete browser/native run both finished normally within
the unchanged budgets. The final standalone release candidate was rebuilt from
neutral source, ZIP-extracted and signature/closure/privacy-checked. Its actual
window reopened the retained workspace, edited and saved it, displayed Saved,
and quit normally without another unsaved-change prompt. Removing the earlier
registered validation apps preserved the saved workspace bytes exactly; Main
reopened and rendered its existing scene library independently.
