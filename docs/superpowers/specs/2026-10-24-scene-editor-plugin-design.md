# Optional Scene Editor Plugin

## Confirmed scope

The user approved a same-repository, separately versioned and packaged editor:
install/remove an independent ZIP; create and import loose/PKG scene projects;
image, text and basic layer editing; real-time preview; undo/redo; save projects
and export loose/PKG projects. Uninstall preserves user projects. Advanced bone
editing, a keyframe timeline and a script IDE are outside version 0.1.0.

Use `Plugins/SceneEditor/` for the plugin payload/build. The application must not
bundle the editor engine/UI by default. Keep its existing macOS 14.0/arm64 target.
System audio remains the existing optional 14.2+ feature. README names upstream
design references and actual dependencies. Documentation-only or release-only
work does not require a PR; feature changes still use English PRs/real-email
commits. Published 1.0.0 artifacts remain unchanged.

## Architecture and alternatives

Use the published MIT `@webwallgl/editor` 3.0.0 API with matching `webwallgl`
3.0.0, bundled offline, and a focused editor interface. Reuse CEF in a native
child view so keyboard, text selection, pointer and form input work normally.
The wallpaper's offscreen-rendered pages retain their existing behavior.

Importing the entire upstream workbench would also import its Node host routes,
large UI and advanced tools. A separate Electron application would duplicate
the Chromium runtime. Neither is needed for the confirmed first release. No
Node server, CDN, dynamically downloaded library or native plugin DLL is used.

The host owns installation, user selection dialogs, project storage, save/export
transactions, window lifetime and optional spectrum publication. The plugin owns
its HTML/CSS/JS editor/model, engine and undo/redo. A small versioned data protocol
connects them. Installed assets run inside the existing renderer sandbox; the
manifest/hash check detects corruption, not publisher authenticity.

## Package and installation

Package `scene-editor-0.1.0.dwplugin.zip` with root `plugin.json` and an explicit
file inventory. The manifest has schemaVersion=1, id=`scene-editor`, name,
version=`0.1.0`, hostAPI=1, entry=`index.html`, and files mapping safe relative
paths to SHA-256 and exact byte size. Preserve all MIT/MPL notices and record
pinned package URLs/integrities and build recipe. The entry and its transitive
assets must be in the inventory. No executables, symlinks or unknown files.

The host uses pinned ZIPFoundation for streaming ZIP access and CryptoKit for
hashing. Validate manifest, API, paths, duplicates (including case/Unicode
aliases), entry types, declared sizes and hashes before activation. Reject
absolute paths, dot traversal, backslashes and symbolic/hard links. Extract to
a new private staging directory under the plugin store, never directly into an
active install or arbitrary path. Publish a verified installation by atomic
rename; a failed replacement retains the previous plugin and reports errors.
Verify installed inventory again before launching; missing/changed bytes fail.

General/Advanced settings expose the editor plugin's version and availability,
Download (official repository releases), Install from ZIP, Open, and Remove.
Download is a separate artifact, not an automatic background install/update.
Do not launch the editor until the package is installed and compatible. Close
editor windows successfully before removing/replacing an active plugin. Unsaved
work prompts Save/Discard/Cancel; Cancel cancels removal too. Remove only the
installed payload, never the separate user-project store or exported folders.

## Projects and persistence

Use separate `Application Support/.../Plugins` and `.../SceneProjects` roots,
derived from ApplicationPaths so validation mode remains isolated. New projects
and imported copies have stable UUIDs and schema-1 workspace metadata. Keep
project.json, scene JSON and resources as ordinary editable project files.

Open a selected project folder containing project.json and a loose scene or
scene.pkg. Use the existing scene reference/probe rules. Import a complete copy;
unpack PKG entries into the new owned workspace with the same safe-path and
duplicate rules. Validate container offsets/lengths before reading/writing.
Never rewrite the original imported project or a library playback copy.

Scene/project JSON is edited as a document that preserves unknown fields and
unmodified resources, not reconstructed from the visible inspector. First save
and subsequent saves atomically replace the owned document after validation.
Failures leave the last saved version intact; dirty state remains until a real
successful save. Closing with unsaved edits offers Save/Discard/Cancel. Reopen
finds saved projects even after plugin removal/reinstallation.

