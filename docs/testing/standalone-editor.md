# Standalone Editor validation

The Editor is a separate Swift package/application. Main does not depend on its
authoring target, UI resources or installation. PR 1 supplies file contracts;
PR 2 supplies the Editor; PR 3 supplies the optional Main handoff and packaging.

## Model workspace acceptance

The Editor/runtime checks contain 246 JavaScript tests, including native mixing, dense pose frames, clip authoring, glTF conversion,
source/package decoding, atomic resources and the existing Model/Timeline tools.
The reproducible build verifies 47 offline resources. Complete protocol, real-browser, image/brush
browser, rest/glTF/clip/pose/mixing browser, native, native-brush, native-rest, native-glTF,
native-clip, native-pose and native-mixing acceptance passes
with the explicitly approved isolated test-keychain configuration.
Product/source checks pass 3 Editor product tests, 42 product-configuration
tests and 16 public-source export tests. These focused checks do not establish
a full application-suite pass.

## Native animation-layer mixing

Run `node --test Editor/Web/model-mixing.test.mjs Editor/Web/model-clip-edit.test.mjs Editor/Web/document.test.mjs`
for native table operations, optional defaults, unknown/controlled row retention,
owned asynchronous candidates and one-revision resource/table history. The
combined transaction stages once; a table-only change stages no MDL resource.
Stale document/MDL/puppet content or a failed stage cannot publish partial JSON.

`node Editor/Web/test-model-mixing.mjs` verifies actual sequential ordering,
weights, rate, visibility and additive pixels. It covers zero/negative additive
totals, first-additive reference initialization, totals above one, extrapolating
ordinary weights, zero rate and all explicit rows hidden. Actual forms exercise
structural edits, confirmed removal/cancellation, invalid focused inputs,
selection restoration, failed staging, independent draft recovery, controlled
rows, malformed whole tables, save/reload and both exports. Five languages,
both themes and 850 × 540 with Timeline pass layout, labels, modal focus and Escape.

The complete runner includes independent `browser-mixing` and `native-mixing`
phases, each at 60 seconds, retaining every previous phase and budget. Real
AppKit changes the second native row's weight from 0.5 to 0.25 without blur.
The frozen document must differ only at that JSON value; staging stays empty
and original MDL bytes/hash remain exact. Save/Undo/Redo retain the full table.
Actual persisted mixing renders 52.5 units at 0.5 seconds; Main loose/PKG
playback independently shows 45..105 motion, known 75-unit interpolation and
the 105-unit peak. All pages release and each runtime shuts down exactly once.

Initial browser regressions found two new form issues: querying `:invalid`
selected a fieldset with an empty validation message, and async modal creation
left focus on the dialog while buttons were temporarily disabled. Validation
now targets the invalid input/select with a nonempty error; the Cancel button
regains focus when the operation finishes. The browser harness also checks the
presence of an `error` field, so an empty error can never count as success.
The new standalone core module is explicitly included in the offline build.

After these corrections, repeated focused browser runs and the complete new-
directory browser/native runner passed. The final source also passes 246 JS
tests, 47 reproducible offline resources, independent Editor build and real
resource-bridge/save checks, 3 product tests, 42 configuration tests and 16
source-export tests. Independent code review passed. Production keychain
behavior is unchanged; only the approved isolated test-host keychain is used.
These are focused Editor checks, not a full repository-suite claim.

## Native bone pose frames

Run `node --test Editor/Web/model-poses.test.mjs Editor/Web/runtime-model-preview.test.mjs`
for exact one-bone/sample changes, source immutability, bind reset, canonical
Float32 radians, endpoint-preserving interpolation, native Euler wrapping,
invalid indices/transforms and sampled world overflow. Preview replacement and
target seeking must remain one runtime queue task before later Timeline seeks.

`node Editor/Web/test-model-poses.mjs` edits the actual forms and renderer. It
checks Copy/Paste/Reset, known exact/intermediate pixels, native loop wrapping,
canonical degree no-ops, combined bone/clip/pose history, hierarchy reindexing,
empty focused inputs, failed staging and independent draft recovery. Save/reload
and loose/PKG export use the actual authored MDL. Five languages, both themes
and 850 × 540 with Timeline cover associated labels, keyboard access and layout.

