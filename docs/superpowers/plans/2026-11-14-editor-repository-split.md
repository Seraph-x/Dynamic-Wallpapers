# Editor Repository Split Implementation Plan

> Execute the authorized extraction in staged batches with isolated workspaces, scoped independent agents, code review, and verification before publishing.

**Goal:** Separate Editor into Seraph-x/Wallpaper-Editor and make both repositories independently buildable.

**Architecture:** Owned source snapshots for shared Core/CEF/Scene runtime; stable file/URL interoperability; independent root packages, dependency preparation, tests and release packaging. Main retains only playback and import ownership.

**Tech Stack:** SwiftPM, Swift/AppKit, Objective-C++/CEF, offline JavaScript bundles, Python build tooling, GitHub.

## Progress

- [x] Inspect dependencies and preserve base 60af80e. Main import/menu baseline: 15 tests pass.
- [x] Create isolated Main worktree refactor/extract-wallpaper-editor and stage new repository source.
- [x] Build the new root Package.swift and independent Editor-only product/CEF preparation, build/test/package scripts. Add regression checks rejecting parent/Main project dependencies and missing required assets.
- [x] Migrate web build paths and provenance to Resources/SceneRuntime; copy required fixtures and current documentation; record original source hashes and standalone build instructions.
- [x] Verify new repository Swift tests/build, locked web reproducibility, native Editor rendering and neutral-tree release packaging.
- [ ] Review complete diffs and inspect source archives for accidental caches, external-source dependencies and missing attribution. Address review findings.
- [x] Commit and create/push public Wallpaper-Editor after verification, then verify the actual published checkout.
- [x] Remove Main Editor targets/files/scripts and authoring bridge capabilities. Keep Scene playback and URL import. Correct current docs/import UI and source export coverage.
- [ ] Verify Main package/build/core/import tests, Scene rendering, packaging/source-export regression checks.
- [ ] Push Main cleanup PR, merge through required rules, synchronize local branches and report both repository results.

## Execution ownership

- New build agent: new repo root Package.swift and scripts/ build/dependency/package/test tooling only.
- Main cleanup agent: defer implementation until Wallpaper-Editor is verified/published; then Main isolated worktree cleanup, excluding this design/plan.
- Root agent: source extraction/provenance, new Editor/Web and Resources paths, tests/fixtures/docs, integration validation, review and GitHub delivery.

No implementation agent may edit the other repository or replace failures with silent fallback paths. Run targeted tests with the repository's 60-second budget; full/native build stages use their established budgets. Main and Editor GUI/native tests run serially.

Publication gate: fresh GitHub noreply history, tracked-source allowlist, fixture-aware credentials/personal-path audit, and inspected source archive. No rewrite of existing public history. User prioritizes Wallpaper-Editor completion before Main cleanup.

Before push, verify BOTH author and committer identities of every new commit use the GitHub noreply address; scan the final candidate commit and extracted Git archive, not only the working tree.

## Release execution status

- User-confirmed versions: Main 1.1.1 (build 6), Editor 0.1.1 (build 2).
- Editor v0.1.1 is published at https://github.com/Seraph-x/Wallpaper-Editor/releases/tag/v0.1.1 from commit 5f5382656f3ccf362d094a159fdb072812925ea0. All 13 uploaded asset digests match the verified local bytes.
- Editor: 312 Swift and 498 Node tests passed. All 54 browser/native harness phases passed across the initial run and targeted reruns after fixing the template-confirmation race. Final neutral release packaging and archive roundtrip passed. A fresh clone of the public repository prepared CEF and built independently.
- Editor privacy: 28 audit tests passed; complete one-commit history and extracted source archive scans passed. Source provenance covers 606 files; both author and committer use GitHub noreply identities.
- Main: source ownership cleanup and targeted tests passed. Current-toolchain CEF, MPV and FFmpeg builds passed; six native MPV and six actual conversion acceptance cases passed. Main application and screen saver release candidate construction passed.
- Main final full-suite, archive and protected-branch publication verification is recorded in the release attachment rather than inferred from this planning checkpoint.
