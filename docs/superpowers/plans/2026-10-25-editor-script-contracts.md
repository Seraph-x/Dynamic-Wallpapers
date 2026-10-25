# SceneScript source contracts and compile-only checks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver independently usable script-source transactions and an offline, non-executing syntax-check command as the first SceneScript IDE infrastructure PR.

**Architecture:** A pure source module identifies native inline layer/effect script targets and edits only the selected wrapper. SceneDocument integrates those edits with existing history/save/export. A separate reproducible `script-api.mjs` bundle binds the actual pinned `checkSceneScript` and captures immutable, checked edit proposals with stale/replay protection. A CLI scans inline source and prints machine-readable native diagnostics without loading the renderer or evaluating user source. No source editing/apply UI or new execution channel is introduced until execution isolation is independently complete.

**Tech Stack:** ES modules, pinned @webwallgl/editor 3.0.0 compiler, esbuild 0.28.2 tree shaking, SceneDocument, Node CLI, actual browser/native Main export checks.

## Scope and isolation boundary

The approved roadmap permits independently tested infrastructure PRs. This PR
is foundation, not completion of the IDE. The pinned engine explicitly says its
in-page script sandbox is not a security boundary: Function/eval can escape it.
Existing Editor rendering behavior is not changed here. The future execution
host must isolate scripts from the workbench/native authoring channel before a
source Apply UI is connected. Highlighting/completion/templates/find-replace,
linked runtime diagnostics and preview restart remain subsequent IDE work.

The actual checkSceneScript is compile-only. An export-only compiler bundle can
load in Node without `window`/`document`; tree shaking removes the renderer
re-export using its declared sideEffects:false. Do not add fake DOM globals,
mock success, rewritten compiler transforms, eval of user source, or silent
fallbacks. Its syntax result is native parity, not a security/safety verdict.
Upstream transformation/lifecycle limitations remain explicit in documentation.

## Source contracts

- `inspectSceneScript(scene,{layerId,target})` returns a source state with
  kind constant/script/bound/unsupported, source where present, owned base value
  and reason when not editable. Targets match the pinned native object whitelist:
  origin, scale, angles, color, alpha, brightness, visible, maxwidth, pointsize,
  volume, intensity, exponent; text only for a pre-existing text layer; and
  `effects[N].visible` for a pre-existing effect. Unknown targets remain read-only.
- Creating a script wraps the existing supported constant as `{value,script}`;
  known absent core fields use the existing native defaults (origin/angles zero,
  scale/color one, alpha one, visible true). Optional fields with no existing base
  are not guessed. Vector constants may be finite 3-component strings/arrays;
  scalar/bool/text use their supported primitive kinds. Existing source wrappers
  preserve all non-source fields and do not invent missing values.
- Existing animation/user bindings, multiple bindings, malformed source types,
  ambiguous/duplicate layer IDs, invalid effect paths and unsupported wrappers
  reject edits visibly. No automatic conversion/removal of another binding.
  Set validates source as a Unicode string without NUL; preserve CR/LF and valid
  astral Unicode exactly. Remove deletes only the script member, retaining the
  wrapper/base and every unknown field; removing from a plain constant is a no-op.
- `editSceneScript(scene,{layerId,target,type:'set'|'remove',source?})` is pure,
  owns its result and never mutates input. `SceneDocument.script(edit)` uses the
  same validation in one history step. This low-level document method stores
  source only: it neither compiles nor evaluates it.
- `listSceneScripts(scene)` scans inline `.script` members, returns stable
  structural paths plus target/layer context, and retains unsupported anchors as
  read-only rather than dropping them. Do not claim external referenced material,
  particle or package-resource scripts are scanned. Detect cyclic input explicitly
  without arbitrary depth/size caps; use iterative traversal for nested JSON.
