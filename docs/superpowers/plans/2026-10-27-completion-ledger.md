# Remaining-work completion ledger

> Use `executing-plans`, isolated worktrees, TDD, independent review and
> `verification-before-completion`. The user requested the complete series.

**Goal:** Complete every item recorded in the companion completion design and
publish verified Main and standalone Editor releases.

**Architecture:** Preserve the existing native ownership, immutable Editor
transactions, generation-bound CEF transport and pinned offline engine. Add
capabilities through those boundaries, with source/build provenance.

**Tech stack:** Swift/AppKit/SwiftUI, CEF/Objective-C++, offline ES modules,
reproducible Python/Node build tooling and source-built media dependencies.

## Work packages

- [x] Live text/font user bindings — actual playing/paused renderer, tracked
  pin patch and reproducible Main/Editor assets.
- [x] External resource scripts — scan/edit/check/revert, atomic resource
  history, native capture, diagnostics and true loose/PKG playback.
- [x] Safe resource collection — cross-process session leases, saved roots,
  capture/undo safety, exact orphan reclamation and visible failures.
- [x] Main per-wallpaper properties — persistent typed overrides, UI/reset,
  restored initial state, live commands and lifetime tests.
- [ ] Real system media — provider scope choice, permissions/native source,
  metadata/transport, explicit unavailable states and end-to-end tests.
- [ ] Dependency source/build/distribution closure — provable source/patch
  archives, complete notices, actual rebuild/verification and packaging gates.
- [ ] Historical documentation and current README/help — remove stale roadmap
  claims; describe implemented capabilities and real limits in five languages.
- [ ] Final releases — Main and independent Editor assets, source archives,
  checksums, signature/closure/extracted-archive verification, privacy gate and
  published GitHub Release records.

## Per-PR execution

1. Inspect current interfaces and record a precise feature plan/spec.
2. Add meaningful failing tests, run red, implement the smallest complete unit.
3. Run targeted tests, real native/browser acceptance and required regressions.
4. Review independently, resolve findings with tests, and inspect the full diff.
5. Run the changed-source privacy gate; commit with the configured real identity.
6. Open an English PR, verify exact tested head and remote checks, merge, and
   record its link/evidence here before starting dependent work.

## Current progress

