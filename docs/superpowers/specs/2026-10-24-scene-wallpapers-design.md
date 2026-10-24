# macOS Scene Wallpaper Support

## Approved scope

The user approved local Wallpaper Engine scene packages/projects rendered through
WebWallGL in the existing macOS CEF runtime, with playback, volume and pointer
interaction, delivered as multiple PRs. System audio spectrum capture and a scene
editor are excluded. No Wallpaper Engine executable, network service, paid API,
or user's running application is required. PRs and commits use English and the
existing identified Git author.

## Architecture and alternatives

Use the existing CEF runtime and the MIT-licensed WebWallGL 3.0.0 browser bundle.
This retains the application's playback ownership, multi-display grouping and
native audio output. Alternatives are a new Metal renderer (requires a separate
implementation of scene formats/shaders) or pre-rendered video (still requires a
renderer and loses interaction); neither meets this request as directly.

Introduce a first-class scene media kind/backend and a SceneProjectReference.
Keep native/video/web routes unchanged. The application owns imported files and
runtime instances; the engine only receives the selected project's resources.
A scene surface implements the existing PlaybackSurface lifecycle.

Data flow:

    imported project -> owned project copy -> per-page local resource mounts
    -> trusted scene shell + pinned WebWallGL -> CEF WebGL2 -> desktop surface

## Scene import and persistence

Accept a user-selected project directory containing project.json and either a
scene.pkg package or loose scene JSON/resources. Read project.json as data:
require a scene type and reject application/executable projects. Resolve the
actual representation from existing safe project-relative files; record which
entry was chosen. Support the common declared scene JSON plus actual scene.pkg
layout without treating a thumbnail or embedded movie as the requested scene.
Reject ambiguous/missing entries and invalid project metadata explicitly.

Copy the whole project through the existing descriptor-checked managed-media
store. Preserve the original project's provenance and directory ownership for
rollback and removal. Never unpack resources into arbitrary user directories.
Imported scene metadata includes the validated project reference and canvas size.
Only fixed-duration timing is offered for scenes, matching interactive web media.

Upgrade the library schema to version 4. Continue reading supported legacy
versions 1 (migration), 2 and 3; save the current version only. New optional scene
fields are absent from existing media; reject scene metadata tagged with old
schemas and cross-kind backend/project mismatches. Loading an old library must
not rewrite it before a successful user mutation. Snapshot/native screen-saver
publication continues to reject non-native sources explicitly; scene support in
the screen saver is not part of this desktop feature.

## Engine distribution

Pin the exact npm webwallgl 3.0.0 tarball and recorded integrity, not a floating
range or CDN URL. Package only the required runtime bundle(s) and licenses;
exclude upstream donation artwork, examples and third-party wallpapers. Keep
provenance and all license notices in the app resources/third-party inventory.
Build and bundle verification must fail for missing or changed pinned bytes.

The host's selected CEF provides WebGL2. A real scene failure or unavailable
WebGL2 is a visible failure; retain the previous wallpaper using the existing
transition transaction. Do not replace it with simulated success, a screenshot,
or an embedded MP4. The engine's default synthetic audio source is replaced with
an explicit zero spectrum because system audio capture is outside approved scope.

## Local resource and control boundary

Each scene uses the existing per-page unpredictable HTTPS origin. Two fixed
virtual mounts serve trusted bundled runtime assets and the selected imported
project through separately bound ProjectFiles descriptors. Neither mount permits
traversal, external origins, symbolic-link escape, or executable application
launch. No localhost server or Node runtime is introduced.

A trusted shell supplies a Source implementation over the project mount. Scene
configuration crosses as serialized JSON data, not interpolated executable code.
Allow only the commands/events needed for lifecycle, volume, fit, FPS, properties
and pointer input. Native resources validate method, route and bounded event
shape; obsolete page/generation events cannot publish ready state.

Prepare completes after the engine reports a real scene frame and CEF has
committed its pixels, rather than on HTML load or an unrelated first paint.
Errors remain on the existing observable error channel. Destroy/close owns all
page, audio, GPU, event and filesystem resources until actual close succeeds.

## Lifecycle, audio and interaction

Prepare silently; the existing multi-display transaction decides when output
starts. Map play/pause/resume to actual engine activity and native audio gating,
without counting paused time toward the playlist clock. Preserve the displayed
frame while paused. Preparation cancellation and switch/delete/shutdown retire
obsolete pages without late callbacks reviving them. The host must not claim a
successful release before CEF closes the page and native audio stops.

Use the existing global mute, per-entry gain and crossfade gain. Scene audio
output is independent from the excluded system audio spectrum input. Pointer
coordinates use each display's rendered viewport, respecting fit letterboxing,
scale, current page identity, and the existing interaction opt-in/permissions.
Support mouse movement/leave and left click through a narrow scene command API.
Author-defined property defaults are read by the engine from project metadata.
A property editor and persisted user overrides are outside this first release;
the source project is never mutated.

## PR sequence

1. **Scene project/data/import foundation.** Schema compatibility, typed project
   validation, owned copies, unsupported-source checks and pure/host tests. No
   importer UI exposes an unrenderable item before the renderer PR.
2. **Pinned engine and CEF scene runtime.** Bundled runtime closure, local mounts,
   first-frame/event/command bridge and actual WebGL scene harness. Target PR 1's
   branch so this remains a reviewable increment.
3. **Scene playback and controls.** Scene surface/factory wiring, grouped pause,
   resume, audio, cancellation, pointer and cleanup integration, with focused
   integration tests. Target PR 2's branch.
4. **User entry points and acceptance.** Import UI, metadata presentation and playback controls,
   five-language help/copy, default packaged-app path and fixture-based real
   scene acceptance. Target PR 3's branch. Cross-link the dependency order in
   every PR. Do not merge the feature PRs without a new merge instruction.

A PR's claims describe only its implemented/tested surface. Infrastructure PRs
must not claim end-user scene support before PR 4 is ready.

## Validation and acceptance

Use TDD for parsers, schema transitions, state and failure paths. Verify invalid
JSON, traversal, symlink replacement, unsupported projects, legacy libraries,
import rollback and removal. Test real internal collaborators; replace only
external player/OS boundaries where deterministic scheduling requires it.

Build pinned CEF/mpv/FFmpeg in an isolated development environment using the
repository preparation and SDK scripts, then reuse those prepared inputs across
worktrees. Run targeted tests with the repository 60-second budget (build may be
performed separately), static checks, packaging and dependency verification.

Use self-authored redistributable scene fixtures: a loose scene with visibly
animated content and a corresponding real scene.pkg fixture. Render on actual
macOS CEF, compare multiple frames for animation, verify pause/resume, pointer
response and cleanup. Verify first-load failure preserves an existing wallpaper,
resource denials remain visible, and paused/destroyed scenes stop producing output.
Record actual native/WebGL vendor/renderer, dimensions, FPS/CPU observations and
platform limits; do not infer 4K/multi-display efficiency from small fixture tests.
Do not change a user's installed application, wallpaper or library for tests.
