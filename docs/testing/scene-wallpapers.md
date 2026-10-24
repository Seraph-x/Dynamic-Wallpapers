# Scene wallpaper validation

The four dependent PRs add local JSON/PKG scene import, an offline pinned
WebWallGL/CEF renderer, retained scene pause/resume and playback controls, and
five-language import UI/help. Author property defaults are used. System audio
spectrum capture, an editor and native screen-saver scene playback are excluded.

## Reproducible checks

Prepare the repository's pinned native dependencies before building.

```sh
python3 scripts/prepare-public-build.py cef mpv ffmpeg
python3 scripts/swift_sdk.py build --disable-sandbox --build-tests
node --test scripts/test-scene-runtime.mjs
node scripts/make-scene-fixture.mjs --check
npm ci --prefix scripts/scene-runtime-build
node scripts/scene-bundle.mjs --check
node scripts/test-scene-rendering.mjs
python3 scripts/test-scene-native.py
bash scripts/build-scene-swift-test.sh
python3 scripts/test-scene-swift.py
python3 scripts/test-app-packaging.py
uv run --with-requirements scripts/help-requirements.txt python scripts/build-help.py --check
```

The browser test needs the matching Playwright Chromium, or an explicitly
selected installed executable through `SCENE_CHROMIUM_EXECUTABLE`. Set
`SCENE_DEVICE_SCALE=2` to check Retina backing resolution. These are test tools;
the shipped app needs neither Node nor a network-loaded engine.

Native and Swift integration runners retain commands, logs and exit records
under `.build/verification`. Each runtime test has a 60-second timeout; native
compilation has a separate 180-second budget. Build Swift tests separately
before using the repository runner's 60-second filtered-test budget.

## Observed results

Validated on an arm64 Apple M1 host with Swift 6.4 / macOS SDK 27, retaining the
application's existing macOS 14 deployment target. This is not validation on
every supported macOS version.

| Check | Result |
| --- | --- |
| Complete app and test-target build | Passed |
| Final focused regression set | 122 core + 70 screen-saver core + 68 app tests passed |
| New scene surface tests | 6 passed, including delayed play acknowledgement, prepare/close cancellation and failed release |
| Actual AppModel scene import | Owned copy, repeated import, provenance and failed-save rollback passed |
| Browser contracts/lifecycle | 8 passed |
| Pinned bundle/PKG fixture reproduction | Passed |
| Real browser scene pixels | Loose and PKG, animation, pause/resume, cursor movement, authored click hook and zero spectrum passed |
| Retina browser render | 1280×720, Apple M1 ANGLE Metal, both formats passed |
| Actual CEF native harness | 320×180, both formats; animation, pause stability, resume, pointer pixels, command cancellation and clean release passed |
| Actual Swift SceneSurface → CEF | Both formats; silent prepare, native gain delegation, retained page, same-instance resume, stale input rejection, pointer pixels and close/shutdown passed |
| Packaged runtime assets through Swift harness | Both formats passed |
| Packaged app default resource lookup/restoration | Both formats launched using separate validation identities/data roots; desktop viewport 2880×1800 at DPR 2; normal quit closed all opened files and CEF |
| Distribution/package checks | 42 tests passed; six component records and 25 notice/provenance files verified |
| Offline help | 14 tests passed; five generated locales and links verified |

The authored scenes contain no PCM soundtrack. Gain tests call the real native
API and inspect delegated gain values; they do not claim captured audible-output
validation. 4K, multi-display performance and power consumption are unmeasured.
The native application logs include existing Chromium background SSL and macOS
helper sandbox-extension diagnostics; scene resource loads and shutdown completed.

## Wider GUI test results

A broader selected run had three failing cases:

- `InterfacePresentationTests/testChangingLanguageUpdatesTheOpenSettingsWindow`:
  SwiftUI `InvalidTransition ... failed(deinit)` in the combined run. Separate
  reruns passed on both the feature branch and unchanged main.
- `ManagedMediaPresentationTests/testManagedTranscodeSuggestsTheOriginalFolderAndRecognizesImportedOutput`:
  the same teardown failure reproduced on unchanged main.
- `SettingsWindowInteractionTests/testSettingsSceneNavigationKeepsFocusAndSharesBackgroundAppearance`:
  window hit-testing/appearance failures reproduced on unchanged main.

These tests were not edited or disabled. The passing 260-test focused set does
not represent a completely passing GUI suite. Picker/NSOpenPanel interaction is
source-reviewed rather than automated; real import and renderer services are
covered separately.

## Packaged candidate isolation

Use `scripts/verify-isolated-candidate.py prepare` and `preflight` for a signed
validation copy. Choose a real worktree-local `.build/verification` parent and
a fresh data root for each launch: startup evidence is intentionally exclusive.
A `/private/tmp` preflight encountered the existing Foundation path-normalization
rejection on this host; worktree-local roots passed without relaxing checks.
Production libraries, preferences and the installed app were not test targets.

`python3 scripts/test-scene-swift.py --runtime-root <packaged-SceneRuntime-directory>`
checks the runtime assets from a packaged candidate. The bundle/signature
verifier separately checks native dependencies, localizations and retained
notices. Existing mpv/FFmpeg redistribution-completeness limits remain recorded
in `Resources/ThirdParty/distribution-status.json`.
