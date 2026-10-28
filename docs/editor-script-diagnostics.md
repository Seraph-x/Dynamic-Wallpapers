# Find a SceneScript runtime failure

Choose **Run preview** to execute the current valid revision in an independent
native scene window. Its issue list retains actual script errors and ordinary
renderer warnings. The workbench never executes source. This feature does not
provide breakpoints or a step debugger.

## Open the source captured for an issue

Select an issue and choose **Open source** (or double-click the row). Script rows
show the layer/name, target, callback phase, engine-reported line and occurrence
count. A missing line stays unavailable; console URLs are never treated as
SceneScript source locations.

When the owning document identity, unique layer/target and exact original source
bytes still match, navigation selects that source in **Script** and reveals the
reported line. Selection and scrolling do not change content or project history.
A reordered layer can still match through its unique ID. A loaded/replaced
document receives a new identity even if it contains the same text.

If the current source changed, the document was replaced, or another input is
pending, a separate **Captured preview source** view opens. It is read-only,
keyboard-focusable, selectable and searchable. Closing it preserves the current
source draft, including invalid text, and both local and project history. This
path does not save, freeze or flush the draft. When an inspector input is
focused, the capture opens without taking focus so navigation itself does not
commit that field; deliberately leaving a valid inspector input keeps its
ordinary commit behavior. General-scene source is readable
in the captured view without becoming a new editable source target.

Source resolution uses the immutable captured scene's structural anchors.
External material/particle issues carry the engine-owned logical path, original
resource SHA-256, literal JSON pointer and exact compiled source. They open that
independent captured source read-only; no mutable resource is reread to invent a
location. Current-resource editing remains unavailable until the resource source
workspace integration is complete. A missing/ambiguous inline layer ID or
unrecognized runtime target remains visible with an explicit unavailable-source
reason. Nothing is matched by layer name, console text or a guessed default ID.

## Read line information honestly

Lines are the pinned engine's reported values. CRLF source is displayed as LF
without changing its stored bytes. A valid line selects that complete display
line; a missing or out-of-range line remains explicitly unavailable.

The upstream compiler transforms imports without a source map. Sources with
import declarations therefore show the reported line as unmapped rather than
claiming it identifies the original source precisely. Stack traces and the
upstream parser can also omit a line. No wrapper URL or heuristic message match
supplies a replacement location.

## Restart a captured simulation

**Restart from beginning** closes the old page and creates a new simulation from
the same immutable captured revision. It clears the issue collection and counts
for that preview generation. Callbacks from the retired page cannot repopulate
it. Pause/resume retains the current simulation; seeking animation time cannot
reverse arbitrary script or particle state.

Editing or saving source does not modify an open preview. Use **Run preview**
again to capture the new source. Preview close waits for native page release
before removing its private project copy; cleanup failures remain observable.
Neither previewing nor opening a diagnostic applies a wallpaper.

## Pinned runtime limits

WebWallGL 3.0.0 supplies legacy inline `getScriptIssues()` records with exactly
`layerId`, `layerName`, `target`, `phase`, `message`, `line` and `count`.
External resource records add one exact `source` descriptor containing `kind`,
`path`, `sha256`, `pointer` and `text`; source identity participates in issue
deduplication. JS, the native protocol and the Swift owner validate that eighth
field without changing the seven-field legacy shape. The engine issue map
retains at most 500 distinct issues and truncates messages to 200 JavaScript
characters. It increments a repeated issue's actual count, and disables a
repeatedly failing callback after three failures. The Editor displays those
actual records/counts; it does not invent additional occurrences or lift the
upstream limit.

Timer exceptions follow a different upstream path: the engine emits one generic
warning and suppresses later timer warnings. They have no structured script
identity or source line, so they remain retained, unmapped console entries.
Other renderer warnings without script identity are retained the same way.
Syntax checking and API completion cannot establish that a callback will work.

## Preserve an incomplete Unicode diagnostic

The pinned engine can truncate an error message in the middle of an emoji's
UTF16 pair. macOS cannot decode that message as an ordinary string. With the
explicitly approved **Original JSON escape representation** mode, the Editor
retains and displays the original complete issue JSON, including the unpaired
`\ud83d` escape. It does not replace the code unit, invent its missing partner
or truncate the message again. The display explains why the original JSON is
shown, and source navigation is unavailable for these entries.

Distinct original reports, including their actual count snapshots, remain
separate. Raw JSON reports are deduplicated only when their UTF8 bytes are
identical. Restart and close use the same generation and cleanup rules as normal
issues. This representation does not change the source, exported project or
ordinary structured diagnostics.

## Isolation and delivery

Only the Editor preview shell adds the read-only observer. It keeps the fixed
trusted `index.html` entry and shares seven unchanged playback resources with
Main, including the pinned renderer. The Editor-only observer bundle exposes a
playback factory, with no authoring controls or Editor resource bridge.

Each actual issue is serialized losslessly and delivered in ordered, canonical
base64 fragments. The existing 8192-byte scene-event budget applies to each
fragment, including identity fields. Native validates the scene/generation,
transfer identity, order, exact final schema, strict nested JSON, path, digest,
pointer and Unicode before publishing an issue. Long layer names, targets and
external source text are not silently shortened. Interrupted,
replayed and retired transfers cannot publish partial issues. Closing a page
cancels the observer and releases incomplete assembly.

See [source workspace](editor-script-workspace.md),
[API catalogue](editor-script-api.md), [snapshot ownership](editor-scene-preview.md)
and [validation](testing/standalone-editor.md).
