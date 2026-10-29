# Staged external resource script implementation plan (proposed)

All stages are required; no UI-only or compile-only slice closes the external-resource script work package. The foundation started from merged GC baseline `ba8a94f` and integrates live-renderer PR #39 at `9472eda`. Subsequent stages preserve these reviewed baselines and use independent verified PRs without repeating the approved design interview.

1. **Lock contracts and failing fixtures.** Add owned `Editor/Web/resource-script-fixtures.mjs` producing effect/model/generic/particle/child resources and both loose/PKG origins. Add pure tests with unknown bytes and Script compile-only probes. Add failing renderer assertions for currently missing mesh/tint/particle/child execution before changing playback. Reuse existing unchanged browser/native budgets and coordinate all GUI use with root.
2. **Lossless parser and registry.** Create `Resources/SceneScript/json-spans.mjs`, `resource-contract.mjs` and Node tests. Implement iterative strict-JSON/JSONC tokenization and selected-span patch operations; register only documented actual typed sinks. Test duplicate-key ambiguity, large-number lexemes, comments/strings and Unicode. Export/bundle the pure contract through script-api-entry without importing the renderer into the compile-only bundle.
3. **Read-only resource discovery.** Create `Editor/Web/resource-scripts.mjs` and graph tests. Read snapshot logical resources using existing readResource/resourcePaths; follow effect/model/particle consumers, detect cycles and aliases, retain unknown/unconsumed metadata with reasons, and expose shared-consumer impact. Add exact source capture/proposal objects and stale assertions across every await.
4. **Immutable commit and history.** Create `Editor/Web/resource-script-edit.mjs` plus transaction/regression tests. Reuse stageResource + doc.resource/transaction; no Swift schema/store write change. Validate no-op, failure/stale capture, pending stage vs GC/close and undo/redo. Stage bytes only after actual syntax checking and leave invalid/pending drafts recoverable.
5. **Shared renderer execution and source provenance.** Create `scripts/scene-resource-script-patches.mjs` plus tests; compose after existing live-text patch set. Add engine-owned source metadata, typed evaluator and source-aware sandbox keys. Wire effect/mesh/per-mesh/generic tint/particle material consumers and child override/emitter-rate sinks without pool rebuild. Record helper/patch hashes and exact anchor counts in scene-bundle provenance; rebuild all shared copies. Run real renderer tests for every registered sink, scripts:false isolation, source exceptions and restart/disposal.
6. **Script workspace adapters and UI.** Modify script-draft/workspace/targets/view/language/messages, app.mjs and runtime.mjs only as required for async external source loading/apply/flush. Reuse CodeMirror behavior; display file and source key/consumer impact. Update build.mjs source list/provenance and all generated offline modules together. Run actual-input browser regression tests, keeping current source/history/selection barriers intact.
7. **Structured diagnostic/navigation protocol.** Extend script-diagnostics/navigation modules; SceneProtocol.mm, WebWallpaperBridge.h, EditorScriptDiagnostic.swift and preview display; update native JS protocol tests. Add exact validated optional resource-origin field and source-aware dedup; preserve old inline shape. Capture comes from the independently executing preview's actual loaded resource bytes. Test malformed/fragmented/stale/shared-source cases and focus-safe captured view without draft commit.
8. **Complete native persistence and playback acceptance.** Extend existing Editor native harness/Script acceptance with material and particle scenes imported from both loose and PKG; edit, undo/redo, save/reopen, preview, export both formats, then real Main playback with pixels/simulation and normal lifecycle release. Verify original/resource unknown-byte hashes and GC compatibility. Run full relevant Node/Core/Editor/CEF regressions under existing budgets, independent review and changed-source privacy gate.
9. **Truthful docs and independent English PR.** Update Editor README, editor-script-workspace/contracts/API/diagnostics docs, tests guide and completion ledger from the actual accepted scope/results. Explain recognized/read-only anchors and shared-file edits. Do not remove current exclusions before the corresponding runtime/acceptance passes. Root owns English PR, exact tested head validation and authorized merge.

## Expected production file boundary

New pure shared modules under `Resources/SceneScript/`; new Web modules resource-scripts/resource-script-edit and fixtures/tests; focused engine patch module; existing scene-bundle/patch composition and provenance; existing Script workspace adapters/build list/generated resources; existing diagnostic transport/Swift source-link handling and tests; docs. No new native arbitrary-file IO, package mutation API, schema migration, dynamic import loader, mock playback, history cap or GC exception policy.

## Review decisions that do not need a user interview

- Reuse schema-2 immutable override transactions and mandatory lifetime session staging; originals remain owned immutable inputs.
- Use a generic span lexer rather than serializing JSON or extending the two specialized metadata parsers beyond their invariants.
- Include required renderer changes and diagnostics before feature completion; a UI-only stage is not an acceptable final result.
- Keep unsupported source-like metadata visible with actual semantic reason, as the umbrella explicitly requires; no fabricated generic JavaScript execution capability.

## Approved technical decisions

- The approved registered particle subset is child instanceoverride typed sinks plus direct emitter.rate, together with supported consumed material paths. Unknown source-like metadata stays visible read-only with reason. No per-frame model/pool rebuild.
- Use explicit validated optional external source descriptors; do not encode opaque resource identity into the target string.
- The foundation uses an isolated worktree based on the merged GC/live-text revisions. Compose the future resource patch module once without duplicating existing live-text changes. GUI validation remains coordinated with other native acceptance runs.

