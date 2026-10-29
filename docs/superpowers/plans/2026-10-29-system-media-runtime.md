# System media runtime integration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved default-off Music/Spotify integration in Main, with actual metadata, artwork and five transport actions reaching playing scenes through a generation-bound data channel.

**Architecture:** Reuse the existing shared `SystemMediaController` and its independent artwork controller. Native CEF pages deliver immutable media JSON through their existing ordered, generation-bound, acknowledged scene command channel; the shell supplies an explicit external driver even when it has no item, so wallpaper audio and simulated media cannot substitute. Main owns settings, explicit Automation consent, playback demand, errors and shutdown; Editor playback receives empty media unless its owner explicitly supplies data, with no new Editor authorization UI. Inspection confirmed the existing command path can carry full JSON without the event body's 8192-byte bound, and its frame acknowledgements avoid a second poll/GET lifecycle.

**Tech Stack:** Swift/Combine/SwiftUI, public Apple Events, Objective-C++/CEF, pinned WebWallGL 3.0.0, Node tests and actual WebGL/CEF harnesses.

**Approved specifications:** `docs/superpowers/specs/2026-10-27-complete-remaining-work-design.md`, `2026-10-27-public-media-providers-design.md`, `2026-10-27-system-media-artwork-design.md` in the same directory. Requirements clarification is complete. This PR does not claim public lyrics or artwork-derived colors: lyrics remain unavailable and renderer color fields are explicit neutral black/white values.

## File ownership

- `Sources/WallpaperMediaIntegration/SystemMediaSceneSnapshot.swift`: immutable renderer projection, actual PNG only for matching provider/track, empty projection on no item, no fabricated metadata.
- `Sources/WallpaperApp/Resources/SceneRuntime/scene-media.mjs`: strict wire validation, driver projection and fixed transport events. Mirror through the existing Editor resource build process.
- `scripts/scene-engine-patches.mjs`: one recorded exact-match fix for explicit external source precedence; `Resources/ThirdParty/WebWallGL/provenance.json` records regenerated hashes.
- `Sources/WebWallpaperBridge/SceneProtocol.{hpp,mm}`, `WebPage.mm`, `include/WebWallpaperBridge.h`: validated native media command and fixed main-frame media-control event callback. No arbitrary JavaScript, paths, URLs or native commands.
- `Sources/WallpaperApp/Media/SceneMediaSessionOwner.swift`: per-instance active demand and snapshot publication, Combine artwork observation, stale/closing-instance rejection, observable publication/control failures.
- `CEFApplicationRuntime.swift`, `CEFScenePageSession.swift`, `AppModel.swift`, `ApplicationTermination.swift`: source configuration, prepare/play/pause/close/quit ownership.
- `Sources/WallpaperApp/UI/SystemMediaSettingsSection.swift`, `UI/SettingsView.swift`, app five-language resources and `Resources/Info.plist`: source selection, permission explanation and explicit authorization/retry/status.
- Targeted tests under `Tests/WallpaperMediaIntegrationTests`, `Tests/WallpaperAppTests`, `Tests/SceneRuntimeHarness`; scripts `test-scene-media.mjs`, `test-scene-runtime.mjs`, `test-scene-rendering.mjs`, `test-scene-native.py`, `test-scene-swift.py` and their build inputs provide independent unit and real-renderer evidence.

## Task 1: Immutable native-to-scene projection

Completed locally: red compile proved the missing projection; isolated build passed,
then all 40 media tests passed in 1.035 seconds under the 60-second supervisor.
The first sandboxed run failed because its owned TLS server could not bind;
the authorized run exercised real TLS successfully, with no test relaxation.
Logs: `/private/tmp/dw-system-media-projection-red.log`,
`/private/tmp/dw-system-media-native-build.log`,
`/private/tmp/dw-system-media-native-tests-authorized.log`.