Separate `browser-poses` and `native-poses` phases retain a 60-second budget each;
no existing phase or budget is removed. Native CEF uses trusted AppKit input
and freezes without blur, checking that precisely one Float32 value changes in
the complete MDL, while scene assignments and all other bytes remain exact.
Hash, saved acknowledgment and complete Undo/Redo are required. Actual preview
pixels must show 140 units at 0.5 seconds. Main must independently render both
exports in the authored 90..120 range, including known 105-unit interpolation
and the 120-unit peak, with stationary bind placement, complete page release
and exactly one runtime shutdown.

Browser regressions exposed a French nowrap button wider than the minimum
inspector and duplicated ownership of an empty focused pose-input error.
Scoped wrapping fixes the first; the Model pose tool now owns its validation
and recovery, while unused bake-range settings do not block saving. These
regressions passed after correction. Production keychain behavior is unchanged;
only the already approved isolated test-host keychain is used for native checks.

The first native pose run failed its combined pixel/time assertion because the
test read the hidden Timeline's unrefreshed time field. Native diagnostics showed
the actual pose at 139.74 units for the requested 140, with the Timeline hidden
and its input still at zero. The harness now opens Timeline before checking its
time; both the original 140-unit pixel and 0.5-second assertions remain intact.
No production timeout, previous coverage or phase budget is changed.

After that harness correction, both the focused native pose phase and a new-
directory complete runner passed all existing and new phases. The final build
also passed 230 JavaScript tests, all 43 offline resource hashes, the independent
Editor build/resource-bridge round trip and the 3/42/16 product checks listed
above. Independent code review and the changed-file privacy gate passed. This
is focused Editor acceptance, not a full repository-suite claim.

## Skeletal clip acceptance

Run `node --test Editor/Web/model-clips.test.mjs Editor/Web/model-clip-edit.test.mjs Editor/Web/runtime-model-preview.test.mjs`
for lossless clip operations, event metadata, normalized samples, source-byte
ownership, hidden shared-model references, staging failures and queued preview
ordering. Default deletion requires a surviving replacement; final deletion is
verified as an empty MDLA with static bind geometry. Unchanged source metadata,
native playback tables and all original binding fields survive Undo exactly.

`node Editor/Web/test-model-clips.mjs` exercises real create/duplicate/settings,
temporary preview versus saved assignment, first/default/last deletion, explicit
reference protection, invalid focused input, failed native freeze recovery,
combined bone/clip history, saved reload and both exports. Known intermediate
motion samples are checked with rendered mesh pixels. A failed clip selection
must restore the visible old selection. Five languages, both themes and
850 × 540 with Timeline cover associated labels, modal focus and Escape.

The full native runner adds separate `browser-clips` and `native-clips` phases,
each retaining a 60-second budget. Native CEF types the clip name and FPS through
AppKit, freezes without blur, verifies the actual MDL/hash and unchanged bind
section, saves, undoes/redoes and uses trusted dialog input to restore default
playback. Actual renderer pixels verify the authored 8-FPS clip at 0.25 seconds.
Main exercises both assigned-motion exports and both static exports after final
clip deletion; static geometry is checked again over at least 0.5 seconds.
Every page must close completely and each phase must shut down its runtime once.

The first native attempt exposed repeated top-level `const` declarations in two
new test-injected focus scripts. Local function scopes fixed that test-host
failure; no production deadlines, existing coverage or budgets were changed.
The focused native clip phase passed all keyboard, motion/static export and
lifetime checks, followed by a fresh-directory complete runner pass covering
every existing and new browser/native phase. Production keychain behavior remains unchanged; native tests
use only the already approved isolated test-host keychain.

Independent Editor builds and its real resource-bridge round trip pass, together
with 3 independent-product, 42 configuration and 16 source-export checks. The
offline resources reproduce at 40 files. These are focused feature checks,
not a claim that every repository test suite was run.

## glTF import acceptance

Run `node --test Editor/Web/gltf-*.test.mjs Editor/Web/package-archive.test.mjs`
for strict owned-source parsing, interleaved/normalized/sparse accessors, hierarchy,
inverse binds, weights, curve sampling and atomic import/history checks. The
source reader additionally has 15 Swift tests for exact referenced files, pinned
root ownership, symlinks, case/Unicode aliases and URI decoding/control characters.
The real `EditorResourceBridgeTests` test verifies native blob/save round trips.