- The compiled API exports `checkSceneScript`, `prepareSceneScript(document,edit)`
  and `applySceneScript(document,proposal)`. Prepare uses the actual checker for
  set; syntax errors throw a structured error containing native message/line and
  target, without producing a proposal or changing history. Valid no-entry source
  returns an explicit warning because the native runtime can discard it. Removal
  is a data operation, not a fabricated successful compilation.
- Proposals are private-map registered, frozen and pinned to the document object
  plus a deep-equivalent captured snapshot (object key order insignificant;
  array order significant). Apply checks stale ownership and consumes the proposal
  once, then performs one document edit. Forged, replayed or stale proposals fail.
  A valid no-op produces no history entry. Preparation never runs supplied source.
- `checkSceneScriptSources(scene)` reports each inline source with layer/target/
  path, native check result, editable state and diagnostics. Unregistered script-like members
  are reported read-only with `checked:false` and an explicit unvalidated reason;
  they are not compiled or counted, because custom metadata can use that name.
  Registered native anchors are checked even when editing is blocked. Only actual
  checks count; registered non-string sources and syntax errors are errors. A
  no-entry result is a warning, not silently called runtime success.

## Offline command

`node Editor/Web/check-scene-scripts.mjs <scene.json>` reads one JSON scene (or a
workspace/snapshot containing `.scene`) and prints a JSON report with actual checked and explicitly unvalidated counts.
Only registered native anchors are compiled; unknown script-like metadata is
retained read-only with checked:false. Exit 0 means no checked-source
syntax/type errors, exit 1 means reported source errors, and invalid input/I/O
prints an explicit diagnostic with nonzero exit. No file is modified, imports
are not fetched and source bodies are not evaluated. Zero scripts is reported as
zero checked, not a fabricated validation of referenced resource scripts.

## Task 1 — source/history contracts (TDD)

Files: create `Editor/Web/script-source.mjs`, `script-source.test.mjs`; modify `document.mjs` and focused document tests.

- [x] Write missing-feature red tests for inspect/list/edit and SceneDocument.script.
- [x] Implement the native target registry, strict wrapper/binding/ID/path checks,
  immutable edits and iterative discovery, preserving unsupported/unknown data.
- [x] Test constant/new/existing/removal/no-op history; numeric/string/Unicode
  fidelity; effect/text anchors; duplicate IDs; unsupported nested sources;
  binding conflicts; cycles; custom `scriptproperties.script` string/object data
  retained without false errors or inflated check counts; owned results and input
  immutability on failures.

## Task 2 — pinned compiler bundle, checked proposals and CLI (TDD)

Files: create `script-api-entry.mjs`, `script-api.test.mjs`, `check-scene-scripts.mjs` and its tests; extend `build.mjs`, copied script-source resource/provenance.

- [x] Observe missing compiler asset/CLI failures before implementation.
- [x] Bundle only the pinned public checker plus source/proposal contracts, using
  nodePaths for the existing .build dependencies; verify Node loads it without DOM
  stubs and no renderer imports remain. Preserve license and source pin validation.
- [x] Implement immutable checked proposals and complete diagnostic reports; use
  actual native compiler messages/lines/entries. No user-code invocation.
- [x] Probe assignments, throwing code, Function/global escape attempts, dynamic
  imports, timers and fetch in source bodies: compile must not run them or request
  native/file/network actions. Verify syntax error/non-entry reporting and stale,
  replay, forged, no-op and key-order-insensitive proposal behavior.
- [x] Test CLI exit codes/JSON reports against temporary real input files, unchanged
  source bytes and absent side-effect marker files. Run all Node checks and offline
  build/check, with actual counts recorded below.

## Task 3 — browser/compiler and real Main exports

Files: create `Editor/Web/test-script-contracts.mjs`, `Tests/EditorRuntimeHarness/ScriptAcceptance.h`; extend main/runner with 60-second browser-script-contracts/native-script-contracts phases.