- [x] Add failing `Tests/WallpaperMediaIntegrationTests/SystemMediaSceneSnapshotTests.swift` cases for Unicode metadata, the 0/1/2 state projection, empty disabled/unavailable state, actual matching PNG bytes, stale artwork exclusion and metadata surviving artwork failure. Require exact JSON fields: `hasMedia`, `state`, `title`, `artist`, `album`, `albumArtist`, `position`, `duration`, `thumbnail` (PNG data URL or null).
- [x] Build the target with `python3 scripts/swift_sdk.py build --target WallpaperMediaIntegrationTests --disable-sandbox` and observe the missing projection fail. Build and run the isolated package with `python3 scripts/test-public-media.py --build-only` then `python3 scripts/test-public-media.py --run-only --filter WallpaperMediaIntegrationTests` (180-second build / 60-second test supervisor). Full-package `swift test --skip-build` requires all unrelated test bundles and is unsuitable before their cold build.
- [x] Implement `SystemMediaSceneSnapshot` as a `Sendable, Encodable, Equatable` value, initializing from native snapshot and artwork state. Empty values are false/0/empty strings/null. Do not clip text, advance the timeline, synthesize images or borrow artwork from another identity.
- [x] Run all `WallpaperMediaIntegrationTests` within 60 seconds after build, preserving existing foundation tests. Commit `feat: project actual system media into scene snapshots`.

## Task 2: Explicit external renderer source

Completed locally: 23 targeted Node checks and 464 Editor Node tests pass;
Main and Editor actual full Chrome/Metal WebGL each pass loose/PKG metadata,
PNG pixels, five controls, paused frame acknowledgement, empty clearing and a
held real decoder followed by queued clear. Both reproducible bundle checks and
five Editor packaging checks pass. Current shared engine SHA256:
`86afbcd49cb54f87bad2bb78e97b29abf5b5e326d9a97fb27915258150b40e5a`.
Evidence: `/private/tmp/dw-scene-media-rendering-delayed-clear.log`,
`/private/tmp/dw-system-media-editor-unit.log`,
`/private/tmp/dw-scene-media-unit-final.log`. Generated engine string literals
retain pinned whitespace; authored-source diff checks exclude generated bundles.
Independent review also exposed neutral-color writeback, stale current/previous
GPU textures, an upload-failure bitmap leak and same-URI identity retirement.
Their regression tests now exercise the actual decoder, GL upload failure,
independent artwork error and explicit retry for both Main and Editor loose/PKG
renderers. Evidence: `/private/tmp/dw-scene-media-identity-unit.log`,
`/private/tmp/dw-scene-media-identity-browser.log`,
`/private/tmp/dw-system-media-editor-final.log`.

- [x] Consult `modern-web-guidance` before client code. Add failing Node tests in `scripts/test-scene-media.mjs` for full validation before mutation, identity/generation mismatch at the command boundary, unknown fields, invalid numeric/thumbnail values, empty item clearing all prior metadata/artwork, disposed controls and visible report failures.
- [x] Run `node --test scripts/test-scene-media.mjs` and observe the missing behavior. Implement the pure source in `scene-media.mjs`. The source implements the engine's structural driver contract (`snapshot`, `update`, five controls), provides explicit neutral colors and empty lyrics, and never progresses time independently. Transport reports exactly `media-control` plus one of `play`, `pause`, `playPause`, `skipNext`, `skipPrevious`; report request failures explicitly without unhandled promises or fabricated player success.
- [x] Add runtime integration tests, then wire `scene-runtime.mjs` and its strict command protocol: always pass this explicit source, accept `media` snapshot commands only after full validation, await its actual frame, and dispose controls with the runtime. Editor scene preview stays empty on the same shared runtime; workbench preview stays media-disabled. Control failure is reported visibly and does not masquerade as player success.
- [x] Add an exact-match patch changing `currentMediaDriver` to honor `rt.mediaSource` even when `snapshot.hasMedia` is false. Add a regression in `scripts/test-scene-engine-patches.mjs`; regenerate Main and both Editor bundle copies with the existing bundle scripts, recording all hashes. Do not edit upstream cached input.
- [x] Extend actual WebGL loose/PKG fixtures to include wallpaper audio and real media hooks. Verify external current and empty snapshots, actual thumbnail pixels, all five control callbacks, no simulated/audio fallback and paused/resumed clearing. Hold an old publication across pause/source-disable and prove it cannot restore old metadata/artwork after the clear acknowledgement; use native revision/invalidation and ordered commands rather than a timing assumption. Expose the existing `renderOnce()` through a recorded `sceneCtl` media-refresh method, return its promise from `instance.setMedia`, and prove paused pixels before acknowledgement without applying unrelated user properties.
- [x] Run Node/runtime/engine tests and `node scripts/scene-bundle.mjs --check`, Editor bundle reproducibility checks, then the existing supervised full browser phases (60 seconds each). Commit `feat: deliver explicit external media to scene rendering`.