Export writes a new selected destination. Loose export includes scene,
project.json and all resources. PKG export uses upstream buildScenePkg (including
PNG/JPEG-to-TEX wrapping), leaves project.json/preview outside the PKG, and runs
checkWeCompat/read-back. Preserve and display diagnostics; do not claim complete
Wallpaper Engine compatibility or silently replace unsupported content. Never
overwrite an unrelated folder. Exported projects must re-import and render in
this application's existing CEF scene playback.

## Editor model and UI

Use the existing app's native window and localized controls, with the plugin's
layer tree, canvas and inspector. Native toolbar actions handle New/Open, Add
Image, Save, Export Loose/PKG and the project chooser. The plugin handles layer
selection, rename, visibility, order, duplicate/delete, position, scale, rotation,
color/opacity, image and text layers, canvas selection and transform interaction.
Show supported basic fields for existing other layer types and preserve their
remaining data. Fields controlled by scripts/animation are identified and kept
read-only in this first inspector, preserving those bindings.

Each edit is an undoable command; undo/redo must update both serialized data and
real rendered pixels. Use upstream hot-edit controls where valid and explicit
scene rebuilds for structural changes; preserve preview time via seek when
rebuilding. Playback errors remain visible. Preview never uses synthetic audio;
the host can provide its existing optional real spectrum while preview plays.

Image import uses a native picker, validates/decodes the selected image and
creates the upstream-compatible model/material/source-image files. Text layers
use the upstream scene representation. New projects have explicit canvas size
and background. UI and host status/help support all five app languages.

## Native CEF boundary and lifecycle

Add a native child-view editor page to the same lazy CEF owner. Each editor
window gets an unpredictable origin, descriptor-bound plugin/runtime and owned
project resource mounts, and independent session ID/generation. Main-frame-only
typed events include ready, dirty, document/export responses and errors. Native
requests carry unique IDs; unsolicited/stale responses and extra fields reject.

Native user actions initiate file dialogs and mutations. Project scripts do not
receive a general filesystem/process API. Commands are serialized JSON passed
to one fixed entry point; no caller-provided executable JS or native path.
Requests for project/runtime files go through checked descriptor-bound readers;
external navigation/protocol execution, arbitrary network and mount escapes are
denied. CPU/GPU/CEF failure, invalid input and missing assets are observable.

Only claim editor readiness after its real engine frame and trusted handshake.
Own native browser/context/client/readers, timers, spectrum subscriptions and
continuations until actual release. Close cancels obsolete requests and drains
CEF callbacks; a close failure retains ownership and prevents uninstall. Include
editor pages in application shutdown before shutting down the shared CEF runtime.

## Delivery and verification

Two reviewable stages: plugin/project foundation, then native editor/integration
and independent packaging. Deliver complete behavior before describing it as an
available editor. Generate a local plugin ZIP and a host candidate; publish a
plugin release separately from application releases when publishing is requested.

TDD covers manifest/ZIP corruption and traversal, atomic install/rollback/remove,
project round trips, PKG bounds/duplicates, unknown-field preservation, dirty/save
failures, commands/undo/redo, stale events and window/removal lifetimes. Use real
internal collaborators; replace only external OS dialogs/network/renderer where
deterministic unit testing requires it. Targeted Swift test runs have 60 s budgets
after building. Run app/product/package/help/localization regressions.

Native acceptance must install the actual ZIP in isolated application paths,
create/edit/save/reopen an image/text project, observe changed CEF pixels for
edit/undo/redo, export loose+PKG, import both into existing scene playback, then
uninstall and verify project preservation. Test invalid archive rejection and
cancelled removal with unsaved work. Verify no editor payload in a default host
application and all dependency/license/build provenance in the plugin artifact.
Use only self-authored fixtures; do not modify the user's installed app/library.

## References

- https://github.com/oneincase/webwallgl (API package 3.0.0; reviewed source tree
  197abe54266c31d346cebc314e49a26b70c960cc)
- https://github.com/elysia395/dsh-wallpaper-engine (scene-hosting design reference)
- https://github.com/weichsel/ZIPFoundation (pinned ZIP library; retain MIT notice)
