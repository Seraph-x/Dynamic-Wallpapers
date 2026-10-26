# System spectrum in independent Editor previews

> Extend the existing Core Audio Tap specification to Editor's playing snapshot previews, with lifecycle tests, native rendering acceptance and independent review.

**Goal:** Let users explicitly enable real system spectrum for independent Editor scene previews, while retaining silent output, script-disabled editing and independent application installation.

**Architecture:** Move the existing FFT, Core Audio driver and serial capture controller into a small shared WallpaperAudioSpectrum library, linked by Main and Editor without linking either executable into the other. One Editor application capture owner feeds the existing per-page spectrum endpoint only for ready, playing preview sessions. Native preview UI shows an application-wide default-off switch, observable capture status/error and explicit Retry. Main and Editor retain separate settings, permissions and captures in their separate processes.

**Approved policy reused:** Core Audio Tap on 14.2+, explicit unsupported status on 14.0/14.1, exclude own-process audio, no microphone/files/network, output mute independent of spectrum, no silent backend fallback/retry. Enabling without playing preview demand waits. Pausing/closing/failing the last preview or disabling capture stops and clears spectrum. Start/stop/cleanup errors remain owned/visible; shutdown waits for capture release.

## Task 1 — shared capture library

- [x] Add a missing-module test/build red before moving the three existing Sources/WallpaperApp/Audio spectrum files into Sources/WallpaperAudioSpectrum. Give only the cross-module types/initializers/methods needed by clients public access; retain analysis internals and capture resources private. AudioSpectrum gains an explicit public initializer; no signal algorithm or permission behavior changes.
- [x] Root package adds library/target and dedicated analyzer/controller tests, moving the existing complete tests with it. Add explicit imports in Main clients and the real system-audio harness. Update every build/harness script referencing moved source paths; keep actual Main capture/exclusion evidence runnable. Main behavior and persisted library setting stay unchanged.
- [x] Keep failures localizable by callers: stable library errors/diagnostics remain explicit, Editor UI supplies five-language status and raw OS details. Do not add error swallowing or runtime mocks.

## Task 2 — Editor capture ownership and native UI

- [x] Add EditorPreviewAudioController owning the shared controller and retained per-session membership, injected capture controller/defaults for test isolation. Persistent separate Editor opt-in defaults off; malformed stored values report an explicit error rather than coercing to enabled. One owner serves all preview windows; output stays muted.
- [x] Preview page exposes setSpectrum(AudioSpectrum) using existing DWWebPage.setSceneSpectrumLeft/right. A preview session subscribes only after real ready and after successful play acknowledgement; removes demand and zeros before pause/close/failure/restart. Re-add only for the current page generation, never a closing or failed page. Retain/retry failed capture cleanup; errors do not fabricate a ready/playing scene. A spectrum delivery error unsubscribes that page and remains visible.
- [x] Editor application injects its single audio owner into production preview windows and shuts it down after closing all workbenches/previews, before CEF shutdown. Startup/close cancellation never loses the owner. Existing fake pages in unit tests implement the new data-only setter; no production test capture path.
- [x] Add a native checkbox, status and explicit Retry to preview footer, with five translations and independent playback mute. Checkbox enabled only on supported OS and not during shutdown; explain permission/data handling and that this is shared across Editor previews. AppKit layouts remain usable at minimum window size in all languages/themes. Reading/opening projects never starts capture.
- [x] Add NSAudioCaptureUsageDescription to Editor's actual Info.plist plus localized InfoPlist.strings copied into the top-level application Resources; packaging verifies all five strings and metadata. No microphone usage description, screen-capture backend, driver or Main audio-setting writes.

## Task 3 — lifecycle and real rendering verification

- [x] Test default-off/no-demand start, multiple previews one capture, individual pause/resume, last pause/close stop, failed load/restart, late generation callbacks, disable during pending OS start, explicit retry, failed cleanup retention/shutdown and separate preferences. Use injected capture/page only for lifecycle unit evidence.
- [x] Keep complete existing FFT/controller tests; validate Editor data flow into real CEF spectrum endpoint and actual known audio-reactive shader/script pixels with explicit stereo bands and silence. Unit/known-band tests are not called real OS capture evidence.
- [x] Run existing actual Core Audio external tone/self-output exclusion harness with the shared source and production process behavior; if OS authorization blocks a check, report it unverified instead of approving a fake success. Do not reset privacy permissions, modify wallpaper/library or bypass dialogs. Reuse existing scene/native endpoint shape unchanged.
- [x] Add native Editor spectrum phase if needed, retain all 38 prior phases and budgets (180s build, 60s each execution). Run fresh full suite, all JS/offline checks, independent Editor and shared audio tests, targeted Core/Main consumers, packaging/localization/product/configuration/public-source tests. Build once separately before 60-second targeted suites where cold compilation exceeds the budget.

## Task 4 — docs, independent review, delivery

- [x] Review the plan and substantial final changes independently, especially subscription generation, reentrant disable/close, shared Main behavior and cleanup ownership. Fix confirmed issues with red/green tests.
- [x] Update both READMEs/API starters/preview diagnostics docs to distinguish edit canvas zero spectrum, muted snapshot preview with opt-in live spectrum, Main settings and per-app OS authorization. Do not claim a new release; published binaries remain unchanged.
- [x] Prepare delivery through changed-file public-export scanning, final-diff inspection and the real author email. Use an English PR and verify the exact remote head before merge. No release or unrelated feature is part of this PR.

## Verification record

- 70 independent Editor tests and 16 shared spectrum tests passed, including actual red/green regressions for pending playback, preference recovery, page lifetime, cleanup errors and rejected shutdown recovery. Main's 13 related audio/surface tests and 41 Editor Core tests passed.
- 397 JavaScript tests and all 84 reproducible offline resources passed. Packaging (4), harness inputs (5), product (3), configuration (42) and public-source export (16) checks passed.
- Canonical fresh native/browser acceptance passed 39/39 with no skipped phases. Build retains 180 seconds; all 38 execution phases retain 60 seconds. The explicit browser is official full Chrome 145.0.7632.6 / build 1208 matching Playwright 1.58.2, using default Metal on the test host. CEF remains pinned to 152.0.6 / Chromium 152.0.7977.83; isolated keychain is confined to the native test host.
- Environment investigation retained the unchanged baseline's Chrome 156 image/FK failures and matching headless-shell 145's disabled WebGL context. The full matching browser passed both unchanged strict checks before the full run; no assertion, production renderer or timeout was changed for these failures.
- Real Core Audio evidence uses the separate shared-capture/Main harness: two external stereo tone, own-output exclusion, disable/zero and tap/device-release cycles passed. Editor known-band CEF/GPU checks and injected lifecycle tests are separately identified and do not claim manual acceptance of Editor's own OS permission dialog.
- A neutral-source Editor candidate passed strict ad-hoc signing, Mach-O dependency closure, five top-level permission localizations and embedded personal-path verification. It was not installed, notarized or published.
- Independent final reviews approved both the shared-module migration and Editor ownership/UI/packaging/native acceptance without blocking findings. Full Main-suite coverage is not claimed.