## Task 3: Private CEF data and transport boundary

The media command envelope and each control event also carry a positive safe
integer `mediaRevision`. The owner changes it when the provider/track or instance
demand changes, checks it before dispatch, and rejects stale actions so an old
button cannot control a newly selected player. The nine snapshot fields remain
unchanged. Clear invalidates owner state synchronously; the ordered empty command
then awaits its actual frame acknowledgement.

- [x] Add failing cases in `Tests/SceneRuntimeHarness/protocol-tests.mm`: fixed media-control events require exact scene/generation, exact fields and command allowlist. Native snapshot validation rejects malformed/nonfinite/wrong-type values and unknown/missing fields. Existing trusted-main-frame POST authorization remains mandatory.
- [x] Implement `validateSceneMediaSnapshot` in the native protocol and a fixed `media` scene command carrying the exact nine-field snapshot. Bind scene ID/generation and unpredictable command ID using the existing `sceneCommand` method. Publish actual PNG as JSON data without an arbitrary body/image cap. Existing 8192-byte control-event limit remains sufficient because artwork is never sent as an event.
- [x] Expose `setSceneMediaSnapshotJSONData:mediaRevision:completion:`, `onSceneMediaControl` and independent `onSceneMediaArtworkError` on `DWWebPage`; reject closed/unready pages and complete only on the existing frame-owned command acknowledgement. Extend the existing event drain. No generic Editor resource or command capability is granted. Test cancellation/late queued events and malformed data.
- [x] Run `bash scripts/build-scene-native-test.sh` with 180-second build supervisor and the existing protocol phase within 60 seconds. Actual CEF phase must receive native metadata/artwork, invoke all five real hook controls, reject stale/cross-frame requests and release the page. Commit `feat: add generation-bound CEF system media channel`.

Native build/protocol/runtime passed in runs
`bad4c25f-6d67-4e05-8ffe-9882a816d69f` and fresh precommit
`2f6128aa-d10f-4d12-979d-5fbc8edd6696`, including real loose/PKG PNG pixels,
neutral colors, five native controls, malformed-data rejection, decoder failure,
same-PNG/new-item retry, close cancellation, stale identity and blocked frames.
All resources release through `DWWEB after-runtime-shutdown`. Earlier failures
remain recorded: system Keychain blocked CEF shutdown; the explicitly selected
`SCENE_NATIVE_TEST_KEYCHAIN=isolated` test-host mode avoids personal credentials
under the previously approved harness policy and does not alter production
Keychain behavior. CSP page-load failure and operation-close failure now retain
their separate scopes, including late load callbacks during teardown.

## Task 4: Shared Main lifetime and delivery

- [x] Add failing `Tests/WallpaperAppTests/SceneMediaIntegrationTests.swift` with injected native provider and page sinks: default off, one service across two playing scenes, no paused/preparing-instance disclosure, independent artwork completion, source-switch and disable clears, per-instance pause clears while another remains active, rejected stale control, delivery failure visible, close draining and rejected quit.
- [x] Add `WallpaperMediaIntegration` to Main/test dependencies and harness object inputs. Implement `SceneMediaSessionOwner` with an injected controller and fixed per-page data sinks, lifecycle registration before playback and explicit detach before close. Combine subscriptions observe the emitted artwork state (because `@Published` sends before assignment) and the already-assigned metadata snapshot.
- [x] Wire the owner into `CEFApplicationRuntime` and `CEFScenePageSession`; attach an empty projection before presentation, supply data only to actual playing instances, synchronously clear native snapshot when an instance pauses, and gate controls on the same current scene/demand. Never query/launch another provider. Keep failures visible in controller/owner state and native diagnostics rather than swallowing them or destroying an otherwise healthy scene for ordinary provider unavailability.
- [x] Configure persisted `systemMediaSource` in `AppModel`, forced disabled on library-load failure. Drain media operations and artwork before native runtime shutdown; preserve the existing rejected-quit preflight behavior. Completed shutdown retires old scene IDs rather than resurrecting demand.
- [x] Run targeted media/Main tests within 60 seconds after a separate build. Extend `Tests/SceneRuntimeHarness/system-media.swift`, `swift-main.swift`, build and runner scripts for actual Swift owner + CEF loose/PKG playback with authored owned provider metadata/artwork and five commands. Use the real Apple Event fixture/TLS pipeline from `scripts/test-public-media.py`, not fake-success substitutes. Commit `feat: connect playing scenes to shared system media`.

