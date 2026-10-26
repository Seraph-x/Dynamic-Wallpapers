# Source-linked SceneScript diagnostics implementation plan

> Execute the approved advanced-editor roadmap after code tools is verified and merged. The user authorized English PRs and self-merge after verification. Use executing-plans and verification-before-completion.

**Goal:** Retain genuine runtime script issues in independent snapshot previews, open the exact captured source/line, and distinguish current source from an older preview.

**Architecture:** The independent preview keeps the Main scene renderer and read-only project mount. An Editor-only wrapper observes the pinned editorOf(instance).getScriptIssues() read API without exposing authoring controls. A fixed data-only script-issue-part scene event carries lossless ordered chunks of genuine issue JSON through the existing trusted-main-frame, origin/session/generation validated channel. The native preview session owns retained issues for its captured revision and rejects old-generation callbacks. A source link is resolved against the immutable captured scene, then sent by the owning native controller to the source workspace as a strictly validated read-only navigation command. Current source is selected only when workspace identity, layer/anchor and exact source bytes match; older/missing/unsupported sources open an explicitly captured/read-only source view. No source execution or content writes are introduced in the workbench.

**Tech stack:** existing pinned WebWallGL3.0.0, offline CodeMirror, Swift/AppKit/CEF, existing scene/event and native Editor command transports.

## Behavior and acceptance contract

- Issues show actual layer/name, target, phase, message, available line and count; no location guessed from console wrapper URLs or message text. An engine null line remains unavailable. A line beyond the captured source remains visibly unmapped, never clamped to pretend precision.
- The captured revision remains immutable after editing/saving in the workbench. Each preview restart recreates the same captured simulation, resets issue collection/counts and generation, and preserves native cleanup/close guarantees. This is not timeline seeking or hot-updating source. A new Run preview captures a new revision.
- Keep generic console/engine diagnostics visible as unmapped entries when they lack script identity. Runtime failures do not become successful edits, and genuine exceptions remain visible even when the engine disables a repeatedly failing callback.
- Mirror actual upstream issue retention/count limits explicitly in documentation rather than adding a hidden cap, sample/drop mechanism or synthetic issue. Keep the established 8192-byte scene-event body bound unchanged with lossless chunk framing; even a single issue can exceed it through a long layerName or general target. Keep accepted identity/fields/types exact; reject malformed events.
- The preview never gains Editor resource read/stage/list APIs, file writes, native authoring commands or a workbench origin. Main receives no new runtime feature dependency; the observer is bundled only with Editor preview.
- Source navigation must not flush/overwrite an invalid pending source. It either selects an exact matching current source after normal existing barriers, or displays captured source independently with an explicit stale/read-only reason. Captured source view is selectable/copyable and labelled, supports Find and exact line reveal where available; closing it leaves current draft/history untouched.
- Five languages, both themes, minimum layouts, independent Main playback and exports remain supported.

## Task 1 — pure issue identity, capture resolution and observer (TDD)

Create Editor/Web/script-diagnostics.mjs and script-diagnostics.test.mjs, preview observer/wrapper entry modules under Editor/Web; update build.mjs/provenance.

- [x] Inspect actual pinned issue producer fields and getScriptIssues lifetime; write red unit tests for exact issue schema, deduplication/count changes, null/general/effect/ambiguous anchors, source byte identity and line mapping (CRLF/Unicode/trailing newline).
- [x] Implement immutable captured-source resolution using existing listSceneScripts/inspectSceneScript structural anchors; no regex source search and no invented writable general anchor. Test unsupported metadata and duplicate layer IDs remain unmapped/read-only.
- [x] Add fixed read-only observer polling only while scene is alive; compare genuine issue records/counts and report changes, surface observer/reporting failures. Tear it down on destroy and retire old callbacks. Test actual pinned renderer with parse/init/update/cursor/animation failures and genuine unmapped timer warnings and no fake getScriptIssues success path in runtime acceptance.
- [x] Build an Editor-only scene shell/wrapper with the read-only getScriptIssues entry bundled offline; Main runtime assets remain byte-identical. The fixed trusted index.html entry remains unchanged; only the Editor preview scene-shell.mjs becomes an Editor-specific observer shell, with the other seven shared runtime files still exact Main copies. Build/provenance checks explicitly distinguish this shell variant. Do not expose editorOf or controls globally. No runtime scripts=false in the actual execution host.