`node Editor/Web/test-gltf-import.mjs` uses a real Chromium renderer to preview
and import the candidate, require unchecked material conversion consent, cancel,
edit the imported skeleton, undo/redo, reopen and export. It checks exact
transparent/low-alpha texture RGB during OPAQUE conversion and preserved source
pixels/orientation. All five languages, both themes and 850 × 540 with Timeline
are exercised with associated labels, modal focus and keyboard cancellation.
The fixture deliberately names its glTF binary buffer `rig.pkg`; source buffers,
images and metadata must retain exact paths and bytes inside exported PKG, even
though the upstream builder normally excludes files with that suffix.

The full `scripts/test-editor-native.py` adds independent `browser-gltf` and
`native-gltf` phases with the existing 60-second per-phase budgets. Native CEF
uses the actual owned-bytes command and shader preview, AppKit keyboard input
and trusted Escape/Return confirmation. It verifies source/resource hashes,
MDL hierarchy and baked clips, saved acknowledgements, atomic history, actual
0.2-second render pixels, per-page release and exactly one runtime shutdown.
Main plays both loose and PKG exports with fixed green geometry, separate blue
material and a known intermediate displacement. Only the previously approved
test-host isolated Chromium keychain is enabled; production behavior is unchanged.

Two initial native failures belonged to the new test harness: direct CEF key
events did not follow the macOS child-view input path, and autoreleased synthetic
AppKit events held native views until the outer pool drained. The harness now
uses the existing AppKit input path and a local event autoreleasepool. Production
timeouts, existing checks and phase budgets were not increased or removed.

The final clean-directory run passed every build, protocol, browser and native
phase. Editor's exact 0.2-second sample and Main loose/PKG intermediate motion
assertions passed, with complete page release and one shutdown. Repeated focused
browser runs additionally cover actual GLB preview and textured OPAQUE pixels.
Product verification passes 3 independent-Editor tests, 42 configuration tests,
16 source-export tests and reproducibility of all 36 offline resources. Root
and standalone Editor builds pass; the 15 source-boundary tests and one real
native resource bridge test pass. This remains focused feature acceptance,
not a claim that every repository test suite was executed.

The browser edits actual model forms and checks the measured linked GPU
palette, bone picking without layer dragging, rename/create/reparent/delete,
weighted/attached replacement confirmation, cancellation, numeric weight pixels
and undo/redo. Invalid model drafts block Timeline creation/key submission and
native image insertion. A model rename preserves an independent property-key
draft, and the native barrier subsequently commits it. An injected resource-read
503 and an unsupported forward-parent source remain explicit and permit leaving
the Model workspace and recovering without losing the document.

All five languages, both themes and the 850 × 540 layout are checked with the
Timeline open, without content edits. A first combined run failed by comparing
screenshots at different canvas sizes after the layout test; the layout helper
now restores its entry viewport. Pixel tolerances were not increased. The full
browser/native run subsequently passed.

Native CEF additionally enters a bone name through real AppKit keyboard events,
freezes without blur, verifies the authored name and SHA-256 in the actual staged
MDL bytes, acknowledges Save, then checks native undo/redo. User-authored model
resources continue through saved-document reload and loose/PKG export into
Main's actual CEF scene runtime, where bind placement, the stationary left bone
and intermediate right-bone deformation are asserted. Normal page closure and
exactly one runtime shutdown remain required. See the
[workspace guide](../editor-model-workspace.md) for user-visible semantics.

Image-to-mesh acceptance exercises cancellation, unsupported dimensions, a real
second-stage HTTP failure, shared-image isolation, explicit layer size/alignment,
one-step history and exact image pixels after conversion. Pixel captures exclude
SVG editing controls and rounded workbench clipping; scene pixels are compared
without increased tolerances. The browser creates an independent bone and uses a
documented test-only native MDLA fixture to verify weight deformation. It saves,
reloads and exports the authored image-generated model; no skeletal clip UI is
implied. Five languages and both themes at 850 × 540 verify labels, native modal
focus, Escape and unchanged content.

The native harness additionally creates the grid from actual owned image files,
checks three staged hashes and the selected binding, then freezes, saves and
undoes/redoes the complete conversion. Main renders the original four-quadrant
image and both converted loose/PKG exports. Assertions require the correct
orientation/bind placement and changing intermediate root motion in the known
0..20-pixel range, followed by page closure and exactly one runtime shutdown.
The independent Editor builds successfully and its real native resource bridge
test passes, including workspace-scoped inventory and denied unknown workspaces.
The resource protocol rejects inventory requests with extra paths/fields.

