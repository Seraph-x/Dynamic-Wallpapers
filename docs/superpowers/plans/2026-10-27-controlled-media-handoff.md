# Controlled media first-group handoff

Branch: `build/source-complete-media`; base/HEAD: `5826046`. Changes are uncommitted. No push, merge, release or user-app installation was performed by this worker.

The actual source-built closure has 14 shared dylibs and statically linked Lua. All 16 original source archives (67,275,423 bytes), original notices, exact mpv branch patch and recipes are retained. The old 69-library metadata/headers are historical only; no old cached dylibs are checked in or used by the public prepare path.

## Review entry points

- `scripts/mpv-source-lock.json`, `scripts/mpv-source-recipes.json`: complete pinned inputs and explicit features.
- `scripts/mpv_source_inputs.py`, `mpv_source_build.py`, `mpv_build_record.py`: extraction, isolated build, source/recipe/tool/architecture/minimum-OS/closed-dylib verification.
- `scripts/media_dependencies.py`, `prepare-public-build.py`, `media_bundle.py`, `media_release.py`, `verify-app-bundle.py`, `Package.swift`: active source-built products, no historical runtime fallback.
- `scripts/media_build_materials.py`, `media_acceptance_materials.py`: measured configuration/license evidence and byte-bound native acceptance.
- `Resources/ThirdParty/MPV/BUILD-RECORD.json`, `CODEC-AUDIT.json`, `CODEC-PARITY.json`, `acceptance/acceptance.json`: actual retained evidence.

The exact tracked/untracked change list is recorded in `.build/media-source-complete/handoff-first-group-files.json`.

## Actual outputs

Prepared runtime: `.build/media-source-complete/mpv`.

Successful build logs: `.build/media-source-complete/build-e4hkr5f8/logs`.

Build-record SHA256: `4f100661c6eb505478b0631c1a4efbb2a78e079ca728189d0455e3e5de02e3fd`.

Prepared libmpv SHA256: `2b05719f17f4f3421bcee71f31db62f15d3a4178b492a6a4f98d22cb60742ac7`.

All 14 actual images passed arm64/macOS14/SDK27, strict ad-hoc signature and closed dependency checks. Prepared dylibs have no LC_RPATH entries; the native runner's executable explicitly targets the controlled runtime, and its environment contained no DYLD overrides.

The actual old API enumerated 514 decoder implementations; the controlled API enumerated 512. All reachable canonical decoder IDs are preserved. The absent alternate libspeex wrapper has the existing native speex implementation; JPEG XL has no mapping in the pinned Matroska/AVI/QuickTime-in-Matroska tables and is outside the advertised bridge contract. zlib/bzlib/liblzma and dav1d were explicitly restored after real parity checks exposed omissions.

## Native acceptance

`test-controlled-mpv.py` compiles the real `MPVBridge.mm`, then runs each phase with a separate 60-second budget and owned process-group cleanup. The full six-case summary is retained under `MPV/acceptance/`; original local evidence is `.build/media-source-complete/acceptance/native-h90xliud/acceptance.json`.

- H264/AAC MKV: 27 actual frames; VideoToolbox-copy.
- VP9/Opus WebM: 25 actual frames; VideoToolbox-copy.
- MPEG4/MP3 AVI: 27 actual software frames.
- AV1/Opus MKV and WebM: 27 actual frames each; explicitly dav1d software, no hardware decoder.
- ZMBV/MP3 AVI: 26 actual software frames, exercising zlib-dependent decoding.

Each phase verified multiple distinct real RGBA frames, loop wrap, active CoreAudio output/decoded-audio clock, mute/volume/pause/HW-option readbacks, native handle/renderer destruction and zero callbacks after close completion. Speaker acoustic output was intentionally not measured; the player remained silent. Real first/last RGBA files and exact generated fixture bytes are retained. No installed application, wallpaper assignment or media library was changed. The native/GUI slot was released after all six phases.

## Verification