## Task 2 — typed scene diagnostic delivery and session retention (TDD)

Modify Sources/WebWallpaperBridge/{SceneProtocol.hpp,SceneProtocol.mm,WebPage.mm,include/WebWallpaperBridge.h}; test Tests/SceneRuntimeHarness/protocol-tests.mm. Add Editor issue types/session and Swift tests.

- [x] Red protocol tests for fixed script-issue schema, all fields, null/positive source line, finite numeric-or-null layer ID (noninteger IDs remain visible but cannot be falsely mapped), positive safe integer count, stale scene/generation, unexpected fields, subframe/wrong-origin and oversized/malformed bodies. Preserve every earlier event/command/spectrum boundary.
- [x] Encode each complete actual seven-field issue JSON as UTF8/canonical base64 fragments with transferID, ordinal, final and data. Compute chunk capacity from the actual 8192-byte serialized event budget, including sceneID/generation/framing bytes. A single serial observer awaits each report and does not overlap polls or issue transfers. Native keeps one ordered in-flight transfer per scene; rejects wrong/duplicate/omitted ordinal, interleaved IDs, unknown fields and noncanonical base64. Publish only after final, complete UTF8/JSON and strict issue-schema validation. Preserve exact diagnostic strings, including empty layerName and escaped NUL/Unicode; do not reuse path/identity nonempty-or-NUL rejection for display-only text. No new total source/issue/transfer byte cap, truncation or dropped entry. Retire/close destroys incomplete assembly. Test >8192-byte names/targets, multibyte splits, refreshed counts, malformed ordering and interrupted/stale generations.
- [x] Add a read-only callback forwarding only validated script-issue data; no new resource/control route, document mutation or event parsing from arbitrary console strings. Existing console diagnostics remain separate and visible.
- [x] Retain unique issues and refreshed actual counts in EditorScenePreviewSession. Restart resets collection after retiring old page; late old callbacks cannot pollute the new generation. Close/failed close/cleanup contracts remain observable. Add Swift generation/retention/reset/cleanup tests with explicit injected page, plus real native event delivery acceptance later.

## Task 3 — preview issue list and exact source navigation (TDD)

Modify EditorScenePreviewWindowController, EditorWindowController/Services and tests; Editor/Web/{runtime,app,script-workspace,script-workspace-view,code-editor,localization} and new focused UI/messages module if needed.

- [x] Add a labelled native retained issue list with selection/message/count/phase/line and an Open source button enabled only when the captured scene resolves the issue source. Unmapped entries retain a visible reason. Keep play/pause/restart available and failure state visible.
- [x] reveal-script is a nonmutating navigation command outside the app's unconditional mutation/snapshot flush list. A captured read-only view must open without snapshot/freeze/script.flush so an invalid pending draft does not block diagnostics. Only a requested exact-current selection follows existing source-switch barriers; on a pending conflict leave the draft intact and open the captured read-only view with an explicit reason.
- [x] The runtime exposes an opaque per-SceneDocument identity in snapshot/freeze replies; ordinary edits/Undo/save preserve it and load creates a new identity. The native capture owns this token. It is not stored in project content or exports, and no source from another loaded document is treated as current merely because bytes match.
- [x] The owning controller stores the exact captured snapshot and wires only its own preview's callback to a validated reveal-script navigation command. Weak owner closure, no global registry or filesystem navigation from issue text.
- [x] Current source exact match opens Script workspace/target and reveals actual line using CodeMirror public selection/scroll API; focus and navigation alone do not dirty content or add project/local undo entries. Invalid pending drafts remain untouched and observable.
- [x] Stale/missing/unknown sources open an independent captured/read-only view with exact source and a clear reason; never replace current draft or silently select an unrelated same-text source from another project. Null/out-of-range lines remain unmapped with source still readable.
- [x] Translate every new visible string in five languages, retain light/dark/min-window keyboard accessibility and no global Undo interception in captured code.