## Approved coherent PR split

1. **Lossless resource source foundation**: generic lexer, pure typed registry, read-only discovery, authentic immutable resource edit proposals/transactions and focused tests. Provide data APIs and truthful compile-only/reporting contracts; add no disabled/inactive feature UI and do not claim playback completion. Reuse mandatory GC sessions. This is independently reviewable and builds/tests without the future runtime patch.
2. **Actual runtime sinks and resource diagnostics**: recorded shared renderer patch, every consumed material path, typed particle sinks, structured source descriptors and protocol/native decoding, actual renderer probes and complete disposal/error handling. Compose with root's final live-text patch baseline and preserve exact shared engine bytes/provenance. Existing workspace remains unchanged until complete authoring integration.
3. **Complete Script workspace and native acceptance**: async inline/resource draft adapter, chooser/current/captured navigation, five-language real-input UX, full freeze/history/save/reopen/loose+PKG workflows, native Editor preview and actual Main playback. All original/unrelated bytes and complete GC safety are verified. Only this final PR closes the umbrella external-resource scripting item after full acceptance.

The foundation started from `9472eda7d8b566d92712efc5c4638ae4db272a13` and was synchronized with main at `7d706d9948427dd522f402b5a81b992e85430e43` before final verification. Every PR has its own tests/review/English description and integration; no stage silently substitutes incomplete behavior for the whole feature.

## Foundation execution checklist

- [x] Add failing parser, typed registry, discovery and opaque transaction tests.
- [x] Implement lossless JSON/JSONC spans and data-only native source contracts.
- [x] Implement inventory/reference discovery, failure reports and snapshot-bound live-reader adapter.
- [x] Implement authentic capture, compile-only preparation and immutable one-step commit with lifetime/stale/concurrency checks.
- [x] Add pure document target validation and read-only Editor lifetime getter; regenerate their existing offline copies without changing the shared engine.
- [x] Exercise actual filesystem staging/reopen and pinned PKG extraction/rebuild byte preservation without renderer/DOM shims.
- [x] Complete independent review, reproducible manifest checks, full Node regression and changed-source privacy/diff gates on the final revision.

Only the first approved PR is represented by this checklist. Runtime execution and complete workspace/native playback acceptance remain open until their own stages pass.

## Later-stage execution checkpoints

- [x] Runtime/diagnostics stage merged as PR #47 at `6349c0a`; all eight original sinks, strict descriptor transport, disposal and complete existing Editor/Main native regression passed.
- [x] Add failing asynchronous resource-draft, chooser, typed template and current/captured navigation tests; implement the adapters and offline API bundle.
- [x] Real-input browser material/child/emitter edit, check, invalid draft, Revert, remove, one-step history, exact PKG bytes and current/pending/stale navigation passed. Existing complete inline workspace and navigation browser regressions passed.
- [x] Register typed scene instanceoverride sources and reproduce/fix parent override broadcasts crossing explicit child overrides; actual inherited/explicit/inherited opacity is `0.2/1/0.2` with per-instance sandboxes.
- [x] Complete five-language resource UI/shared-consumer/unknown-source layout, saved reload, package-derived import and fault/race acceptance. The full shared-consumer list retains every owning layer/reference slot and uses keyboard-operable native disclosure.
- [x] Complete actual native material/particle edit, freeze, undo/redo, save/reopen, captured preview, loose/PKG Main playback, resource/GC/lifetime and long-origin diagnostics acceptance.
- [x] Run full relevant regressions, review, privacy/build gates, truthful docs and the final workspace English PR/merge. PR #48 merged at `721e940` from tested implementation head `4fbdc7b`; the umbrella external-resource scripting item is closed.

## Workspace verification before integration

- All 489 Node checks and the complete 98-test Editor Swift suite passed. The
  Swift persistence case uses actual Core loose/PKG stores, staging, preview,
  save/reopen/reimport and collection rather than an in-memory save substitute.
- All 54 defined Editor browser/native phases have supervised exit-zero
  evidence. After correcting asynchronous test-selection/input barriers, the
  remaining phases were completed through the same runner command definitions
  and verified native build with new cache directories. The combined receipt is
  `.build/verification/editor-native/72a86401-0799-4427-8e81-5d9214a61e3d/completed-matrix.json`;
  earlier failing invocations are not reported as passing full invocations.
- Actual material, child-override and emitter-rate native edits passed focused
  keyboard/freeze, exact one-step history, save acknowledgement, disk reopen,
  independent preview and Main loose/PKG GPU/simulation checks and full release.
  Each actual native export passed complete inventory, project/entry and byte
  comparison; five damaged-output negative controls were rejected.
- A real resource exception with more than 8192 bytes of Unicode/CRLF source
  passed fragmented native transport, original-byte digest/pointer/text,
  phase/count/line and independent read-only captured navigation checks.
- Main scene native build, protocol and runtime exited zero. Both reproducible
  build checks passed; all three engine copies have SHA-256
  `822c8a221bac0f8b74d8bd4ccec0106ea4a64af79c29e8699b51bcd2937ba31c`.
- Independent review found no remaining Important issues. All 69 changed/new
  files passed the publication scan. Source diff checks passed; existing shader
  whitespace inside the three generated engine bundles is unchanged upstream
  content, excluded from that source-only whitespace check.
