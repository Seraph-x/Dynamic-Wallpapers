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

Completed locally: 21 targeted Node checks and 464 Editor Node tests pass;
Main and Editor actual full Chrome/Metal WebGL each pass loose/PKG metadata,
PNG pixels, five controls, paused frame acknowledgement, empty clearing and a
held real decoder followed by queued clear. Both reproducible bundle checks and
five Editor packaging checks pass. Current shared engine SHA256:
`0a45b3acc7a6ec65ca260f8a803ec6c276139aef5a0fb3a249a6f168481d27ca`.
Evidence: `/private/tmp/dw-scene-media-rendering-delayed-clear.log`,
`/private/tmp/dw-system-media-editor-unit.log`,
`/private/tmp/dw-scene-media-unit-final.log`. Generated engine string literals
retain pinned whitespace; authored-source diff checks exclude generated bundles.

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

- [ ] Add failing cases in `Tests/SceneRuntimeHarness/protocol-tests.mm`: fixed media-control events require exact scene/generation, exact fields and command allowlist. Native snapshot validation rejects malformed/nonfinite/wrong-type values and unknown/missing fields. Existing trusted-main-frame POST authorization remains mandatory.
- [ ] Implement `validateSceneMediaSnapshot` in the native protocol and a fixed `media` scene command carrying the exact nine-field snapshot. Bind scene ID/generation and unpredictable command ID using the existing `sceneCommand` method. Publish actual PNG as JSON data without an arbitrary body/image cap. Existing 8192-byte control-event limit remains sufficient because artwork is never sent as an event.
- [ ] Expose `setSceneMediaSnapshotJSONData:completion:` and `onSceneMediaControl` on `DWWebPage`; reject closed/unready pages and complete only on the existing frame-owned command acknowledgement. Extend the existing event drain. No generic Editor resource or command capability is granted. Test cancellation/late queued events and malformed data.
- [ ] Run `bash scripts/build-scene-native-test.sh` with 180-second build supervisor and the existing protocol phase within 60 seconds. Actual CEF phase must receive native metadata/artwork, invoke all five real hook controls, reject stale/cross-frame requests and release the page. Commit `feat: add generation-bound CEF system media channel`.

## Task 4: Shared Main lifetime and delivery

- [ ] Add failing `Tests/WallpaperAppTests/SceneMediaIntegrationTests.swift` with injected native provider and page sinks: default off, one service across two playing scenes, no paused/preparing-instance disclosure, independent artwork completion, source-switch and disable clears, per-instance pause clears while another remains active, rejected stale control, delivery failure visible, close draining and rejected quit.
- [ ] Add `WallpaperMediaIntegration` to Main/test dependencies and harness object inputs. Implement `SceneMediaSessionOwner` with an injected controller and fixed per-page data sinks, lifecycle registration before playback and explicit detach before close. Combine subscriptions must observe completed artwork as well as metadata; read the controller's current values after published changes to avoid `@Published` willSet stale values.
- [ ] Wire the owner into `CEFApplicationRuntime` and `CEFScenePageSession`; attach an empty projection before presentation, supply data only to actual playing instances, synchronously clear native snapshot when an instance pauses, and gate controls on the same current scene/demand. Never query/launch another provider. Keep failures visible in controller/owner state and native diagnostics rather than swallowing them or destroying an otherwise healthy scene for ordinary provider unavailability.
- [ ] Configure persisted `systemMediaSource` in `AppModel`, forced disabled on library-load failure. Drain media operations and artwork before native runtime shutdown; preserve the existing rejected-quit behavior and only restore fresh demand through new playback callbacks.
- [ ] Run targeted media/Main tests within 60 seconds after a separate build. Extend `Tests/SceneRuntimeHarness/system-media.swift`, `swift-main.swift`, build and runner scripts for actual Swift owner + CEF loose/PKG playback with authored owned provider metadata/artwork and five commands. Use the real Apple Event fixture/TLS pipeline from `scripts/test-public-media.py`, not fake-success substitutes. Commit `feat: connect playing scenes to shared system media`.

## Task 5: Main consent, settings and packaging

- [ ] Add targeted settings/localization/packaging assertions before implementation: disabled legacy default, exact three options, no prompt on selection, explicit authorization button, provider/permission/no-item/failure statuses and independent artwork errors/retry.
- [ ] Implement `SystemMediaSettingsSection` using existing `@Localized`, observed controller/artwork and persisted mutation pattern. Explain that trusted scenes can read/control the selected already-running player, that no global source exists, and that artwork/lyrics availability is limited. Disable actions during shutdown/load failure.
- [ ] Add `NSAppleEventsUsageDescription` and five localized purpose strings; if the actual distribution uses hardened runtime, add the Automation entitlement only to the Main executable's signing path. Preserve helper signing and state the actual signing/notarization status.
- [ ] Run localization/product-configuration/packaging tests and actual settings/consent owned-fixture smoke in an isolated bundle. Do not launch Music/Spotify or modify user libraries/wallpaper for tests. Record actual vendor smoke separately; if no vendor is running/authorized, leave that acceptance item open rather than claiming the fixture proves it.
- [ ] Commit `feat: expose localized system media consent and settings`.

## Task 6: Review, verification, PR and completion record

- [ ] Use `requesting-code-review` with a read-only independent reviewer for the whole change, fix material issues and rerun affected checks.
- [ ] Run `verification-before-completion`: complete relevant Swift and Node suites, strict native harness build (180 seconds), each actual browser/CEF/Apple Event/TLS phase (60 seconds), same-input reproducible Main/Editor bundles, dependency/signature checks and changed-file sanitized-public-export gate.
- [ ] Inspect final diff, preserve source originals and unknown metadata, record exact tested heads and actual receipts in `docs/superpowers/plans/2026-10-27-completion-ledger.md` (locate the existing ledger before editing if its filename differs). English commits/PR text use configured real identity. Documentation PR #49 merged as `3583cc0`; this branch includes that remote merge. Do not bypass automatic approval review.
- [ ] Push and create the coherent system media PR under existing authorization, wait for actual checks, merge the exact tested head when review is available, verify remote merge state and update the ledger. A local passing implementation is not a merged PR.
- [ ] Continue the remaining queue: controlled final dependency/app packaging, five-language README/help and historical roadmap correction, then Main/independent Editor releases built from final merged source. This plan does not mark those releases complete.
