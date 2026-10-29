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
- [x] Commit in English, push preparation PR, verify exact head and actual configured checks, then merge. Record the final merged revision before building distribution apps.

## Task 3: Neutral builds and current dependency closure

- [x] Export `git archive <merged revision>` into a fresh `/private/tmp/dynamic-wallpaper-final-*` directory. Record revision and tracked inventory outside release artifacts. No local symlinks, build caches, Git history or personal logs enter source archives.
- [x] Copy locked downloaded inputs, rebuild CEF wrapper in the neutral source root, and either rebuild controlled media or reuse only neutral-built products whose full current source/recipe/toolchain/product records verify against this exact source. Verify FFmpeg tool and all 14 runtime-library signatures/closures. Do not substitute Homebrew/runtime historical binaries. Run `python3 scripts/verify-current-media.py` to execute and retain the actual six native and six software-conversion cases for those precise products.
- [x] If regenerated public build/native acceptance records differ from tracked evidence, run their actual byte-bound native/convert checks, synchronize only those measured records/notices/manifest back to the repository, review and merge the evidence update. Re-export that new merged revision into the same neutral source directory while preserving only verified build products; record it as the final release source. Final application binaries/resources must be built after this step, with no uncommitted material drift.
- [x] `bash scripts/build-app.sh --output dist/main/Dynamic\ Wallpaper.app`; verify the standalone `.saver` is included and closed.
- [x] `python3 scripts/build-editor-app.py --output dist/editor/Dynamic\ Wallpaper\ Editor.app --zip`. Verify its independent identity/version and absence of mpv/FFmpeg.
- [x] Verify actual top-level localized Automation/audio purpose strings, offline help/resources/provenance, Mach-O closure and `codesign --verify --deep --strict` for each original app. Record ad-hoc signing and lack of Apple notarization accurately.

## Task 4: Functional and extracted-archive acceptance

- [x] Exercise actual apps through owned validation copies/data roots only; keep original release bytes untouched. Main test copy uses its existing `.validation.*` identifier and explicit validation root, CFFIXED_USER_HOME and TMPDIR. Editor uses its existing explicit data-root environment and a separate validation identity/preferences. Never replace installed apps, alter personal wallpaper or launch personal players.
- [x] Check final Main launch/settings/help, owned scene import/render/pause/close and full process/resource shutdown. Record exactly which validation-copy metadata differs from the original executable.
- [x] Exercise final Main's package-local controlled mpv with authored video/audio, verify its actual decoder/output and close. Run the packaged FFmpeg through actual conversion and decode the output. Exercise the bundled `.saver` in an owned test window, with actual advancing frames and complete stop, without installing it or changing personal wallpaper.
- [x] Exercise final Editor's real edit → undo/redo → save/reopen → loose/PKG export flows in isolated owned projects, then render both exported forms in final Main or the final independent preview. Assert known pixels/resource bytes and normal close; retain actual app/process evidence. Source-tree harness passes and static closure alone do not establish this final-package acceptance.
- [x] Create Main ZIP using `create-local-release.py` and a DMG with app plus five installation notes. Extract ZIPs and mount DMG read-only; reverify exact contents/signatures/closure, inventory and hashes, then detach.
- [x] Gate the actual extracted app payloads and authored notes for personal paths/credentials, preserving pinned third-party notices as documented upstream material. Report and fix unexpected findings; do not mask failures or invent runtime success.

## Task 5: Source, receipts and actual publication

- [x] Create exact tracked-source archives from the recorded merged revision, with complete locked dependency source/patch/notice/build recipes and no Git history/cache. Verify extracted inventory and privacy; use a fresh-source build/check path for reproducibility. Do not rely on the legacy private-mirror exporter requiring a nonexistent PUBLIC_README.md.
- [x] Attach sanitized public build/closure/signature records, licenses, release notes, five-language install directions and SHA256SUMS.txt. Keep raw local paths, screenshots/diagnostic logs and commit-author email out of artifacts.
- [x] Create distinct Main `v1.1.0` and Editor `editor-v0.1.0` releases targeting the exact merged revision. Upload only verified assets; read back asset names/sizes/digests and release state. Publish both under existing authorization and verify public tag/release records.
- [x] Update completion ledger with PRs, exact revision, actual releases/asset hashes, verification scope and residual limitations. Mark complete only after publication and all required verification actually finish.
- [x] Remove the now-unused system-media worktree after preserving required receipts/shared build assets. Recheck remaining registered worktrees and keep branch heads/user files intact.

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

Preparation PR #52 merged as `5f37c04e488e4499d96fe9689ec16ffe59b6987a`, from
reviewed/tested head `d956074548b665cc41c2788eed0ef98a63bfa8c1`. No remote CI
checks are configured. A neutral tracked-source snapshot of that merged commit
is now preparing fresh CEF/FFmpeg and actual six-format controlled-mpv acceptance.
If these produce new measured material records, they must be committed/merged
before final app packaging; no stale acceptance record will be reused for new
binary bytes. Final app/source/archive/tag identity remains an explicit gate.

