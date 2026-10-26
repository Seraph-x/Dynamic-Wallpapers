# Edit scenes without executing SceneScript

The Editor's **Edit canvas** plays property curves and skeletal animation without
evaluating imported SceneScript. Choose **Run preview** to execute the current
valid revision in an independent native scene window without saving it.
**File → Preview snapshot** remains available for the same operation. The
[source workspace](editor-script-workspace.md) and
[linked runtime diagnostics](editor-script-diagnostics.md) build on this execution separation.

## Editing and running a revision

Every authoring-page renderer uses the pinned WebWallGL 3.0.0 `scripts:false`
option through `createWorkbenchScene`. This covers initial/rebuilt document
mounts, load, undo/redo and the model-import subpreview in the same privileged
page. Script wrappers, bindings, unknown metadata and source/resource bytes
remain data; the migration does not strip or rewrite them. Script-bound
inspector fields remain read-only. Non-script curves and MDL animation continue
to use the pinned engine's ordinary playback and sampling.

The persistent mode explanation distinguishes the edit canvas from actual
SceneScript playback. **Play animation / Pause animation** and Timeline seek
control edit-mode animation. They do not execute script lifecycle or frame-event
handlers. **Run preview** executes a captured revision in another scene page;
restarting that window resets its stateful scripts and particles. An existing
preview keeps its captured revision when the document is edited or undone.

Run sends only `{type:'preview',session,generation}` to the Editor event endpoint.
Native parsing rejects additional fields and invalid/stale identities. The
event supplies no source, file path, native command or request ID. Browser code
waits only for transport confirmation, outside pending document-edit actions,
so native capture can flush those actions without waiting on itself.

The installed `onEditorPreview` callback reaches the actual owning
`EditorWindowController.previewSnapshot()` path. That owner freezes and flushes
valid pending fields, validates the current snapshot, materializes its immutable
resource versions in a private copy, opens the existing snapshot host and thaws
editing. Invalid drafts block preview creation and remain visible. Transport,
missing-handler and unavailable/busy-owner failures surface explicitly. The
request does not create a document-history step, save the workspace, or apply
wallpaper. See [snapshot ownership and cleanup](editor-scene-preview.md).

## Execution boundary and compatibility

Only independent scene pages run SceneScript in Editor. Main's scene runtime
and loose/PKG playback remain script-enabled and require no Editor installation.
The native preview has a unique origin, no opener, no Editor session and no
authoring command or resource-stage channel. Its captured resources remain
descriptor-bound; page release precedes directory cleanup.

These are page, origin and native-channel boundaries within the existing CEF
runtime. They do not promise separate operating-system processes or protection
from a Chromium compromise. The upstream in-page script sandbox is not itself
a security boundary. Offline compilation still never executes supplied source;
its supported source anchors and limits are documented in
[SceneScript source contracts](editor-script-contracts.md).

WebWallGL 3.0.0 supplies the execution switch, renderer and SceneScript semantics;
CEF supplies hosting. The change adds no custom script format or alternate
animation evaluator. Main's eight offline scene resources are copied exactly
into Editor's independent preview bundle. Retain the
[upstream provenance](../Editor/ThirdParty/provenance.json),
[WebWallGL license](../Editor/ThirdParty/WebWallGL-Editor-LICENSE) and
[dependency notices](../Resources/ThirdParty/README.md).

## Verification scope

Real browser/native fixtures exercise object, text, effect, material and general
script anchors. The same fixture bytes must execute top-level/init/update probes
in an independent script-enabled host and remain quiet during authoring
load/seek/edit/history/reload/export. Unknown script-like metadata stays data.
Actual curve and skeletal motion, original resource bytes, both export formats
and independent callback playback retain positive assertions.

Four Swift controller tests use the real owner and project store with injected
external page/window transport. The separate CEF harness receiver verifies real
event dispatch and DOM draft flushing; it does not stand in for that owner.
Neither fixture is used to claim fabricated rendering. Current focused results
are 353 JavaScript tests, 19 independent Editor tests and 70 reproducible offline
resources (62 workbench + 8 preview). The fresh-directory 29-phase acceptance
run and 41 Editor Core tests also passed. These focused checks do not establish
a full Main application-suite pass. Commands, phase budgets and detailed limits are recorded in
[standalone Editor validation](testing/standalone-editor.md).