## Task 4 — independent runtime/browser/native acceptance

Create test-script-diagnostics.mjs, Tests/EditorRuntimeHarness/ScriptDiagnosticsAcceptance.h, update native main/runner; extend real Swift owner tests.

- [x] Real runtime fixtures produce independently expected layer/effect/general issues and actual counts; verify each available line against engine output, null line remains null. Repeated errors remain retained after engine callback disable. Restart starts the same captured simulation and fresh issue collection; stale callbacks ignored.
- [x] Browser source-link acceptance covers current exact source, stale source after edit, pending invalid draft, deleted/reordered/duplicate layer, unknown metadata, null/general target, Unicode/CRLF and unmapped line. Verify read-only captured content and current project bytes/history remain unchanged.
- [x] Native attached CEF acceptance uses actual preview issue callback and owner navigation, source opening, restart/close isolation and both loose/PKG exports with known Main pixels. No invented DOM diagnostic or simulated runtime issue as acceptance evidence.
- [x] Run JS/offline checks, Editor/Core/product/config/public-export checks and the full fresh-directory native runner retaining every earlier phase and timeout. Re-run only after meaningful fixes.

## Task 5 — independent review, documentation and delivery

- [x] Independent plan review before implementation and implementation review before merge; address confirmed findings with red/green regressions.
- [x] Document issue/capture/line/staleness/restart semantics, actual host and upstream limits, completed IDE scope and excluded breakpoint debugger; retain WebWallGL/CodeMirror/dsh inspiration attribution in both READMEs.
- [ ] Privacy gate changed files, inspect final diff, real commit identity, English PR; verify exact remote head/checks, normal merge, exact tree equality and clean main. No release publishing is part of this instruction.

Plan review: independently approved after explicit lossless chunk framing, finite-number layer ID handling, exact display strings and invalid-draft navigation were specified.

## Approved Unicode representation adjustment

The user explicitly approved lossless raw JSON escape display for upstream
messages containing incomplete UTF16 surrogate code units. Validate the same
strict seven-field schema using a separate validation representation, preserve
the original JSON bytes in a distinct callback/list mode, label the reason in
five languages and disable source navigation. Never replace with U+FFFD, invent
a missing code unit or silently change an ordinary issue. Retain distinct actual
count snapshots and byte-identical deduplication; cover real truncated-emoji
output in the native renderer acceptance, plus strict protocol and Swift tests.

## Review and regression record

- Independent plan review required lossless per-event-budget framing, finite
  numeric IDs, exact display strings and a nonmutating captured-view path.
- Red/green regressions fixed a native command allowlist omission, namespace
  imports whose transformed line differed from the captured source, focused
  inspector input loss, stale line labels, native window foreground behavior
  and list selection identity when script issues arrive before console rows.
- Real API research confirmed timer exceptions are generic warnings; no
  structured source identity is fabricated. Actual engine counts and retention
  limits remain explicit.
- The user approved raw JSON escape representation after a real truncated-emoji
  failure demonstrated Foundation's inability to decode an isolated surrogate.
  Protocol sanitizer tests, native callback acceptance and Swift list/session
  tests cover the separate labelled representation without source navigation.
- The earlier complete native attempt failed at the old preview test closing
  after an init warning while its first frame was still loading. The test now
  awaits actual readiness before close; failures remain visible and the final
  fresh-directory run must pass every phase.

## Final verification

- 397 JavaScript checks; 44 independent Editor tests; 41 targeted Editor Core tests.
- Reproducible 84 offline assets: 75 workbench and nine preview; seven shared
  preview files and all Main runtime files remain unchanged.
- All 38 browser/native phases passed in a fresh directory, including real
  truncated-emoji raw JSON callbacks, exact CRLF locations/counts, captured-source
  navigation, Main loose/PKG pixels and complete runtime release.
- Three product, 42 configuration and 16 public-source checks passed; sanitizer
  protocol and strict native compilation checks passed.
- A cold-build targeted Core run timed out at the unchanged 60-second budget;
  the separate complete build and subsequent 60-second skip-build test passed.