- [x] Add a focused native workspace store test for CRLF/Unicode source and
  unknown wrapper fields, saved-file parsing, real reopen and source removal;
  never instantiate a renderer/controller for data persistence verification.
- [x] Browser starts a blank Editor workspace and imports the actual offline
  compiler/source API. Source preparation/check/apply occurs only on standalone
  SceneDocument instances, not the live Editor renderer. Verify no supplied probe
  executes, no resource stage happens, source diagnostics and exact undo/redo.
- [x] Build an independently expected standard scene with two static model meshes
  and a color script: `export function update(value){return Math.floor(engine.runtime*2)%2===0?{x:0,y:1,z:0}:{x:1,y:0,z:0};}`.
  Source transaction adds that wrapper; snapshot/history and manual expected scene
  must agree. Use existing native package builder to export without loading the
  authored scene into the workbench. Save/reparse the generated source snapshot.
- [x] Export `ScriptLoose`/`ScriptPackage` plus snapshot and expected script data.
  Native blank-workbench checks compile-only probes and script proposal/history
  through actual CEF; source compilation must produce no resource-stage request.
- [x] Main actual scene runtime plays both exports and verifies real green/red
  pixels and stationary mesh positions over time; close pages to zero active
  instances and shut down once. No native write bridge is introduced into Main.
- [x] Run the complete fresh-directory native runner preserving all existing phases
  and budgets; only the approved test host uses the isolated keychain.

## Task 4 — docs, independent review and English PR

Files: README, Editor README, `docs/editor-script-contracts.md`, native testing docs and this plan.

- [x] Document the usable CLI/API, supported anchors, read-only bindings, no-entry
  warning, compile-only limits, lifecycle parity and exact remaining IDE/isolation
  scope. Retain WebWallGL attribution. Do not claim the full IDE or a security fix.
- [x] Independently review validation, snapshot ownership, no-execution guarantees,
  actual compiler packaging and command behavior; fix material findings with tests.
- [x] Verify independent Editor build/resource bridge, product/config/source-export
  checks, offline hashes and final diff; scan a changed-file copy with the requested
  sanitization skill while retaining the explicitly requested real author email.
- [ ] Submit an English PR, leave it open and record actual verification/link.

## Verification record

- Previous PR #27 merged at `efa1b84a91adffe4dcf6b5a132c3e66f6f8d4102`; this branch starts there.
- Missing-feature red phases observed for source module, compiler asset/CLI and browser entry.
- Independent review reproduced a shared-wrapper alias bug. A red test covered
  shared wrappers/effects/layer-list metadata; selected-path detachment made it
  green. A separate red check caught sparse-array length in proposal staleness.
- Fresh Node checks: 350 passed, zero failures. Source/API/CLI subset: 28 passed.
- Offline build/check: 61 resources verified with pinned compiler/engine hashes.
- Independent Editor build with tests passed; real workspace source persistence
  and existing resource bridge: 2 passed, zero failures.
- Product/source checks: 3 Editor product, 42 configuration and 16 export tests passed.
- Real-browser source contracts passed. In the complete run, existing shared
  artifact blobs exposed an incorrect empty-directory assertion in the new test;
  it now compares before/after inventory and still requires zero stage events.
- New native phase initially exposed CEF ExecuteJavaScript's missing relative
  import referrer. Test module URLs now resolve explicitly against location.href.
- Independent final source/API/CLI/browser/Swift review has no unresolved findings.
- Fresh final native runner: all 26 build/protocol/browser/native phases passed,
  including native-script-contracts. Both Main formats showed actual green/red/green
  pixels at fixed two-mesh positions, zero Editor session and complete release.
- New CLI regression rejected unsupported workspace schemas explicitly instead of
  interpreting them as raw scene metadata; a real side-effect file probe remained absent.
- Documentation example executed and relative links verified.
- Changed-file public copy: 23 files scanned, RESULT clean; real author identity retained as explicitly requested.
