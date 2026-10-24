# System Audio Spectrum Implementation Plan

> **For agentic workers:** Use executing-plans to implement this approved plan
> inline, task by task. Use test-driven-development for behavior changes and
> verification-before-completion before reporting completion.

**Goal:** Give playing scene wallpapers a real, optional stereo system spectrum.

**Architecture:** One Core Audio Tap owner serves all playing scenes. A serial
FFT analyzer publishes replaceable snapshots over the existing isolated CEF
resource boundary, independently of audio output controls.

**Tech Stack:** Swift, Core Audio (14.2+), Accelerate/vDSP, Objective-C++, CEF,
JavaScript modules, XCTest/node:test. Application deployment target stays 14.0.

## File responsibilities

- `Sources/WallpaperApp/Audio/AudioSpectrumAnalyzer.swift`: PCM/FFT analysis.
- `Sources/WallpaperApp/Audio/CoreAudioSpectrumCapture.swift`: real tap resources.
- `Sources/WallpaperApp/Audio/SystemAudioSpectrumController.swift`: observable
  intent/subscription lifecycle, periodic publication, failures and explicit retry.
- `Sources/WallpaperCore/Models.swift`: optional compatible setting.
- `Sources/WallpaperApp/Media/CEFApplicationRuntime.swift` and
  `CEFScenePageSession.swift`: own controller, subscribe playing page IDs.
- `Sources/WebWallpaperBridge/{SceneProtocol.hpp,SceneProtocol.mm,WebPage.mm,
  LocalWebRequestContext.cpp,include/WebWallpaperBridge.h}`: replaceable per-page
  snapshot and trusted local route, public typed setter.
- `Sources/WallpaperApp/Resources/SceneRuntime/{scene-runtime.mjs,
  scene-shell.mjs,scene-spectrum.mjs}`: validated AudioSource and bounded polling.
- `Sources/WallpaperApp/{AppModel.swift,UI/SettingsView.swift,
  UI/SystemAudioSpectrumSettingsSection.swift}`: persistence and status/retry UI.
- `scripts/product_configuration.py` and resource localizations/help: permission
  description, five-language copy, capability/compatibility explanation.
- Focused tests alongside existing Swift/scene suites plus a real-audio harness.

## Task 1: Baseline and FFT

- [x] Run `node --test scripts/test-scene-runtime.mjs` on clean worktree; all 8 pass.
- [x] Write `Tests/WallpaperAppTests/AudioSpectrumAnalyzerTests.swift` first:
  48 kHz 1000 Hz left / 4000 Hz right sine peaks in the corresponding log bands;
  0.5-amplitude response is half 1.0 response, silence is zero, split packets
  equal contiguous input, invalid format/NaN rejects without publishing data.
- [x] Build test targets and run the focused test; verify missing analyzer fails.
- [x] Implement 2048-point Hann-windowed stereo FFT using vDSP, fixed latest
  arrays, partial-packet buffering and 64 logarithmic bands from 20 Hz to Nyquist
  (bounded at 20 kHz). Map bins by their actual center frequency; normalize with
  Hann coherent gain and clamp full-scale spectral amplitudes to 0...1.
- [x] Re-run the focused tests and inspect the diff.

## Task 2: Native capture and lifecycle

- [x] Add controller tests using an injected capture driver (external OS boundary):
  default disabled; one start for multiple subscribers; stop only after last;
  disable/pause during pending start cannot publish; start/poll/stop failures
  remain visible; retry is explicit; shutdown drains and releases once.
- [x] Verify red, implement controller and pass the tests.
- [x] Implement real Core Audio driver: translate host PID to audio object;
  private nonmuting global stereo tap excluding host; read tap ASBD; create
  private tap-only aggregate; install serial IO block and start. No output-device
  assignment. Validate float PCM layout and copy/use only within callback scope.
- [x] Add default-output/tap-format/alive property observation; report a device
  change, malformed sample or OSStatus through the shared state. Start rollback
  and stop release IO proc, aggregate and tap in dependency order, retain IDs on
  failure and aggregate cleanup errors. Controller retains failed cleanup driver.
- [x] Build for `arm64-apple-macosx14.0`, guard 14.2 APIs at availability boundary.

## Task 3: Scene transport

- [x] Extend native protocol tests with trusted spectrum GET, denied subframe,
  unsupported method, retired session, 64 finite bounded values and replacement.
- [x] Extend JS node tests with spectrum shape/range validation, update/reset,
  bounded polling, cancellation and visible failures; verify red first.
- [x] Implement mutex-protected current snapshot and typed native setter. Add
  fixed local endpoint guarded by the same trusted-main-frame rule as events.
- [x] Implement JS pull source and one-in-flight 30 Hz poller. Capture disabled
  uses explicit zero snapshot; no engine synthetic input. Polling destroy aborts.
- [x] Wire CEF runtime controller broadcasting and page play/pause/close demand.
- [x] Run node tests and native protocol harness, update standalone Swift harness
  source lists to include the new audio files/frameworks where required.

## Task 4: Setting, UI and documentation

- [x] Add tests: missing setting defaults off, valid true round trips, present
  wrong type/null fails; setting restoration never enables capture after load
  failure. Verify red and add `systemAudioSpectrumEnabled` to AppSettings.
- [x] Wire AppModel restoration/mutation into controller and a General > Sound
  section that observes controller, shows unsupported/disabled/waiting/capturing/
  error status, the persistent toggle and explicit retry. Disable on 14.0/14.1.
- [x] Add main-bundle-only NSAudioCaptureUsageDescription with localized usage
  strings; add five-language UI/help copy and README feature/14.2 restriction.
  Do not change release version or 1.0.0 installation/release artifacts.
- [x] Run packaging/product configuration/help/localization tests.

## Task 5: Real validation and completion

- [x] Build application and XCTest targets using `python3 scripts/swift_sdk.py
  build --build-tests --disable-sandbox`, then run focused Swift tests using the
  repository runner's 60 s budget (no rebuild in the budget).
- [x] Run real Core Audio harness with independently generated stereo tones and
  own-process exclusion, repeat start/stop, compare tap/device inventory before
  and after. Record exact authorization/device failures, never fake success.
- [x] Feed real captured frequency data to an authored audio-responsive fixture
  in actual CEF; verify pixels change with external tone and stop on pause/off.
- [x] Run scene protocol/JS/Swift regressions and relevant pure core tests.
- [x] Use requesting-code-review for independent final review, fix concrete
  findings with regression tests, run affected checks again.
- [x] Inspect `git diff --check` and final diff; commit with configured real
  identity. Create an English PR if completing the existing PR delivery workflow;
  do not merge without fresh merge authorization for this feature.

Delivered as PR #7: https://github.com/Seraph-x/Dynamic-Wallpapers/pull/7
