# Live user properties in independent Editor previews

> Execute the approved advanced-editor and immutable-preview contracts using executing-plans, TDD and independent review. System media is separately researched, as selected by the user; it is not part of this PR.

**Goal:** Test captured, author-declared user properties in a running independent preview without changing the workspace, source project or exports.

**Architecture:** A validated data-only `properties` scene command updates the pinned engine in place. Editor's closure-scoped playback facade uses `declareUserProperties` with value-only entries and awaits its real render completion, including while paused. It never exposes the Editor control object or a native authoring channel. Native AppKit controls read captured `project.json` metadata and submit typed changes through the existing generation/acknowledgement discipline. Restart restores the captured defaults in a new scene origin.

**Scope:** Existing bool, numeric slider, three-component color, string textinput and combo declarations. Unknown/malformed declarations, unsupported conditions, file/directory properties and preset-only entries remain visible with an explicit read-only reason; they are never coerced, dropped or saved. General declarations override the same preset key, matching the pin. No new declarations, content/history edits, persistent overrides, Main property UI, OS permissions or media backend in this PR. Main's shared scene command API remains usable for playback acceptance; its ordinary settings/defaults stay unchanged.

**Tech stack:** Swift/AppKit, existing Objective-C++ CEF data bridge, offline ES modules and pinned WebWallGL/@webwallgl/editor 3.0.0. No new dependency or runtime backend.

**Acknowledgement:** Editor acceptance means the values were accepted and the requested real rendering frame completed. It does not promise that the pin's internally unawaited texture/scale asset work has finished. File/directory properties are not editable in this feature. No seek or simulation restart substitutes for the paused render.

**Exact identity:** Native catalog/default/ack maps use UTF-8 byte identities because Swift String dictionaries merge canonically equivalent Unicode keys. A Foundation dictionary encoded to NSData crosses the dedicated JSONData bridge without Swift dictionary conversion. Individual text/combo values also compare exact UTF-8. Native callback tests exercise both distinct names in one update/reset, not only their UI labels.

**Inspection compatibility:** Property inspection is an independent Result. If the catalog cannot inspect metadata that the existing renderer accepts (including null general/properties/preset shapes), the property section shows the actual inspection failure and disables its controls; ordinary preview creation, pause, restart and close remain available. Inspection failure survives restart and never masquerades as an empty catalog. This restores the preceding preview behavior rather than introducing a substitute renderer or fabricated property success.

**Execution ownership:** Following independent plan approval, use dispatching-parallel-agents for disjoint domains: runtime/native bridge, native Editor UI/lifecycle, and authored browser/native acceptance. Each works on separate files under the stable property command/method contract below; root integrates generated resources, packaging, documentation and final verification. GUI runs are serialized with explicit handoff. No agent commits or publishes independently.

## Task 1 — data-only runtime contract

Files: `Sources/WallpaperApp/Resources/SceneRuntime/scene-properties.mjs` (new), `scene-protocol.mjs`, `scene-runtime.mjs`; `Editor/Web/scene-preview-script.mjs`, `build.mjs`; related pure/runtime JS tests.

- [x] Write failing tests for scalar wire values, finite numbers, exact declared names/types/ranges/options/colors, empty strings, prototype-like names, malformed definitions/preset metadata, patch atomicity, no caller mutation, stale identity and unexpected command fields.
- [x] Implement catalog/patch validation. Preserve original metadata; produce explicit read-only explanations. Do not fabricate slider limits/defaults or clamp invalid values. Only declared, supported properties can be changed; initial values and unknown fields remain exact.
- [x] Add `{type:'properties', properties:{name:value}}` to the existing serialized scene command. Validate the full patch before applying it. Shared playback uses `instance.setProperties`; the Editor facade privately maps value-only entries to `controls.declareUserProperties` and awaits the actual render promise. Do not use seek/resume as a repaint workaround or rerun source factories.
- [x] Add the new shared runtime module to reproducible preview copying. Keep the other shared assets byte-identical; do not bundle a second renderer. Root integration owns generated assets/provenance and packager shared-file lists.
- [x] Verify actual pinned script callbacks and bound pixels while playing and paused, no remount/source rereads, preserved clock/play state, visible errors and disposal.

## Task 2 — native bridge and preview controls

Files: `Sources/WebWallpaperBridge/include/WebWallpaperBridge.h`, `WebPage.mm`; new `EditorPreviewProperties.swift` and `EditorPreviewPropertiesView.swift`; `EditorScenePreview{Page,Session,WindowController}.swift`; five `Localizable.strings`; focused Swift tests.

