# External resource script contracts

The Script workspace discovers and edits registered material/particle sources
through the data-only APIs below. It uses the shared renderer's actual typed
sinks for independent preview and exported playback. The implementation follows
the [approved staged plan](superpowers/plans/2026-10-27-external-resource-scripts.md).
Discovery still never executes source, and syntax checking alone never claims
runtime success.

## Lossless resource documents

`Resources/SceneScript/json-spans.mjs` parses owned UTF-8 bytes into immutable
structural spans. Strict JSON is used for particle/model documents; material and
effect documents support JSONC comments/trailing commas. Unknown number lexemes,
duplicate unknown fields, BOM, whitespace, comments and line endings remain
unchanged. Selected duplicate keys or duplicate path ancestors are ambiguous and
read-only. Parsing/traversal has no custom depth/file/history limit.

Set changes only the selected source string. Add inserts one source member or
wraps a recognized primitive/array base while retaining its original literal.
Remove deletes that member and the required separator. Unchanged source is a
byte no-op, including original Unicode escape spellings. These functions never
serialize an entire imported resource or execute a script.

`resource-contract.mjs` registers first-pass material constants, typed particle
child overrides and emitter rate. Generic tint opacity/brightness require scalar
bases and color requires three components; uniform consumers support their
numeric scalar/vector authoring shapes. Existing user/animation bindings,
unsupported bases, unconsumed material keys/passes and alternate MDL skins retain
a read-only reason. Unregistered script-like metadata remains visible.

For example, `materials/shared.json` with the literal anchor
`["passes",0,"constantshadervalues","Color"]` identifies one source wrapper;
punctuation in a file name or constant key is not split into extra path segments.
The chooser displays all consumers of that shared file before an edit is applied.

## Discovery APIs

`discoverEditorResourceScripts(editor)` binds the Editor document identity and
complete snapshot before and after each asynchronous inventory/resource read.
Use this entry point with the live Editor. It rejects a stale scan or replaced
owner, even when the replacement document has identical content.

`discoverResourceScripts({snapshot, paths, read})` is the lower-level API for an
already captured source, including extracted PKG entries. Its reader must resolve
the supplied snapshot. It follows model/MDL materials, effect material passes,
particle materials and particle child references. JSON, JSONC and glTF assets
outside those references are inspected as unconsumed metadata; standalone JS/MJS
assets remain read-only because the pinned runtime has no external module loader.
Referenced files can have other extensions. Each resource is read once per scan.

Both return frozen `{scope, records, failures, unavailable}` reports. Records
carry the logical path, literal structural anchor, source/raw source, value kind,
consumer list, SHA-256 and override version. `checked` is false. Invalid JSON,
cyclic references, read errors and mismatched override hashes produce explicit
failure records. References without owned inventory bytes are reported as
unavailable; no substitute resource is fabricated. Case/Unicode aliases and
file/directory conflicts reject inventory input before any resource read.

## Capture, check and commit

`captureResourceScript(editor, record)` accepts only an authentic discovery
record, verifies the current complete snapshot, reads owned source bytes and
checks their SHA-256. Captures/proposals retain private copies in WeakMaps;
spreading a public object cannot forge one. The read-only `editor.closed` getter
and pure `SceneDocument.validateResource(path, version)` expose existing lifetime
and reserved-path rules without changing history.

`prepareResourceScript(capture, {type, source})` supports `set` and `remove`.
It patches an owned candidate and uses the actual pinned compile-only checker.
Syntax errors include path, anchor and reported line. No-entry source retains an
explicit warning; checking does not claim successful playback. Preparation never
stages bytes or changes the document.

`commitResourceScript(editor, proposal)` requires the original live, unfrozen
owner. It checks the complete document and source hash, stages through the
existing native resource bridge, verifies the returned hash, checks again after
staging and inside the synchronous document transaction, then adds one
`doc.resource(path, version)` history entry. Undo/redo and saved snapshots retain
that immutable version. A no-op still verifies current source bytes but creates
no blob/history entry. One proposal cannot commit concurrently or be replayed;
a failed pre-mutation stage remains retryable. A render error after canonical
mutation remains an error and does not make the proposal reusable.