- Resource collection PR [#38](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/38) merged at `ba8a94f`. Its feature head `9887cd4` passed 52 Core tests, 22 focused native fixtures and the complete 93-test Editor Swift suite; all 19 changed files passed the publication scan.
- Live text/font PR [#39](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/39) merged at `9472eda` from tested head `be7b0fa`. Actual Chromium public/paused rendering, grow/shrink/fractional sizes, fixed-box anchors, script precedence, frame ownership and destruction regressions pass. All 415 Node tests and the complete 47-phase browser/native CEF acceptance passed, with 21 normal runtime shutdowns; 23 changed files passed the publication scan.
- The user confirmed Music/Spotify public Automation providers, default disabled,
  explicit opt-in authorization and unsupported other players. Native foundation
  PR [#40](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/40) merged at
  `7d706d9`: 20 native and 130 Core tests plus owned actual Apple Events passed.
  Production settings/CEF delivery remain open; owned fixtures do not establish
  live vendor-app playback acceptance.
- External resource script data foundation PR
  [#41](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/41) merged at `5826046`.
  All 465 Node tests passed, including 39 new lossless resource/transaction tests.
  Actual renderer sinks, workspace UI and native export acceptance remain open.
- Per-wallpaper property data foundation PR
  [#42](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/42) merged at `c8b53ee`.
  All 143 Core tests and eight raw-JavaScript catalog parity cases passed.
  Main controls, persistence integration and live session delivery remain open.
- Controlled source-built media PR
  [#43](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/43) merged at `c704625`
  from tested head `80b6021`. The 14-library arm64 closure, complete locked
  sources/patches/notices, 158 targeted tooling tests, four full packaging
  isolation tests and six actual native MPVBridge cases passed. Main release
  compilation passed. Final packaged app/release acceptance is still open.
  The old IINA binary closure is historical, not a fallback. FFmpeg 9 software
  AV1 transcode failure remains a separately tracked fix.

- Native actual artwork PR [#44](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/44)
  merged at `9abb3fd` from tested head `e1d08e1`. Two complete runs passed all
  35 native and 143 current Core tests with no skips, plus owned actual Apple
  Events/TLS/pixel/transport/shutdown acceptance for both dictionary adapters.
  Queued cancellation and isolated Core fixture-path review findings are fixed.
  Production media settings and renderer delivery remain open.

- Software AV1/conversion and neutral-path media build PR
  [#45](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/45) merged at `ba838b0`
  from tested head `fcd5cf8`. All 121 tooling tests, four complete package-isolation
  tests, two six-format actual decode/conversion runs and six actual MPVBridge
  phases passed. All 512 decoder registrations are unchanged. The 39 changed
  files and all 16 measured media binaries passed publication scans; neither
  executable nor any dylib contains a personal home path. Final app release
  packaging remains a separate completion item.

- Main persistent per-wallpaper controls PR
  [#46](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/46) merged at
  `1f8fa35`. Typed overrides persist independently per wallpaper, restore before
  initial playback, support live update/reset and retain explicit validation and
  lifecycle errors.

- External resource runtime/diagnostics PR
  [#47](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/47) merged at
  `6349c0a`, implementation head `d9222a3`: all eight actual renderer/simulation sinks, disabled execution,
  source exceptions and restart/close timer disposal passed in real Chrome.
  All 451 Editor Web tests, complete Editor browser/native CEF acceptance,
  Main scene native acceptance, strict protocol tests and eight focused Swift
  tests passed. Both reproducible build checks and three identical renderer
  copies passed; all 33 changed files passed the publication scan. Resource
  workspace authoring and complete native resource edit/export acceptance remain
  open until the final approved stage.

- Complete resource Script workspace PR
  [#48](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/48) merged at
  `721e940` from tested implementation head `4fbdc7b`. Material/particle and
  package-derived source editing, complete shared-consumer disclosure, exact
  immutable edits/history and current/captured navigation are implemented.
  All 489 Node checks and 98 Editor Swift tests passed. Every one of the 54
  defined Editor browser/native phases has supervised exit-zero evidence,
  including recorded continuations after asynchronous fixture/input fixes;
  failed earlier invocations remain recorded as failures. Actual native material,
  child override and emitter edits passed save/reopen, preview and Main loose/PKG
  playback, full resource/metadata byte checks, long fragmented source diagnostics
  and lifetime release. Five damaged-output negative controls, Main scene native
  acceptance, both reproducible builds and identical renderer copies passed.
  Independent review had no remaining Important issues; all 69 changed/new files
  passed the publication scan. The external-resource scripting package is closed.

- Completion record PR
  [#49](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/49) merged at
  `3583cc0`. The following system-media worktree includes that merge.
- System-media runtime plan Tasks 1–3 are implemented locally: immutable native
  projection, explicit renderer source and generation/revision-bound CEF data,
  transport and independent artwork failures. The 40 media tests, 23 targeted
  renderer checks, 464 Editor Node checks and actual Main/Editor loose/PKG
  browser fixtures pass. Fresh native run `2f6128aa-d10f-4d12-979d-5fbc8edd6696`
  passed build, protocol, real pixels/control/boundary tests and full shutdown;
  the test host explicitly uses isolated credentials, not production Keychain.
  Independent review of this batch has no remaining Important issues. Shared
  Main playback ownership, consent/settings, full integration review and the
  system-media PR remain open; this is not a completed or merged media feature.
- System-media Task 4 now connects actual playing Main scenes to one shared
  controller, including persisted selection, forced-off library-load failure,
  empty preparation, acknowledged pause clears and close/shutdown draining.
  Independent review's real native-worker cancellation finding was reproduced
  with seven handshake regressions and fixed through the complete Task/GCD
  chain. All 66 targeted Main/media/Core checks and 199 isolated media/Core/owner
  tests pass after successful full/incremental builds. Actual owned Apple
  Events/TLS and Main/Metal CEF loose/PKG runs for both dictionaries passed,
  including preparing a new empty page while another has live data; latest run
  `5acf3d94-15ec-44e8-8b9b-7e2c127b5a01` has all four acceptance records and both
  real runtime shutdowns. No Critical/Important review findings remain. Main
  settings/consent and the system-media PR are still open.
- The current controlled media closure was rebuilt from locked tracked sources
  in a neutral directory, then retained in the shared build cache. Current input
  fingerprints, SDK/tool environment, all 14 libraries and signatures verify.
  Final app/extracted-archive and distribution acceptance remain open; historical
  media products are not substituted for the current verified build.
- System-media Task 5 implements localized Main consent/settings and actual
  failure/retry presentation. Seven targeted UI/localization checks and owned
  settings Automation run `74cd7439-90c3-4558-8085-58f91122e3e5` pass for both
  dictionary adapters with actual Apple Events and artwork pixels. Product,
  permission-copy and package-isolation checks pass. Neither vendor application
  is running; live Music/Spotify playback remains unverified. Broad regression
  first lacked authored MPV fixtures; documented generation restored the inputs
  and 20 affected media/TLS tests pass. Actual audio and ScreenSaver reruns pass;
  inspector UI and capture-cadence assertions remain failed, not waived or
  represented as a successful full suite. Final review/PR and releases stay open.