Fresh neutral CEF/FFmpeg preparation completed with real exit 0. Current controlled
mpv acceptance passed all six native fixtures, and FFmpeg software decode plus
H.264/AAC conversion passed all six formats without frame loss and with actual
PCM evidence. The new reproducible `verify-current-media.py` command first was
absent (red), then its full real run passed all twelve cases and strict current
source/product/material-byte checks (green). It replaces the documented manual
procedure gap; it has no simulated success path or runtime fallback. The public
records and actual RGBA/JSON acceptance files are synchronized for review before
final application builds. Raw local logs/paths are not publication attachments.

The first actual final candidates were built from merged `90542cf`: Main's
production build, static closure/signature/purpose-localization checks and six
package-local FFmpeg conversions passed; Editor's application and ZIP extraction
checks passed. Main's actual isolated preflight then failed before GUI startup.
Foundation standardized existing `/private/tmp` directories to `/tmp` while a
new evidence file kept `/private/tmp`, so the same physical child was falsely
rejected. No GUI acceptance or release publication is claimed for these bytes.

A new real `/private/tmp` regression reproduced the failure while the original
five path tests passed. Validation paths now retain lexical input until
`realpath` establishes one physical root. Existing boundary, dot/dotdot,
per-component symlink and O_NOFOLLOW checks remain. Tests use an independent
realpath oracle instead of the same existence-dependent Foundation method;
all six path tests pass, including both `/private/tmp` and `/tmp` root spellings.
Independent review found no Critical/Important issue. The corrected source must
merge and both candidates must be rebuilt before final GUI/archive acceptance.


## Published outcome

Main [v1.1.0](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v1.1.0)
and independent Editor
[editor-v0.1.0](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/editor-v0.1.0)
are published from `c1e8c689d2f9dc4eb0a83ed5dafbd65a09592f8d`.
PR [#54](https://github.com/Seraph-x/Dynamic-Wallpapers/pull/54) merged the
physical-root correction; both final candidates were rebuilt after that merge.
The public [release index](../../releases/2026-10-30-release-index.json) records
all 28 uploaded assets, GitHub SHA256 digests, sizes and download URLs. Each
release also carries its own checksums, exact 1437-file tracked-source archive,
sanitized build receipt, bundle inventory, verification scope, license and five
installation notes. Main remains the repository's latest product release.

Actual final-package acceptance completed Main settings/all five offline guides,
owned MKV and scene imports, and real CEF rendering of both Editor exports.
Editor completed isolated text editing, Undo/Redo, save/close/reopen, loose/PKG
export, actual independent preview pixels and acknowledged pause/resume/close.
Main's desktop-linked preview and wallpaper application were not exercised;
those would change the personal desktop. A native bridge harness built from
this exact source instead used byte-identical final Main CEF/helpers and final
runtime assets in an owned window: both scene representations advanced pixels,
remained stable when paused, resumed, accepted pointer input, closed all 12 file
handles and shut CEF down. This is explicitly a package-dependency/bridge test,
not a claim of final Main desktop playback. Both actual GUI applications and all
their helper processes were absent after normal Quit.

All six actual package-local mpv fixtures and six packaged FFmpeg conversion
cases passed. The bundled saver loaded in an owned window, advanced real GIF
pixels, handled process-local power notifications, revoked output on stop and
released its lease. Its static-image negative control failed as intended. No
saver was installed. Main ZIP and Editor ZIP contents match the originals;
Main DMG was mounted read-only, its app matched exactly, five installation
notes and strict signatures/closure passed, and it was detached.

The actual extracted app privacy gates scanned 310 Main and 371 Editor files.
Six exact upstream CEF matches per app were reviewed: a generic NUL-terminated
home prefix followed by ICU symbols and known Chromium/Chromecast/Quad9 URL
paths. No detector was globally disabled. Source archives and public records
also passed their gates. Independent final review found no Critical/Important
issue and independently matched source files, manifests, Mach-O hashes, ZIP
payloads and every asset checksum.

Failed attempts remain excluded and documented in the public verification:
initial validation-path preflight, Editor sandbox exit and unisolated auto-launch,
an incorrect file-panel selection, a saver fixture missing measured duration,
sandbox bookmark denial, and the first cross-application CEF helper layout.
The successful Editor rerun first confirmed its dedicated instance/data root.
Newly created excluded test data was preserved outside the default app directory.
The contained CEF rerun kept its sandbox enabled. None of these failures was
silently treated as success or repaired through a product fallback.

The existing complete-suite inspector/cadence failures, untested live vendor
players and platform/performance limits remain explicit release limitations.
Both apps are ad-hoc signed and not notarized. The final obsolete system-media
worktree was removed without force after preserving its evidence and branch
head; only the original main checkout remains registered. Publication and
cleanup are complete; this later record does not change released source bytes.