The owning editing window must retain its native `EditorResourceSession` during
capture/staging/history/save. This layer adds no unsafe legacy staging overload,
original-file writer or package mutation path. Closed/frozen/stale owners and
out-of-band source changes fail explicitly. Abandoned staged blobs remain under
the existing session/closed-project collection policy.

## Workspace adapter and source navigation

The offline `resource-api.mjs` bundle exposes the discovery/capture/prepare/commit
functions without renderer imports. `ResourceScriptDraft.open(editor, record)`
adapts these operations to the existing Script input contract. Apply, Remove and
Revert are asynchronous; document history mutation remains synchronous inside
the resource transaction owner. Selection/save/preview/export/close barriers
wait for accepted work, and a failed stage or stale source keeps its local draft.

Resource vector starters preserve their exact dimensions. Cursor starters are
explicitly unavailable because resource constant sandboxes receive no cursor
callback. Scene `instanceoverride` registration uses the same numeric/color
subset; runtime application targets only the actual inheriting particle systems.
Explicit child overrides, including empty objects, and event-child noninheritance
retain their authored precedence. Static/user/animation-bound wrappers are never
sent to a scripted write sink, and disabled authoring execution preserves bases.

Structured issues retain the logical path, original-byte digest, literal script
pointer and compiled text. Open source reveals the current resource only if all
those identities match and inputs remain settled throughout the asynchronous
read. Otherwise the independently captured text is shown read-only. Viewing a
capture never flushes another draft.

## Verification boundary

Tests cover exact span preservation, deep/wide structures, prototype-like names,
invalid UTF-8 and escaped lone Unicode surrogates in JSON keys/values,
real MDL references, graph failures, opaque proposal ownership, stage failures,
no-op/concurrent/stale/close/freeze races, actual filesystem staging and saved
snapshot reopen. Real PKG encoding/extraction/rebuilding verifies original and
unrelated byte preservation using the pinned packager, independently bundled
without a renderer or DOM shim. Workspace and native acceptance complement these
data-layer checks rather than treating compilation as playback evidence.

The renderer stage adds engine-owned origins for exact material/particle bytes,
typed per-consumer sandboxes and actual effect, mesh/per-mesh, generic tint,
particle material, child override and emitter-rate sinks. `scripts:false`
constructs no resource sandbox. Exceptions create an eight-field structured
issue with exact source identity and never write the failed result. Restart and
close dispose owned timers. Main, Editor workbench and Editor preview use the
same hash-verified bundle and recorded patch inputs.

Real Chrome/WebGL acceptance covers all eight external visible/simulation sinks,
inline particle inheritance, static/bound color preservation, disabled execution
for every consumer, source exceptions and restart/close timer disposal. Pure
tests cover scalar and exact vector2/3/4 typing, independent shared-resource
consumers, malformed returns and layer disposal. ObjC++ and Swift tests validate
the optional source descriptor while preserving the legacy seven-field issue.

Final foundation verification on the synchronized main baseline passed all 465
data-layer Node tests: every `Editor/Web/*.test.mjs` plus
`scripts/test-scene-{engine-patches,runtime,spectrum,properties}.mjs`. The existing
process-group runner enforced a 60-second execution timeout. Both
`node Editor/Web/build.mjs --check` and `node scripts/scene-bundle.mjs --check`
passed on the original foundation without changing the shared engine. Independent review corrections cover
typed generic tint bases, prototype-like constant names and unreferenced
glTF/JSONC metadata. The changed-source privacy gate passed with no allowed or
retained patterns; `git diff --check` was clean. These are historical foundation
results. Current workspace, native persistence/playback and full export-byte
checks are described in the [validation guide](testing/standalone-editor.md#external-resource-script-acceptance).
