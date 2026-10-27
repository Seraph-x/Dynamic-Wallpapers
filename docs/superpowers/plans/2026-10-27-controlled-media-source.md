# Controlled Media Source Implementation Plan

> **For agentic workers:** Execute task by task inline in the assigned isolated worktree; root reviews the design and integration. No commits, pushes, merges, publication or native GUI playback in this worker.

**Goal:** Replace the unproven IINA binary closure with real source-built media dependencies and distribute corresponding source, notices and measured build records.

**Architecture:** Keep the existing prepare/package entry points, distinguish pinned source inputs from checked built products, and bind both with a verified build record. Build shared dependencies under `.build/media-source-complete` and preserve the actual software-render/CoreAudio/VideoToolbox bridge contract. Retain old 69-library provenance only as explicitly historical evidence.

**Tech Stack:** Python standard library, Meson/Ninja, CMake, Apple clang/SDK27, make, mpv0.38+18, FFmpeg7.0.1 and existing separate FFmpeg9.0.1 tools.

---

## Task 1: Acquire and lock source inputs

Files: create `scripts/mpv-source-lock.json`, `Resources/ThirdParty/MPV/sources/`, `Resources/ThirdParty/MPV/notices/`, `Resources/ThirdParty/MPV/patches/`; preserve historical binary files under `MPV/historical/`.

- [x] Obtain root approval of linked design before production edits or building.
- [x] Resolve immutable revisions, download actual archives into isolated cache, hash bytes and collect original notices. Record selected build tool versions and all used generation inputs. Do not execute package builds yet.
- [x] Add source-lock/schema/archive tests to `scripts/test-mpv-source-build.py`, run with a 60-second timeout and observe missing implementation failure.
- [x] Implement lock validation and safe extraction in `scripts/mpv_source_inputs.py`; verify positive and tampering tests.

## Task 2: Build actual controlled shared closure

Files: create `scripts/build-mpv-source.py`, `scripts/mpv_source_build.py`, `scripts/mpv_build_record.py`; update source-lock recipes if an upstream build fails, explicitly recording any local patches.

- [x] Write failing record tests for source/recipe/output mutation, architecture, minimum OS, closed runtime graph and tool identity.
- [x] Implement sequential dependency recipes with fully isolated prefix/pkg-config and logged configure/build/install commands; use unique staging directories and exclusive publication.
- [x] Build sources with the selected SDK and target arm64/macOS14. Capture every failure and fix the identified root cause; never substitute installed/binary dependencies.
- [x] Inspect all actual dylibs and exported ABI, capture source/recipe/config/output records and original notices.

## Task 3: Integrate prepare/package/release inputs

Files: modify `scripts/media-dependencies.json`, `scripts/media_dependencies.py`, `scripts/prepare-public-build.py`, `scripts/media_release.py`; extend `scripts/test-media-dependencies.py`, `scripts/test-prepare-public-build.py`, `scripts/test-local-release.py`.

- [x] Add failing source-mode and active-library-set tests before changes.
- [x] Make mpv prepare invoke source build and verify the matching build record; keep binary-cache mode only for explicitly historical tests if required, never as runtime fallback.
- [x] Expose checked built library names/paths to package verification and release roundtrip; verify both headers and the complete closed dylib set.
- [x] Run targeted existing and new tests, inspect diff, report root any adjacent packaging files requiring synchronized changes.

## Task 4: Ship measured materials and hand off acceptance

Files: modify `Resources/ThirdParty/MPV/SOURCE-STATUS.md`, `Resources/ThirdParty/FFmpeg/SOURCE.md`, add public build records, update `Resources/ThirdParty/distribution-status.json`; add a non-GUI libmpv software-render fixture probe only after root coordinates native execution.

- [x] Export FFmpeg9 current actual source/recipe/config/license/tool evidence without user paths. Preserve its complete corresponding source and originals.
- [x] Archive every controlled mpv component's source and notices, exact mpv patch, lock, executable recipe and measured record. Regenerate manifest hashes; preserve root's WebWallGL updates on integration.
- [x] Run static closure, architecture/minimum-OS and record checks against actual new artifacts. Native codec/container loop/audio/VideoToolbox fixtures remain an explicit coordinated gate.
- [x] Send root artifact paths, hashes, source records, logs, all targeted test results and the uncommitted worktree diff for integration. Root owns final app/ZIP/public release and native GUI acceptance.

## Executed checkpoint

The actual closure is 14 shared dylibs plus statically linked Lua. dav1d, system zlib/bzlib and controlled XZ/liblzma were required to preserve software AV1 and compressed AVI/container capability. Exact Vulkan-Headers are also needed by disabled libplacebo stubs. All sources/notices are retained. Six actual product-bridge phases passed with real pixels, CoreAudio clock/output, settings, loops and native destruction. Root owns independent review, integration and release. A separate real FFmpeg9 software-AV1 transcoding failure (exit 69) is authorized for the next isolated worktree; it is not claimed fixed by this checkpoint.
