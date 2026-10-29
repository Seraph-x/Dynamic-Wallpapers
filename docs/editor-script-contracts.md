# Check and preserve SceneScript source

Source transactions and offline syntax diagnostics support inline native
layer/effect/particle-override scripts. Separate
[resource contracts](editor-resource-script-foundation.md) cover owned material
and particle file discovery and immutable span-only transactions. The [Script workspace](editor-script-workspace.md) now
provides an offline CodeMirror editor and Check/Apply/Revert/Remove on these
contracts. The
[execution migration](editor-script-migration.md) disables SceneScript in every
authoring-page mount and runs captured revisions in an independent scene page
through **Run preview**. The workspace also provides highlighting, conservative
API hints, complete starter templates and find/replace; see the
[API catalogue](editor-script-api.md) for actual target/host restrictions.
[Runtime diagnostics](editor-script-diagnostics.md) retain actual issues and link to captured source. The pinned engine's
in-page script sandbox is not itself a security boundary.

## Check a scene without running its scripts

From the repository root, with Node installed:

```sh
node Editor/Web/check-scene-scripts.mjs Tests/Fixtures/SceneAnimatedLoose/scene.json
```

The command also accepts an Editor `workspace.json` (schema 1 or 2) or browser
document snapshot. It reads the JSON once, prints a JSON report and does not
modify the file. The checked-in compiler bundle works offline and needs no DOM,
renderer, npm installation or network requests. Node is needed for this developer
command, not for either application's normal operation.

| Report field | Meaning |
| --- | --- |
| `scope` | `inline-native-scene-scripts`; external resource scripts are outside this scan |
| `discovered` | Number of inline members named `script`, including custom metadata |
| `checked` | Number of registered native anchors actually passed to the compiler |
| `unvalidated` | Unknown script-like metadata retained with `checked:false` |
| `errors` / `warnings` | Source-contract input errors, native syntax errors and explicit no-entry warnings |
| `results` | Per-source structural path, layer/target, editability, native check and diagnostics |

Exit **0** means no checked-source input/syntax errors; **1** means source errors
were reported; **2** means usage, input or I/O failed and stderr explains why.
Zero checked sources is reported as zero. Unknown metadata is not treated as
source or as an error: for example, a custom `scriptproperties.script` object
remains unvalidated. A registered source is checked even if another binding
prevents editing it.