The complete Swift application/test build passed in 139.23 seconds, followed by
successful incremental builds for the final regressions. All 66 targeted Main,
media and Core tests passed. The complete isolated package passed 45 native media,
143 Core and 11 owner tests (199 total), including actual owned TLS.
Independent review found a deeper Task/GCD cancellation window: seven handshake
tests first failed after controls entered the actual blocked Apple Event worker.
Per-control task cancellation now propagates through the controller into the
existing worker cancellation gate, including pause/close while another instance
stays active. The native queue regressions and all affected tests pass.
`SceneSurface.close` also revokes playback intent before native retirement; its
new test first observed the old true intent and now passes.

Strict Swift/CEF test-host builds passed within the 180-second supervisor, using
explicit isolated Keychain bridge objects while production objects stay intact.
Actual Apple Event/TLS → Main owner → Metal CEF runs
`a8482c7a-4d68-44e5-92f7-8e4a6d51b401` and
`5acf3d94-15ec-44e8-8b9b-7e2c127b5a01` passed both owned dictionary adapters and
loose/PKG scenes, five scene controls, actual metadata and PNG pixels, independent
artwork/transport failures, explicit retry, per-instance pause and source-disable
clears, and complete runtime shutdown. The second run explicitly prepares a new
page while another already displays live native metadata/PNG and proves that
new page stays empty until actual playback. Independent review has no remaining
Critical/Important findings. This proves owned fixtures, not personal vendor-app
playback. Main consent/settings and final PR integration remain open.

Evidence logs: `/private/tmp/dw-media-worker-red-tests.log`,
`/private/tmp/dw-media-worker-green-tests.log`,
`/private/tmp/dw-system-media-close-red-tests.log`,
`/private/tmp/dw-system-media-main-current-tests.log`,
`/private/tmp/dw-system-media-complete-foundation-tests.log`,
`/private/tmp/dw-system-media-main-preparing-automation.log`.

## Task 5: Main consent, settings and packaging

- [x] Add targeted settings/localization/packaging assertions before implementation: disabled legacy default, exact three options, no prompt on selection, explicit authorization button, provider/permission/no-item/failure statuses and independent artwork errors/retry.
- [x] Implement `SystemMediaSettingsSection` using existing `@Localized`, observed controller/artwork and persisted mutation pattern. Explain that trusted scenes can read/control the selected already-running player, that no global source exists, and that artwork/lyrics availability is limited. Disable actions during shutdown/load failure.
- [x] Add `NSAppleEventsUsageDescription` and five localized purpose strings; if the actual distribution uses hardened runtime, add the Automation entitlement only to the Main executable's signing path. Preserve helper signing and state the actual signing/notarization status.
- [x] Run localization/product-configuration/packaging tests and actual settings/consent owned-fixture smoke in an isolated bundle. Do not launch Music/Spotify or modify user libraries/wallpaper for tests. Record actual vendor smoke separately; if no vendor is running/authorized, leave that acceptance item open rather than claiming the fixture proves it.
- [x] Commit `feat: expose localized system media consent and settings`.

Main now exposes the actual production section with three persisted choices,
explicit authorization and separate metadata/artwork retries. Seven native
AppKit/localization tests pass, including a save-failure regression that first
failed and now shows the real persistence error without enabling the provider.
Five localized Automation purpose strings and the root purpose are verified.
Current signing is ad-hoc without hardened runtime; no unsupported hardened
runtime/notarization claim or unnecessary entitlement is added.

Actual settings run `74cd7439-90c3-4558-8085-58f91122e3e5` passed both owned
Apple Event dictionary adapters through the production SwiftUI view, real
metadata, decoded artwork pixels, independent artwork retry, visible provider
failure, persisted disable and complete shutdown. Product configuration (42),
permission copy (1), Editor product (3) and package isolation (4) checks passed.
Neither Music nor Spotify was running in the read-only presence check. Their
live vendor-app playback acceptance remains unverified; no personal app was
launched and owned fixtures are not represented as vendor playback.