The independent-review targeted run passed 158 tests: dependency25, source-build14, source-integration4, build-material11, FFmpeg-record8, public-prepare7, packaging42, product-configuration42 and local-release5. Each suite used an explicit 60-second timeout. `git diff --check` is clean. The separate full package-isolation suite passed 4 tests in 80.166 seconds; an earlier attempt to wrap that native integration suite in the backend 60-second default timed out and is not reported as a pass.

The worker did not build a complete CEF application/ZIP candidate. Root owns independent review, integration, full application packaging and release. CEF and old shared dependency caches were not modified.

## Independent review correction

Review found that packaging verified current dylibs and build records but did not revalidate retained native acceptance against the current product bridge. `scripts/media_build_materials.py` now checks every distributed recipe copy against the verified build inputs and, when the mpv material record claims `complete=true`, verifies the six retained native phases and their current source/product/artifact bindings before packaging. Explicitly incomplete materials retain the existing local-candidate behavior.

Six regression tests were added in `scripts/test-media-build-materials.py`. Before the fix, the tests exposed six missing rejection cases: bridge/harness/runner source drift, a changed recipe copy, acceptance for different products, and absent acceptance despite `complete=true`. After the fix all eleven build-material tests passed; the positive tests use copies of the real retained native records and fixtures, while machine-dependent build verification is isolated separately.

The actual corrected packaging-material verifier also passed against all 14 prepared dylibs, current source fingerprints, original archive notices, ten recipe copies, six native phases and 119 retained material hashes. The FFmpeg9 check explicitly used the existing root-workspace cache through `ffmpeg_root`; this worktree has no local FFmpeg cache. Actual tool/configuration/license evidence matched the retained record. No cache symlinks, rebuilt binaries or GUI runs were introduced.

The two modified scripts are outside the frozen `INPUT_FILES` list. The build-record SHA256 remains `4f100661c6eb505478b0631c1a4efbb2a78e079ca728189d0455e3e5de02e3fd`; no fingerprint was rebound. The conservative `native acceptance pending` label in `scripts/media-dependencies.json` remains unchanged because that lock is a fingerprinted build input. The separately verified native records and distribution status contain the measured current acceptance state.

## Integration notes

Preserve root's live WebWallGL engine/provenance/README fields and regenerate distribution file hashes after merging the component data. This worktree predates the live-renderer and media-foundation merges.

The mpv build identity includes the shared dependency/Mach-O/SDK/publication helpers. A later change to those helpers must not be manually rebound to these binaries; use a fresh verified source build if their fingerprint changes.

## Authorized second group

The existing separate FFmpeg9 tools have an actual software AV1 decoding/transcoding regression: exit 69 with the real AV1 fixture. The failure evidence is `.build/media-source-complete/ffmpeg9-av1-baseline-failure.json`. Their current LGPL/source/license record is accurate but does not claim functional AV1 success. Root has authorized an independent static dav1d/liblzma plus system zlib/bzlib FFmpeg9 rebuild and real AV1 transcoding regression after the first group is merged, in a new worktree. That fix is not mixed into this checkpoint, and the old shared tools remain unchanged.

## Root integration verification

Main GC, live-text and public-media foundation changes were integrated without
changing controlled source-build inputs. The actual 14-library record still
verifies against frozen source/recipe/helper fingerprints. Main's release build
completed successfully against that exact closure and immutable CEF inputs.
This does not claim a packaged CEF application or ZIP has been verified; full
packaging and archive acceptance remain part of the final release work.

After integrating Main `5826046`, the nine targeted suites were rerun: all 158
checks passed, each suite retaining its 60-second execution limit. The full
release executable build passed in 105.33 seconds. The strict publication scan
covered 76 first-party/evidence files; 56 original upstream source, notice and
historical files were excluded from personal-contact scanning and independently
hash-verified. Original upstream patch author emails are explicitly retained;
the normalization detector's own test fixtures are classified as fixtures.
No private workspace path or contact finding remains unexpected.
