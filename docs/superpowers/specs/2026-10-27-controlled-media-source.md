# Controlled media source distribution design

The existing IINA 1.4.0 closure has 69 pinned binary files but no complete, contemporaneous Homebrew source/patch lock. Its own mpv tree has now been recovered as commit `c0dd2b32d52c66b9efa85a7ee69965569503f6b8`, exactly 18 commits ahead of v0.38.0. This does not establish the remaining binary sources. Keep the old manifest and status explicitly as historical, unproven provenance; ship newly built libraries from controlled inputs.

## Decisions proposed for root review

1. Build that exact recovered mpv commit with FFmpeg 7.0.1, libplacebo 6.338.2, libass 0.17.3, FreeType, FriBidi and HarfBuzz. Pin every source archive with SHA256, immutable upstream URL and license paths. Pin libplacebo's actual Jinja/MarkupSafe/fast_float inputs where used. Preserve all unmodified source archives, notices, mpv 18-commit patch and the executable recipe in the delivered materials.
2. Prefer shared libraries for the approximately 12-library closure. This keeps dependencies visible to Mach-O audit and individually replaceable. Use explicit disabled autodetection and no Meson wrap downloads. Dependency discovery is restricted to the build's own pkg-config directory and system SDK. It must fail when a required feature is unavailable.
3. Preserve the actual bridge contract: mpv software render API, CoreAudio, VideoToolbox-copy, local lavf demuxing, native supported codecs and bridge option names including no scripts/ytdl. Do not claim all optional IINA features survive. The app's bridge and local-format acceptance, not IINA's unrelated feature set, define parity. No GUI/native playback runs until root coordinates them.
4. Build under this worktree's `.build/media-source-complete`; use no shared mpv build/cache prefix or installed libraries. A read-only CEF source-cache symlink is allowed if needed by final build integration. Existing FFmpeg 9.0.1 tools are verified read-only and copied into an isolated candidate when packaging; their original paths are not mutated.
5. A source-build record binds lock SHA, recipes/tool versions, architecture/minimum OS, feature configuration, headers and all built dylib hashes. Reuse validates those inputs and outputs. A public material record contains normalized paths and real measured hashes, not machine-specific paths. Existing FFmpeg 9 source/recipe/tool record is exported with current measured license and config flags; do not rebuild an already verified identical input without reason.
6. Adapt existing dependency and packaging interfaces to source-produced mpv outputs, retaining the public `prepare-public-build.py mpv` entry point. `media_release.py` must read the active lock, not the historical 69-library list. Built outputs are verified separately from pinned source bytes.
7. Completeness becomes true only after real controlled build, all-source/notices hashing, closed dylib audit and root-coordinated native codec/container/audio acceptance. Bundle relocation/signing remains an explicit transformation joined to the input record by the final bundle manifest.

## Evidence

- https://api.github.com/repos/mpv-player/mpv/compare/v0.38.0...c0dd2b32d52c66b9efa85a7ee69965569503f6b8 reports ahead 18 / behind 0.
- https://raw.githubusercontent.com/iina/homebrew-mpv-iina/e2bca9b25f6250a77038d7ff77af8646fe7d6ca0/mpv-iina.rb
- https://raw.githubusercontent.com/iina/homebrew-mpv-iina/c8a6b6adcdc42fa3a910cedd62bcb4a0732174a0/ffmpeg-iina.rb
- Actual MPVBridge uses `MPV_RENDER_API_TYPE_SW`, `ao=coreaudio`, `hwdec=videotoolbox-copy` and an explicit local container/protocol whitelist.
- FFmpeg 9.0.1 current local record verifies for SDK27/clang21; measured GPL/NONFREE/VERSION3/NETWORK are zero and executable license is LGPL2.1+.

## Acceptance

Automated tests reject changed source archives, lock or recipes, output tampering, stale toolchains, missing headers/notices, unexpected dylibs, non-arm64 outputs and deployment targets above macOS14. Source/release records cover every retained material. Actual new mpv exports the expected libmpv ABI, reports the controlled version and successfully decodes each promised local fixture through the software render API, loops and accepts audio controls. Native playback is a coordinated final gate, never simulated.

## Approved execution refinements

Actual source inspection and decoder API comparisons required Lua5.2 option compatibility, dav1d software AV1, Vulkan-Headers for disabled-backend stubs, explicit system zlib/bzlib and pinned XZ/liblzma. These additions were approved by root during execution. The resulting runtime has 14 shared dylibs; Lua is static. Old 514 decoder implementations become 512: the unused alternate libspeex wrapper is replaced by the already-registered native speex decoder, and JPEG XL has no mapping in the advertised Matroska/AVI/QuickTime-in-Matroska tables. Every other canonical decoder ID is preserved. Actual software rendering/CoreAudio/VT-copy/loop/settings/AV1/ZMBV acceptance passed in six independently bounded, strictly closed phases.
