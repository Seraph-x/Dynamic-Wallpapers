# Advanced scene authoring roadmap

Status: the user approved the five-PR scope and acceptance standard on 2026-10-24.

## Product contract

The standalone Editor gains keyframe animation, skeletal authoring and a
SceneScript IDE. It remains an independently installed application. Main keeps
its optional Editor entry and plays exported projects without installing Editor.
Existing projects and unknown fields/assets retain their contents. The current
paper/charcoal themes and five UI languages remain supported.

Each user-facing feature must work through editing, undo/redo, save/reopen,
loose/PKG export and playback in Main. A panel which only previews an effect is
not a completed authoring feature. Infrastructure PRs must deliver independently
tested contracts; subsequent feature PRs build on those contracts. A PR may be
subdivided further if review requires it, without dropping the agreed scope.

## Chosen approach

Extend the existing workbench using the pinned WebWallGL 3.0.0 playback and
editor APIs. Reuse the existing scene JSON, MDL and SceneScript formats instead
of introducing an Editor-only animation runtime. This keeps exported projects
usable by Main independently of Editor.

Embedding the upstream complete workbench would also replace our application
integration, persistence and interface. A separate custom animation format would
require a second implementation in Main. Neither is needed for this scope.

Local pinned API declarations are the capability reference:
`@webwallgl/editor/index.d.ts`, `webwallgl/types.d.ts`. They expose scene-clock
seek/step, MDL skeleton/skin/clip mutation, model/bone inspection, script checking
and runtime issues. Their availability is not evidence of correct integration;
each feature needs real fixtures and exported playback checks.

## PR boundaries

1. **Resource transactions.** A revision owns scene/project JSON and references
   to immutable edited resource versions. Undo/redo includes resource references.
   Save publishes the whole revision atomically; preview and both export formats
   resolve the selected revision's resources. Read existing schema-1 workspaces.
   Detailed first-PR specification is in the companion resource-transactions spec.
2. **Property keyframe timeline.** Property tracks for transforms, opacity and
   color; add/delete/move/copy keys; numeric key editing; supported linear and
   smooth interpolation; time/frame ruler, snapping, scrubbing, frame stepping,
   loop range and playback controls. Preserve unrecognized imported animation
   data. A property with a script/user binding cannot be silently converted to a
   curve. Use explicit conversion/removal actions with undo.
3. **Skeleton and skin authoring.** Import glTF/GLB models with hierarchy and
   skinning; inspect/create/rename/reparent/delete bones; edit rest transforms;
   mesh/weight visualization and brush/numeric skin-weight editing. Reindex
   affected joints, tracks and attachment references coherently when topology
   changes. Preserve surviving influences, reject cycles and invalid weights,
   and make any necessary destructive changes explicit and undoable. Image-to-
   puppet mesh creation supplies an authoring path without an external model.
4. **Skeletal animation.** Create/duplicate/delete/rename clips; frame rate,
   duration and loop mode; bone pose keys; clip layers and mixing; frame events;
   FK manipulation and IK posing baked into ordinary MDL animation tracks.
   Editor-only IK solver state is not required for exported playback. Preserve
   bind pose and avoid resetting unrelated tracks when editing one bone.
5. **SceneScript IDE.** An offline code editor with syntax highlighting,
   SceneScript API completion, lifecycle templates, find/replace, syntax checks,
   runtime diagnostics linked to source, apply/revert and preview restart.
   Script code participates in the same project history/save/export path.
   Document the supported API and any unsupported lifecycle hooks. Do not call
   a source editor a step debugger: breakpoint debugging is not included in this
   scope. Script execution is isolated from the workbench's native write/control
   channel; compilation alone never executes the edited script.

## Interaction and data ownership

Keep the layer list and canvas. Add a collapsible timeline and contextual
Properties / Animation / Model / Script workspaces as the features land. Narrow
windows must allow explicit workspace switching instead of covering the canvas
with overlapping controls. Shortcuts must respect focused text/code inputs.

The document/history layer owns committed edits. Tool drags and script drafts
are temporary interaction state until committed; freeze/save/close must flush
valid pending changes or expose a blocking error. A user can cancel a draft
without changing the saved document. Selection, playhead and panel choice are
not content edits. Undo restores content, resources and the corresponding
rendered result, rather than only changing inspector controls.

The preview consumes a document revision and a resolver for that revision. It
uses the same pinned engine as Main. Engine hot-update calls may give immediate
feedback, but the committed document/resources remain the authority after
reload and export. Do not reuse unsupported engine load behavior.

## Failure handling and compatibility

Do not silently drop unsupported curves, scripts, model sections or imported
data. An operation the engine cannot represent must report the specific reason.
Do not silently replace a script or animation binding with a constant. Reject
invalid numeric values, bone cycles, invalid joints and malformed resources at
their boundaries. Leave the current valid document intact after failed edits.

Time-based curves and bone animation can be sampled at absolute time. Stateful
scripts and particles are not generally reversible by calling seek; the UI must
distinguish restarting simulation from seeking an animation. Define restart and
diagnostic behavior in the Script IDE specification before its implementation.

Existing workspace readers reject unknown schemas. A workspace that uses the
new resource-reference schema therefore requires the new Editor, while standard
exported projects remain independent of workspace schema. No automatic rewrite
of user projects occurs merely by opening the application.

## Validation and delivery

Every PR carries focused unit tests and relevant browser/native integration
checks. Feature fixtures are authored for the tests, with known animation
values, mesh deformation or script output. Assert intermediate frames, undo/
redo, save/reopen and exported results, rather than merely checking nonempty
files or visible controls. Test loose and PKG in Main's actual scene runtime.

Cover malformed data, conflicts, cancellation, interrupted saves, focused input,
resource ownership and repeated edits. A script exception must remain visible;
it cannot be converted to a successful save or a fabricated preview. Verify
Editor shutdown and independence from Main after changes to rendering hosts.

PR titles/descriptions are English and commits use the configured real author
email. Preserve upstream license notices and document reused projects. Publishing
a release and merging these new feature PRs are separate actions; this roadmap
does not claim either has already happened.