The first broad Swift run failed. Missing authored MPV fixtures were restored
using the documented fixture generator with explicitly selected Homebrew
FFmpeg; the controlled runtime intentionally lacks the optional encoding
libraries required to generate those test inputs. The shipped runtime remains
the verified controlled build. Twenty selected media/TLS/MPV tests then passed;
real audio and ScreenSaver playback also passed in the subsequent authorized
run. Existing inspector UI and 30/60 Hz capture assertions still failed, and
are retained as broad-suite limitations rather than hidden or relaxed.
The old General checkbox assertion omitted the already-merged system-audio
switch; it now asserts all eight switches and the separate three media radios.

Evidence: `/private/tmp/dw-system-media-settings-final-ui-tests.log`,
`/private/tmp/dw-system-media-settings-native.log`,
`/private/tmp/dw-system-media-package-isolation-tests.log`,
`/private/tmp/dw-system-media-full-swift-tests.log`,
`/private/tmp/dw-system-media-restored-fixture-targeted.log`,
`/private/tmp/dw-system-media-remaining-authorized.log`.

## Task 6: Review, verification, PR and completion record

- [x] Use `requesting-code-review` with a read-only independent reviewer for the whole change, fix material issues and rerun affected checks.
- [ ] Run `verification-before-completion`: complete relevant Swift and Node suites, strict native harness build (180 seconds), each actual browser/CEF/Apple Event/TLS phase (60 seconds), same-input reproducible Main/Editor bundles, dependency/signature checks and changed-file sanitized-public-export gate.
- [ ] Inspect final diff, preserve source originals and unknown metadata, record exact tested heads and actual receipts in `docs/superpowers/plans/2026-10-27-completion-ledger.md` (locate the existing ledger before editing if its filename differs). English commits/PR text use configured real identity. Documentation PR #49 merged as `3583cc0`; this branch includes that remote merge. Do not bypass automatic approval review.
- [ ] Push and create the coherent system media PR under existing authorization, wait for actual checks, merge the exact tested head when review is available, verify remote merge state and update the ledger. A local passing implementation is not a merged PR.
- [ ] Continue the remaining queue: controlled final dependency/app packaging, five-language README/help and historical roadmap correction, then Main/independent Editor releases built from final merged source. This plan does not mark those releases complete.

Final independent whole-branch review found no Critical/Important issues in the
native boundary, cancellation/lifetime, renderer/artwork, consent/settings or
signing paths. Fresh focused run passed 5 projection, 8 Main media and 32 settings
checks (45 total), with actual exit 0. Product configuration (42) and Editor
product (3) checks passed again. The 24 changed authored files passed the external
sanitized-public-export gate. Evidence:
`/private/tmp/dw-system-media-final-focused-current.log`,
`/private/tmp/dw-system-media-product-final.log`,
`/private/tmp/dw-system-media-editor-product-final.log`.

Current feature head `cd0692731624963700a4ab6fc59cb8e70b617d69` passed all 54
Editor browser/native phases in run `636258f5-57d7-433f-838b-edb47e02ed5b`,
strict build (180 seconds) and each execution phase (60 seconds), with actual
export pixels and normal CEF shutdown. Fresh Main native run
`2c311dee-61ad-40eb-bd22-ceb999e75a09` passed build/protocol/runtime and every
media/boundary receipt. All 199 isolated media/Core/owner tests passed again.
Actual production settings run `51321e21-afa0-4208-a6ce-54e5e0502f34` passed
both owned native adapters and complete consent/artwork/retry/shutdown receipts.

The complete packaging check exposed a stale distribution-material manifest:
its WebWallGL provenance hash still described an earlier renderer patch record.
The existing manifest generator updated only that file's actual SHA256/size;
all 42 packaging tests then passed. Its original failing run is retained in
`/private/tmp/dw-system-media-final-packaging-tests.log`, with green result in
`/private/tmp/dw-system-media-packaging-green.log`. This is a material-index
correction, not a renderer/runtime change. Final candidate/archive verification
and the documented broad-suite UI/cadence limits remain distinct.

Draft PR: https://github.com/Seraph-x/Dynamic-Wallpapers/pull/50. GitHub reports
no configured checks for this branch; local receipts and the exact head are
recorded explicitly instead of inventing a remote CI pass.
