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
- [ ] External resource scripts — scan/edit/check/revert, atomic resource
  history, native capture, diagnostics and true loose/PKG playback.
- [x] Safe resource collection — cross-process session leases, saved roots,
  capture/undo safety, exact orphan reclamation and visible failures.
- [ ] Main per-wallpaper properties — persistent typed overrides, UI/reset,
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

- Current Main: `ba8a94f`, merged resource collection PR [#38](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/38). Its feature head `9887cd4` passed 52 Core tests, 22 focused native fixtures and the complete 93-test Editor Swift suite; all 19 changed files passed the publication scan.
- Live text/font PR [#39](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/39) merged at `9472eda` from tested head `be7b0fa`. Actual Chromium public/paused rendering, grow/shrink/fractional sizes, fixed-box anchors, script precedence, frame ownership and destruction regressions pass. All 415 Node tests and the complete 47-phase browser/native CEF acceptance passed, with 21 normal runtime shutdowns; 23 changed files passed the publication scan.
- The user confirmed Music/Spotify public Automation providers, default disabled, explicit opt-in authorization and unsupported other players. The independently testable native foundation is in progress.
- Distribution research recovered mpv `c0dd2b32d52c66b9efa85a7ee69965569503f6b8`
  and the 18 commits after v0.38.0; the complete old 69-library closure remains
  unproven, so no completion claim is made.
