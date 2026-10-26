# Preview a scene revision independently

**Run preview** or **File → Preview snapshot** opens the current scene in a separate native window,
without saving the workspace or applying wallpaper. The standalone Editor stays
optional; Main needs no Editor installation for playback.

This is the future Script IDE's execution host. All workbench and model-import
preview mounts use the pinned engine's `scripts:false` option. The edit canvas
continues property curves and skeletal animation; SceneScript runs in the
independent scene window. Source Apply and the full IDE UI remain later work.

## Use the preview

1. Open a scene and finish or cancel any invalid pending fields. Choose
   **Run preview** or **File → Preview snapshot** from the active project window.
2. The Editor flushes valid pending edits and captures scene/project JSON plus
   the current immutable resource versions. Invalid drafts or changed disk data
   produce a visible error; no saved workspace is overwritten.
3. Use **Pause** and **Resume** to stop and continue the actual scene clock.
   **Restart from beginning** closes the old page and recreates the captured
   scene in a fresh origin, resetting stateful scripts and particles.
4. Close the window when finished. Page release completes before its private
   directory is removed. Project close and Editor quit close all owned previews
   before the workbench and shared CEF runtime.

An open window keeps its captured revision. Editing, undo/redo or saving the
project does not change that preview; open another snapshot to include those
changes. Selection and preview controls do not create project history entries.
Preview audio is muted and its system spectrum is zero, matching Editor preview
behavior. Exported wallpapers retain their original audio-response behavior.

The status area shows loading/playback state, a native failure or the latest
renderer warning/error. Messages are selectable, scrollable plain text. The
pinned engine reports some SceneScript exceptions as warnings; these remain
visible without being silently called successful execution or converted into
fatal failures. Restart clears the previous generation's diagnostic. Linked
source navigation and a full runtime issue list are later IDE work.

## Snapshot and lifetime ownership

The workbench button emits exactly `{type:'preview',session,generation}` using
its existing identity. Native parsing rejects extra fields, stale identities and
invalid generations. There is no caller-supplied source, path, command or request
ID. The browser awaits transport confirmation only; it does not put the request
in the pending document-edit queue. The actual owning `EditorWindowController`
receives `onEditorPreview` and uses its existing freeze/flush, validated snapshot,
private export and thaw path. Invalid visible drafts block capture and report
their error. An unavailable, busy or closing owner reports failure rather than
creating another preview; a missing native handler fails explicitly.

`EditorProjectStore.exportPreview(_:basedOn:to:)` materializes a draft using the
same descriptor-bound loose export path as standard export. Draft identity,
revision, scene entry and original package must match the baseline. The saved
baseline must still match disk. Resource names, version ownership, hashes,
collisions and symbolic links retain the existing validation rules.

Media staging and removal cross actor boundaries. Baseline and draft resources
are checked again after staging and immediately before publication, so a save
or resource change during either interval rejects the preview. Publication uses
an exclusive rename and cannot replace an existing destination. Source PKG data
is expanded into the owned loose copy; stale containers are removed from that
copy, while unknown data and original resources are preserved. No workspace
schema rewrite or automatic save occurs.

Each open preview owns `Previews/<preview ID>/` under Editor's existing data
directory. Factory/start failures leave the session owning any acquired page
and directory. Restart waits for actual old-page closure before creating another
page and keeps the captured directory. Failed closure retains the page and
directory; failed cleanup retains directory ownership for a later close attempt.
Errors are shown. Native lifecycle operations are serialized, and old
ready/error/diagnostic callbacks cannot change a replacement generation.

## Execution boundary

The native host uses a separate `DWWebPage` with a unique origin and the existing
scene-only protocol. It has no opener, Editor session, workbench configuration,
authoring command endpoint or resource-stage handler. It can read only its
descriptor-bound captured project and bundled runtime. Native playback commands
wait for the scene engine's acknowledgement; the console diagnostic callback is
read-only display data and grants no command or file access.

This is separation of pages, origins and authoring channels within the existing
CEF runtime. It does not promise separate operating-system processes or protect
against a Chromium compromise. The in-page SceneScript sandbox is not a security
boundary. The [authoring execution migration](editor-script-migration.md) keeps
all authoring scene mounts script-disabled; Main and independent scene pages
retain actual SceneScript playback. This does not add the later source IDE UI.

## Sources and validation

`ScenePreviewWeb` is an exact, reproducible copy of Main's eight offline
`SceneRuntime` resources. The build verifies their hashes and the independent
Editor package includes its own copy. [WebWallGL](https://github.com/oneincase/webwallgl)
3.0.0 supplies scene/SceneScript execution; CEF supplies hosting. No new engine,
dependency, custom script format or Main runtime modification is introduced.
See [Editor provenance](../Editor/ThirdParty/provenance.json) and
[third-party notices](../Resources/ThirdParty/README.md).

Tests use actual workspace files for unsaved export, immutable versions,
concurrent saves/resource changes and failures. Native-session tests use an
explicit external-page fixture to control acknowledgements and failure timing;
they do not render or fabricate pixel success. Separate native CEF acceptance
runs real escaped script probes, engine clocks/pixels and authoring-request
denials beside a live blank Editor page. Migration acceptance separately loads
real object, text, effect, material and general scripts into the authoring page
and requires silence there plus execution in independent hosts. Four Swift
controller tests exercise actual owner wiring, snapshot policy and store export;
the CEF harness receiver separately covers real event delivery and DOM draft
flushing. See [validation commands and evidence](testing/standalone-editor.md).

## Retained issues and source navigation

The native preview now retains actual script issues and generic renderer
warnings. Select an issue and choose Open source; exact current source opens
in the Script workspace, while stale or pending input opens a read-only
captured view without discarding the draft. Restart resets the issue collection
for the same captured revision. See [runtime diagnostics](editor-script-diagnostics.md)
for available lines, unavailable source identities and pinned engine limits.