The compiler is the actual `checkSceneScript` from pinned
[@webwallgl/editor](https://github.com/oneincase/webwallgl). Its import/export
transform and lifecycle-entry detection define these diagnostics. A valid
`noEntry` result carries `NO_ENTRY`: the native runtime can discard source with
no recognized entry or engine clock use. Native message/line/entries are returned
without rewriting them; source-line location follows the upstream checker.
Checking constructs functions but never calls supplied code, imports modules or
runs source bodies. A syntax pass does not establish runtime API availability,
module support, visual correctness or security.

## Store a checked edit in a standalone document

This Node example uses the checked-in offline bundle and operates on an owned
document only; it does not connect to the live Editor renderer:

```js
import { SceneDocument } from './Editor/Web/document.mjs';
import {
  prepareSceneScript, applySceneScript,
} from './Editor/Sources/EditorApp/Resources/EditorWeb/script-api.mjs';

const doc = new SceneDocument({
  title: 'Script source', entry: 'scene.json',
  project: { type: 'scene', file: 'scene.json' },
  scene: { objects: [{ id: 1, alpha: 1 }] },
});
const proposal = prepareSceneScript(doc, {
  layerId: 1, target: 'alpha', type: 'set',
  source: 'export function update(value){return value;}',
});
applySceneScript(doc, proposal);
doc.undo();
doc.redo();
console.log(JSON.stringify(doc.snapshot()));
```

`prepareSceneScript` validates the target and returns an immutable proposal with
the actual native check and diagnostics. Syntax failure throws
`SceneScriptSyntaxError` with `layerId`, `target`, `line` and `check`, without
changing history. A proposal owns its input and is tied to that document and its
captured snapshot. Apply rejects another document, changed content, a forged
proposal or replay. JSON object member order does not make a snapshot stale;
array order/length do. A successful apply consumes the proposal once and creates
one history step; an identical source produces no history step.

Use `{layerId:1,target:'alpha',type:'remove'}` to remove only the `script` member.
Removal is a data operation and has `check:null`. It preserves the wrapper's
base, `scriptproperties` and unknown members. Source strings preserve CRLF and
Unicode exactly; malformed Unicode, NUL and non-string source are explicit errors.

The pure `script-source.mjs` exports `inspectSceneScript`, `editSceneScript` and
`listSceneScripts`; the compiled bundle re-exports them plus
`checkSceneScriptSources`. `SceneDocument.script(edit)` is deliberately a lower
level data-only operation: it validates source/target shape but does not compile
or evaluate source. Use prepare/apply when syntax diagnostics are required.

## Supported source anchors

| Target | Base requirements |
| --- | --- |
| `origin`, `scale`, `angles`, `color` | Finite three-component string or numeric array |
| `alpha`, `brightness`, `maxwidth`, `pointsize`, `volume`, `intensity`, `exponent` | Existing finite numeric base; absent `alpha` uses native default 1 |
| `visible` | Boolean; absent field uses native default true |
| `text` | Existing text field with a string base |
| `effects[N].visible` | Existing effect with boolean visibility, or native default true |
| `instanceoverride.rate/count/size/speed/lifetime/brightness/alpha` | Existing finite numeric base and a consuming particle resource |
| `instanceoverride.colorn` | Existing finite three-component color base and a consuming particle resource |

Absent origin/angles use `0 0 0`; absent scale/color use `1 1 1`.
Existing ordinary layer script wrappers without a base remain without a base;
particle overrides require their explicit typed base. No value is invented.
Wrappers controlled by a user property or animation, malformed bases,
duplicate/missing layer IDs and unsupported anchors remain read-only with an
explicit reason. There is no automatic replacement of another binding.
Only the selected structural anchor changes, including when API input shares
wrappers/effects elsewhere. Returned data is owned; cyclic input is rejected.

Discovery preserves unknown inline script-like metadata and its structural path.
The inline CLI and `listSceneScripts` do not resolve resource files. The workspace
uses the separate asynchronous `discoverEditorResourceScripts` scan for those
assets; discovery itself never executes or checks source.

## Keep temporary source outside history

`ScriptDraft(document, selection)` captures the document identity, full snapshot
and selected anchor. Its `state`, `source`, `dirty` and `diagnostics` describe
temporary input; `setSource` invalidates an earlier checked proposal. `check()`
uses the real offline compiler without executing source or changing history.
The workspace always checks explicit Apply, including unchanged imported source,
so a no-op cannot falsely report that invalid syntax passed.

Call `apply(document)` or `remove(document)` inside `editor.change`. Apply uses
the checked proposal once, and Remove discards pending input while removing only
the committed script member. Failed checks and stale/replaced documents preserve
the pending source and current committed revision. A conflict requires explicit
`revert(document)` to adopt the current document. `restoreInput()` restores only
the captured local input; it does not rebase the draft onto another revision.

No script and an empty script are distinct. The UI's explicit Apply can create
`script: ''`; typing and locally undoing back to an initially empty constant
field does not create a script during navigation or freeze. An identical existing
source creates no history step. Source-only transactions preserve exact CRLF and
Unicode; the UI retains consistent CRLF after input, while edited mixed line
endings follow its documented LF policy.

The workspace's serial action queue settles accepted source operations before
native capture. Native dirty notifications include pending drafts. Freeze first
locks user input, then flushes valid source before the runtime becomes frozen.
Invalid drafts return the committed freeze document with dirty state, and the
owner's validation snapshot rejects them. Thaw and explicit Revert retain the
existing recovery path. Mark-saved and redraw cannot erase pending text.

`ResourceScriptDraft.open(editor, record)` captures an authentic resource discovery
record. It offers the same `state/source/dirty/diagnostics`, `setSource`, `check`
and `restoreInput` contract; its `apply`, `remove` and `revert` operations are
asynchronous. Apply/Remove delegate to the resource transaction owner rather than
running an asynchronous callback inside `editor.change`. Read/hash/stage errors
and stale owner/revision checks remain observable, and preserve uncommitted input.

## Verification and remaining IDE work

The browser and native tests keep the live workbench blank while preparing,
checking and editing standalone source documents. They assert no probe execution,
no resource staging, exact history and independently expected serialized data.
The real native workspace store preserves CRLF/Unicode/unknown wrapper fields on
save/reopen and source removal. Standard loose/PKG exports run in Main's actual
CEF scene runtime, where two stationary meshes must show green, red, then green;
Main has no Editor authoring session and releases every page before shutdown.
See [native validation](testing/standalone-editor.md).

The [snapshot preview host](editor-scene-preview.md) supplies a separate scene
page without Editor authoring channels. Both authoring renderers use the pinned
`scripts:false` option, preserving source wrappers/resources and animation data.
**Run preview** requests the native owner's freeze/snapshot/thaw flow without
saving. The fixed request contains no source, path or native command. This
separates script execution from the workbench's native write/control channel
within the existing CEF runtime, without claiming operating-system process
isolation. The source workspace adds real UI compiler/draft tests and actual CEF
focused input; its authored loose/PKG scene must play independently in Main.
Offline CodeMirror acceptance adds highlighting, completion, template
confirmation, search/replace and local history without changing these source
transactions. Linked retained runtime diagnostics cover current and captured
inline/resource sources. The
independent preview already supports restarting its captured revision.

The compiler, runtime semantics and package writer come from the pinned WebWallGL
project; see [Editor provenance](../Editor/ThirdParty/provenance.json) and
[third-party license](../Editor/ThirdParty/WebWallGL-Editor-LICENSE).