- [x] Add failing native/Swift tests before implementation. Bridge method: `setSceneUserProperties:completion:`; session page method: `setUserProperties(_ values: [String: Any]) async throws`. Match Objective-C/JS JSON scalar validation (CFBoolean distinguished from numbers), reject nested/null/nonfinite data before dispatch and retain existing close/retired-command cancellation.
- [x] Parse captured metadata into immutable typed descriptors with stable property names and deterministic author order/name sorting. Invalid/unknown rows retain their identity/raw description and a visible reason. Catalog loading errors remain observable without replacing the project or inventing controls. Preserve preset entries explicitly and honor general-property precedence.
- [x] Add the property command to session serialization: only ready playing/paused sessions, one command at a time with existing busy state; keep current generation through await, ignore retired acknowledgements, expose actual failures. Successful changes update only preview-local acknowledged values. Restart resets them to captured defaults, close never saves them. Preserve audio subscription demand and pause state.
- [x] Add a compact native property section using the existing scrollable footer; bool/number/RGB/text/options controls with commit/Apply, explicit invalid-input error and no accidental write. Labels show author text and stable name. Reset uses actual captured defaults and a real command. Explain per-preview, unsaved values and restart semantics in five languages. Existing minimum window dimensions, theme, diagnostics/source buttons and audio controls stay usable.
- [x] Test typed validation, unsupported rows, restart/reset, queued/busy commands, late ack/close, paused/playing updates, failure before/after native dispatch, two independent previews and five-language minimum layouts. Build separately before 60-second targeted Swift selections.

## Task 3 — real browser/native acceptance

Files: new owned user-property fixture/acceptance helper; `Tests/EditorRuntimeHarness/main.mm`; `scripts/test-editor-native.py`.

- [x] Establish a meaningful red before enabling live property delivery. Use independently authored bool/number/color/text/combo expectations and real SceneScript callbacks/bound pixel results, not injected success or inspector DOM alone.
- [x] Verify all supported types, repeated updates, pause/frozen clock with actual repaint, resume, reset/default restart in a new origin, immutable captured files and no Editor authoring/native write capability. Exercise actual native setter plus Main loose/PKG playback. Retain complete CEF release and original suite assertions.
- [x] Add focused browser/native phases as needed; preserve all prior 39 phases, 180-second compile and 60-second execution budgets. For browser checks use official full Chrome 145.0.7632.6/build1208 matching Playwright1.58.2 through the existing explicit executable setting. Existing verified binary is in the preceding audio worktree's ignored verification folder. Native CEF remains pinned; isolated keychain only in the authorized native test host.

## Task 4 — integrate, verify and deliver

- [x] Independently review the plan before implementation, then review substantial final code: types and prototype handling, conditional/read-only semantics, stale native callbacks, async render/clock behavior, script isolation and unchanged Main defaults. Fix confirmed issues with red/green evidence.
- [x] Root integration updates API hints/templates/host notes, both READMEs, preview/API/validation docs and packager shared-file lists. State this is transient preview input, not property-definition authoring or persisted Main overrides. Retain upstream attribution and do not claim media support or a release.
- [x] Run complete Editor Swift and JS suites, relevant Core/Main/bridge tests, reproducible offline build, fresh complete browser/native suite, packaging/product/configuration/export checks and a neutral-source candidate build. No timeout/partial run counts as a pass.
- [x] Prepare the staged diff and changed-file privacy export with sanitized-public-export. Use the configured real author email for the English PR and verified normal merge. Verify exact remote head/checks and sync clean main; no application installation/release.

## Progress

- Clean base: merged PR34, `68c117fb2f2361b6b602cbef6c9baf25d90f107b`.
- Baseline: 397 JavaScript tests and all 84 existing offline assets pass.
- Worktree: `.worktrees/editor-preview-properties`, branch `feat/editor-preview-properties`.
- Independent plan review: Approved; ACK wording clarified before implementation.

## Verification record

- 409 JavaScript tests, 87 complete Editor tests, 41 Editor Core tests and 13 related Main audio/surface tests passed. Targeted Editor properties/request selections retain 60 seconds; test builds run separately.
- Fresh canonical acceptance passed 41/41: all old 39 phases plus new browser/native property phases, 180-second build and 60-second execution budgets unchanged. Actual callbacks, bound GPU pixels, paused repaint/frozen clock, resume, Unicode double names, atomic Reset, new-origin defaults, immutable loose/PKG files and complete release passed. Full Chrome145/build1208 matches Playwright1.58.2; CEF152 and isolated test-host keychain remain unchanged.
- 85 offline assets reproduce; packaging5/product3/configuration42/public-source-export16 passed. The configuration suite's nested sandbox failure was diagnosed as sandbox_apply not permitted; the same unmodified suite passed under normal host manifest evaluation.
- A final neutral-source candidate containing the inspection Result fix passed ad-hoc signature, Mach-O closure, five localized permissions and embedded personal-path checks. It was not installed, notarized or published.
- Independent reviews approved the plan, runtime/native boundary, exact Unicode map/JSONData path, menu values and final inspection-error isolation. Actual red/green tests exposed UTF-8 identity loss, ECMAScript whitespace mismatch, duplicate combo labels, Reset drafts and eager null-metadata inspection; all were fixed without weakening the original rendering checks or budgets.
- Full Main application-suite coverage, persisted Main property overrides and system media are not claimed.
