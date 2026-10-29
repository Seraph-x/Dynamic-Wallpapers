# Final Main and independent Editor release plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to execute this approved release scope task-by-task. Use checkbox tracking. Publication is already authorized; no new interview is needed.

**Goal:** Publish Main 1.1.0/build 5 and independently versioned Editor 0.1.0/build 1 from final merged source, with verified binaries, exact source and truthful notices/checksums.

**Architecture:** Keep the two applications independent. Prepare version/docs in the existing main checkout, review and merge that preparation PR, then export the exact merged tracked snapshot to a neutral build directory. Rebuild CEF wrapper there and verify current controlled media inputs/products before use. Retain original candidate/archive bytes; isolate functional smoke through owned validation copies and data roots.

**Tech stack:** Swift/AppKit, CEF/Metal, controlled source-built mpv/FFmpeg, Python release tooling, codesign, ditto, hdiutil and GitHub CLI.

**Approved design:** `docs/superpowers/specs/2026-10-27-complete-remaining-work-design.md`. Main and Editor publishing and merging are already authorized. Historical worktrees were cleaned as requested; do not create additional worktrees. Build exports are ordinary directories without Git registrations.

## Task 1: Release metadata and five-language installation/help

- [x] Set `scripts/product-configuration.json` to 1.1.0/build 5; keep Editor's independent `Editor/product.json` at its first release 0.1.0/build 1.
- [x] Update README, `docs/help/{zh-Hans,en,ja,fr,es}.md`, `docs/help/README.md` and generated `Sources/WallpaperApp/Help/*/index.html` to the configured version. Describe implemented features as current behavior without claiming publication before it occurs; release links identify the candidate tags.
- [x] Create `docs/releases/1.1.0/RELEASE_NOTES.md`, five `INSTALL-*.md`, and Editor release notes/install directions. Preserve upgrade/downgrade and removal/data consequences. Main and Editor remain separate downloads; audio response requires 14.2 while base support is 14.0 arm64.
- [x] Correct `BUILDING.md` controlled closure/tool/source instructions. Current source/notice inventory is complete; never call historical IINA binaries current products. Record live vendor playback, full-suite inspector/cadence and OS/performance limits truthfully.
- [x] Run deterministic help generation/check, `test-help.py`, `test-product-configuration.py`, `test-editor-product.py`, `test-app-packaging.py` and targeted release-tool tests. Inspect all diffs and the changed-file privacy gate.

## Task 2: Review and merge preparation

- [x] Read-only independent review of metadata, translations, installation and release truthfulness; resolve material issues.
- [ ] Commit in English, push preparation PR, verify exact head and actual configured checks, then merge. Record the final merged revision before building distribution apps.

## Task 3: Neutral builds and current dependency closure

- [ ] Export `git archive <merged revision>` into a fresh `/private/tmp/dynamic-wallpaper-final-*` directory. Record revision and tracked inventory outside release artifacts. No local symlinks, build caches, Git history or personal logs enter source archives.
- [ ] Copy locked downloaded inputs, rebuild CEF wrapper in the neutral source root, and either rebuild controlled media or reuse only neutral-built products whose full current source/recipe/toolchain/product records verify against this exact source. Verify FFmpeg tool and all 14 runtime-library signatures/closures. Do not substitute Homebrew/runtime historical binaries.
- [ ] `bash scripts/build-app.sh --output dist/main/Dynamic\ Wallpaper.app`; verify the standalone `.saver` is included and closed.
- [ ] `python3 scripts/build-editor-app.py --output dist/editor/Dynamic\ Wallpaper\ Editor.app --zip`. Verify its independent identity/version and absence of mpv/FFmpeg.
- [ ] Verify actual top-level localized Automation/audio purpose strings, offline help/resources/provenance, Mach-O closure and `codesign --verify --deep --strict` for each original app. Record ad-hoc signing and lack of Apple notarization accurately.

## Task 4: Functional and extracted-archive acceptance

- [ ] Exercise actual apps through owned validation copies/data roots only; keep original release bytes untouched. Main test copy uses its existing `.validation.*` identifier and explicit validation root, CFFIXED_USER_HOME and TMPDIR. Editor uses its existing explicit data-root environment and a separate validation identity/preferences. Never replace installed apps, alter personal wallpaper or launch personal players.
- [ ] Check final Main launch/settings/help, owned scene import/render/pause/close and full process/resource shutdown. Record exactly which validation-copy metadata differs from the original executable.
- [ ] Exercise final Main's package-local controlled mpv with authored video/audio, verify its actual decoder/output and close. Run the packaged FFmpeg through actual conversion and decode the output. Exercise the bundled `.saver` in an owned test window, with actual advancing frames and complete stop, without installing it or changing personal wallpaper.
- [ ] Exercise final Editor's real edit → undo/redo → save/reopen → loose/PKG export flows in isolated owned projects, then render both exported forms in final Main or the final independent preview. Assert known pixels/resource bytes and normal close; retain actual app/process evidence. Source-tree harness passes and static closure alone do not establish this final-package acceptance.
- [ ] Create Main ZIP using `create-local-release.py` and a DMG with app plus five installation notes. Extract ZIPs and mount DMG read-only; reverify exact contents/signatures/closure, inventory and hashes, then detach.
- [ ] Gate the actual extracted app payloads and authored notes for personal paths/credentials, preserving pinned third-party notices as documented upstream material. Report and fix unexpected findings; do not mask failures or invent runtime success.

## Task 5: Source, receipts and actual publication

- [ ] Create exact tracked-source archives from the recorded merged revision, with complete locked dependency source/patch/notice/build recipes and no Git history/cache. Verify extracted inventory and privacy; use a fresh-source build/check path for reproducibility. Do not rely on the legacy private-mirror exporter requiring a nonexistent PUBLIC_README.md.
- [ ] Attach sanitized public build/closure/signature records, licenses, release notes, five-language install directions and SHA256SUMS.txt. Keep raw local paths, screenshots/diagnostic logs and commit-author email out of artifacts.
- [ ] Create distinct Main `v1.1.0` and Editor `editor-v0.1.0` releases targeting the exact merged revision. Upload only verified assets; read back asset names/sizes/digests and release state. Publish both under existing authorization and verify public tag/release records.
- [ ] Update completion ledger with PRs, exact revision, actual releases/asset hashes, verification scope and residual limitations. Mark complete only after publication and all required verification actually finish.
- [ ] Remove the now-unused system-media worktree after preserving required receipts/shared build assets. Recheck remaining registered worktrees and keep branch heads/user files intact.

Preparation evidence: product configuration 42, five-language help 14, Editor
product 3 and local archive-tool 5 checks passed. The metadata bump first exposed
two old 1.0.0/build4 repository assertions and a help negative-control mutation
that no longer changed its input. The repository assertions now require 1.1.0/5;
fixed 1.0.0 parser fixtures remain intact, and the help negative control derives
the current header then deliberately corrupts it. Red and green logs are retained
locally. This preparation does not claim final candidates or publication exist.

Independent preparation review found one packaging blocker: the retained
ThirdParty README still carried 1.0.0/build4, and its real packaging label gate
rejects the new metadata. A new current-tree cross-check first reproduced that
failure. The notice label and its manifest SHA256/size are now current; all 43
packaging tests pass. The final-package functional matrix was expanded to cover
actual package-local mpv/audio, FFmpeg conversion, saver windows and Editor
edit/undo/save/reopen/export playback. No final runtime claim is made from these
preparation checks. The main checkout's historical FFmpeg cache has an obsolete
record schema, so it will not be reused; the final neutral build must produce
current FFmpeg tools and evidence from the locked sources.