## Weight brush acceptance

The brush uses real pointer capture and edits actual staged MDL weights. Coverage
includes segment interpolation, influence normalization, one history step per
stroke, no-op completion, Escape/pointer cancellation, delayed preparation and
pointerup followed by native freeze, explicit stage failure/recovery, and
preserving an unrelated invalid Timeline draft. Browser acceptance saves,
reopens and exports the painted mesh in loose and PKG form. Main's native CEF
frames must show a stationary painted corner while the remaining root-driven
vertices move over the documented test-only MDLA fixture's 0..20-pixel range.
The fixture establishes playback of painted weights, not skeletal clip authoring.
A separate native brush phase uses actual CEF pointer input, Save and undo/redo;
normal closure and exactly one shutdown are required in each native phase.
The complete run passed protocol, browser, image/brush browser, native and native
brush phases within the unchanged budgets. A second native-brush execution with
a fresh context also passed real input, history, both export formats and normal
single shutdown. The independent Editor build and
real native resource-bridge test also passed. The production Editor executable
omits the test-keychain marker, and an unknown test-keychain mode exits with 64.

A native validation attempt reached the expected export pixels but exceeded its
60-second shutdown budget. Symbolication identified a worker waiting for macOS
Keychain authorization in `KeychainPassword::GetPassword` / `SecItemCopyMatching`,
while the main thread waited in `TaskTracker::CompleteShutdown`. That attempt
remains failed; changing argv or message-pump draining did not resolve it and
those experiments were not applied to production source.

For explicit, user-approved test isolation, run:

```sh
EDITOR_NATIVE_TEST_KEYCHAIN=isolated python3 scripts/test-editor-native.py
```

`isolated` compiles Chromium's `--use-mock-keychain` only into the native test
host. It does not create a macOS Keychain and does not validate system-keychain
integration. Real CEF rendering, resource transactions and shutdown assertions
still run. Unset `EDITOR_NATIVE_TEST_KEYCHAIN` or set it to `system` to use the
normal system keychain; unknown values fail the build. Production app builders
do not define this test macro and omit the switch entirely.

## Local rest-transform acceptance

The focused tests cover exact selected-matrix edits, source/unknown-data
preservation, canonical no-op precision, reflections and gimbal cases, malformed
inputs and renderer-matched Float32 parent composition/inversion. A combined
rest/parent transaction validates the final candidate, covering both a rejected
singular combination and a successful repair whose intermediate state is invalid.

A dedicated real-browser phase changes Right bind X from 35 to 45 and verifies
its mesh shifts left by ten scene units while Left and the existing Y animation
remain unchanged. It checks focused freeze, one-step history, invalid scale and
Timeline/native insertion barriers, combined numeric weights, staging failure,
selection preparation, unrelated Timeline drafts, saved reload, both exports and
an explicitly read-only sheared source. Existing layout acceptance opens the nine
rest fields in all five languages, both themes and 850 × 540 with Timeline.

Early pixel assertions included the bone editing overlay; the test now compares
scene pixels in the same workspace with Show bones disabled. Tolerances are
unchanged. Another test incorrectly expected freeze to reject an invalid draft;
the existing close-state protocol returns the valid document with dirty=true.
The regression now checks that exact contract, then requires a saved snapshot
to fail and explicit thaw/Revert recovery. Production freeze behavior is unchanged.

An initial complete native execution failed in the existing brush phase because
no authored weight change was observed. The harness now awaits the actual
trusted pointerup target before freezing, and sets host focus before measuring
map coordinates. The rest harness similarly waits for the actual focused input
before sending AppKit keyboard events. These are test-host synchronization checks;
they do not synthesize successful application replies or bypass content checks.
That failed execution remains failed. A fresh complete run passed all phases
within unchanged budgets, including original brush history/export coverage and
the new rest keyboard/matrix/hash/history assertions. Main rendered both rest
exports with the right mesh shifted ten pixels and known intermediate Y motion;
the left mesh stayed fixed. All three native phases closed normally with exactly
one runtime shutdown each. The independent Editor build and real resource-bridge
test passed; its production executable omits the native-test keychain marker.
A second native brush/rest run with fresh contexts also passed actual inputs,
history, both exports and normal single shutdowns. These remain focused results,
not a full application-suite or system-keychain integration pass.

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
